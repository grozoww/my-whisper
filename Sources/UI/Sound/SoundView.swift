import SwiftUI

/// Which microphone, and what the app sounds like.
struct SoundView: View {
    @Environment(AppState.self) private var appState

    @State private var devices: [AudioDevices.Device] = []
    /// `@State`, not `let`: a plain property is rebuilt on every render, which would release the
    /// player holding the preview sound alive and cut it off part-way.
    @State private var player = SoundPlayer()

    var body: some View {
        @Bindable var settings = appState.settings

        SettingsPage {
            SettingsSection(
                title: "Input",
                subtitle: "Choosing a device pins it. Following the system default means plugging in headphones silently changes what OurWhisper records from."
            ) {
                SettingsRow(
                    symbol: "mic",
                    title: "Microphone",
                    detail: deviceDetail
                ) {
                    Picker("Microphone", selection: $settings.settings.sound.inputDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.isDefault ? "\(device.name) (default)" : device.name)
                                .tag(Optional(device.id))
                        }
                    }
                    .frame(width: 220)
                }
                RowDivider()
                SettingsRow(
                    symbol: "arrow.clockwise",
                    title: "Rescan devices",
                    detail: "Devices are read when this screen opens. Rescan after plugging something in."
                ) {
                    Button("Rescan") { devices = AudioDevices.inputs() }
                        .buttonStyle(.bordered)
                }
            }

            SettingsSection(
                title: "Feedback sounds",
                subtitle: "The hotkey is silent and the pill is at the bottom of the screen. A sound is often the only confirmation that the press registered."
            ) {
                SettingsRow(symbol: "speaker.wave.2", title: "Play feedback sounds") {
                    Toggle("", isOn: $settings.settings.sound.playFeedbackSounds).toggleStyle(.switch)
                }
                RowDivider()
                soundPicker("Recording started", "play.circle", $settings.settings.sound.startSound)
                RowDivider()
                soundPicker("Recording finished", "stop.circle", $settings.settings.sound.stopSound)
                RowDivider()
                soundPicker("Something went wrong", "exclamationmark.circle", $settings.settings.sound.errorSound)
                RowDivider()
                SettingsRow(
                    symbol: "dial.medium",
                    title: "Volume",
                    detail: "Relative to the system alert volume. Never changes it."
                ) {
                    Slider(value: $settings.settings.sound.feedbackVolume, in: 0...1)
                        .frame(width: 160)
                }
            }
        }
        .task { devices = AudioDevices.inputs() }
        .onChange(of: appState.settings.settings.sound.playFeedbackSounds) { _, isOn in
            guard isOn else { return }
            preview(appState.settings.settings.sound.startSound)
        }
    }

    private var deviceDetail: String {
        guard let uid = appState.settings.settings.sound.inputDeviceUID else {
            return "Follows whatever macOS is using."
        }
        guard let device = devices.first(where: { $0.id == uid }) else {
            return "The chosen device is not connected. Recording falls back to the system default."
        }
        return device.name
    }

    /// Plays the sound as it is chosen. Picking a notification sound you cannot hear until the
    /// next time you dictate is guesswork.
    private func soundPicker(_ title: String, _ symbol: String, _ value: Binding<FeedbackSound>) -> some View {
        SettingsRow(symbol: symbol, title: title) {
            Picker(title, selection: value) {
                ForEach(FeedbackSound.allCases) { sound in
                    Text(sound.title).tag(sound)
                }
            }
            .frame(width: 160)
            .onChange(of: value.wrappedValue) { _, sound in preview(sound) }
        }
    }

    private func preview(_ sound: FeedbackSound) {
        player.play(sound, volume: appState.settings.settings.sound.feedbackVolume)
    }
}
