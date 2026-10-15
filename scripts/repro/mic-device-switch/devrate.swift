import CoreAudio
func defaultInputDevice() -> AudioObjectID {
    var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}
func nominalRate(_ dev: AudioObjectID) -> Double {
    var rate = Float64(0); var size = UInt32(MemoryLayout<Float64>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
    return rate
}
@discardableResult func setNominalRate(_ dev: AudioObjectID, _ hz: Double) -> OSStatus {
    var rate = Float64(hz)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
}
func availableRates(_ dev: AudioObjectID) -> [Double] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0); AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size)
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges)
    return ranges.map { $0.mMinimum }
}

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func deviceUID(_ dev: AudioObjectID) -> String {
    var a = addr(kAudioDevicePropertyDeviceUID); var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &uid)
    return uid!.takeRetainedValue() as String
}
@discardableResult func setDefaultInput(_ dev: AudioObjectID) -> OSStatus {
    var a = addr(kAudioHardwarePropertyDefaultInputDevice); var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
}
let harnessAggUID = "com.lucent.lisper.harness.agg"
func createAggregate(wrapping dev: AudioObjectID) -> AudioObjectID {
    let sub = deviceUID(dev)
    let desc: [String: Any] = [
        kAudioAggregateDeviceUIDKey: harnessAggUID,
        kAudioAggregateDeviceNameKey: "Lisper Harness Mic",
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: sub]],
        kAudioAggregateDeviceMainSubDeviceKey: sub,
        kAudioAggregateDeviceIsPrivateKey: 0,
    ]
    var id = AudioObjectID(0)
    let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
    print("createAggregate status=\(st) id=\(id)")
    return id
}
func destroyAggregate(_ id: AudioObjectID) { print("destroyAggregate status=\(AudioHardwareDestroyAggregateDevice(id))") }

func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func transportType(_ dev: AudioObjectID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType); var t = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t)
    return t
}
func hasInput(_ dev: AudioObjectID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    return AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr && size > 0
}
/// The Mac's built-in microphone — the harness always switches FROM it, whatever the user's
/// current default input is (e.g. Bluetooth headphones that only run at 16 kHz).
func builtInMic() -> AudioObjectID? {
    allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
}
/// Any leftover harness aggregate (e.g. from a run that was killed).
func existingHarnessAggregate() -> AudioObjectID? {
    allDevices().first { deviceUID($0) == harnessAggUID }
}

/// Device IDs are not stable (a Bluetooth headset gets a new one when it reconnects), so the
/// harness remembers the original default input by UID and resolves it again on restore.
func device(forUID uid: String) -> AudioObjectID? {
    allDevices().first { deviceUID($0) == uid }
}
