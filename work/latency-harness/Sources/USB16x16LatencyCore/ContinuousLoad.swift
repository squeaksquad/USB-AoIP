import CoreAudio
import Foundation

// Bounded statistics: no recording buffer grows with the soak duration.
public struct ChannelActivity: Encodable, Sendable {
    public private(set) var samples = 0
    public private(set) var peak: Float = 0
    public private(set) var sumSquares: Double = 0
    public private(set) var longestZeroRun = 0
    public private(set) var nonFinite = 0
    public private(set) var fullScaleSamples = 0
    private var zeroRun = 0
    public var rms: Double { samples > 0 ? sqrt(sumSquares / Double(samples)) : 0 }

    private enum CodingKeys: String, CodingKey {
        case samples, peak, rms, longestZeroRun, nonFinite, fullScaleSamples
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(samples, forKey: .samples)
        try values.encode(peak, forKey: .peak)
        try values.encode(rms, forKey: .rms)
        try values.encode(longestZeroRun, forKey: .longestZeroRun)
        try values.encode(nonFinite, forKey: .nonFinite)
        try values.encode(fullScaleSamples, forKey: .fullScaleSamples)
    }

    mutating func observe(_ value: Float) {
        samples += 1
        guard value.isFinite else { nonFinite += 1; zeroRun = 0; return }
        peak = max(peak, abs(value))
        sumSquares += Double(value) * Double(value)
        if abs(value) >= 1 { fullScaleSamples += 1 }
        zeroRun = value == 0 ? zeroRun + 1 : 0
        longestZeroRun = max(longestZeroRun, zeroRun)
    }
}

public struct ContinuousLoadReport: Encodable, Sendable {
    public let kind = "continuous-activity-not-latency"
    public let device: CoreAudioDeviceSnapshot
    public let seconds: Int
    public let amplitude: Float
    public let warmupSeconds = 2
    public let outputFrames: Int
    public let inputFrames: Int
    public let inputDiscontinuities: Int
    public let outputDiscontinuities: Int
    public let invalidBuffers: Int
    public let invalidTimestamps: Int
    public let channels: [ChannelActivity]
    public let eventCapture: ContinuousEventReport
}

final class ContinuousState: @unchecked Sendable {
    let totalFrames: Int
    let amplitude: Float
    let finished = DispatchSemaphore(value: 0)
    var outputFrames = 0
    var inputFrames = 0
    var inputDiscontinuities = 0
    var outputDiscontinuities = 0
    var invalidBuffers = 0
    var invalidTimestamps = 0
    var channels = [ChannelActivity](repeating: ChannelActivity(), count: 16)
    let eventCapture = ContinuousEventCapture()
    var load = DeterministicChannelLoad()
    var expectedInput: Double?
    var expectedOutput: Double?
    var signaled = false

    init(seconds: Int, amplitude: Float) {
        totalFrames = seconds * 48_000
        self.amplitude = amplitude
    }

    func process(_ input: UnsafePointer<AudioBufferList>, _ inputTime: Double,
                 _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: Double,
                 inputTimeValid: Bool = true, outputTimeValid: Bool = true) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !signaled else { return }
        guard outputs.count == 1, let out = outputs.first, out.mNumberChannels == 16,
              out.mDataByteSize > 0, out.mDataByteSize % 64 == 0, let outData = out.mData else {
            invalidBuffers += 1
            eventCapture.breakContinuity()
            expectedInput = nil; expectedOutput = nil
            return
        }
        let count = Int(out.mDataByteSize) / 64
        let validOutputTime = outputTimeValid && outputTime.isFinite
        let validInputTime = inputTimeValid && inputTime.isFinite
        var continuityBroken = false
        if !validOutputTime { invalidTimestamps += 1; continuityBroken = true }
        if validOutputTime, let expectedOutput, abs(outputTime - expectedOutput) > 0.5 {
            outputDiscontinuities += 1; continuityBroken = true
        }
        expectedOutput = validOutputTime ? outputTime + Double(count) : nil
        let outputFirstFrame = outputFrames
        let samples = outData.assumingMemoryBound(to: Float.self)
        if !signaled {
            for i in 0..<(count * 16) { samples[i] = load.next(amplitude: amplitude) }
            outputFrames += count
        }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if inputs.count == 1, let buffer = inputs.first, buffer.mNumberChannels == 16,
           buffer.mDataByteSize > 0, buffer.mDataByteSize % 64 == 0, let data = buffer.mData {
            let frames = Int(buffer.mDataByteSize) / 64
            if !validInputTime { invalidTimestamps += 1; continuityBroken = true }
            if validInputTime, let expectedInput, abs(inputTime - expectedInput) > 0.5 {
                inputDiscontinuities += 1; continuityBroken = true
            }
            expectedInput = validInputTime ? inputTime + Double(frames) : nil
            if !signaled {
                if continuityBroken { eventCapture.breakContinuity() }
                let values = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let armed = inputFrames + frame >= 96_000
                    eventCapture.observe(values.advanced(by: frame * 16),
                        inputFrame: inputFrames + frame,
                        inputTime: validInputTime ? inputTime + Double(frame) : nil,
                        outputFrame: outputFirstFrame, outputTime: validOutputTime ? outputTime : nil,
                        outputFrames: count, armed: armed)
                    if armed {
                        for channel in 0..<16 { channels[channel].observe(values[frame * 16 + channel]) }
                    }
                }
                inputFrames += frames
            }
        } else {
            invalidBuffers += 1
            eventCapture.breakContinuity()
            expectedInput = nil
        }
        if !signaled, outputFrames >= totalFrames {
            signaled = true
            finished.signal()
        }
    }
}

public enum ContinuousLoad {
    public static func run(deviceName: String, bufferFrames: UInt32,
                           seconds: Int, amplitude: Float) throws -> ContinuousLoadReport {
        guard (5...600).contains(seconds), amplitude.isFinite, amplitude > 0, amplitude <= 0.1,
              bufferFrames == 32 || bufferFrames == 64 else {
            throw CoreAudioInspectionError.invalidProperty("continuous load settings")
        }
        let before = try CoreAudioInspector.snapshot(named: deviceName)
        let id = AudioDeviceID(before.deviceID)
        try CoreAudioInspector.setBufferFrameSize(bufferFrames, on: id)
        defer { try? CoreAudioInspector.setBufferFrameSize(before.bufferFrameSize, on: id) }
        let device = try CoreAudioInspector.snapshot(named: deviceName)
        guard device.input.channels == 16, device.output.channels == 16,
              device.nominalSampleRate == 48_000, device.bufferFrameSize == bufferFrames,
              (device.input.streams + device.output.streams).allSatisfy({
                  $0.formatID == "lpcm" && $0.bitsPerChannel == 32 && $0.interleaved &&
                  $0.bytesPerFrame == 64 && $0.sampleRate == 48_000 &&
                  (UInt32($0.formatFlagsHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0) & 1 == 1
              }) else { throw CoreAudioInspectionError.invalidProperty("48 kHz interleaved Float32 16x16") }
        let state = ContinuousState(seconds: seconds, amplitude: amplitude)
        var proc: AudioDeviceIOProcID?
        func check(_ status: OSStatus) throws {
            if status != noErr { throw LiveMeasurementError.io(status, operation: "continuous load") }
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, input, inputTime, output, outputTime in
            state.process(input, inputTime.pointee.mSampleTime, output, outputTime.pointee.mSampleTime,
                inputTimeValid: inputTime.pointee.mFlags.contains(.sampleTimeValid),
                outputTimeValid: outputTime.pointee.mFlags.contains(.sampleTimeValid))
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
        return ContinuousLoadReport(device: device, seconds: seconds, amplitude: amplitude,
            outputFrames: state.outputFrames, inputFrames: state.inputFrames,
            inputDiscontinuities: state.inputDiscontinuities, outputDiscontinuities: state.outputDiscontinuities,
            invalidBuffers: state.invalidBuffers, invalidTimestamps: state.invalidTimestamps,
            channels: state.channels, eventCapture: state.eventCapture.report())
    }
}
