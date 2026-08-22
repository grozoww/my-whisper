import Foundation
import Testing

@testable import OurWhisper

/// The cloud path, exercised without a network or an API key — which `CONTRIBUTING.md` requires,
/// and which is the only way these tests can run on a fork's CI.
@Suite("Soniox provider")
struct SonioxProviderTests {
    private let samples = [Float](repeating: 0.1, count: 16_000)

    private func provider(_ script: [(match: String, response: StubHTTPClient.Response)], key: String? = "test-key")
        -> (SonioxProvider, StubHTTPClient)
    {
        let stub = StubHTTPClient(script: script)
        let provider = SonioxProvider(http: stub, model: "stt-async-preview", keyProvider: { key })
        return (provider, stub)
    }

    private var happyPath: [(match: String, response: StubHTTPClient.Response)] {
        [
            ("/v1/files", .json(["id": "file-1"])),
            ("/v1/transcriptions", .json(["id": "job-1", "status": "queued"])),
            ("/v1/transcriptions/job-1", .json(["status": "completed"])),
            ("/transcript", .json(["text": "  hello from the cloud  "])),
            ("/v1/files/file-1", .json([:])),
        ]
    }

    @Test("Upload, start, poll, fetch — and the text comes back trimmed")
    func completesTheHappyPath() async throws {
        let (provider, _) = provider(happyPath)
        let result = try await provider.transcribe(samples: samples, language: .english)
        #expect(result.text == "hello from the cloud")
        #expect(result.audioDuration == 1.0)
    }

    @Test("The key is sent as a bearer token and never in the URL")
    func authorizesWithABearerToken() async throws {
        let (provider, stub) = provider(happyPath)
        _ = try await provider.transcribe(samples: samples, language: .english)

        let upload = stub.request(containing: "/v1/files")
        #expect(upload?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        // A key in a query string ends up in server logs and browser history. It must only ever
        // travel in the header.
        #expect(stub.requests.allSatisfy { !($0.url?.absoluteString.contains("test-key") ?? false) })
    }

    @Test("A chosen language is sent as a hint; auto sends none")
    func sendsLanguageHints() async throws {
        let (provider, stub) = provider(happyPath)
        _ = try await provider.transcribe(samples: samples, language: .ukrainian)

        let start = stub.requests.first { $0.httpMethod == "POST" && ($0.url?.path ?? "").hasSuffix("/v1/transcriptions") }
        let body = try #require(start?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_hints"] as? [String] == ["uk"])
        #expect(json["model"] as? String == "stt-async-preview")
    }

    @Test("Auto-detect sends no hint at all")
    func omitsHintsForAuto() async throws {
        let (provider, stub) = provider(happyPath)
        _ = try await provider.transcribe(samples: samples, language: .auto)

        let start = stub.requests.first { $0.httpMethod == "POST" && ($0.url?.path ?? "").hasSuffix("/v1/transcriptions") }
        let body = try #require(start?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["language_hints"] == nil)
    }

    @Test("A token-only transcript is assembled rather than rejected")
    func assemblesTokens() async throws {
        var script = happyPath
        script[3] = ("/transcript", .json(["tokens": [["text": "hello"], ["text": " there"]]]))
        let (provider, _) = provider(script)

        let result = try await provider.transcribe(samples: samples, language: .english)
        #expect(result.text == "hello there")
    }

    @Test("A rejected key says so, rather than showing a status code")
    func mapsUnauthorized() async {
        let (provider, _) = provider([("/v1/files", .json(["error_message": "bad key"], status: 401))])

        await #expect(throws: HTTPError.self) {
            try await provider.transcribe(samples: samples, language: .english)
        }
    }

    @Test("A failed job surfaces the provider's own reason")
    func surfacesJobFailure() async {
        var script = happyPath
        script[2] = ("/v1/transcriptions/job-1", .json(["status": "error", "error_message": "audio too quiet"]))
        let (provider, _) = provider(script)

        do {
            _ = try await provider.transcribe(samples: samples, language: .english)
            Issue.record("expected the failed job to throw")
        } catch {
            #expect(error.localizedDescription.contains("audio too quiet"))
        }
    }

    @Test("Recordings shorter than the model can use are rejected before uploading")
    func rejectsTooShort() async {
        // Failing locally saves an upload, a bill, and a round trip to be told the same thing.
        let (provider, stub) = provider(happyPath)

        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(samples: [0, 0, 0], language: .english)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("With no key, nothing is sent anywhere")
    func refusesWithoutAKey() async {
        let (provider, stub) = provider(happyPath, key: nil)

        await #expect(throws: TranscriptionError.self) {
            try await provider.transcribe(samples: samples, language: .english)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("The uploaded body is a WAV file")
    func uploadsWAV() async throws {
        let (provider, stub) = provider(happyPath)
        _ = try await provider.transcribe(samples: samples, language: .english)

        let upload = try #require(stub.request(containing: "/v1/files"))
        let body = try #require(upload.httpBody)
        #expect(String(decoding: body.prefix(400), as: UTF8.self).contains("RIFF"))
        #expect(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
    }
}
