# OurWhisper

Local dictation for macOS. Hold a hotkey, talk, and the text lands in whatever field has focus.

Transcription runs on your Mac's Neural Engine. No audio leaves the machine unless you explicitly
turn on the optional cloud provider. There is no account, no telemetry, and no paid tier.

> Status: feature-complete and building from source. Not yet released — see [Roadmap](#roadmap).

## Why another one

Superwhisper and Wispr Flow are good and closed. This is the same idea, open, with the model
choice made on evidence rather than brand recognition.

The default engine is **NVIDIA Parakeet TDT v3**, not Whisper. On FLEURS it is both faster and
more accurate than Whisper large-v3 for the languages this was built for:

| FLEURS WER (lower is better) | Parakeet v3 | Whisper large-v3 |
| ---------------------------- | ----------- | ---------------- |
| Ukrainian                    | **5.10%**   | 12.52%           |
| Russian                      | **3.00%**   | 4.04%            |
| Spanish                      | **3.45%**   | ~4.2%            |
| German                       | **5.04%**   | ~5.5%            |
| English                      | 4.85%       | ~4.2%            |

Parakeet is also roughly 11x faster on the Neural Engine and a third of the size. The trade-off
is language coverage: 25 European languages, so no Chinese or Japanese offline. Those route to
the optional cloud provider instead.

## Features

- **Global hotkey** — toggle, or push-to-talk. Text is pasted into the focused field of any app.
- **Fully offline by default** — Parakeet for speech, on-device cleanup. Zero API keys, zero
  accounts, and nothing to download beyond the speech model.
- **Modes** — per-profile prompts that clean up the raw transcript: drop `mm` and `hmm`, resolve
  self-corrections ("send it Tuesday, no, Wednesday" becomes "send it Wednesday"), set the tone.
  Modes can auto-switch based on the app you are typing into.
- **Menu bar app** with a floating pill overlay and live audio bars while recording.
- **Vocabulary** — teach it your names, jargon, and spellings. Applied as an exact rule, not a
  hint to a model, so it works every time.
- **History** — searchable, stored locally, with a retention setting that actually deletes. Keeps
  the raw transcript next to the cleaned one, so a bad result can be traced to the stage that
  caused it.

## Languages

Offline (Parakeet TDT v3): 25 European languages, including English, Russian, Ukrainian, Spanish,
German, French, Polish, Italian, Portuguese, Dutch, Czech, Greek, Swedish and more.

Online (optional, Soniox): 60+ including Chinese and Japanese. Requires your own API key.

## Requirements

- macOS 15 (Sequoia) or later, Apple Silicon
- ~600 MB disk for the speech model, downloaded once on first launch
- Optional: macOS 26 with Apple Intelligence enabled, for model-based cleanup. Nothing to
  download, and the rule-based cleanup works without it on every supported version.

## Install

Download the DMG from [Releases](https://github.com/grozoww/my-whisper/releases), open it, and
drag OurWhisper to Applications.

Builds that are not notarized are marked as pre-releases. macOS refuses those on a plain
double-click — **right-click the app in Applications and choose Open** instead, once. That warning
means Apple has not vouched for the build, which costs $99 a year, not that anything is wrong with
it. Every release says which kind it is.

OurWhisper then asks for Microphone and Accessibility permission, and both are required: the
microphone to hear you, Accessibility to watch for the hotkey and paste into the focused field.
It is a menu bar app — look for the microphone icon in the menu bar, not the Dock. There is a
"Show in the Dock" switch in Configuration if you would rather have one.

Building from source is documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy

- Audio and transcripts stay on disk, under your control, with a retention setting.
- No telemetry. No crash reporting. No network calls unless you enable a cloud provider.
- API keys you paste are stored in the **macOS Keychain**, never in a config file or a log, and
  are only ever sent to that provider.

## How cleanup works

Two stages, in this order, and the second is optional.

**Rules** run first: filler removal, self-corrections, spoken punctuation, sentence casing, and
your vocabulary list. They are pure functions — instant, deterministic, and identical every time.
They run on every dictation regardless of what else is available.

**The on-device model** runs second, if you turn it on. It handles what rules cannot: tone,
phrasing, and judgement about what you meant. If it is unavailable, slow, or returns something
implausible, the rule-cleaned text is used instead. A model problem costs you latency, never words.

## Roadmap

- [x] **P0** Project skeleton, permissions, menu bar, window shell
- [x] **P1** Core loop: record, transcribe with Parakeet, paste. Hotkey and pill overlay
- [x] **P2** Soniox cloud provider, model library and downloads
- [x] **P3** Modes, on-device cleanup, vocabulary
- [x] **P4** History, sound settings, themes, update check
- [ ] **P5** First signed and notarized release

## Credits

- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — CC-BY-4.0
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML runtime for Parakeet
- Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) — the
  on-device language model used for cleanup on macOS 26

## License

MIT. See [LICENSE](LICENSE). Models carry their own licenses, listed in the app's About screen.
