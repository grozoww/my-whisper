import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Which microphone the app records from.
///
/// `AVAudioEngine` follows the system default input unless told otherwise, which is wrong often
/// enough to matter: plugging in headphones or joining a call moves the default, and a dictation
/// tool that silently follows records the wrong device. Devices are identified by their CoreAudio
/// UID rather than their name, because names are neither unique nor stable.
enum AudioDevices {
    struct Device: Identifiable, Hashable, Sendable {
        /// CoreAudio UID. Survives reboots and renames; a `AudioDeviceID` does not.
        let id: String
        let name: String
        let isDefault: Bool
    }

    private static let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "audio")

    /// Every device with at least one input channel.
    static func inputs() -> [Device] {
        let defaultID = defaultInputDeviceID()

        return deviceIDs().compactMap { deviceID in
            guard inputChannelCount(of: deviceID) > 0 else { return nil }
            guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID) else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? uid
            return Device(id: uid, name: name, isDefault: deviceID == defaultID)
        }
    }

    /// Resolves a saved UID back to the live device. Returns `nil` when the device is unplugged,
    /// which the caller treats as "fall back to the system default" rather than as an error.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    /// Input channels, summed across the device's streams. Zero means it is an output-only device
    /// and has no business in a microphone picker.
    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        // AudioBufferList is variable-length, so it has to be allocated by hand rather than
        // declared — a plain `var list = AudioBufferList()` only has room for one buffer.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio writes a retained `CFStringRef` into the buffer. Passing `&someCFString`
        // directly makes Swift form a raw pointer to a managed reference, which it warns about and
        // is right to: the bridging is not guaranteed to survive. An unmanaged slot is the honest
        // way to receive a +1 reference from C.
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanaged) == noErr,
              let value = unmanaged
        else { return nil }
        return value.takeRetainedValue() as String
    }
}
