import Foundation

/// The deterministic half of cleanup: no model, no network, no waiting.
///
/// Everything here is a pure function of its input. That is the point — these rules run on every
/// dictation including the ones where the model is off or unavailable, so they have to be fast,
/// predictable, and safe enough to leave on by default. Anything that needs judgement belongs in
/// `OnDeviceRefiner` instead.
///
/// Order is not arbitrary and is documented at each step below.
struct RuleRefiner: Sendable {
    var options: CleanupOptions
    var vocabulary: [VocabularyEntry] = []
    var language: SpeechLanguage = .auto

    func refine(_ text: String) -> String {
        var result = text

        // Vocabulary first: it fixes proper nouns, and every later rule — sentence casing above
        // all — should see the correct spelling rather than the mis-transcription.
        if options.applyVocabulary { result = applyVocabulary(to: result) }

        // Before filler removal, so "period" becomes "." while the sentence structure that tells
        // us which "so" is filler is still intact.
        if options.spokenPunctuation { result = applySpokenPunctuation(to: result) }

        if options.removeFillers { result = removeFillers(from: result) }

        // After filler removal: "send it Tuesday, um, no, Wednesday" only matches the correction
        // pattern once the "um" is gone.
        if options.resolveSelfCorrections { result = resolveSelfCorrections(in: result) }

        // Whitespace last but one, to clean up the gaps every rule above leaves behind.
        if options.tidyWhitespace { result = tidyWhitespace(in: result) }

        // Casing genuinely last: it needs final sentence boundaries.
        if options.sentenceCase { result = applySentenceCase(to: result) }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Vocabulary

    private func applyVocabulary(to text: String) -> String {
        var result = text
        for entry in vocabulary where entry.isEnabled {
            for pattern in entry.patterns {
                guard let regex = Self.cachedWordRegex(for: pattern) else { continue }
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    // The replacement is user text, so it must be escaped: a term containing "$1"
                    // would otherwise be read as a capture-group reference.
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.term)
                )
            }
        }
        return result
    }

    // MARK: - Spoken punctuation

    /// Saying the name of a mark types the mark. Only whole words match, so dictating the sentence
    /// "the comma is overused" does not turn into "the , is overused".
    private func applySpokenPunctuation(to text: String) -> String {
        var result = text

        for (phrase, mark) in Self.punctuationPhrases(for: language) {
            guard let regex = Self.cachedWordRegex(for: phrase) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: mark)
            )
        }

        // The replacements leave "word , word". Pulling the mark back onto the previous word is
        // what makes the result look typed rather than assembled.
        result = Self.replace(#"[ \t]+([,.!?;:])"#, in: result, with: "$1")
        // Strips spaces hugging a line break without touching the break itself. `\s` would
        // include the newline, so `\s*\n\s*` eats a paragraph break down to a single line break
        // — which silently undoes "new paragraph".
        result = Self.replace(#"[ \t]*\n[ \t]*"#, in: result, with: "\n")
        return result
    }

    // MARK: - Fillers

    /// Removes filler words when they stand alone.
    ///
    /// The list is short on purpose. "like" and "so" are filler most of the time and load-bearing
    /// the rest of the time, and a rule that silently eats a real word is worse than one that
    /// leaves an "um" in.
    private func removeFillers(from text: String) -> String {
        var result = text
        for filler in Self.fillers(for: language) {
            guard let regex = Self.cachedWordRegex(for: filler) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        // Filler removal leaves ", ," and " ." behind wherever the filler sat between marks.
        result = Self.replace(#"([,;])(\s*[,;])+"#, in: result, with: "$1")
        result = Self.replace(#"(?m)^\s*[,;]\s*"#, in: result, with: "")
        return result
    }

    // MARK: - Self-corrections

    /// "send it Tuesday, no, Wednesday" becomes "send it Wednesday".
    ///
    /// Scoped to a single word on each side. Correcting a whole clause is a judgement call about
    /// where the correction starts, and getting that wrong deletes something the user said — so
    /// clause-level corrections are left to the model.
    private func resolveSelfCorrections(in text: String) -> String {
        var result = text
        for marker in Self.correctionMarkers(for: language) {
            let pattern = #"(\S+)\s*,?\s+"# + NSRegularExpression.escapedPattern(for: marker) + #"\s*,?\s+(\S+)"#
            result = Self.replace(pattern, in: result, with: "$2", options: [.caseInsensitive])
        }
        return result
    }

    // MARK: - Whitespace and casing

    private func tidyWhitespace(in text: String) -> String {
        var result = text
        result = Self.replace(#"[ \t]+"#, in: result, with: " ")
        result = Self.replace(#" ?\n ?"#, in: result, with: "\n")
        result = Self.replace(#"\n{3,}"#, in: result, with: "\n\n")
        result = Self.replace(#"\s+([,.!?;:])"#, in: result, with: "$1")
        // A mark needs a space after it, unless it ends the text or a decimal follows.
        result = Self.replace(#"([,.!?;:])(?=[^\s\d.,!?;:])"#, in: result, with: "$1 ")
        return result
    }

    /// Capitalises the first letter of the text and of anything following `.`, `!`, `?` or a line
    /// break. Only ever raises case — lowering it would destroy acronyms and the identifiers the
    /// Code mode exists to protect.
    private func applySentenceCase(to text: String) -> String {
        var characters = Array(text)
        var capitaliseNext = true

        for index in characters.indices {
            let character = characters[index]

            if capitaliseNext, character.isLetter {
                let upper = String(character).uppercased()
                if upper.count == 1, let first = upper.first {
                    characters[index] = first
                }
                capitaliseNext = false
                continue
            }

            if character == "." || character == "!" || character == "?" || character == "\n" {
                capitaliseNext = true
            }
        }

        return String(characters)
    }

    // MARK: - Language data

    /// Fillers by language. Only languages with a list get filler removal; the rest fall through
    /// to English, which is a no-op on text that contains none of these words.
    static func fillers(for language: SpeechLanguage) -> [String] {
        switch language {
        case .russian:
            ["ну", "эм", "мм", "как бы", "типа", "короче", "это самое"]
        case .ukrainian:
            ["ну", "ем", "мм", "як би", "типу", "коротше"]
        case .german:
            ["äh", "ähm", "hm", "also ja"]
        case .spanish:
            ["eh", "este", "o sea"]
        case .french:
            ["euh", "ben", "bah"]
        default:
            ["um", "uh", "erm", "hmm", "mm", "mhm", "uhh", "umm", "er"]
        }
    }

    static func correctionMarkers(for language: SpeechLanguage) -> [String] {
        switch language {
        case .russian: ["нет", "точнее", "вернее"]
        case .ukrainian: ["ні", "точніше"]
        default: ["no", "sorry", "I mean", "rather", "scratch that"]
        }
    }

    static func punctuationPhrases(for language: SpeechLanguage) -> [(String, String)] {
        switch language {
        case .russian:
            [("запятая", ","), ("точка", "."), ("вопросительный знак", "?"),
             ("восклицательный знак", "!"), ("двоеточие", ":"), ("новая строка", "\n"),
             ("новый абзац", "\n\n")]
        case .ukrainian:
            [("кома", ","), ("крапка", "."), ("знак питання", "?"),
             ("знак оклику", "!"), ("двокрапка", ":"), ("новий рядок", "\n"),
             ("новий абзац", "\n\n")]
        default:
            // Longest phrases first, so "new paragraph" is not consumed by "new line".
            [("new paragraph", "\n\n"), ("new line", "\n"), ("question mark", "?"),
             ("exclamation mark", "!"), ("exclamation point", "!"), ("open parenthesis", "("),
             ("close parenthesis", ")"), ("full stop", "."), ("semicolon", ";"),
             ("comma", ","), ("period", "."), ("colon", ":"), ("dash", "—")]
        }
    }

    // MARK: - Regex helpers

    /// Compiling a regex is not cheap and these run on every dictation, so the compiled objects
    /// are kept. Word boundaries are hand-rolled rather than `\b`: `\b` is defined on ASCII word
    /// characters, so it fires in the middle of Cyrillic text and would corrupt Russian and
    /// Ukrainian — the two languages this app was built for.
    private static let regexCache = RegexCache()

    static func cachedWordRegex(for phrase: String) -> NSRegularExpression? {
        regexCache.wordRegex(for: phrase)
    }

    private static func replace(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = regexCache.regex(pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}

/// Compiled regexes, shared across dictations.
///
/// `NSRegularExpression` is documented as thread-safe once built; the lock guards only the
/// dictionary. `@unchecked` is honest about that being the argument rather than a compiler proof.
private final class RegexCache: @unchecked Sendable {
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let built = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = built
        return built
    }

    /// A whole-word match that works in any script.
    ///
    /// `(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])` says "not preceded or followed by a letter or digit"
    /// in Unicode terms, which is what `\b` only manages for ASCII.
    func wordRegex(for phrase: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return regex(#"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#, options: [.caseInsensitive])
    }
}
