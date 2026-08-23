import Foundation
import Testing

@testable import OurWhisper

@Suite("Update checking")
struct UpdateCheckerTests {
    // MARK: - Version comparison

    @Test("Versions compare numerically, not lexically", arguments: [
        ("1.0.0", "0.9.9", true),
        ("0.10.0", "0.9.0", true),   // the one a string compare gets backwards
        ("0.2.0", "0.10.0", false),
        ("1.2.3", "1.2.3", false),
        ("1.2", "1.2.0", false),     // missing components are zero
        ("1.2.1", "1.2", true),
        ("v1.0.1", "1.0.0", true),   // a leading v is noise
    ])
    func comparesVersions(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isVersion(candidate, newerThan: current) == expected)
    }

    @Test("A build-from-main tag compares as the version it carries")
    func comparesBuildFromMainTag() {
        // `release-1.0.8-71f957b` is the tag almost every shipped build has. It used to parse as
        // no version at all — 1.0.8 compared as 0.0.0 — so the newest release on offer read as
        // older than whatever the user was already running.
        #expect(UpdateChecker.isVersion("release-1.0.8-71f957b", newerThan: "1.0.5"))
        #expect(!UpdateChecker.isVersion("release-1.0.5-5201edd", newerThan: "1.0.8"))
    }

    @Test("A tag with no version in it never reads as newer", arguments: ["build-7", "latest", "main"])
    func tagWithoutAVersion(tag: String) {
        // A rehearsal run is tagged `build-<run number>`. Reading that 7 as a major version would
        // offer everyone version 7 and hand them a downgrade.
        #expect(!UpdateChecker.isVersion(tag, newerThan: "1.0.5"))
    }

    @Test("A pre-release suffix does not make a version newer")
    func ignoresPreReleaseSuffix() {
        // 1.0.0-beta.1 and 1.0.0 must not read as an upgrade in either direction here; the
        // pre-release filter in `parse` is what keeps betas out.
        #expect(!UpdateChecker.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    // MARK: - Parsing

    private func release(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "tag_name": "v0.2.0",
            "name": "Modes and history",
            "body": "Notes",
            "html_url": "https://github.com/grozoww/my-whisper/releases/tag/v0.2.0",
            "published_at": "2026-01-15T10:00:00Z",
            "draft": false,
            "prerelease": false,
        ]
        object.merge(overrides) { _, new in new }
        return object
    }

    private func releaseJSON(_ overrides: [String: Any] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: release(overrides))
    }

    /// The shape the app actually receives: GitHub's releases list, newest first.
    private func releaseListJSON(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    @Test("A published release parses, with the v stripped")
    func parsesRelease() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON()))
        #expect(release.version == "0.2.0")
        #expect(release.title == "Modes and history")
        #expect(release.publishedAt != nil)
    }

    @Test("A build from main parses to the version in its tag")
    func parsesBuildFromMainTag() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON(["tag_name": "release-1.0.8-71f957b"])))
        #expect(release.version == "1.0.8")
    }

    @Test("Drafts and pre-releases are not offered", arguments: ["draft", "prerelease"])
    func rejectsUnfinishedReleases(flag: String) {
        // Someone running the shipped app should never be nudged onto a build the maintainer has
        // not finished publishing.
        #expect(UpdateChecker.parse(releaseJSON([flag: true])) == nil)
    }

    @Test("A release with no name falls back to its tag")
    func fallsBackToTag() throws {
        let release = try #require(UpdateChecker.parse(releaseJSON(["name": ""])))
        #expect(release.title == "v0.2.0")
    }

    @Test("The newest finished release in the list is the one offered")
    func picksNewestFinishedRelease() throws {
        // A rehearsal build is a prerelease and sorts ahead of the finished releases. Taking the
        // first entry regardless is what would offer everyone a build nobody merged.
        let data = releaseListJSON([
            release(["tag_name": "release-1.0.9-abc1234", "prerelease": true]),
            release(["tag_name": "v1.0.8", "draft": true]),
            release(["tag_name": "v1.0.7"]),
            release(["tag_name": "v1.0.6"]),
        ])
        let found = try #require(UpdateChecker.parse(data))
        #expect(found.version == "1.0.7")
    }

    @Test("A list with nothing finished in it offers nothing")
    func listOfOnlyPrereleases() {
        let data = releaseListJSON([
            release(["tag_name": "release-1.0.9-abc1234", "prerelease": true]),
            release(["tag_name": "release-1.0.8-def5678", "prerelease": true]),
        ])
        #expect(UpdateChecker.parse(data) == nil)
    }

    @Test("A repository whose every release is a prerelease reads as up to date, not as an error")
    @MainActor
    func treatsUnfinishedReleasesAsUpToDate() async {
        // A repository whose only builds are rehearsals. Reporting that as a failure — or as
        // "no usable tag_name" — is what made the Check button look broken.
        let data = releaseListJSON([release(["tag_name": "release-99.0.0-abc1234", "prerelease": true])])
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: data))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("expected up to date, got \(state)")
            return
        }
    }

    @Test("An empty releases list reads as up to date")
    @MainActor
    func treatsEmptyListAsUpToDate() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: Data("[]".utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("expected up to date, got \(state)")
            return
        }
    }

    @Test("A response that is not JSON is reported as a failure")
    @MainActor
    func reportsUnreadableResponse() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: Data("<html>nope</html>".utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .failed = state else {
            Issue.record("expected a failure state, got \(state)")
            return
        }
    }

    @Test("Malformed JSON returns nil rather than throwing")
    func handlesGarbage() {
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
        #expect(UpdateChecker.parse(Data("{}".utf8)) == nil)
    }

    // MARK: - Behaviour

    @Test("A newer release is reported as available")
    @MainActor
    func reportsAvailableRelease() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .available(let release) = state else {
            Issue.record("expected an available release, got \(state)")
            return
        }
        #expect(release.version == "99.0.0")
    }

    @Test("A skipped version is not offered again")
    @MainActor
    func honoursSkippedVersion() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check(skippedVersion: "99.0.0")
        guard case .upToDate = state else {
            Issue.record("a skipped version should not be offered, got \(state)")
            return
        }
    }

    @Test("Checking manually overrides a skip")
    @MainActor
    func forceOverridesSkip() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseListJSON([release(["tag_name": "v99.0.0"])])))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check(skippedVersion: "99.0.0", force: true)
        guard case .available = state else {
            Issue.record("pressing Check should find a skipped version, got \(state)")
            return
        }
    }

    @Test("The request carries no identifying information")
    @MainActor
    func sendsNothingIdentifying() async throws {
        // README.md promises this check is not telemetry. The promise is only kept if the request
        // says nothing about the user or this Mac.
        let stub = StubHTTPClient(script: [("/releases", .init(status: 200, body: releaseJSON()))])
        let checker = UpdateChecker(http: stub)
        _ = await checker.check()

        let request = stub.requests[0]
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query == nil)
    }

    @Test("A repository with no releases yet is not an error")
    @MainActor
    func treatsMissingReleasesAsUpToDate() async {
        // Before the first release, GitHub answers 404. Reporting that as a failure would tell
        // every early user their update check is broken.
        let stub = StubHTTPClient(script: [("/releases", .init(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8)))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .upToDate = state else {
            Issue.record("a repository with no releases should read as up to date, got \(state)")
            return
        }
    }

    @Test("A network failure is reported, not swallowed")
    @MainActor
    func reportsFailure() async {
        let stub = StubHTTPClient(script: [("/releases", .init(status: 503, body: Data()))])
        let checker = UpdateChecker(http: stub)

        let state = await checker.check()
        guard case .failed = state else {
            Issue.record("expected a failure state, got \(state)")
            return
        }
    }
}
