import AVFoundation
import Accelerate
import CoreAudio
import OSLog

/// Microphone capture, converted to what the speech models want: 16 kHz, mono, 32-bit float.
///
/// The input device runs at whatever rate it likes (usually 44.1 or 48 kHz), so every buffer goes
/// through an `AVAudioConverter`. Conversion happens on the audio thread, which must never block
/// or allocate unpredictably — hence the pre-sized output buffer and the lock-free handoff.
///
/// Two consumers read from here and they want different things: the transcriber wants every
/// sample, the pill overlay wants a cheap loudness number ~60 times a second. Both are served
/// from the same tap so they can never drift apart.
final class AudioCapture: @unchecked Sendable {
    /// What the ASR models expect. Not configurable — both Parakeet and Whisper are trained at this rate.
    static let targetSampleRate: Double = 16_000

    enum CaptureError: LocalizedError {
        case engineStartFailed(String)
        case converterUnavailable
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let detail): "Could not start the audio engine: \(detail)"
            case .converterUnavailable: "Could not convert microphone audio to 16 kHz mono."
            case .noInputDevice: "No microphone is available."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "audio")

    /// Accumulated 16 kHz mono samples for the current utterance.
    private var samples: [Float] = []
    /// Most recent loudness, 0...1, already smoothed for display.
    private var level: Float = 0

    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var isRunning = false

    // MARK: - Control

    /// Starts capture.
    ///
    /// - Parameter deviceUID: CoreAudio UID of the microphone to record from, or `nil` to follow
    ///   the system default. An unknown UID — the device was unplugged since it was chosen — also
    ///   falls back to the default rather than failing: the user pressed the hotkey to talk, and
    ///   refusing to record because their preferred mic is in another bag helps nobody.
    func start(deviceUID: String? = nil) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        selectInputDevice(uid: deviceUID, on: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.converterUnavailable
        }

        self.targetFormat = target
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.targetSampleRate) * 30)
        level = 0
        lock.unlock()

        // 0 asks the engine for its preferred buffer size. Forcing a small size here only adds
        // wake-ups; the resampler downstream is what determines latency, not the tap size.
        input.installTap(onBus: 0, bufferSize: 0, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        isRunning = true
    }

    /// Stops capture and hands back everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        level = 0
        lock.unlock()
        return captured
    }

    /// Current loudness, 0...1. Safe to poll from the main thread at display rate.
    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    var capturedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }

    // MARK: - Device selection

    /// Points the engine's input unit at a specific device.
    ///
    /// Must happen before `outputFormat(forBus:)` is read: switching the device changes the
    /// hardware sample rate, and a converter built for the previous device would resample from the
    /// wrong rate — which sounds like a chipmunk, not like an error.
    private func selectInputDevice(uid: String?, on input: AVAudioInputNode) {
        guard let uid, let audioUnit = input.audioUnit else { return }
        guard var deviceID = AudioDevices.deviceID(forUID: uid) else {
            log.info("Preferred input device is not connected; using the system default")
            return
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log.error("Could not select input device \(uid, privacy: .public): OSStatus \(status)")
        }
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        do {
            try converter.convertOnce(buffer, into: output)
        } catch {
            return
        }

        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)

        // Root-mean-square is the cheap, standard loudness measure. vDSP keeps it off the
        // critical path even for large buffers.
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        // Asymmetric smoothing: jump to a new peak immediately so the bars feel responsive to
        // speech onset, but fall gradually so they do not flicker between syllables.
        let scaled = min(1, rms * 6)
        level = scaled > level ? scaled : level * 0.82 + scaled * 0.18
        lock.unlock()
    }
}
