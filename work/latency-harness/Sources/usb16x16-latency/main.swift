import Foundation
import USB16x16LatencyCore

private struct Arguments {
    let command: String
    let deviceName: String
    let outputPath: String?
    let bufferFrames: UInt32
    let inputChannel: Int
    let outputChannel: Int
    let impulseCount: Int
    let maximumLagMilliseconds: Double
    let otherChannelLoadAmplitude: Float

    init(_ values: [String]) throws {
        guard values.count >= 2 else { throw CLIError.usage }
        command = values[1]
        var deviceName = "USB 16x16"
        var outputPath: String?
        var bufferFrames: UInt32 = 64
        var inputChannel = 1
        var outputChannel = 1
        var impulseCount = 20
        var maximumLagMilliseconds = 200.0
        var otherChannelLoadAmplitude: Float = 0
        var index = 2
        while index < values.count {
            switch values[index] {
            case "--device":
                guard index + 1 < values.count else { throw CLIError.usage }
                deviceName = values[index + 1]
                index += 2
            case "--output":
                guard index + 1 < values.count else { throw CLIError.usage }
                outputPath = values[index + 1]
                index += 2
            case "--buffer-frames":
                guard index + 1 < values.count,
                      let parsed = UInt32(values[index + 1]) else { throw CLIError.usage }
                bufferFrames = parsed
                index += 2
            case "--input-channel":
                guard index + 1 < values.count,
                      let parsed = Int(values[index + 1]) else { throw CLIError.usage }
                inputChannel = parsed
                index += 2
            case "--output-channel":
                guard index + 1 < values.count,
                      let parsed = Int(values[index + 1]) else { throw CLIError.usage }
                outputChannel = parsed
                index += 2
            case "--impulses":
                guard index + 1 < values.count,
                      let parsed = Int(values[index + 1]), parsed > 0 else { throw CLIError.usage }
                impulseCount = parsed
                index += 2
            case "--maximum-lag-ms":
                guard index + 1 < values.count,
                      let parsed = Double(values[index + 1]), parsed > 0, parsed < 250 else {
                    throw CLIError.usage
                }
                maximumLagMilliseconds = parsed
                index += 2
            case "--other-channel-load-amplitude":
                guard index + 1 < values.count,
                      let parsed = Float(values[index + 1]), parsed >= 0, parsed <= 0.25 else {
                    throw CLIError.usage
                }
                otherChannelLoadAmplitude = parsed
                index += 2
            default:
                throw CLIError.unknownArgument(values[index])
            }
        }
        self.deviceName = deviceName
        self.outputPath = outputPath
        self.bufferFrames = bufferFrames
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.impulseCount = impulseCount
        self.maximumLagMilliseconds = maximumLagMilliseconds
        self.otherChannelLoadAmplitude = otherChannelLoadAmplitude
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case unknownArgument(String)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              usb16x16-latency inspect [--device NAME] [--output FILE]
              usb16x16-latency list [--output FILE]
              usb16x16-latency measure [--device NAME] [--buffer-frames N]
                  [--input-channel N] [--output-channel N] [--impulses N]
                  [--maximum-lag-ms N] [--other-channel-load-amplitude 0...0.25]
                  [--output FILE]
            """
        case let .unknownArgument(argument):
            return "unknown argument: \(argument)"
        }
    }
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([0x0a])
}

private func emit(_ data: Data, to outputPath: String?) throws {
    if let outputPath {
        let url = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
    FileHandle.standardOutput.write(data)
}

do {
    let arguments = try Arguments(CommandLine.arguments)
    switch arguments.command {
    case "inspect":
        try emit(
            encoded(CoreAudioInspector.snapshot(named: arguments.deviceName)),
            to: arguments.outputPath
        )
    case "list":
        try emit(encoded(CoreAudioInspector.allDevices()), to: arguments.outputPath)
    case "measure":
        let configuration = LiveMeasurementConfiguration(
            deviceName: arguments.deviceName,
            bufferFrames: arguments.bufferFrames,
            inputChannel: arguments.inputChannel,
            outputChannel: arguments.outputChannel,
            impulseCount: arguments.impulseCount,
            maximumLagMilliseconds: arguments.maximumLagMilliseconds,
            otherChannelLoadAmplitude: arguments.otherChannelLoadAmplitude
        )
        try emit(
            encoded(LiveImpulseMeasurement.run(configuration: configuration)),
            to: arguments.outputPath
        )
    default:
        throw CLIError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
