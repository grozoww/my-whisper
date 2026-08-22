# OurWhisper

Local dictation for macOS. Hold a hotkey, talk, and the text lands in whatever field has focus.

Transcription runs on your Mac's Neural Engine. No audio leaves the machine unless you explicitly
turn on the optional cloud provider. There is no account, no telemetry, and no paid tier.

> Status: early development. Not yet usable — see [Roadmap](#roadmap).

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
- **Fully offline by default** — Parakeet for speech, a local LLM for cleanup. Zero API keys needed.
- **Modes** — per-profile prompts that clean up the raw transcript: drop `mm` and `hmm`, resolve
  self-corrections ("send it Tuesday, no, Wednesday" becomes "send it Wednesday"), set the tone.
  Modes can auto-switch based on the app you are typing into.
- **Menu bar app** with a floating pill overlay and live audio bars while recording.
- **Vocabulary** — teach it your names, jargon, and spellings.
- **History** — searchable, stored locally, with a retention setting.

## Languages

Offline (Parakeet TDT v3): 25 European languages, including English, Russian, Ukrainian, Spanish,
German, French, Polish, Italian, Portuguese, Dutch, Czech, Greek, Swedish and more.

Online (optional, Soniox): 60+ including Chinese and Japanese. Requires your own API key.

## Requirements

- macOS 15 (Sequoia) or later, Apple Silicon
- ~600 MB disk for the speech model, ~2.5 GB more if you want local LLM cleanup

## Install

Not yet released. Building from source is documented in [CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy

- Audio and transcripts stay on disk, under your control, with a retention setting.
- No telemetry. No crash reporting. No network calls unless you enable a cloud provider.
- API keys you paste are stored in the **macOS Keychain**, never in a config file or a log, and
  are only ever sent to that provider.

## Roadmap

- [ ] **P0** Project skeleton, permissions, menu bar, window shell
- [ ] **P1** Core loop: record, transcribe with Parakeet, paste. Hotkey and pill overlay
- [ ] **P2** Soniox cloud provider, model library and downloads
- [ ] **P3** Modes, prompt cleanup with local LLM, vocabulary
- [ ] **P4** History, sound settings, themes, auto-update

## Credits

- [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — CC-BY-4.0
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML runtime for Parakeet
- [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) — on-device LLM for cleanup

## License

MIT. See [LICENSE](LICENSE). Models carry their own licenses, listed in the app's About screen.
