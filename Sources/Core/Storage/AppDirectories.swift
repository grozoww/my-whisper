import Foundation

/// Every path the app writes to, in one place.
///
/// The app is deliberately not sandboxed (see `OurWhisper.entitlements`), so nothing forces this
/// layout on us — which is exactly why it needs to be written down once rather than assembled
/// ad hoc at each call site. Everything the user owns lives under one directory they can find,
/// inspect and delete, because "your data stays on your machine" is only credible if you can
/// point at where.
enum AppDirectories {
    /// `~/Library/Application Support/OurWhisper` — or a throwaway directory under test.
    ///
    /// The redirect is a safety net, not a convenience. The unit tests use the app itself as their
    /// test host, so the real `AppState` is constructed on every test run; anything that reaches
    /// this property without an explicit `directory:` would read and write the settings, modes,
    /// vocabulary and history of whoever ran the suite. Stores still take a `directory:` and tests
    /// still pass one — this is what catches the time somebody forgets.
    static let support: URL = {
        let base: URL

        if isRunningTests {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OurWhisper-test-host-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else if ScreenshotMode.isActive {
            // Same reason as the test redirect: the README's pictures are seeded demo data, and a
            // screenshot run must not read — or write over — the modes, vocabulary and history of
            // whoever is taking them.
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OurWhisper-screenshots-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OurWhisper", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    /// Recorded audio, kept only when the user asks for it in History settings.
    static var recordings: URL { subdirectory("Recordings") }

    /// Local LLM weights. Separate from the speech model, which FluidAudio owns and stores under
    /// its own directory — see `ModelLibrary`.
    static var languageModels: URL { subdirectory("LanguageModels") }

    static func file(_ name: String) -> URL {
        support.appendingPathComponent(name, isDirectory: false)
    }

    private static func subdirectory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Total bytes under a directory. Used by the Models library and History to show what the app
    /// is costing in disk, which is the number people actually want before they trust a local app.
    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
