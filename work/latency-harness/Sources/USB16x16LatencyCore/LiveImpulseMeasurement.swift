import CoreAudio
import Foundation

public enum LiveMeasurementError: Error, CustomStringConvertible {
    case invalidChannel(direction: String, requested: Int, available: UInt32)
    case io(OSStatus, operation: String)
    case noUsableInput
    case noImpulseTimestamps
    case timedOut(callbacks: Int, outputFrames: Int, inputStarted: Bool, impulses: Int)

    public var description: String {
        switch self {
        case let .invalidChannel(direction, requested, available):
            return "\(direction) channel \(requested) is outside 1...\(available)"
        case let .io(status, operation):
            return "\(operation) failed with CoreAudio status \(status)"
        case .noUsableInput:
            return "CoreAudio supplied no usable interleaved Float32 input"
        case .noImpulseTimestamps:
            return "CoreAudio produced no impulse output timestamps"
        case let .timedOut(callbacks, outputFrames, inputStarted, impulses):
            return "live measurement timed out (callbacks=\(callbacks), outputFrames=\(outputFrames), inputStarted=\(inputStarted), impulses=\(impulses))"
        }
    }
}

public struct LiveMeasurementConfiguration: Codable, Equatable, Sendable {
    public var deviceName: String
    public var bufferFrames: UInt32
    public var inputChannel: Int
    public var outputChannel: Int
    public var impulseCount: Int
    public var impulseAmplitude: Float
    public var intervalMilliseconds: Double
    public var leadInMilliseconds: Double
    public var maximumLagMilliseconds: Double
    public var peakSearchRadiusSamples: Int
    public var otherChannelLoadAmplitude: Float

    public init(
        deviceName: String = "USB 16x16",
        bufferFrames: UInt32 = 64,
        inputChannel: Int = 1,
        outputChannel: Int = 1,
        impulseCount: Int = 20,
        impulseAmplitude: Float = 0.25,
        intervalMilliseconds: Double = 250,
        leadInMilliseconds: Double = 500,
        maximumLagMilliseconds: Double = 200,
        peakSearchRadiusSamples: Int = 8,
        otherChannelLoadAmplitude: Float = 0
    ) {
        self.deviceName = deviceName
        self.bufferFrames = bufferFrames
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.impulseCount = impulseCount
        self.impulseAmplitude = impulseAmplitude
        self.intervalMilliseconds = intervalMilliseconds
        self.leadInMilliseconds = leadInMilliseconds
        self.maximumLagMilliseconds = maximumLagMilliseconds
        self.peakSearchRadiusSamples = peakSearchRadiusSamples
        self.otherChannelLoadAmplitude = otherChannelLoadAmplitude
    }
}

struct DeterministicChannelLoad {
    private var state: UInt32 = 0x9e37_79b9

    mutating func next(amplitude: Float) -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        let normalized = Float(Int32(bitPattern: state)) / Float(Int32.max)
        return max(-1, min(1, normalized)) * amplitude
    }
}

public struct LiveMeasurementReport: Codable, Equatable, Sendable {
    public let capturedAt: String
    public let deviceBefore: CoreAudioDeviceSnapshot
    public let deviceDuring: CoreAudioDeviceSnapshot
    public let configuration: LiveMeasurementConfiguration
    public let impulseOutputSampleTimes: [Double]
    public let inputBaseSampleTime: Double
    public let inputDiscontinuities: Int
    public let outputDiscontinuities: Int
    public let capturedPeak: Float
    public let correlation: CorrelationResult
}

private final class MeasurementState: @unchecked Sendable {
    let configuration: LiveMeasurementConfiguration
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
    let leadFrames: Int
    let intervalFrames: Int
    let maximumLagFrames: Int
    let totalFrames: Int
    let impulseFrames: Set<Int>
    let finished = DispatchSemaphore(value: 0)

    private(set) var outputFrameCounter = 0
    private(set) var callbackCount = 0
    private(set) var inputBaseSampleTime: Double?
    private(set) var capture: [Float]
    private(set) var impulseOutputSampleTimes: [Double] = []
    private(set) var inputDiscontinuities = 0
    private(set) var outputDiscontinuities = 0
    // Diagnostics: raw input as delivered, independent of placement.
    private(set) var rawInputPeak: Float = 0
    private(set) var inputCallbacksWithData = 0
    private(set) var inputCallbacksSkipped = 0
    private(set) var copiedFrames = 0
    private(set) var placementMisses = 0
    private(set) var firstOutputSampleTime: Double?
    private(set) var firstInputSampleTime: Double?
    private(set) var lastInputSampleTime: Double?
    private(set) var firstInputByteSize: UInt32 = 0
    private var expectedInputSampleTime: Double?
    private var expectedOutputSampleTime: Double?
    private var completionSignaled = false
    private var channelLoad = DeterministicChannelLoad()
    static let impulseLength: Int = Int(ProcessInfo.processInfo.environment["USB16X16_IMPULSE_LEN"] ?? "1") ?? 1

    init(
        configuration: LiveMeasurementConfiguration,
        sampleRate: Double,
        inputChannels: Int,
        outputChannels: Int
    ) {
        callbackCount += 1
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        let calculatedLeadFrames = Int(
            (configuration.leadInMilliseconds * sampleRate / 1_000).rounded()
        )
        let calculatedIntervalFrames = max(
            1,
            Int((configuration.intervalMilliseconds * sampleRate / 1_000).rounded())
        )
        let calculatedMaximumLagFrames = max(
            1,
            Int((configuration.maximumLagMilliseconds * sampleRate / 1_000).rounded())
        )
        leadFrames = calculatedLeadFrames
        intervalFrames = calculatedIntervalFrames
        maximumLagFrames = calculatedMaximumLagFrames
        let markers = (0..<configuration.impulseCount).map {
            calculatedLeadFrames + $0 * calculatedIntervalFrames
        }
        impulseFrames = Set(markers)
        let calculatedTotalFrames =
            (markers.last ?? calculatedLeadFrames) +
            calculatedMaximumLagFrames +
            Int(sampleRate * 0.5)
        totalFrames = calculatedTotalFrames
        capture = [Float](
            repeating: 0,
            count: calculatedTotalFrames + calculatedMaximumLagFrames
        )
    }

    func process(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>,
        frameCountHint: Int
    ) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in outputBuffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let outputSampleTime = outputTime.pointee.mSampleTime
        if firstOutputSampleTime == nil { firstOutputSampleTime = outputSampleTime }
        if let expectedOutputSampleTime,
           abs(outputSampleTime - expectedOutputSampleTime) > 0.5 {
            outputDiscontinuities += 1
        }

        var renderedFrames = frameCountHint
        if let buffer = outputBuffers.first,
           let data = buffer.mData,
           Int(buffer.mNumberChannels) == outputChannels,
           buffer.mDataByteSize >= UInt32(outputChannels * MemoryLayout<Float>.size) {
            renderedFrames = min(
                frameCountHint,
                Int(buffer.mDataByteSize) / (outputChannels * MemoryLayout<Float>.size)
            )
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<renderedFrames {
                let absoluteFrame = outputFrameCounter + frame
                if configuration.otherChannelLoadAmplitude > 0 {
                    for channel in 0..<outputChannels
                    where channel != configuration.outputChannel - 1 {
                        samples[frame * outputChannels + channel] = channelLoad.next(
                            amplitude: configuration.otherChannelLoadAmplitude
                        )
                    }
                }
                if impulseFrames.contains(absoluteFrame) {
                    samples[frame * outputChannels + configuration.outputChannel - 1] =
                        configuration.impulseAmplitude
                    impulseOutputSampleTimes.append(outputSampleTime + Double(frame))
                } else if Self.impulseLength > 1,
                          (1..<Self.impulseLength).contains(where: { impulseFrames.contains(absoluteFrame - $0) }) {
                    samples[frame * outputChannels + configuration.outputChannel - 1] =
                        configuration.impulseAmplitude
                }
            }
        }
        outputFrameCounter += renderedFrames
        expectedOutputSampleTime = outputSampleTime + Double(renderedFrames)

        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let inputSampleTime = inputTime.pointee.mSampleTime
        if firstInputSampleTime == nil {
            firstInputSampleTime = inputSampleTime
            firstInputByteSize = inputBuffers.first?.mDataByteSize ?? 0
        }
        lastInputSampleTime = inputSampleTime
        if inputBaseSampleTime == nil { inputBaseSampleTime = inputSampleTime }
        if let expectedInputSampleTime,
           abs(inputSampleTime - expectedInputSampleTime) > 0.5 {
            inputDiscontinuities += 1
        }

        if let base = inputBaseSampleTime,
           let buffer = inputBuffers.first,
           let data = buffer.mData,
           Int(buffer.mNumberChannels) == inputChannels,
           buffer.mDataByteSize >= UInt32(inputChannels * MemoryLayout<Float>.size) {
            let inputFrames = min(
                frameCountHint,
                Int(buffer.mDataByteSize) / (inputChannels * MemoryLayout<Float>.size)
            )
            let destinationStart = Int((inputSampleTime - base).rounded())
            let samples = data.assumingMemoryBound(to: Float.self)
            inputCallbacksWithData += 1
            for frame in 0..<inputFrames {
                let value = abs(samples[frame * inputChannels + configuration.inputChannel - 1])
                if value > rawInputPeak { rawInputPeak = value }
            }
            if destinationStart >= 0, destinationStart < capture.count {
                let copyCount = min(inputFrames, capture.count - destinationStart)
                copiedFrames += copyCount
                for frame in 0..<copyCount {
                    capture[destinationStart + frame] =
                        samples[frame * inputChannels + configuration.inputChannel - 1]
                }
            } else {
                placementMisses += 1
            }
            expectedInputSampleTime = inputSampleTime + Double(inputFrames)
        } else {
            inputCallbacksSkipped += 1
        }

        if !completionSignaled, outputFrameCounter >= totalFrames {
            completionSignaled = true
            finished.signal()
        }
    }
}

private func measurementIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let state = Unmanaged<MeasurementState>.fromOpaque(clientData).takeUnretainedValue()
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    let frameCount: Int
    if let buffer = outputBuffers.first, buffer.mNumberChannels > 0 {
        let derivedFrameCount = Int(buffer.mDataByteSize) /
            (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
        frameCount = derivedFrameCount > 0
            ? derivedFrameCount
            : Int(state.configuration.bufferFrames)
    } else {
        frameCount = Int(state.configuration.bufferFrames)
    }
    state.process(
        inputData: inputData,
        inputTime: inputTime,
        outputData: outputData,
        outputTime: outputTime,
        frameCountHint: frameCount
    )
    return noErr
}

public enum LiveImpulseMeasurement {
    public static func run(
        configuration: LiveMeasurementConfiguration
    ) throws -> LiveMeasurementReport {
        debug("snapshot before")
        let before = try CoreAudioInspector.snapshot(named: configuration.deviceName)
        guard configuration.inputChannel >= 1,
              configuration.inputChannel <= Int(before.input.channels) else {
            throw LiveMeasurementError.invalidChannel(
                direction: "input",
                requested: configuration.inputChannel,
                available: before.input.channels
            )
        }
        guard configuration.outputChannel >= 1,
              configuration.outputChannel <= Int(before.output.channels) else {
            throw LiveMeasurementError.invalidChannel(
                direction: "output",
                requested: configuration.outputChannel,
                available: before.output.channels
            )
        }

        let oldBufferFrames = before.bufferFrameSize
        if oldBufferFrames != configuration.bufferFrames {
            debug("request buffer \(configuration.bufferFrames) (was \(oldBufferFrames))")
            try CoreAudioInspector.setBufferFrameSize(
                configuration.bufferFrames,
                on: AudioDeviceID(before.deviceID)
            )
            Thread.sleep(forTimeInterval: 0.2)
        }
        defer {
            if oldBufferFrames != configuration.bufferFrames {
                try? CoreAudioInspector.setBufferFrameSize(
                    oldBufferFrames,
                    on: AudioDeviceID(before.deviceID)
                )
            }
        }

        debug("snapshot during")
        let during = try CoreAudioInspector.snapshot(named: configuration.deviceName)
        let state = MeasurementState(
            configuration: configuration,
            sampleRate: during.actualSampleRate ?? during.nominalSampleRate,
            inputChannels: Int(during.input.channels),
            outputChannels: Int(during.output.channels)
        )
        var ioProcID: AudioDeviceIOProcID?
        debug("create IOProc")
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                AudioDeviceID(during.deviceID),
                nil
            ) { _, inputData, inputTime, outputData, outputTime in
                let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
                let frameCount: Int
                if let buffer = outputBuffers.first, buffer.mNumberChannels > 0 {
                    let derivedFrameCount = Int(buffer.mDataByteSize) /
                        (Int(buffer.mNumberChannels) * MemoryLayout<Float>.size)
                    frameCount = derivedFrameCount > 0
                        ? derivedFrameCount
                        : Int(state.configuration.bufferFrames)
                } else {
                    frameCount = Int(state.configuration.bufferFrames)
                }
                state.process(
                    inputData: inputData,
                    inputTime: inputTime,
                    outputData: outputData,
                    outputTime: outputTime,
                    frameCountHint: frameCount
                )
            },
            "create audio IOProc"
        )
        guard let ioProcID else {
            throw LiveMeasurementError.io(-1, operation: "create audio IOProc")
        }
        defer {
            AudioDeviceDestroyIOProcID(AudioDeviceID(during.deviceID), ioProcID)
        }

        debug("start audio device")
        try check(
            AudioDeviceStart(AudioDeviceID(during.deviceID), ioProcID),
            "start audio device"
        )
        let timeout = Double(state.totalFrames) / state.sampleRate + 5
        debug("wait up to \(String(format: "%.3f", timeout)) seconds")
        let waitResult = state.finished.wait(timeout: .now() + timeout)
        debug("wait returned \(waitResult == .success ? "success" : "timeout")")
        debug("stop audio device")
        let stopStatus = AudioDeviceStop(AudioDeviceID(during.deviceID), ioProcID)
        debug("stop returned \(stopStatus)")
        try check(stopStatus, "stop audio device")
        if let dumpPath = ProcessInfo.processInfo.environment["USB16X16_DUMP"] {
            let data = state.capture.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: URL(fileURLWithPath: dumpPath))
            let markers = state.impulseOutputSampleTimes.map { Int(($0 - (state.inputBaseSampleTime ?? 0)).rounded()) }
            try? (markers.map(String.init).joined(separator: ",") + "\n").write(toFile: dumpPath + ".markers", atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data((
            "diag: callbacks=\(state.callbackCount) inputWithData=\(state.inputCallbacksWithData)" +
            " inputSkipped=\(state.inputCallbacksSkipped) copiedFrames=\(state.copiedFrames)" +
            " placementMisses=\(state.placementMisses) rawInputPeak=\(state.rawInputPeak)" +
            " capturePeak=\(state.capture.map(abs).max() ?? 0)" +
            " firstOut=\(state.firstOutputSampleTime ?? -1) firstIn=\(state.firstInputSampleTime ?? -1)" +
            " lastIn=\(state.lastInputSampleTime ?? -1) firstInBytes=\(state.firstInputByteSize)" +
            " outputFrames=\(state.outputFrameCounter) inDisc=\(state.inputDiscontinuities)" +
            " outDisc=\(state.outputDiscontinuities)" +
            " peakIndex=\(peakIndexOf(state.capture)) captureCount=\(state.capture.count)" +
            " markers=\(state.impulseOutputSampleTimes.prefix(4).map { Int(($0 - (state.inputBaseSampleTime ?? 0)).rounded()) })" +
            " nonZeroSpan=\(nonZeroSpanOf(state.capture))\n").utf8))
        guard waitResult == .success else {
            throw LiveMeasurementError.timedOut(
                callbacks: state.callbackCount,
                outputFrames: state.outputFrameCounter,
                inputStarted: state.inputBaseSampleTime != nil,
                impulses: state.impulseOutputSampleTimes.count
            )
        }
        guard let inputBase = state.inputBaseSampleTime else {
            throw LiveMeasurementError.noUsableInput
        }
        guard !state.impulseOutputSampleTimes.isEmpty else {
            throw LiveMeasurementError.noImpulseTimestamps
        }

        let markerIndices = state.impulseOutputSampleTimes.map {
            Int(($0 - inputBase).rounded())
        }.filter {
            $0 >= 0 && $0 + state.maximumLagFrames < state.capture.count
        }
        let correlation = try ImpulseCorrelation.analyze(
            capture: state.capture,
            impulseMarkers: markerIndices,
            sampleRate: state.sampleRate,
            maximumLag: state.maximumLagFrames,
            peakSearchRadius: configuration.peakSearchRadiusSamples
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return LiveMeasurementReport(
            capturedAt: formatter.string(from: Date()),
            deviceBefore: before,
            deviceDuring: during,
            configuration: configuration,
            impulseOutputSampleTimes: state.impulseOutputSampleTimes,
            inputBaseSampleTime: inputBase,
            inputDiscontinuities: state.inputDiscontinuities,
            outputDiscontinuities: state.outputDiscontinuities,
            capturedPeak: state.capture.map(abs).max() ?? 0,
            correlation: correlation
        )
    }

    private static func peakIndexOf(_ capture: [Float]) -> Int {
        var best = 0; var bestValue: Float = -1
        for (index, value) in capture.enumerated() where abs(value) > bestValue {
            bestValue = abs(value); best = index
        }
        return best
    }

    private static func nonZeroSpanOf(_ capture: [Float]) -> String {
        var first = -1; var last = -1; var count = 0
        for (index, value) in capture.enumerated() where value != 0 {
            if first < 0 { first = index }
            last = index; count += 1
        }
        return "\(first)..\(last) (\(count) nonzero)"
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw LiveMeasurementError.io(status, operation: operation)
        }
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["USB16X16_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[usb16x16-latency] \(message)\n".utf8))
    }
}
