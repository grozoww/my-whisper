# Contributing to OurWhisper

## Build from source

```bash
git clone https://github.com/<you>/our-whisper.git
cd our-whisper
./scripts/dev-cert.sh          # one time — read the section below first
open OurWhisper.xcodeproj
```

Requires macOS 26+, Xcode 26+, Apple Silicon. Swift package dependencies resolve on first build.

## Read this before your first build: the signing trap

OurWhisper needs macOS **Accessibility** permission to paste text into other apps and to watch
for the global hotkey. macOS ties that permission to the app's **code signature**.

Xcode's default "Sign to Run Locally" produces an *ad-hoc* signature, and it is different on every
single build. So macOS sees each build as a brand new app that has never been granted anything.
The symptom is nasty because it is silent: you grant Accessibility, it works, you change one line,
rebuild, and dictation just stops. No error, no prompt, nothing in the log.

`./scripts/dev-cert.sh` fixes this. It creates a self-signed code-signing certificate called
`OurWhisper Dev` in your login keychain. The signature is then stable across rebuilds, so you
grant Accessibility once and it stays granted.

The script will ask for your login password — that is macOS gating keychain trust changes, and it
is why this is a script you run yourself rather than something the build does silently. The
certificate never leaves your machine and is not used for distribution.

If dictation stops working after a rebuild anyway:

1. Open System Settings → Privacy & Security → Accessibility
2. Remove OurWhisper, then add it back
3. Confirm the identity still exists: `security find-identity -v -p codesigning`

The app also ships a permission health check — if the event tap fails to arm, it tells you which
permission is missing and links to the right settings pane rather than failing quietly.

## Project layout

```
Sources/
  App/          entry point, menu bar, scenes, onboarding
  Core/
    Audio/          capture, resampling, level metering, VAD
    Hotkey/         Carbon hotkey + CGEventTap for push-to-talk
    Injection/      pasting into the focused field of another app
    Permissions/    microphone and Accessibility gating
    Transcription/  provider protocol, Parakeet, Soniox
    Formatting/     vocabulary, filler rules, LLM cleanup
    ModelCatalog/   downloads and disk management
    Store/          SwiftData models, Keychain, settings
  UI/
    Shell/ Home/ Modes/ Vocabulary/ Configuration/ Sound/ ModelsLibrary/ History/
    Pill/           the floating recording overlay
    DesignSystem/   tokens and shared components
```

The Xcode project uses **synchronized file groups**, so a new file inside `Sources/` joins the
target automatically. You do not need to add it to the project, and pull requests do not conflict
in `project.pbxproj`.

## Rules

**Never commit a secret.** Every API key is supplied by the user at runtime and stored in the
macOS Keychain. Nothing in the build, the tests, or CI may require a key. Tests for cloud
providers use recorded fixtures. `.gitignore` covers `.env`, `*.p12` and `*.cer`, but the real
safeguard is not putting them there in the first place.

**The app must work with zero keys.** Parakeet and the local cleanup model are the default path.
A key only unlocks Chinese/Japanese and cloud cleanup, and it is always optional.

**No telemetry, ever.** No analytics, no crash reporting, no phone-home version check beyond the
user-initiated update check. This is the point of the project.

**Do not add a second local speech model without evidence.** The choice of Parakeet over Whisper
is documented in the README with benchmark numbers. If you want to change it, bring numbers.

## Pull requests

CI builds and tests every PR on a macOS runner with no secrets available. The release workflow is
separate, tag-triggered, and only runs on the main repository, so a fork PR can never reach the
signing certificate.

Keep PRs focused. For anything that changes the recording, transcription or paste path, say in the
description which apps you tested pasting into — that path breaks in app-specific ways.
