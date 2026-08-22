# CLAUDE.md

Working notes for agents and humans on this codebase. `README.md` is what the app is;
`CONTRIBUTING.md` is how to build it. This is what to know before changing it.

## What this app is

A macOS menu bar dictation tool. Hold a hotkey, talk, and the cleaned-up text is pasted into
whatever field had focus. Everything runs on the Mac by default: speech through NVIDIA Parakeet on
the Neural Engine, cleanup through rules plus Apple's on-device model.

Not sandboxed, on purpose — the Accessibility API cannot reach other apps from inside the App
Sandbox, and pasting into another app is the entire product. Distribution is Developer ID plus
notarization, never the Mac App Store.

## The four rules

These are from `CONTRIBUTING.md` and they are not negotiable. Everything below is downstream of
them.

1. **Never commit a secret.** Keys come from the user at runtime and live in the macOS Keychain.
   Nothing in the build, the tests or CI may require a key.
2. **The app works with zero keys.** Local speech and local cleanup are the default path.
3. **No telemetry, ever.** The only unattended network request is the GitHub release check, and it
   sends nothing about the user. See `UpdateChecker` — the test `sendsNothingIdentifying` is what
   keeps that true.
4. **Keep the build warning-free.** CI fails on a warning. The Swift 6 concurrency warnings in the
   audio path are real defects; that code runs on the audio thread.

And one that follows from them:

5. **Audio never leaves the Mac implicitly.** Choosing a language Parakeet cannot handle does not
   quietly start uploading — it fails with a message naming the switch the user has to turn on.
   `TranscriptionRouter` is the only place that decision is made.

## Commands

```bash
./scripts/run.sh                 # build and relaunch
./scripts/run.sh --build         # build only
./scripts/run.sh --test          # unit tests
./scripts/run.sh --check         # what CI runs: warning-free build, tests, dependency audit
./scripts/run.sh --logs          # stream the app's logs at info level
./scripts/run.sh --selftest speech.wav ru   # transcribe a file, no UI or permissions needed
./scripts/audit-deps.sh          # dependency pinning and vulnerability check

OURWHISPER_SECTION=modes open -a OurWhisper   # open the window on a given screen
```

`--selftest` exists because the interactive path needs Accessibility permission, which a fresh
clone, a CI runner and an automated agent all lack. **If you are an agent and want to know whether
transcription works, this is the command** — not launching the app.

`OURWHISPER_SECTION` exists for the same reason on the UI side: the window is only reachable by
clicking a menu bar icon, which nothing automated can do. Values are the `NavigationSection` raw
values (`home`, `modes`, `vocabulary`, `configuration`, `sound`, `modelsLibrary`, `history`).

## Layout

```
Sources/
  App/          Entry point, AppState, menu bar
  Core/
    Audio/          Capture, device selection, WAV encoding
    DictationController.swift   The record → transcribe → clean → paste → remember loop
    History/        Transcripts and retention
    Hotkey/         CGEventTap and chord matching
    Injection/      Paste into the focused field
    Modes/          Per-context cleanup profiles
    Networking/     HTTPClient seam — the reason cloud code is testable
    Permissions/    Microphone and Accessibility
    Refinement/     Rule cleanup, on-device model, pipeline
    Security/       Keychain
    Settings/       Settings value, store, theme
    Sound/          Feedback sounds, CoreAudio device list
    Storage/        Paths, JSON file store, lenient decoding
    Transcription/  Provider protocol, Parakeet, Soniox, router
    Update/         Release check
    Vocabulary/     Substitution list
  UI/           One directory per screen, plus DesignSystem
Tests/          Swift Testing, no network, no key, no permissions
```

The Xcode project uses **synchronized file groups**: a new file under `Sources/` or `Tests/` joins
its target automatically. Never edit `project.pbxproj` to add a file.

## Things that will catch you out

**Swift's `Codable` ignores property defaults.** A missing key throws — it does not fall back to
the default you wrote in the struct. Every persisted type therefore decodes through the helpers in
`Core/Storage/LenientDecoding.swift`. **If you add a field to `Settings`, `Mode`, `HistoryEntry` or
`VocabularyEntry`, add it to that type's `init(from:)` too.** Forgetting means every existing file
fails to decode, `JSONFileStore` quarantines it, and the user's settings, modes and history revert
on upgrade. `SchemaEvolutionTests` covers this.

**`\b` is ASCII-only.** It matches inside Cyrillic text, so any regex that needs a word boundary
must use the Unicode form in `RuleRefiner.RegexCache.wordRegex`. Russian and Ukrainian are two of
the app's primary languages; getting this wrong corrupts them silently.

**The event tap is fragile in two specific ways.** macOS disables it if a callback is slow, and it
dies silently when Accessibility is revoked. Both are handled in `HotkeyMonitor`; keep callbacks
fast and do not add work to them.

**Capture the paste target before drawing anything.** Showing the pill first lets
`frontmostApplication` change underneath, and the text lands in the wrong app.
`DictationController.beginRecording` gets this order right — do not reorder it.

**The pill must never take keyboard focus.** It is a `nonactivatingPanel` with
`canBecomeKey == false`. If it took focus there would be nothing left to paste into.

**Signing is tied to Accessibility permission.** Ad-hoc signatures change every build, so macOS
sees a new app each time and silently drops the grant. `./scripts/dev-cert.sh` fixes it. Read "The
signing trap" in `CONTRIBUTING.md` before debugging "dictation stopped working after a rebuild".

**A programmatically created `NSWindow` releases itself on `close()`.** ARC then releases it again
and the process dies. `Tests/ViewRenderingTests.swift` sets `isReleasedWhenClosed = false`.

**Unit tests use the app as their test host, so the app really launches.** `AppState.start()`
returns early under XCTest — otherwise every test run would begin a 600 MB model download and
install a system-wide event tap.

**Stores default to the real Application Support directory.** Every store takes a `directory:`
parameter for exactly one reason: a test that used the default would destroy the settings, modes,
vocabulary and history of whoever ran the suite. Use `TemporaryDirectory` from `Tests/TestSupport`.
`AppDirectories.support` also redirects to a temporary directory under XCTest as a backstop —
that backstop exists because this mistake was made once and silently rewrote real user data.

**Accessibility is granted per app bundle at a path.** A second clone or a git worktree produces a
second `OurWhisper.app` in a different DerivedData directory, and a permission granted to one does
not apply to the other — while System Settings still shows a ticked OurWhisper. This presents as
"I granted it and the app still says I did not". The Home screen shows the running bundle path and
warns when other builds exist; check that before suspecting the permission code.

**`decodeIfPresent` cannot tell "absent" from "null".** For an optional field whose default is not
nil — `pushToTalkChord` is the live example — use
`container.optional(key, defaultWhenAbsent:)`, or upgrading users get nil instead of the new
default and the feature silently arrives switched off.

## Adding things

**A new transcription engine.** Conform to `TranscriptionProvider`, take an `HTTPClient` if it is
a cloud engine, and add it to `TranscriptionRouter`. Do not add a second *local* speech model
without benchmark numbers — the Parakeet-over-Whisper choice is documented in `README.md` with
FLEURS WER, and `CONTRIBUTING.md` requires evidence to change it.

**A cleanup rule.** Add it to `CleanupOptions`, implement it in `RuleRefiner`, wire the toggle into
`ModesView`, and add it to `Mode`'s `init(from:)`. Rules must be pure and fast: they run on every
dictation, including when the model is off. Anything needing judgement belongs in
`OnDeviceRefiner` instead.

**A setting.** Add the field with a default, add it to its section's `init(from:)`, and surface it
in the right screen. Never add a control without the sentence explaining it — `SettingsRow`
requires a `detail` for that reason.

**A dependency.** It must be pinned to an exact version, `Package.resolved` must be committed in
the same change, and `./scripts/audit-deps.sh` must pass. Two traps found the hard way, both
recorded in `CONTRIBUTING.md`: a package with a build-tool plugin needs Xcode's plugin trust, and
anything depending on `mlx-swift` 0.31.5+ needs Xcode's separately-downloaded Metal toolchain.

## Testing

Swift Testing, not XCTest. 94 tests, no network, no API key, no microphone, no permissions.

- Cloud providers are tested against `StubHTTPClient` with recorded response shapes.
- Every screen is built and laid out in `ViewRenderingTests` — a view that crashes on
  construction compiles fine and fails the first time someone clicks that sidebar row.
- The rule refiner has the deepest coverage because it is pure and it touches every dictation.

What is *not* covered, and why: the event tap, the paste path and CoreAudio device selection all
need permissions and real hardware. For those, `CONTRIBUTING.md` asks which apps you tested pasting
into, and that stays a human answer.

## Style

Match the surrounding code. Specifically:

- Comments explain **why**, not what. If a line needs a comment saying what it does, rename
  something instead. Existing comments are the model — they document trade-offs, traps and
  decisions, not mechanics.
- Types get a doc comment saying what they are for and what the non-obvious constraint is.
- Prefer the plain word. The codebase says "loudness" rather than "amplitude envelope".
- User-facing strings say what to do about it. "Add a Soniox API key in Configuration", not
  "unauthorized".
