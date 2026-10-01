import CoreAudio
import Foundation

/// Where Kliq's sounds play. Only Kliq's own output changes; the system's
/// default output device (music, videos, calls) is never touched.
enum OutputRoute: String, CaseIterable, Identifiable {
    /// The MacBook's built-in speakers, even with Bluetooth headphones connected.
    case builtInSpeakers
    /// Whatever the system output is (the behavior before this setting existed).
    case system

    static let `default` = OutputRoute.builtInSpeakers

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .builtInSpeakers: return "MacBook Speakers"
        case .system: return "Same as system output"
        }
    }

    /// Short label for the popover's segmented control.
    var shortName: String {
        switch self {
        case .builtInSpeakers: return "MacBook"
        case .system: return "System"
        }
    }
}

/// CoreAudio device lookups and change notifications.
enum AudioDevices {
    /// The Mac's built-in output: the speakers, or on Apple silicon the
    /// "External Headphones" device that replaces them while wired headphones
    /// are plugged in. Speakers win when both are listed. Nil when there is no
    /// built-in output (e.g. lid closed with an external display).
    static func builtInOutput() -> AudioDeviceID? {
        let candidates = allDevices().filter {
            transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn
                && isAlive($0)
                && !outputStreams(of: $0).isEmpty
        }
        let speakers = candidates.first { device in
            outputStreams(of: device).contains { terminalType(of: $0) == kAudioStreamTerminalTypeSpeaker }
        }
        return speakers ?? candidates.first
    }

    static func defaultOutput() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = globalAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "device \(device)" }
        return name.takeRetainedValue() as String
    }

    // MARK: Properties

    private static func allDevices() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32? {
        uint32(kAudioDevicePropertyTransportType, of: device)
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        uint32(kAudioDevicePropertyDeviceIsAlive, of: device) != 0
    }

    private static func terminalType(of stream: AudioStreamID) -> UInt32? {
        uint32(kAudioStreamPropertyTerminalType, of: stream)
    }

    private static func outputStreams(of device: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }

    private static func uint32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Calls `onChange` on the main queue when output devices come or go or the
/// default output changes (headphones connected or disconnected).
final class AudioDeviceWatcher {
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]

    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
