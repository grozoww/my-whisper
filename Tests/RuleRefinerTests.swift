import Testing

@testable import OurWhisper

/// The rules run on every dictation, including the ones where no model is involved. They are pure
/// functions, so they get the closest thing this app has to exhaustive coverage.
@Suite("Rule-based cleanup")
struct RuleRefinerTests {
    private func refiner(
        _ options: CleanupOptions = CleanupOptions(),
        vocabulary: [VocabularyEntry] = [],
        language: SpeechLanguage = .auto
    ) -> RuleRefiner {
        RuleRefiner(options: options, vocabulary: vocabulary, language: language)
    }

    // MARK: - Fillers

    @Test("Standalone fillers are removed")
    func removesFillers() {
        let result = refiner().refine("So um I think uh we should ship it")
        #expect(!result.lowercased().contains(" um "))
        #expect(!result.lowercased().contains(" uh "))
        #expect(result.contains("we should ship it"))
    }

    @Test("A filler spelling inside a real word is left alone")
    func doesNotEatRealWords() {
        // "um" appears inside "umbrella" and "erm" inside "germ". A naive substring replace
        // silently mangles both, and the user never finds out why.
        let result = refiner().refine("the umbrella has a germ on it")
        #expect(result.lowercased().contains("umbrella"))
        #expect(result.lowercased().contains("germ"))
    }

    @Test("Russian fillers are removed without touching the surrounding Cyrillic")
    func removesRussianFillers() {
        // The real reason word boundaries here are hand-rolled: `\b` is ASCII-only, so it matches
        // inside Cyrillic and would cut this sentence apart.
        let result = refiner(language: .russian).refine("Ну давай отправим это завтра")
        // Sentence case then capitalises what is now the first word, which is the correct result.
        #expect(result == "Давай отправим это завтра")
    }

    // MARK: - Self-corrections

    @Test("A spoken correction keeps only the correction")
    func resolvesSelfCorrection() {
        // The example from the README.
        let result = refiner().refine("send it Tuesday, no, Wednesday")
        #expect(result.contains("Wednesday"))
        #expect(!result.contains("Tuesday"))
    }

    @Test("\"I mean\" works as a correction marker too")
    func resolvesIMean() {
        let result = refiner().refine("meet me at four I mean five")
        #expect(result.contains("five"))
        #expect(!result.contains("four"))
    }

    // MARK: - Spoken punctuation

    @Test("Saying a mark types the mark, attached to the previous word")
    func appliesSpokenPunctuation() {
        let result = refiner().refine("hello comma world period")
        #expect(result == "Hello, world.")
    }

    @Test("\"new paragraph\" beats \"new line\"")
    func prefersLongerPunctuationPhrase() {
        // "new line" is a substring of nothing here, but the phrase table is ordered longest-first
        // so that "new paragraph" cannot be half-consumed.
        let result = refiner().refine("first new paragraph second")
        #expect(result.contains("\n\n"))
    }

    @Test("Punctuation words are left alone when the rule is off")
    func respectsPunctuationToggle() {
        var options = CleanupOptions()
        options.spokenPunctuation = false
        let result = refiner(options).refine("hello comma world")
        #expect(result.contains("comma"))
    }

    // MARK: - Casing

    @Test("Sentence case capitalises, and never lowercases")
    func appliesSentenceCase() {
        // Acronyms and identifiers must survive. A rule that normalised case would break the Code
        // mode's entire reason for existing.
        let result = refiner().refine("the API returned JSON. it was fine")
        #expect(result.hasPrefix("The"))
        #expect(result.contains("API"))
        #expect(result.contains("JSON"))
        #expect(result.contains("It was fine"))
    }

    // MARK: - Vocabulary

    @Test("Vocabulary replaces a misheard spelling")
    func appliesVocabulary() {
        let entry = VocabularyEntry(term: "Kruhlov", soundsLike: ["Kruglov", "crew glove"])
        let result = refiner(vocabulary: [entry]).refine("ask crew glove about it")
        #expect(result.contains("Kruhlov"))
        #expect(!result.lowercased().contains("crew glove"))
    }

    @Test("Vocabulary matches on word boundaries only")
    func vocabularyDoesNotMatchMidWord() {
        let entry = VocabularyEntry(term: "Ana", soundsLike: ["ana"])
        let result = refiner(vocabulary: [entry]).refine("I ate a banana")
        #expect(result.contains("banana"))
    }

    @Test("A disabled entry does nothing")
    func skipsDisabledVocabulary() {
        var entry = VocabularyEntry(term: "Kruhlov", soundsLike: ["Kruglov"])
        entry.isEnabled = false
        let result = refiner(vocabulary: [entry]).refine("ask Kruglov")
        #expect(result.contains("Kruglov"))
    }

    @Test("A term containing a regex template escape is inserted literally")
    func escapesReplacementTemplate() {
        // "$1" in a replacement template means "capture group 1". Unescaped, this entry would
        // insert the empty string instead of the term the user typed.
        let entry = VocabularyEntry(term: "$1.99", soundsLike: ["a dollar ninety nine"])
        let result = refiner(vocabulary: [entry]).refine("it costs a dollar ninety nine")
        #expect(result.contains("$1.99"))
    }

    // MARK: - Whitespace

    @Test("Double spaces collapse and marks lose the space before them")
    func tidiesWhitespace() {
        let result = refiner().refine("hello   world , again")
        #expect(!result.contains("  "))
        #expect(result.contains("world, again"))
    }

    @Test("Decimals survive punctuation spacing")
    func doesNotBreakDecimals() {
        // The "space after a mark" rule must not fire between the digits of 3.14.
        let result = refiner().refine("pi is 3.14 exactly")
        #expect(result.contains("3.14"))
    }

    // MARK: - Options

    @Test("The empty option set changes nothing but trailing whitespace")
    func noneIsIdentity() {
        let raw = "  um so ,  hello comma world  "
        let result = refiner(.none).refine(raw)
        #expect(result == raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("Cleanup is idempotent")
    func isIdempotent() {
        // Running cleanup twice must not keep changing the text — the pipeline re-applies the
        // vocabulary rule after the model, so a non-idempotent rule set would drift.
        let once = refiner().refine("So um hello comma world period")
        let twice = refiner().refine(once)
        #expect(once == twice)
    }
}
