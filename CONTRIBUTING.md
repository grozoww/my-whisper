# Contributing to OurWhisper

## Get building

```bash
git clone https://github.com/<you>/our-whisper.git
cd our-whisper
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

If dictation stops working after a rebuild anyway:

1. System Settings → Privacy & Security → Accessibility — remove OurWhisper, then add it back
2. Check the identity still exists: `security find-identity -p codesigning | grep OurWhisper`
   (note: no `-v`, which would filter out this deliberately-untrusted certificate)

The app also ships a permission health check: if the event tap fails to arm, it says which
permission is missing rather than failing quietly.

## Day-to-day commands

```bash
./scripts/run.sh                          # build and relaunch
./scripts/run.sh --build                  # build only
./scripts/run.sh --logs                   # stream the app's logs
./scripts/run.sh --selftest speech.wav ru # transcribe a file, no UI or permissions needed
```

`--logs` passes `--level info` deliberately: most of the useful output — transcripts, timings,
model loading — is logged at info level, which `log show` hides by default.

`--selftest` exists because the interactive path cannot run without Accessibility permission.
It answers the question that actually matters — does the model transcribe on this machine — with
one command, and works on a fresh clone and in CI.

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

`.vscode/` ships Build, Build and Run, Stream logs and Self-test tasks (⇧⌘B), plus two debug
configurations. The self-test one is the useful one before Accessibility is granted.

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

## Pull requests

CI builds every PR on a macOS runner with `CODE_SIGNING_ALLOWED=NO` and no secrets available. The
release workflow is separate, tag-triggered and main-repo only, so a fork PR can never reach the
signing certificate.

The Xcode project uses **synchronized file groups**: a new file under `Sources/` joins the target
automatically, so you never edit `project.pbxproj` and PRs do not conflict in it.

For anything touching the recording, transcription or paste path, say in the description which
apps you tested pasting into — that path breaks in app-specific ways.
