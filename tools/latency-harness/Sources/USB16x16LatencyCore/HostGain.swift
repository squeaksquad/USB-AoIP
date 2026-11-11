import CoreAudio
import Foundation

// The gain macOS applies to this device in each direction, measured through
// the loop instead of assumed. On 2026-10-10 it was 0.999998 each way
// (2^23-1 left the Mac as 8388590); on 2026-10-27 it was unity both ways
// (a 0.25 impulse reached the Pi as 2097152 and came back as 0.25), with no
// macOS update between. So `bitexact` and the soak reference measure it.
//
// Every channel holds a constant code for one step, and the steady value it
// returns is read at the end of the step. The path must carry each output to
// the input of the same number, which `bitexact` then confirms by locking.
//   - Small codes (a few thousand) leave the Mac unchanged by its output
//     rounding for any gain within 1e-4 of unity, so their return gives the
//     input gain: each reading allows the interval of gains whose product
//     rounds to that float, and the readings are intersected.
//   - Near-full-scale codes then give the output gain: the returned value,
//     divided by the input gain, is the whole code that reached the wire, and
//     each code allows a gain interval one code wide; intersected again.
// Nothing is assumed about the gain's value or about float or double
// arithmetic on the host. Inconsistent readings are a failure, never a guess.
public struct HostGain: Codable, Sendable, Equatable {
    public let outputGain: Double
    public let inputGain: Double
    /// Width of the interval each gain was narrowed to.
    public let outputGainWidth: Double
    public let inputGainWidth: Double
    /// The largest code the Mac can put on the wire at this output gain.
    public let limit: Int32

    public static let unity = HostGain(outputGain: 1, inputGain: 1, outputGainWidth: 0, inputGainWidth: 0)

    public init(outputGain: Double, inputGain: Double, outputGainWidth: Double, inputGainWidth: Double) {
        self.outputGain = outputGain
        self.inputGain = inputGain
        self.outputGainWidth = outputGainWidth
        self.inputGainWidth = inputGainWidth
        // A float client's largest sample is (2^23-1)/2^23 (2026-10-10: it arrived as 8388590 at 0.999998).
        limit = Int32(min(8_388_607, (8_388_607 * outputGain).rounded()))
    }
}

public struct HostGainReport: Encodable, Sendable {
    public let kind = "host-gain"
    public let device: CoreAudioDeviceSnapshot
    public let sampleRate: Int
    /// Channels 1...loopChannels were read; the rest were sent but are not looped.
    public let loopChannels: Int
    public let hostGain: HostGain
}

public enum HostGainError: Error, CustomStringConvertible {
    case unsteady(step: Int, channel: Int)
    case inconsistent(String)

    public var description: String {
        switch self {
        case let .unsteady(step, channel):
            return "host gain: channel \(channel + 1) did not return a steady level in step \(step + 1)"
        case let .inconsistent(detail):
            return "host gain: \(detail)"
        }
    }
}

public enum HostGainCalibration {
    static let scale = 8_388_608.0
    public static let steps = 4
    static let smallSteps = 2

    /// The code channel `channel` holds in `step`: small for the first two, near full scale after, signs alternating.
    public static func code(step: Int, channel: Int) -> Int32 {
        let sign: Int32 = (channel + step) % 2 == 0 ? 1 : -1
        let magnitude = step < smallSteps ? 2_000 + 97 * channel + 1_031 * step
                                          : 8_000_000 + 23_456 * channel + 11_111 * (step - smallSteps)
        return sign * Int32(magnitude)
    }

    /// The float sent for a code: exact, with no gain compensation.
    static func sample(step: Int, channel: Int) -> Float { Float(Double(code(step: step, channel: channel)) / scale) }

    /// Gains from the steady returns, `readings[step][channel]`. Only channels
    /// 1...loopChannels are read: a loop narrower than the device (2026-10-29: 8
    /// channels at 96 kHz, MADI halving) leaves the rest unreturned.
    public static func solve(_ readings: [[Float]], loopChannels: Int = 16) throws -> HostGain {
        guard readings.count == steps, readings.allSatisfy({ $0.count == 16 }) else {
            throw HostGainError.inconsistent("expected \(steps) steps of 16 readings")
        }
        guard (1...16).contains(loopChannels) else { throw HostGainError.inconsistent("loop channels \(loopChannels)") }
        var inLow = 0.0, inHigh = Double.infinity
        for step in 0..<smallSteps {
            for channel in 0..<loopChannels {
                let sent = Double(code(step: step, channel: channel)), back = readings[step][channel]
                guard back.isFinite, back != 0, (Double(back) > 0) == (sent > 0) else {
                    throw HostGainError.inconsistent("channel \(channel + 1) returned \(back) for code \(Int(sent))")
                }
                let half = Double(abs(back).ulp) / 2
                inLow = max(inLow, (Double(abs(back)) - half) * scale / abs(sent))
                inHigh = min(inHigh, (Double(abs(back)) + half) * scale / abs(sent))
            }
        }
        guard inLow <= inHigh, abs((inLow + inHigh) / 2 - 1) < 1e-4 else {
            throw HostGainError.inconsistent(String(format: "input gain interval [%.9f, %.9f]: the small codes disagree, or the gain is not near unity", inLow, inHigh))
        }
        let inputGain = (inLow + inHigh) / 2
        var outLow = 0.0, outHigh = Double.infinity
        for step in smallSteps..<steps {
            for channel in 0..<loopChannels {
                let sent = Double(code(step: step, channel: channel)), back = readings[step][channel]
                let codes = Double(back) * scale / inputGain
                let wire = codes.rounded()
                guard back.isFinite, abs(codes - wire) <= 0.3, (wire > 0) == (sent > 0) else {
                    throw HostGainError.inconsistent("channel \(channel + 1) returned \(back) for code \(Int(sent)), off the 24-bit grid at input gain \(inputGain)")
                }
                outLow = max(outLow, (abs(wire) - 0.5) / abs(sent))
                outHigh = min(outHigh, (abs(wire) + 0.5) / abs(sent))
            }
        }
        guard outLow <= outHigh, abs((outLow + outHigh) / 2 - 1) < 1e-4 else {
            throw HostGainError.inconsistent(String(format: "output gain interval [%.9f, %.9f]: the large codes disagree, or the gain is not near unity", outLow, outHigh))
        }
        return HostGain(outputGain: (outLow + outHigh) / 2, inputGain: inputGain,
                        outputGainWidth: outHigh - outLow, inputGainWidth: inHigh - inLow)
    }

    /// Run the steps on an open device: 0.5 s each, read at the end of each step.
    static func measure(id: AudioDeviceID, rate: Int, loopChannels: Int = 16) throws -> HostGain {
        let state = HostGainState(stepFrames: rate / 2)
        var proc: AudioDeviceIOProcID?
        func check(_ status: OSStatus) throws {
            if status != noErr { throw LiveMeasurementError.io(status, operation: "host gain") }
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, input, _, output, _ in
            state.process(input, output)
        })
        guard let proc else { throw LiveMeasurementError.noUsableInput }
        defer { AudioDeviceDestroyIOProcID(id, proc) }
        try check(AudioDeviceStart(id, proc))
        let completed = state.finished.wait(timeout: .now() + Double(steps) / 2 + 5) == .success
        try check(AudioDeviceStop(id, proc))
        guard completed else {
            throw LiveMeasurementError.timedOut(callbacks: 0, outputFrames: state.outputFrames,
                                               inputStarted: state.inputFrames > 0, impulses: 0)
        }
        for step in 0..<steps {
            for channel in 0..<loopChannels where state.steady[step][channel] < state.stepFrames / 4 {
                throw HostGainError.unsteady(step: step, channel: channel)
            }
        }
        return try solve(state.readings, loopChannels: loopChannels)
    }

    public static func run(deviceName: String, bufferFrames: UInt32, loopChannels: Int = 16) throws -> HostGainReport {
        guard bufferFrames == 32 || bufferFrames == 64, (1...16).contains(loopChannels) else {
            throw CoreAudioInspectionError.invalidProperty("host gain settings")
        }
        let before = try CoreAudioInspector.snapshot(named: deviceName)
        let id = AudioDeviceID(before.deviceID)
        try CoreAudioInspector.setBufferFrameSize(bufferFrames, on: id)
        defer { try? CoreAudioInspector.setBufferFrameSize(before.bufferFrameSize, on: id) }
        let device = try CoreAudioInspector.snapshot(named: deviceName)
        let rate = try SoakRate.validate(device, bufferFrames: bufferFrames)
        return HostGainReport(device: device, sampleRate: rate, loopChannels: loopChannels,
                              hostGain: try measure(id: id, rate: rate, loopChannels: loopChannels))
    }
}

/// The IOProc side: no allocation after init. The input lags the output by
/// the loop's latency (tens of ms), so a level read at the end of its step has
/// held for most of it; `steady` says for how many frames.
final class HostGainState: @unchecked Sendable {
    let stepFrames: Int
    let finished = DispatchSemaphore(value: 0)
    var outputFrames = 0
    var inputFrames = 0
    var readings = [[Float]](repeating: [Float](repeating: .nan, count: 16), count: HostGainCalibration.steps)
    var steady = [[Int]](repeating: [Int](repeating: 0, count: 16), count: HostGainCalibration.steps)
    private var last = [Float](repeating: .nan, count: 16)
    private var run = [Int](repeating: 0, count: 16)
    private var signaled = false

    init(stepFrames: Int) { self.stepFrames = stepFrames }

    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !signaled, outputs.count == 1, let out = outputs.first, out.mNumberChannels == 16,
              out.mDataByteSize % 64 == 0, let outData = out.mData else { return }
        let total = stepFrames * HostGainCalibration.steps
        let count = Int(out.mDataByteSize) / 64
        let samples = outData.assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
            let step = min((outputFrames + frame) / stepFrames, HostGainCalibration.steps - 1)
            for channel in 0..<16 { samples[frame * 16 + channel] = HostGainCalibration.sample(step: step, channel: channel) }
        }
        outputFrames += count

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if inputs.count == 1, let buffer = inputs.first, buffer.mNumberChannels == 16,
           buffer.mDataByteSize % 64 == 0, let data = buffer.mData {
            let values = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(buffer.mDataByteSize) / 64 {
                let index = inputFrames + frame
                guard index < total else { break }
                for channel in 0..<16 {
                    let value = values[frame * 16 + channel]
                    run[channel] = value == last[channel] ? run[channel] + 1 : 1
                    last[channel] = value
                }
                if index % stepFrames == stepFrames - 1 {
                    let step = index / stepFrames
                    for channel in 0..<16 { readings[step][channel] = last[channel]; steady[step][channel] = run[channel] }
                }
            }
            inputFrames += Int(buffer.mDataByteSize) / 64
        }
        if inputFrames >= total {
            signaled = true
            finished.signal()
        }
    }
}
