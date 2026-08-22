import Foundation

/// The seam between the app and the network.
///
/// `CONTRIBUTING.md` requires that nothing in the build, the tests or CI needs an API key, and
/// that cloud providers are tested against recorded fixtures. That is only possible if the thing
/// making the request can be swapped, so every provider takes one of these rather than reaching
/// for `URLSession.shared` directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP
        }
        return (data, http)
    }
}

enum HTTPError: LocalizedError {
    case notHTTP
    case unauthorized
    case rateLimited
    case status(Int, String?)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            "The server sent a response that was not HTTP."
        case .unauthorized:
            "The API key was rejected. Check it in Configuration."
        case .rateLimited:
            "The provider is rate-limiting this key. Try again shortly."
        case .status(let code, let detail):
            detail.map { "The provider returned \(code): \($0)" } ?? "The provider returned \(code)."
        case .malformedResponse(let detail):
            "Could not read the provider's response: \(detail)"
        }
    }

    /// Maps a status code to the error the user should see. 401 and 429 get their own cases
    /// because they are the two the user can actually do something about.
    static func from(status: Int, body: Data) -> HTTPError {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        default: .status(status, message(in: body))
        }
    }

    /// Providers put their human-readable reason in different places. Pulling out whichever is
    /// present beats showing the user a raw JSON blob.
    private static func message(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        for key in ["error_message", "message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
