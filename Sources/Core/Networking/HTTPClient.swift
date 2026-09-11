import Foundation

/// The seam between the app and the network.
///
/// `CONTRIBUTING.md` requires that nothing in the build, the tests or CI needs an API key, and
/// that cloud providers are tested against recorded fixtures. That is only possible if the thing
/// making the request can be swapped, so every provider takes one of these rather than reaching
/// for `URLSession.shared` directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Writes a large body straight to disk, reporting the bytes written so far.
    ///
    /// Separate from `send` because the one caller is fetching a 12 MB disk image: holding that in
    /// memory to show a progress bar would be the wrong trade twice over. Declared here rather
    /// than only in an extension so `URLSessionHTTPClient`'s streaming version is the one that
    /// runs when the call goes through `any HTTPClient` — an extension-only method is chosen at
    /// compile time and the default below would win.
    ///
    /// Bytes and not a fraction, because the caller knows the total and this does not: GitHub
    /// serves the image from a redirect, and a response without a `Content-Length` would leave a
    /// fraction pinned at zero for the whole download and then jump to one. The release's own
    /// `assets[].size` is the honest denominator.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse
}

extension HTTPClient {
    /// Enough for anything answering from memory, which is what the tests do. Adding the
    /// requirement above without this would have meant editing `StubHTTPClient` and every
    /// recorded-response test for a method they do not use.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse {
        let (data, response) = try await send(request)
        try data.write(to: destination, options: .atomic)
        progress(Int64(data.count))
        return response
    }
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

    /// Streams the body to `destination`, appending as it arrives.
    ///
    /// `bytes(for:)` rather than `download(for:delegate:)`: the delegate form delivers no
    /// `didWriteData` callbacks at all on a shared, default or ephemeral session, so the progress
    /// bar sits at zero for the whole download while everything else works.
    ///
    /// Buffered into `[UInt8]` and not `Data`, because appending a byte at a time to `Data` costs
    /// about half a second of CPU over 12 MB against four hundredths for an array, for identical
    /// bytes out.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse {
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.from(status: http.statusCode, body: Data())
        }

        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer: [UInt8] = []
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count == 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(written)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress(written)
        return http
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
