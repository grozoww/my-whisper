# Contributing to OurWhisper

## Get building

```bash
git clone https://github.com/<you>/my-whisper.git
cd my-whisper
./scripts/dev-cert.sh     # one time — read "The signing trap" below first
./scripts/run.sh          # build and launch
```

Requires macOS 15+, Xcode 26+ (for the toolchain, not necessarily the editor), Apple Silicon.
Swift package dependencies resolve on the first build.

It is a menu bar app. After launching, look for the microphone icon in the menu bar — there is
no Dock icon and nothing appears in command-tab.

## Read this first: the signing trap

OurWhisper needs macOS **Accessibility** permission to paste text into other apps and to watch for
the global hotkey. macOS ties that permission to the app's **code signature**.

Xcode's default "Sign to Run Locally" produces an *ad-hoc* signature that is different on every
single build. So macOS sees each build as a brand new app that has never been granted anything.
The symptom is nasty because it is silent: you grant Accessibility, it works, you change one line,
rebuild, and dictation stops. No error, no prompt, nothing in the log.

`./scripts/dev-cert.sh` fixes this by creating a self-signed certificate called `OurWhisper Dev`
in your login keychain, so the signature stays the same across rebuilds. It needs no sudo and asks
for no password. The certificate never leaves your machine and is not used for distribution.

It prints `CSSMERR_TP_NOT_TRUSTED` next to the identity. **That is expected.** The certificate is
deliberately not installed as a trusted root — `codesign` does not require that in order to sign
with it, and leaving it untrusted is what keeps the script prompt-free and your trust store clean.

You can see the difference the certificate makes. `codesign -d -r-` prints the *designated
requirement*, which is what macOS actually stores the permission against:

```
ad-hoc      designated => cdhash H"e7c60c73…"
certificate designated => identifier "com.grozoww.ourwhisper" and certificate leaf = H"5792c7a4…"
```

The first names one exact binary. The second names the bundle id and the certificate, so anything
signed by the same certificate satisfies it. That is the whole mechanism, and it is why
`scripts/release-cert.sh` exists for public releases — see "Shipping a build".

### The other half of the trap: two copies

Accessibility is granted to one app **bundle at one path**. A second clone, or a git worktree,
builds a second `OurWhisper.app` into a different DerivedData directory — and a permission granted
to the first does not apply to the second, while System Settings still shows a ticked OurWhisper.
The symptom is "I granted it and the app still says I have not".

The Home screen names the bundle it is actually running from and warns when other builds exist.
Remove every OurWhisper from the Accessibility list, then add back exactly that one.

If dictation stops working after a rebuild anyway:

1. System Settings → Privacy & Security → Accessibility — remove OurWhisper, then add it back
2. Check the identity still exists: `security find-identity -p codesigning | grep OurWhisper`
   (note: no `-v`, which would filter out this deliberately-untrusted certificate)
3. Check you granted the copy you are running — the path is on the Home screen

The app also ships a permission health check: if the event tap fails to arm, it says which
permission is missing rather than failing quietly.

## Day-to-day commands

```bash
./scripts/run.sh                          # build and relaunch
./scripts/run.sh --build                  # build only
./scripts/run.sh --test                   # unit tests
./scripts/run.sh --check                  # everything CI runs, before you push
./scripts/run.sh --logs                   # stream the app's logs
./scripts/run.sh --selftest speech.wav ru # transcribe a file, no UI or permissions needed
./scripts/audit-deps.sh                   # dependency pinning and vulnerability check
./scripts/screenshots.sh                  # redraw the README's screenshots

OURWHISPER_SECTION=modes open -a OurWhisper   # open the window straight onto a screen
```

`--logs` passes `--level info` deliberately: most of the useful output — transcripts, timings,
model loading — is logged at info level, which `log show` hides by default.

`--selftest` exists because the interactive path cannot run without Accessibility permission.
It answers the question that actually matters — does the model transcribe on this machine — with
one command, and works on a fresh clone and in CI.

`--check` runs the same three gates as CI: a warning-free build, the tests, and the dependency
audit. Running it before pushing turns a red pull request into a local failure.

## Tests

Swift Testing, in `Tests/`. They need no API key, no network, no microphone and no permissions —
which is what lets them run on a fork's CI and on a machine that has granted this app nothing.

Three things worth knowing before adding one:

**Cloud providers use `StubHTTPClient`.** Every provider takes an `HTTPClient`, so the network is a
parameter rather than a global. Responses are recorded shapes, and the requests are captured so a
test can assert on what *would* have been sent — that is how `sendsNothingIdentifying` keeps the
no-telemetry promise honest.

**Stores take a `directory:`.** Always pass one, using `TemporaryDirectory` from
`Tests/TestSupport.swift`. A store left on its default writes to the real Application Support
directory and destroys the settings, modes, vocabulary and history of whoever runs the suite.

**Screens are rendered, not just compiled.** `ViewRenderingTests` builds every sidebar destination
against real stores and forces a layout pass. A SwiftUI view that crashes on construction — a
mismatched `Picker` selection type, an index out of range — compiles perfectly and fails the first
time someone clicks that row. Add new screens to that test.

The event tap, the paste path and CoreAudio device selection are not covered: they need
permissions and real hardware. That is why the pull request checklist below asks which apps you
tested pasting into.

## Dependencies

Every dependency is pinned to an **exact** version, and `Package.resolved` is committed. A version
range means CI and your machine can resolve different code from the same commit, and that a
compromised release inside the range lands without review.

`./scripts/audit-deps.sh` enforces that, checks the resolved file has not drifted, and queries
[osv.dev](https://osv.dev) — which carries the GitHub Advisory Database — for known vulnerabilities
in what is pinned. CI runs it on every pull request and again weekly, because an advisory can be
published for code that has not changed. Dependabot opens the update pull requests; nothing updates
itself.

Two traps, both found the hard way:

**A package with a build-tool plugin will not build from the command line** until Xcode trusts the
plugin. `mlx-swift` 0.31.5 added a CUDA build plugin and the build fails with
`Validate plug-in "CudaBuild"`. Prefer a version without the plugin over disabling plugin
validation, which would auto-trust arbitrary build-time code.

**`mlx-swift` 0.31.5+ also needs Xcode 26's separately-downloaded Metal toolchain**
(`xcodebuild -downloadComponent MetalToolchain`, several gigabytes). This is why cleanup uses
Apple's Foundation Models rather than a downloaded MLX model: same privacy guarantee, no
multi-gigabyte tax on every contributor and every CI run.

## Editor

**Xcode** is needed only for SwiftUI previews and its own debugger. Open `OurWhisper.xcodeproj`.

**VS Code / Cursor** works for everything else. Install the
[Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)
and [LLDB DAP](https://marketplace.visualstudio.com/items?itemName=llvm-vs-code-extensions.lldb-dap),
then generate the build-server config that gives sourcekit-lsp its compiler flags:

```bash
brew install xcode-build-server
xcode-build-server config -project OurWhisper.xcodeproj -scheme OurWhisper
```

`buildServer.json` holds absolute paths for your machine, so it is git-ignored — regenerate it
after a fresh clone. It points at Xcode's default DerivedData, which is why `scripts/run.sh`
builds there too rather than into a local directory; a custom `-derivedDataPath` would leave the
editor indexing a directory nothing writes to.

`.vscode/` ships Build, Test, Check, Build and Run, Stream logs and Self-test tasks (⇧⌘B), plus
two debug configurations. The self-test one is the useful one before Accessibility is granted.

## Rules

**Never commit a secret.** Every API key is supplied by the user at runtime and stored in the
macOS Keychain. Nothing in the build, the tests, or CI may require a key. Tests for cloud
providers use recorded fixtures.

**The app must work with zero keys.** The local model and local cleanup are the default path. A
key is always optional.

**No telemetry, ever.** No analytics, no crash reporting, no phone-home beyond the user-initiated
update check. This is the point of the project.

**Do not add a second local speech model without evidence.** The choice of Parakeet over Whisper
is documented in the README with benchmark numbers. If you want to change it, bring numbers.

**Keep the build warning-free.** Swift 6 concurrency warnings in the audio path are not noise —
that code runs on the audio thread, where "probably fine" becomes a dropout.

## Shipping a build

```bash
./scripts/release-cert.sh          # once, ever: the certificate every release is signed with
./scripts/package.sh               # the best path the environment allows
./scripts/package.sh --unsigned    # ad-hoc, even when a certificate is available
```

All three produce a DMG with the app and an Applications symlink inside. The filename says which
you got: `OurWhisper-<version>.dmg`, `-unnotarized.dmg` or `-unsigned.dmg`.

**Self-signed** is the path this project ships on, and it is what `release-cert.sh` sets up. The
signing trap at the top of this file applies to releases exactly as it applies to your rebuilds:
an ad-hoc signature pins the Accessibility grant to one exact binary, so every update used to
silently break dictation for everyone who had installed the previous one. A certificate — any
certificate, Apple is not involved — makes the grant survive. Run the script once, put the three
secrets it prints into the repository, and never think about it again.

**Do not lose that key.** A release signed by a different certificate is a different app to macOS,
and every user re-grants Accessibility by hand once. The script tells you to back the `.p12` up
because there is no way to recreate it.

**Unsigned** is ad-hoc signed: a real signature with no certificate behind it. Only for builds
nobody installs — it costs every user their permission on every update. `--unsigned` exists to
rehearse the workflow, not to ship.

Neither of those is notarized, so Gatekeeper still blocks the first double-click and the user
still needs `scripts/install.sh`. `package.sh` writes `dist/INSTALL.md` with the exact wording to
give them; the release workflow pastes it into the release notes. Do not skip that — a download
that refuses to open with no explanation reads as broken software.

**Signed and notarized** opens with a double-click and no warning. It needs a paid Apple Developer
account: put the Developer ID certificate in the same three secrets and add `APPLE_TEAM_ID`,
`NOTARY_APPLE_ID` and `NOTARY_PASSWORD`. Notarization uploads the DMG to Apple and waits a few
minutes. Signing and notarizing are separate decisions in `package.sh` for a reason — coupling
them is what made every release ad-hoc until the certificate arrived.

### Version numbers

Nobody types the patch number. `scripts/version.sh` works out what a build is called, and both
`package.sh` and the release workflow ask it rather than deciding for themselves — so the DMG
filename, the version baked into the app and the name on the release page cannot drift apart.

The `VERSION` file at the repository root holds the line you are on. **Major and minor are yours**:
edit the file when a release deserves the number. **The patch is counted**: it is the number of
pull requests merged since `VERSION` last changed.

```
VERSION says 1.0.0, nothing merged since   →  1.0.0
four PRs merged since                      →  1.0.4
edit VERSION to 1.1.0                      →  1.1.0, counting starts again
```

PRs are counted along main's first-parent chain, so only what landed counts, once each, and both
merge styles are recognised — `Merge pull request #12` and a squashed `Some change (#12)`. A commit
pushed straight to main is not a PR and does not move the number.

A `v*` tag on the exact commit being built overrides all of it. Tagging `v1.2.0` is a decision, and
a release whose tag and whose app disagree tells every user to upgrade to what they are already
running — `UpdateChecker` compares the release tag against `CFBundleShortVersionString`.

`MARKETING_VERSION` in the project is kept equal to the `VERSION` file so a plain Xcode build is
not wrong, but it is not what a release uses; `package.sh` passes the computed value on the
`xcodebuild` command line. `CURRENT_PROJECT_VERSION` gets every PR ever merged, plus one — a
build number has to keep rising when the marketing version resets.

```bash
./scripts/version.sh            # VERSION=… BUILD=… SHA=… RELEASE_NAME=…
./scripts/version.sh --name     # release-1.0.3-a1b2c3d
```

This needs real history. `actions/checkout` clones a single commit by default, which has no merges
in it to count, so both workflows pass `fetch-depth: 0`.

### Where builds come from

Releases are named `release-<version>-<short sha>` — `release-1.0.3-a1b2c3d` — whatever the
trigger. The tag says what kind of build it is; the name says which code is in it, which is the
first thing anyone asks when a download misbehaves.

| Trigger | Tag | Name |
| --- | --- | --- |
| Pull request | — | A DMG as a CI artifact. Nothing published. |
| Push to `main` | `latest`, a rolling prerelease replaced each time | `release-1.0.3-a1b2c3d` |
| Push a tag `v*` | the tag. Notarized if the signing secrets are set | `release-1.0.3-a1b2c3d` |
| Actions → Run workflow | `build-<n>`, with an "unsigned" checkbox for rehearsing | `release-1.0.3-a1b2c3d (build 7)` |

`.github/workflows/release.yml` signs whenever `MACOS_CERTIFICATE` is set, and notarizes on top of
that only when the notary secrets are set too. With no certificate at all it falls back to ad-hoc
and logs a workflow warning, because that build will cost its users their Accessibility
permission. Anything that is not a notarized tag is marked a prerelease, so
GitHub keeps pointing people at the newest real release. The rolling release is deleted and
recreated on each push rather than added to — reusing the tag would otherwise leave two DMGs
attached to it once the version number changes, and `install.sh` takes the first one it finds.

The DMG job in `ci.yml` exists because the Release build is not the Debug build: it signs, it
hardens the runtime, it compiles the asset catalog and it is arm64-only. Each of those has broken
without the Debug build noticing.

### Installing

`scripts/install.sh` is the `curl | bash` in the README. It finds the newest release carrying a
DMG — deliberately not `/releases/latest`, which skips prereleases and would therefore find
nothing at all until this project is notarized — then copies the app into `/Applications` and
clears `com.apple.quarantine`. That last step is the point of the script. macOS refuses to open an
unnotarized download at all, claiming the app is damaged, and talking every user through
`xattr -dr` by hand is not a distribution strategy.

Keep it dependency-free. It has to run on a stock Mac, which means no `jq`, and Python cannot be
assumed either. It parses the GitHub API with `grep`, and it is short enough to read before
running, which is the only reason anyone should be willing to pipe it into a shell.

### The screenshots

`./scripts/screenshots.sh` redraws `docs/images`. It launches the real app once per shot with
`OURWHISPER_SCREENSHOT` set, which poses that screen with invented demo data and prints its window
number, then photographs that one window — see `ScreenshotMode`. Your own settings, modes and
history are never in the pictures: screenshot mode redirects the app's storage to a throwaway
directory, the same trick the tests use.

The app cannot photograph itself. Screen recording is granted per bundle and a debug build's path
changes with the checkout, so a fresh build has been granted nothing while your terminal already
has. Blank or black images mean that permission is missing — System Settings ▸ Privacy & Security
▸ Screen Recording, for whatever ran the script.

Re-run it when a screen changes shape, and commit the PNGs. Light and dark are separate files;
the README picks between them with `<picture>`.

Two more environment variables, for looking at a screen rather than photographing it for the
README. `OURWHISPER_SCREENSHOT_SIZE=880x560` poses the window at a given size — layouts break at
the small end, and the small end is the one nobody drags a window to. `OURWHISPER_SCREENSHOT_SIDEBAR=collapsed`
hides the sidebar, which is how the screens with a list of their own look when that list becomes
the leftmost thing in the window. The sidebar is set either way rather than left alone, because
AppKit autosaves whether it is collapsed into the app's defaults — which a debug build shares with
the installed one, so whoever collapsed it in the real app would otherwise get README screenshots
with no sidebar in them.

### The app icon

`./scripts/make-icon.swift` draws `Sources/Resources/Assets.xcassets` with CoreGraphics. The PNGs
it writes are committed, so a clone builds without running it; re-run it only when changing the
icon. Each size is drawn at its own scale rather than downsampled from 1024, because a stroke that
reads well at 512 turns to mush when squeezed into 16 pixels. `--icns` also writes
`dist/OurWhisper.icns` for anything outside the app bundle.

Release builds are **arm64 only**, set on the `xcodebuild` command line rather than only in the
project — Swift package targets live in a generated project of their own and do not inherit
`ARCHS`. Without it the Release build goes universal and fails compiling FluidAudio for x86_64,
a machine this app cannot run on anyway.

## Pull requests

CI builds and tests every PR on a macOS runner with `CODE_SIGNING_ALLOWED=NO`, and packages a DMG
with `--unsigned`. Neither needs a secret, so a fork's PR runs exactly as ours does. The release
workflow is separate and main-repo only, so a fork PR can never reach the signing certificate.

The Xcode project uses **synchronized file groups**: a new file under `Sources/` joins the target
automatically, so you never edit `project.pbxproj` and PRs do not conflict in it.

For anything touching the recording, transcription or paste path, say in the description which
apps you tested pasting into — that path breaks in app-specific ways, and no test covers it.

Before pushing:

```bash
./scripts/run.sh --check
```
