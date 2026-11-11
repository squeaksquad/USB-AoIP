import Testing
import CoreAudio
@testable import USB16x16LatencyCore

@Test func continuousActivityDistinguishesSilenceClippingAndInvalidSamples() {
    var stats = ChannelActivity()
    for value: Float in [0, 0, 0.5, -0.5, 0, 1, .nan] { stats.observe(value) }
    #expect(stats.samples == 7)
    #expect(stats.longestZeroRun == 2)
    #expect(stats.fullScaleSamples == 1)
    #expect(stats.nonFinite == 1)
    #expect(stats.peak == 1)
    #expect(stats.sumSquares == 1.5)
}

@Test func continuousLoadRejectsUnsafeSettingsBeforeOpeningAudio() {
    #expect(throws: (any Error).self) {
        try ContinuousLoad.run(deviceName: "unopened", bufferFrames: 64, seconds: 601, amplitude: 0.1)
    }
    #expect(throws: (any Error).self) {
        try ContinuousLoad.run(deviceName: "unopened", bufferFrames: 64, seconds: 60, amplitude: .nan)
    }
}

@Test func continuousCallbackDrivesAllChannelsAndDetectsCaptureHoles() {
    let state = ContinuousState(seconds: 5, amplitude: 0.1)
    state.inputFrames = 96_000 // past warmup
    var input = [Float](repeating: 0.05, count: 64 * 16)
    var output = [Float](repeating: 0, count: 64 * 16)
    input.withUnsafeMutableBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            var inputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 16, mDataByteSize: UInt32(inputBytes.count), mData: inputBytes.baseAddress))
            var outputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 16, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress))
            state.process(&inputs, 0, &outputs, 0)
            inputBytes.initializeMemory(as: UInt8.self, repeating: 0)
            state.process(&inputs, 128, &outputs, 64) // missing 64 input timestamp frames
        }
    }
    #expect(state.inputDiscontinuities == 1)
    #expect(state.outputDiscontinuities == 0)
    #expect(state.outputFrames == 128)
    #expect(state.channels.allSatisfy { $0.samples == 128 && $0.longestZeroRun == 64 && $0.peak == 0.05 })
    for channel in 0..<16 {
        #expect((0..<64).contains { output[$0 * 16 + channel] != 0 })
    }
}

@Test func soakLengthAndWarmupFollowTheDeviceRate() {
    let at48 = ContinuousState(seconds: 5, amplitude: 0.1)
    #expect(at48.totalFrames == 240_000 && at48.warmupFrames == 96_000)
    let at96 = ContinuousState(seconds: 5, amplitude: 0.1, sampleRate: 96_000)
    #expect(at96.totalFrames == 480_000 && at96.warmupFrames == 192_000)
    #expect(BitExactState(seconds: 5, gain: .unity).totalFrames == 240_000)
    #expect(BitExactState(seconds: 5, sampleRate: 88_200, gain: .unity).totalFrames == 441_000)
    #expect(SoakRate.accepted.map(SoakRate.kHz) == ["44.1", "48", "88.2", "96"])
}
