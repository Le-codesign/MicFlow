import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole") || uid.localizedCaseInsensitiveContains("BlackHole")
    }
}

/// Thin wrappers around the CoreAudio HAL property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name,
                               inputChannels: streamChannels(id, scope: kAudioObjectPropertyScopeInput).reduce(0, +),
                               outputChannels: streamChannels(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +))
        }
    }

    static func defaultInputDevice() -> AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutputDevice() -> AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioObjectID) -> Bool {
        if defaultOutputDevice() == id { return true }
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var addr = address(selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Channel count of each stream in the given scope, in the order the HAL hands buffers to an IOProc.
    static func streamChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Float64? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Float64) -> Bool {
        if nominalSampleRate(id) == rate { return true }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// Raises the device's own input level to 100%, on the main element and on each channel that has one.
    static func setInputVolumeToMax(_ id: AudioObjectID) {
        let channels = streamChannels(id, scope: kAudioObjectPropertyScopeInput).reduce(0, +)
        for element in 0...UInt32(channels) {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &addr),
                  AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { continue }
            var volume: Float32 = 1
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        }
    }
}
