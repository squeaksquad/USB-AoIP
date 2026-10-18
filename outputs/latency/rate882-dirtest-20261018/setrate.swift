// setrate NAME [RATE]: read, or set, a CoreAudio device's nominal sample rate.
import CoreAudio
import Foundation
func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
}
let args = CommandLine.arguments
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
for id in ids {
    var name: CFString = "" as CFString
    _ = prop(id, kAudioObjectPropertyName, &name)
    guard (name as String) == args[1] else { continue }
    if args.count > 2, let r = Double(args[2]) {
        var rate = r
        var w = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let s = AudioObjectSetPropertyData(id, &w, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
        if s != noErr { print("set failed \(s)"); exit(1) }
        Thread.sleep(forTimeInterval: 1.5)
    }
    var now = 0.0
    _ = prop(id, kAudioDevicePropertyNominalSampleRate, &now)
    print("\(args[1]) nominal=\(Int(now))"); exit(0)
}
print("no device \(args[1])"); exit(2)
