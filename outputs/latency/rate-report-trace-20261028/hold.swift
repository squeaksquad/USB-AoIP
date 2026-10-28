// hold NAME [BUFFER_FRAMES]: keep a CoreAudio device running with a silent IOProc
// (outputs zeroed, inputs ignored) until killed, so the device never stops between
// other clients. Made 2026-10-28 to test whether the round-trip level drawn at each
// harness open comes from the device's IO restarting.
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
guard let id = ids.first(where: { var n: CFString = "" as CFString; _ = prop($0, kAudioObjectPropertyName, &n); return (n as String) == args[1] }) else {
    print("no device \(args[1])"); exit(2)
}
if args.count > 2, var frames = UInt32(args[2]) {
    var w = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let s = AudioObjectSetPropertyData(id, &w, 0, nil, 4, &frames)
    if s != noErr { print("buffer set failed \(s)"); exit(1) }
}
var rate = 0.0, frames: UInt32 = 0
_ = prop(id, kAudioDevicePropertyNominalSampleRate, &rate)
_ = prop(id, kAudioDevicePropertyBufferFrameSize, &frames)
print("hold \(args[1]) rate=\(Int(rate)) buffer=\(frames)"); fflush(stdout)

final class Counters: @unchecked Sendable { var calls = 0 }
let c = Counters()
var proc: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, _, _, output, _ in
    c.calls += 1
    for buffer in UnsafeMutableAudioBufferListPointer(output) {
        if let o = buffer.mData { memset(o, 0, Int(buffer.mDataByteSize)) }
    }
}
guard status == noErr, let proc else { print("ioproc failed \(status)"); exit(1) }
guard AudioDeviceStart(id, proc) == noErr else { print("start failed"); exit(1) }
signal(SIGTERM) { _ in exit(0) }
while true {
    Thread.sleep(forTimeInterval: 10)
    print("calls=\(c.calls)"); fflush(stdout)
}
