import Foundation
import Observation
import OSLog

/// Asks GitHub whether there is a newer release.
///
/// This is the *only* outbound request the app makes without the user starting a dictation, and
/// `README.md` promises it is not telemetry. That promise is kept by what is not here: no
/// identifier, no version reported to the server, no analytics endpoint. It is an unauthenticated
/// GET of a public JSON file — the same request `curl` would make — and the comparison happens on
/// this machine. Turning it off in Configuration means the app makes no unattended requests at all.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case failed(String)
    }

    struct Release: Equatable, Sendable {
        let version: String
        let title: String
        let notes: String
        let url: URL
        let publishedAt: Date?
    }

    /// The list of releases, newest first — deliberately *not* `/releases/latest`.
    ///
    /// That endpoint only ever answers with a release GitHub itself considers the latest, which
    /// means it skips prereleases. There is no Apple Developer account behind this project, so
    /// every build published before a version tag is cut is marked a prerelease — and the endpoint
    /// therefore answered 404, which this type reads as "up to date". The check was silently
    /// finding nothing, for ever. `scripts/install.sh` reads this same list for the same reason.
    ///
    /// No query string, so the request stays something anyone can verify says nothing about them —
    /// see `sendsNothingIdentifying`. GitHub's default page of 30 is far more than enough.
    private static let endpoint = URL(string: "https://api.github.com/repos/grozoww/my-whisper/releases")!

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "update")
    private let http: any HTTPClient

    private(set) var state: State = .idle

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Dismisses the current banner. Separate from `check` so the UI does not need write access to
    /// `state`, which only this type is allowed to set.
    func dismissAvailableRelease() {
        guard case .available = state else { return }
        state = .upToDate(checkedAt: Date())
    }

    /// Checks now. `skippedVersion` is honoured so a release the user dismissed does not come back
    /// on every launch — they can still find it with the manual button, which passes `force`.
    @discardableResult
    func check(skippedVersion: String? = nil, force: Bool = false) async -> State {
        state = .checking

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await http.send(request)

            // GitHub answers 404 when a repository has no published releases at all. That is the
            // normal state before the first release, not a failure, and showing the user "404 Not
            // Found" for it would be alarming and wrong.
            if response.statusCode == 404 {
                state = .upToDate(checkedAt: Date())
                return state
            }

            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError.from(status: response.statusCode, body: data)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                throw HTTPError.malformedResponse("the releases list was not JSON")
            }

            // A readable list with nothing finished in it is an ordinary state — every release so
            // far is a prerelease — and not the same thing as a response we could not read. Only
            // the latter is worth telling the user about.
            guard let release = Self.newestFinishedRelease(in: json) else {
                state = .upToDate(checkedAt: Date())
                log.info("Update check: no finished release published yet")
                return state
            }

            let isNewer = Self.isVersion(release.version, newerThan: Self.currentVersion)
            let wasSkipped = !force && release.version == skippedVersion

            state = (isNewer && !wasSkipped) ? .available(release) : .upToDate(checkedAt: Date())
            log.info("Update check: latest \(release.version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }

        return state
    }

    // MARK: - Parsing
    //
    // Parsing and version comparison are pure functions of their input, so they are `nonisolated`
    // — the surrounding type is `@MainActor` for its observable state, and there is no reason for
    // a string comparison to need the main thread to run or a test to reach it.

    /// Takes either the releases list or a single release object, so the same parsing covers the
    /// list endpoint above and a hand-fetched release.
    nonisolated static func parse(_ data: Data) -> Release? {
        (try? JSONSerialization.jsonObject(with: data)).flatMap(newestFinishedRelease(in:))
    }

    /// The first release in the list that is finished — GitHub returns them newest first, so the
    /// first one that qualifies is the newest one on offer.
    nonisolated static func newestFinishedRelease(in json: Any) -> Release? {
        if let list = json as? [[String: Any]] {
            return list.lazy.compactMap(release(from:)).first
        }
        return (json as? [String: Any]).flatMap(release(from:))
    }

    nonisolated private static func release(from json: [String: Any]) -> Release? {
        guard let tag = json["tag_name"] as? String,
              let urlString = json["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }

        // Drafts and pre-releases are not offered. Someone running the shipped app should not be
        // nudged onto a build the maintainer has not finished.
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }

        let published = (json["published_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        return Release(
            version: normalise(tag),
            title: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: json["body"] as? String ?? "",
            url: url,
            publishedAt: published
        )
    }

    /// Strips a leading `v` and anything after the numbers, so `v1.2.3` and `1.2.3` compare equal.
    nonisolated static func normalise(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    /// Numeric component-wise comparison.
    ///
    /// Not a string compare: `"0.10.0" < "0.9.0"` lexically, which would tell everyone on 0.10 to
    /// downgrade. Missing components count as zero, so `1.2` and `1.2.0` are the same version.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func components(of version: String) -> [Int] {
        normalise(version)
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .prefix { Int($0) != nil }
            .compactMap { Int($0) }
    }
}
