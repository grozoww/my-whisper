import Foundation
import Testing

@testable import OurWhisper

@Suite("Schema evolution")
struct SchemaEvolutionTests {
    /// The guarantee: a settings, modes or vocabulary file written by *any* version of the app
    /// loads. Swift's synthesized `Codable` does not give this for free — it throws on a missing
    /// key — and a throw here means `JSONFileStore` quarantines the file and the user's
    /// configuration silently reverts.
    @Test("A settings section with only some keys keeps its values and defaults the rest")
    func partialSectionDecodes() throws {
        let json = #"{"dictation":{"language":"ru"},"sound":{"feedbackVolume":0.25}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.dictation.language == .russian)
        #expect(settings.dictation.provider == .parakeet)      // defaulted
        #expect(settings.sound.feedbackVolume == 0.25)
        #expect(settings.sound.playFeedbackSounds == true)     // defaulted
        #expect(settings.history.retention == .days30)         // whole section defaulted
    }

    @Test("A key from a newer version is ignored rather than fatal")
    func unknownKeysAreIgnored() throws {
        let json = #"{"dictation":{"language":"de","somethingFromTheFuture":42},"aWholeNewSection":{}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.dictation.language == .german)
    }

    @Test("A value of the wrong type costs that setting, not the file")
    func wrongTypesFallBack() throws {
        let json = #"{"history":{"retention":30,"isEnabled":false}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.history.retention == .days30)  // the bad value fell back
        #expect(settings.history.isEnabled == false)    // the good one survived
    }

    @Test("A mode missing a field it gained later still loads")
    func modeDecodesWithoutNewFields() throws {
        let json = #"{"id":"00000000-0000-0000-0000-00000000A001","name":"Legacy","symbol":"star","instructions":"x"}"#
        let mode = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))

        #expect(mode.name == "Legacy")
        #expect(mode.appBundleIDs.isEmpty)
        #expect(mode.cleanup.removeFillers)  // defaulted from the current CleanupOptions
    }

    @Test("A history entry missing later fields still loads")
    func historyEntryDecodesWithoutNewFields() throws {
        let json = #"{"rawText":"a","finalText":"a","providerID":"parakeet","language":"en","audioDuration":1,"processingTime":0.1}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))

        #expect(entry.finalText == "a")
        #expect(entry.usedModel == false)
        #expect(entry.audioFileName == nil)
    }

    @Test("A vocabulary entry missing later fields still loads")
    func vocabularyEntryDecodesWithoutNewFields() throws {
        let entry = try JSONDecoder().decode(VocabularyEntry.self, from: Data(#"{"term":"Kruhlov"}"#.utf8))
        #expect(entry.term == "Kruhlov")
        #expect(entry.isEnabled)
    }
}

@Suite("On-device model output guard")
struct OnDeviceRefinerGuardTests {
    /// A small model asked to clean text sometimes answers it, apologises, or returns nothing.
    /// The guard is what stops any of those from being pasted into the user's document.
    @Test("A plausible cleanup is accepted")
    func acceptsPlausibleOutput() {
        let original = "so um i think we should ship it on tuesday"
        let cleaned = OnDeviceRefiner.sanityChecked("I think we should ship it on Tuesday.", against: original)
        #expect(cleaned == "I think we should ship it on Tuesday.")
    }

    @Test("Empty output is rejected")
    func rejectsEmptyOutput() {
        #expect(OnDeviceRefiner.sanityChecked("   \n  ", against: "a reasonably long sentence here") == nil)
    }

    @Test("An answer instead of a cleanup is rejected")
    func rejectsRunawayOutput() {
        let original = "what is the capital of France"
        let answer = String(repeating: "The capital of France is Paris, a city with a long history. ", count: 6)
        #expect(OnDeviceRefiner.sanityChecked(answer, against: original) == nil)
    }

    @Test("Output that dropped most of the input is rejected")
    func rejectsTruncatedOutput() {
        let original = "please remind me to call the dentist about the appointment on Thursday morning"
        #expect(OnDeviceRefiner.sanityChecked("ok", against: original) == nil)
    }

    @Test("Short utterances are exempt from the length check")
    func allowsShortUtterancesToGrow() {
        // "yes" legitimately becomes "Yes." — a 33% jump that the ratio check would otherwise
        // reject on three characters.
        #expect(OnDeviceRefiner.sanityChecked("Yes.", against: "yes") == "Yes.")
    }

    @Test("Echoed prompt delimiters are stripped")
    func stripsDelimiters() {
        let original = "hello there friend how are you"
        let cleaned = OnDeviceRefiner.sanityChecked("<<<TRANSCRIPT Hello there, friend. TRANSCRIPT>>>", against: original)
        #expect(cleaned == "Hello there, friend.")
    }
}

@Suite("Engine routing")
@MainActor
struct TranscriptionRouterTests {
    @Test("A cloud-only language does not upload unless the user turned it on")
    func refusesImplicitUpload() {
        // The rule the whole privacy story rests on: choosing Japanese must not quietly start
        // sending audio to a third party.
        let router = TranscriptionRouter()
        var settings = DictationSettings()
        settings.language = .japanese
        settings.allowCloudFallback = false

        #expect(throws: TranscriptionRouter.RoutingError.self) {
            _ = try router.provider(for: settings)
        }
    }

    @Test("The error names the switch the user has to flip")
    func explainsHowToFixIt() {
        let router = TranscriptionRouter()
        var settings = DictationSettings()
        settings.language = .chinese
        settings.allowCloudFallback = false

        do {
            _ = try router.provider(for: settings)
            Issue.record("expected the cloud-disabled route to throw")
        } catch {
            #expect(error.localizedDescription.contains("Configuration"))
        }
    }

    @Test("A local language routes offline")
    func routesLocalLanguagesOffline() throws {
        let router = TranscriptionRouter()
        var settings = DictationSettings()
        settings.language = .ukrainian
        settings.provider = .parakeet

        let provider = try router.provider(for: settings)
        #expect(provider.id == .parakeet)
    }

    @Test("The planned engine reflects what the language forces")
    func reportsPlannedEngine() {
        let router = TranscriptionRouter()
        var settings = DictationSettings()

        settings.language = .english
        settings.provider = .parakeet
        #expect(router.plannedProviderID(for: settings) == .parakeet)

        settings.language = .chinese
        #expect(router.plannedProviderID(for: settings) == .soniox)
    }
}

@Suite("Language coverage")
struct SpeechLanguageTests {
    @Test("Only Chinese and Japanese need the cloud")
    func marksCloudOnlyLanguages() {
        for language in SpeechLanguage.allCases {
            let expected = language == .chinese || language == .japanese
            #expect(language.isLocal == !expected, "\(language.rawValue)")
        }
    }

    @Test("Auto-detect sends no hint")
    func autoSendsNoHint() {
        #expect(SpeechLanguage.auto.hints.isEmpty)
        #expect(SpeechLanguage.polish.hints == ["pl"])
    }
}

@Suite("Hotkey chords")
struct HotkeyChordTests {
    @Test("An unbound chord is empty")
    func recognisesEmpty() {
        #expect(HotkeyChord(modifiers: []).isEmpty)
        #expect(!HotkeyChord.hyper.isEmpty)
        #expect(!HotkeyChord.fn.isEmpty)
        #expect(!HotkeyChord(keyCode: 49, modifiers: []).isEmpty)
    }

    @Test("fn is a modifier-only chord that displays as fn")
    func describesFn() {
        #expect(HotkeyChord.fn.isModifierOnly)
        #expect(HotkeyChord.fn.displayGlyphs == ["fn"])
    }

    @Test("A chord matches only its exact modifier set")
    func matchesExactly() {
        // Holding ⌘ as well as fn must not fire the fn binding, or every ⌘-shortcut in the system
        // would start a recording.
        #expect(HotkeyChord.fn.isSatisfied(by: .maskSecondaryFn))
        #expect(!HotkeyChord.fn.isSatisfied(by: [.maskSecondaryFn, .maskCommand]))
        #expect(!HotkeyChord.fn.isSatisfied(by: []))
    }

    @Test("Irrelevant flags are ignored")
    func ignoresNoiseFlags() {
        // Caps lock and the numeric-pad bit ride along on ordinary events; comparing them would
        // make a shortcut stop working the moment caps lock was on.
        #expect(HotkeyChord.hyper.isSatisfied(by: [
            .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskAlphaShift, .maskNumericPad,
        ]))
    }

    @Test("Hold-to-talk defaults to fn")
    func defaultsToFn() {
        #expect(DictationSettings().pushToTalkChord == .fn)
    }

    @Test("A settings file written before hold-to-talk existed picks up the new default")
    func upgradeGetsTheNewDefault() throws {
        // The field is optional, so `decodeIfPresent` alone would read "absent" as "unbound" and
        // an upgrading user would find the feature switched off with no way to know why.
        let json = #"{"dictation":{"language":"en","toggleChord":{"modifierBits":1966080}}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.dictation.pushToTalkChord == .fn)
    }

    @Test("Deliberately clearing hold-to-talk survives a round trip")
    func unbindingSurvives() throws {
        // The other half: an explicit null must stay null, or the app would keep re-binding a key
        // the user went out of their way to clear.
        let json = #"{"dictation":{"pushToTalkChord":null}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.dictation.pushToTalkChord == nil)
    }
}
