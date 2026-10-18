// hold NAME SECONDS: keep the device's IO running, writing zeros, for SECONDS.
import CoreAudio
import Foundation
let args = CommandLine.arguments
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
var target: AudioObjectID = 0
for id in ids {
    var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &n, 0, nil, &s, &name)
    if let name, (name.takeRetainedValue() as String) == args[1] { target = id }
}
guard target != 0 else { print("no device"); exit(2) }
var proc: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&proc, target, nil) { _, _, _, output, _ in
    for b in UnsafeMutableAudioBufferListPointer(output) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
}
AudioDeviceStart(target, proc)
print("holding \(args[1]) for \(args[2]) s"); fflush(stdout)
Thread.sleep(forTimeInterval: Double(args[2]) ?? 10)
AudioDeviceStop(target, proc); AudioDeviceDestroyIOProcID(target, proc!)
