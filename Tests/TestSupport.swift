import Foundation
import Testing

@testable import OurWhisper

/// A directory that deletes itself.
///
/// Every store in this app writes JSON to Application Support. A test that used the default
/// location would read and destroy the settings, modes, vocabulary and history of whoever ran the
/// suite — so no test constructs a store without one of these.
final class TemporaryDirectory {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ourwhisper-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// An `HTTPClient` that answers from a script instead of the network.
///
/// `CONTRIBUTING.md` forbids anything in the build, the tests or CI needing an API key. This is how
/// the cloud provider is tested anyway: the responses are recorded shapes, the requests are
/// captured so the test can assert on what would have been sent.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data

        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }

        static func text(_ string: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(string.utf8))
        }
    }

    /// Matched against the request path in order; the first match wins and is consumed, so a
    /// polling loop can be scripted as "in progress, in progress, done".
    private var script: [(match: String, response: Response)]
    private let lock = NSLock()

    private(set) var requests: [URLRequest] = []

    init(script: [(match: String, response: Response)]) {
        self.script = script
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try take(for: request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response.body, http)
    }

    /// Locking is kept out of `send` so it never spans an `await`. `NSLock` is unavailable from an
    /// async context precisely because holding one across a suspension can deadlock.
    private func take(for request: URLRequest) throws -> Response {
        lock.lock()
        defer { lock.unlock() }

        requests.append(request)

        let path = request.url?.path ?? ""
        guard let index = script.firstIndex(where: { path.contains($0.match) }) else {
            throw HTTPError.malformedResponse("no stubbed response for \(path)")
        }
        return script.remove(at: index).response
    }

    func request(containing path: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first { ($0.url?.path ?? "").contains(path) }
    }
}
