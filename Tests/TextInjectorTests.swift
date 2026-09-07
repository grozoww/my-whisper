import AppKit
import ApplicationServices
import Testing

@testable import OurWhisper

/// The one decision in `TextInjector` that costs the user something when it is wrong.
///
/// Skipping the clipboard restore is how a dictation that had nowhere to land survives, and it is
/// also how a clipboard gets eaten. It used to be spent on any answer that was not a clear yes —
/// including "Accessibility did not reply", which is what a busy Chrome, an Electron app still
/// building its tree, or an element rebuilt during transcription all look like. These are the
/// cases that must not spend it.
@MainActor
@Suite("Nowhere to paste")
struct TextInjectorAcceptanceTests {
    @Test("A frontmost app with nothing focused is a real no")
    func nothingFocusedRefuses() {
        // The case the whole check exists for: a Finder window, a PDF in Preview, an empty
        // desktop. `kAXErrorNoValue` is the app answering, not failing.
        let verdict = TextInjector.acceptance(focus: .noValue, belongsToTarget: false, settable: nil, role: nil)
        #expect(verdict == .refuses)
    }

    @Test("An Accessibility call that failed is not a no")
    func aFailedQueryIsUnknown() {
        // The bug. Every one of these used to arrive as the same answer as an empty desktop, and
        // the app spent the user's clipboard on it while the paste visibly worked.
        for failure in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .notImplemented] {
            #expect(TextInjector.acceptance(focus: failure, belongsToTarget: true, settable: nil, role: nil) == .unknown)
        }
    }

    @Test("An element belonging to another app is not evidence about this one")
    func aBorrowedElementIsUnknown() {
        // `activate()` is asynchronous, so system-wide focus can still belong to whatever the user
        // switched to while we transcribed.
        let verdict = TextInjector.acceptance(
            focus: .success,
            belongsToTarget: false,
            settable: true,
            role: "AXTextField"
        )
        #expect(verdict == .unknown)
    }

    @Test("A settable selection is a yes on its own")
    func settableAccepts() {
        let verdict = TextInjector.acceptance(focus: .success, belongsToTarget: true, settable: true, role: nil)
        #expect(verdict == .accepts)
    }

    @Test("An Open panel's answer counts as the app that opened it")
    func embeddedServicesCountAsTheTarget() {
        // macOS vends the focused element from a process that is not the app: an Open or Save panel
        // from openAndSavePanelService, web content from WebKit.WebContent, share sheets from their
        // own remote view services. Measured on macOS 26: those are `.prohibited` and `.accessory`;
        // Finder, Chrome and any real app are `.regular`. Treating the panel as "some other app"
        // demotes a real refusal to `.unknown`, and the restore then wipes out a dictation the
        // panel swallowed — the Finder regression, one layer in.
        #expect(TextInjector.belongs(owner: 500, to: 100, ownerPolicy: .prohibited))
        #expect(TextInjector.belongs(owner: 500, to: 100, ownerPolicy: .accessory))
        // A pid with no application behind it is a service too.
        #expect(TextInjector.belongs(owner: 500, to: 100, ownerPolicy: nil))

        // A real app the user switched to while we transcribed is not evidence about the target.
        #expect(!TextInjector.belongs(owner: 500, to: 100, ownerPolicy: .regular))

        #expect(TextInjector.belongs(owner: 100, to: 100, ownerPolicy: .regular))
        #expect(!TextInjector.belongs(owner: nil, to: 100, ownerPolicy: nil))
    }

    @Test("A role that answered decides it either way")
    func theRoleDecides() {
        // Named literally rather than by iterating `textRoles`: a loop over the set under test
        // asserts `textRoles.contains(x)` for every `x` in `textRoles`, which is true whatever the
        // set holds — including after someone deletes the entry below.
        func accepts(_ role: String) -> Bool {
            TextInjector.acceptance(focus: .success, belongsToTarget: true, settable: false, role: role) == .accepts
        }

        // Chromium and Electron hand out one `AXWebArea` for a whole page rather than an element
        // per input, so dropping this breaks dictation in every browser and every Electron app.
        #expect(accepts("AXWebArea"))

        #expect(accepts("AXTextField"))
        #expect(accepts("AXTextArea"))
        #expect(accepts("AXComboBox"))
        #expect(!accepts("AXOutline"))
    }

    @Test("A role that did not answer is not evidence at all")
    func anUnansweredRoleIsUnknown() {
        let verdict = TextInjector.acceptance(focus: .success, belongsToTarget: true, settable: nil, role: nil)
        #expect(verdict == .unknown)
    }
}
