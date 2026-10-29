import CoreAudio
import Foundation

// Bit transparency from the Mac: every output channel carries its own
// full-period 24-bit sequence in which each sample predicts the next, so the
// return is checked sample for sample with no alignment and no recording. The
// period is 2^24 samples (349.5 s at 48 kHz). The same idea as the Pi probe's
// pattern check (work/dante-mode/probe), from the other end of the path.
//
// macOS is not always bit-exact on this device by itself. On 2026-10-10 it
// multiplied by 0.999998 on the way out and again on the way in (2^23-1
// arrived on the Pi as 8388590, 2^21 as 2097148, 2^17 as itself); on
// 2026-10-27 it was unity both ways. So each run first measures the gain
// through the loop (HostGain.swift), and the sequence is defined on the codes
// that reach the wire: each float is chosen to land on its code after that
// gain, and each returned float is divided by the gain to recover the code it
// came from. Codes beyond the gain's limit (+/-8388590 at 0.999998) cannot be
// sent by a Mac at all; the sequence clamps there, and a sample after a
// clamped one is passed over, not judged.
public enum BitExactSequence {
    static let multiplier: UInt32 = 1_664_525          // 1 mod 4, with an odd increment: full period mod 2^24
    static let mask: UInt32 = 0x00FF_FFFF
    static let scale: Float = 8_388_608

    static func increment(channel: Int) -> UInt32 { (1_013_904_223 &+ UInt32(2 * channel)) & mask }
    static func next(_ code: UInt32, channel: Int) -> UInt32 {
        (code &* multiplier &+ increment(channel: channel)) & mask
    }
    static func signed(_ code: UInt32) -> Int32 {
        code >= 0x0080_0000 ? Int32(code) - 0x0100_0000 : Int32(code)
    }
    /// The code a sequence value is sent as: itself, held at the limit.
    static func wire(_ code: UInt32, _ gain: HostGain) -> Int32 { max(-gain.limit, min(gain.limit, signed(code))) }
    static func atLimit(_ code: UInt32, _ gain: HostGain) -> Bool { abs(signed(code)) >= gain.limit }

    /// The float that the host's gain and rounding turn into `wire`. Runs in
    /// the IOProc: no allocation.
    static func sample(wire: Int32, _ gain: HostGain) -> Float {
        let target = Double(wire), product = gain.outputGain * Double(scale)
        let ideal = Float(target / product)
        var best = ideal
        var bestError = abs(Double(ideal) * product - target)
        let up = ideal.nextUp
        let upError = abs(Double(up) * product - target)
        if upError < bestError { best = up; bestError = upError }
        let down = ideal.nextDown
        if abs(Double(down) * product - target) < bestError { best = down }
        return best
    }
    /// The code a returned float came from, and how far from a whole code it was.
    static func received(_ value: Float, _ gain: HostGain) -> (code: Int32, error: Double) {
        let codes = Double(value) * Double(scale) / gain.inputGain
        let rounded = codes.rounded()
        return (Int32(max(-8_388_608, min(8_388_607, rounded))), abs(codes - rounded))
    }
}

public struct BitExactChannel: Encodable, Sendable {
    /// Output channel (1-based) whose sequence this input carries; 0 until it locks.
    public private(set) var source = 0
    public private(set) var firstLockFrame = -1
    public private(set) var matches = 0
    public private(set) var mismatchesAfterLock = 0
    public private(set) var lostLocks = 0
    public private(set) var lastLostLockFrame = -1
    public private(set) var offGridAfterLock = 0
    /// Samples that matched the sequence at the largest codes the host can send.
    public private(set) var positiveLimit = 0
    public private(set) var negativeLimit = 0
    /// Samples passed over because the one before them was a clamped code.
    public private(set) var unjudged = 0
    public private(set) var longestZeroRunAfterLock = 0
    private let gain: HostGain
    private var previous: UInt32?
    private var locked = false
    private var zeroRun = 0

    private enum CodingKeys: String, CodingKey {
        case source, firstLockFrame, matches, mismatchesAfterLock, lostLocks, lastLostLockFrame, offGridAfterLock
        case positiveLimit, negativeLimit, unjudged, longestZeroRunAfterLock
    }

    init(gain: HostGain) { self.gain = gain }

    mutating func observe(_ value: Float, frame: Int) {
        let (wire, error) = value.isFinite ? BitExactSequence.received(value, gain) : (0, 1)
        if error > 0.3 {
            if firstLockFrame >= 0 { offGridAfterLock += 1; mismatchesAfterLock += 1 }
            if locked { lostLocks += 1; lastLostLockFrame = frame; locked = false }
            previous = nil
            return
        }
        if firstLockFrame >= 0 {
            zeroRun = wire == 0 ? zeroRun + 1 : 0
            longestZeroRunAfterLock = max(longestZeroRunAfterLock, zeroRun)
        }
        let code = UInt32(truncatingIfNeeded: wire) & BitExactSequence.mask
        guard let previous else {
            // Nothing to predict from. A clamped code does not say which value it was.
            if locked { unjudged += 1 }
            self.previous = abs(wire) >= gain.limit ? nil : code
            return
        }
        if locked {
            let expected = BitExactSequence.next(previous, channel: source - 1)
            if wire == BitExactSequence.wire(expected, gain) {
                matched(expected)
            } else {
                mismatchesAfterLock += 1
                lostLocks += 1
                lastLostLockFrame = frame
                locked = false
                self.previous = abs(wire) >= gain.limit ? nil : code
            }
            return
        }
        // Not locked: whose sequence, if anyone's, does this pair of samples belong to?
        for channel in 0..<16 {
            let expected = BitExactSequence.next(previous, channel: channel)
            guard wire == BitExactSequence.wire(expected, gain), !BitExactSequence.atLimit(expected, gain) else { continue }
            source = channel + 1
            locked = true
            if firstLockFrame < 0 { firstLockFrame = frame }
            matched(expected)
            return
        }
        if firstLockFrame >= 0 { mismatchesAfterLock += 1 }
        self.previous = abs(wire) >= gain.limit ? nil : code
    }

    private mutating func matched(_ expected: UInt32) {
        matches += 1
        let value = BitExactSequence.signed(expected)
        if value >= gain.limit { positiveLimit += 1 }
        if value <= -gain.limit { negativeLimit += 1 }
        previous = BitExactSequence.atLimit(expected, gain) ? nil : expected
    }
}

public struct BitExactReport: Encodable, Sendable {
    public let kind = "bit-exact-24"
    public let device: CoreAudioDeviceSnapshot
    public let sampleRate: Int
    public let seconds: Int
    public let outputFrames: Int
    public let inputFrames: Int
    public let inputDiscontinuities: Int
    public let outputDiscontinuities: Int
    public let invalidBuffers: Int
    public let channels: [BitExactChannel]
    /// Channels 1...loopChannels are judged; the rest carry their sequence but are not looped.
    public let loopChannels: Int
    /// Measured through the loop just before the sequence ran.
    public let hostGain: HostGain
    public let largestCode: Int32
    /// Every looped input locked on its own output's sequence and never left it, nothing
    /// off the 24-bit grid, and the largest codes of both signs came back on every one.
    public let pass: Bool

    /// The verdict over channels 1...loopChannels.
    public static func passes(_ channels: [BitExactChannel], loopChannels: Int, fullScaleDue: Bool,
                              inputDiscontinuities: Int, outputDiscontinuities: Int, invalidBuffers: Int) -> Bool {
        channels.prefix(loopChannels).enumerated().allSatisfy { index, channel in
            channel.source == index + 1 && channel.firstLockFrame >= 0 && channel.mismatchesAfterLock == 0 &&
                channel.lostLocks == 0 && channel.offGridAfterLock == 0 &&
                (!fullScaleDue || (channel.positiveLimit > 0 && channel.negativeLimit > 0))
        } && inputDiscontinuities == 0 && outputDiscontinuities == 0 && invalidBuffers == 0
    }
}

final class BitExactState: @unchecked Sendable {
    let totalFrames: Int
    let finished = DispatchSemaphore(value: 0)
    var outputFrames = 0
    var inputFrames = 0
    var inputDiscontinuities = 0
    var outputDiscontinuities = 0
    var invalidBuffers = 0
    let gain: HostGain
    var channels: [BitExactChannel]
    var codes: [UInt32] = (0..<16).map { UInt32($0) &* 0x0001_0001 }
    var expectedInput: Double?
    var expectedOutput: Double?
    var signaled = false

    init(seconds: Int, sampleRate: Int = 48_000, gain: HostGain) {
        totalFrames = seconds * sampleRate
        self.gain = gain
        channels = [BitExactChannel](repeating: BitExactChannel(gain: gain), count: 16)
    }

    func process(_ input: UnsafePointer<AudioBufferList>, _ inputTime: Double,
                 _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: Double) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !signaled else { return }
        guard outputs.count == 1, let out = outputs.first, out.mNumberChannels == 16,
              out.mDataByteSize > 0, out.mDataByteSize % 64 == 0, let outData = out.mData else {
            invalidBuffers += 1
            return
        }
        let count = Int(out.mDataByteSize) / 64
        if let expectedOutput, abs(outputTime - expectedOutput) > 0.5 { outputDiscontinuities += 1 }
        expectedOutput = outputTime + Double(count)
        let samples = outData.assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
            for channel in 0..<16 {
                codes[channel] = BitExactSequence.next(codes[channel], channel: channel)
                samples[frame * 16 + channel] = BitExactSequence.sample(wire: BitExactSequence.wire(codes[channel], gain), gain)
            }
        }
        outputFrames += count

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if inputs.count == 1, let buffer = inputs.first, buffer.mNumberChannels == 16,
           buffer.mDataByteSize > 0, buffer.mDataByteSize % 64 == 0, let data = buffer.mData {
            let frames = Int(buffer.mDataByteSize) / 64
            if let expectedInput, abs(inputTime - expectedInput) > 0.5 { inputDiscontinuities += 1 }
            expectedInput = inputTime + Double(frames)
            let values = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<16 {
                    channels[channel].observe(values[frame * 16 + channel], frame: inputFrames + frame)
                }
            }
            inputFrames += frames
        } else {
            invalidBuffers += 1
        }
        if outputFrames >= totalFrames {
            signaled = true
            finished.signal()
        }
    }
}

public enum BitExact {
    public static func run(deviceName: String, bufferFrames: UInt32, seconds: Int, loopChannels: Int = 16) throws -> BitExactReport {
        guard (5...3600).contains(seconds), bufferFrames == 32 || bufferFrames == 64, (1...16).contains(loopChannels) else {
            throw CoreAudioInspectionError.invalidProperty("bit-exact settings")
        }
        let before = try CoreAudioInspector.snapshot(named: deviceName)
        let id = AudioDeviceID(before.deviceID)
        try CoreAudioInspector.setBufferFrameSize(bufferFrames, on: id)
        defer { try? CoreAudioInspector.setBufferFrameSize(before.bufferFrameSize, on: id) }
        let device = try CoreAudioInspector.snapshot(named: deviceName)
        let rate = try SoakRate.validate(device, bufferFrames: bufferFrames)
        let gain = try HostGainCalibration.measure(id: id, rate: rate, loopChannels: loopChannels)
        let state = BitExactState(seconds: seconds, sampleRate: rate, gain: gain)
        var proc: AudioDeviceIOProcID?
        func check(_ status: OSStatus) throws {
            if status != noErr { throw LiveMeasurementError.io(status, operation: "bit-exact run") }
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, input, inputTime, output, outputTime in
            state.process(input, inputTime.pointee.mSampleTime, output, outputTime.pointee.mSampleTime)
        })
        guard let proc else { throw LiveMeasurementError.noUsableInput }
        defer { AudioDeviceDestroyIOProcID(id, proc) }
        try check(AudioDeviceStart(id, proc))
        let completed = state.finished.wait(timeout: .now() + Double(seconds) + 5) == .success
        try check(AudioDeviceStop(id, proc))
        guard completed else {
            throw LiveMeasurementError.timedOut(callbacks: 0, outputFrames: state.outputFrames,
                                               inputStarted: state.inputFrames > 0, impulses: 0)
        }
        // One period of the sequence is 2^24 samples: 360 s covers it at 48 kHz.
        let fullScaleDue = seconds * rate >= 360 * 48_000
        let pass = BitExactReport.passes(state.channels, loopChannels: loopChannels, fullScaleDue: fullScaleDue,
            inputDiscontinuities: state.inputDiscontinuities, outputDiscontinuities: state.outputDiscontinuities,
            invalidBuffers: state.invalidBuffers)
        return BitExactReport(device: device, sampleRate: rate, seconds: seconds, outputFrames: state.outputFrames,
            inputFrames: state.inputFrames, inputDiscontinuities: state.inputDiscontinuities,
            outputDiscontinuities: state.outputDiscontinuities, invalidBuffers: state.invalidBuffers,
            channels: state.channels, loopChannels: loopChannels, hostGain: gain, largestCode: gain.limit, pass: pass)
    }
}
