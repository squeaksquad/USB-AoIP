// passthrough NAME [BUFFER_FRAMES]: copy a CoreAudio device's inputs to its own
// outputs, channel for channel, in one IOProc (one clock, no resampling), until
// killed. Made 2026-10-27 to turn Dante Virtual Soundcard into the far end of a
// 96 kHz loop for the Pi. Every 10 s it prints the callbacks, the input peak, and
// the callbacks whose input and output buffers did not match in shape.
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
print("passthrough \(args[1]) rate=\(Int(rate)) buffer=\(frames)"); fflush(stdout)

final class Counters: @unchecked Sendable { var calls = 0; var mismatched = 0; var peak: Float = 0 }
let c = Counters()
var proc: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, input, _, output, _ in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outs = UnsafeMutableAudioBufferListPointer(output)
    c.calls += 1
    if ins.count != outs.count { c.mismatched += 1 }
    for i in 0..<outs.count {
        guard let o = outs[i].mData else { continue }
        guard i < ins.count, let src = ins[i].mData, ins[i].mDataByteSize == outs[i].mDataByteSize,
              ins[i].mNumberChannels == outs[i].mNumberChannels else {
            memset(o, 0, Int(outs[i].mDataByteSize)); c.mismatched += 1; continue
        }
        memcpy(o, src, Int(outs[i].mDataByteSize))
        let f = src.assumingMemoryBound(to: Float.self)
        for k in 0..<Int(ins[i].mDataByteSize) / 4 { c.peak = max(c.peak, abs(f[k])) }
    }
}
guard status == noErr, let proc else { print("ioproc failed \(status)"); exit(1) }
guard AudioDeviceStart(id, proc) == noErr else { print("start failed"); exit(1) }
signal(SIGTERM) { _ in exit(0) }
while true {
    Thread.sleep(forTimeInterval: 10)
    print("calls=\(c.calls) mismatched=\(c.mismatched) peak=\(c.peak)"); fflush(stdout)
    c.peak = 0
}
