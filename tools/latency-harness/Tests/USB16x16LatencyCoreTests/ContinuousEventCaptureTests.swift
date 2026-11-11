import CoreAudio
import Foundation
import Testing
@testable import USB16x16LatencyCore

private func callback(_ state: ContinuousState, frame: Int, input: inout [Float],
                      inputTime: Double? = nil, valid: Bool = true) {
    var output = [Float](repeating: 0, count: input.count)
    input.withUnsafeMutableBytes { inBytes in
        output.withUnsafeMutableBytes { outBytes in
            var ins = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 16, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
            var outs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 16, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
            state.process(&ins, inputTime ?? (1000 + Double(frame)), &outs, 5000 + Double(frame),
                          inputTimeValid: valid)
        }
    }
}

private func runSevenZeros(quantized: Bool) -> ContinuousState {
    let state = ContinuousState(seconds: 5, amplitude: 0.1)
    state.inputFrames = 96_000
    // Nonzero DSP samples from the retained offline event, surrounded by its
    // actual neighbors. S32 rounding + high-three-byte wire conversion yields
    // seven zeros; this is a natural quantization fixture, not injected silence.
    let dsp: [Float] = [-5.3222152e-7, -4.6749349e-7, -3.9771470e-7, -3.2494674e-7,
        -2.5138382e-7, -1.7934528e-7, -1.1126653e-7, -4.9665633e-8,
        2.9688203e-9, 4.4269811e-8, 7.2012213e-8, 8.4152802e-8,
        7.8844259e-8, 5.4423754e-8, 9.5081392e-9, -5.6927973e-8]
    for base in stride(from: 0, to: 192, by: 64) {
        var input = (0..<(64 * 16)).map { Float($0 % 16 + 1) / 100 }
        for f in 0..<64 {
            let index = base + f
            if quantized && (55..<71).contains(index) {
                let s32 = Int32((Double(dsp[index - 55]) * 2147483648).rounded())
                input[f * 16 + 3] = Float(s32 >> 8) / 8388608
            } else if !quantized && (63..<70).contains(index) {
                input[f * 16 + 3] = 0
            }
        }
        callback(state, frame: base, input: &input)
    }
    return state
}

@Test func eventCapturePreservesQuantizationAndInjectedGapAcrossCallbacks() throws {
    let natural = runSevenZeros(quantized: true)
    let gap = runSevenZeros(quantized: false)
    for state in [natural, gap] {
        let report = state.eventCapture.report()
        #expect(report.triggeredEvents == 1 && report.omittedEvents == 0)
        let event = try #require(report.events.first)
        #expect(event.channel == 4 && event.startInputFrame == 96_063 && event.zeroFrames == 7)
        #expect(event.windowComplete && !event.windowCapacityReached && event.termination == "nonzero")
        #expect(event.frames.map(\.inputFrame) == Array(96_047...96_085))
        #expect(event.frames[16].inputSampleTime == 1063)
        #expect(event.frames[16].outputCallbackFirstFrame == 0)
        #expect(event.frames[17].outputCallbackFirstFrame == 64)
        #expect(event.frames[17].outputCallbackSampleTime == 5064)
        #expect(event.frames[17].outputCallbackFrames == 64)
        for frame in event.frames {
            #expect(frame.samples.count == 16 && frame.sampleBits.count == 16)
            #expect(frame.sampleBits[15] == Float(0.16).bitPattern)
        }
        #expect(state.channels[3].longestZeroRun == 7) // gate still fails both
    }
    let naturalBefore = natural.eventCapture.report().events[0].frames[15].samples[3]
    let gapBefore = gap.eventCapture.report().events[0].frames[15].samples[3]
    #expect(naturalBefore == -1 / Float(8388608))
    #expect(gapBefore == Float(0.04)) // preserved evidence separates neighborhoods
}

private func feed(_ capture: ContinuousEventCapture, start: Int, count: Int,
                  value: (Int, Int) -> Float) {
    var frame = [Float](repeating: 0, count: 16)
    for f in start..<(start + count) {
        for c in 0..<16 { frame[c] = value(f, c) }
        frame.withUnsafeBufferPointer {
            capture.observe($0.baseAddress!, inputFrame: f, inputTime: Double(f),
                outputFrame: f, outputTime: Double(f + 500), outputFrames: 1, armed: true)
        }
    }
}

@Test func eventCaptureBoundsLongAndRepeatedEvents() {
    let long = ContinuousEventCapture()
    feed(long, start: 0, count: 240) { f, c in c == 3 && f >= 20 ? 0 : 0.1 }
    let event = long.report().events[0]
    #expect(event.zeroFrames == 220 && event.frames.count == 96)
    #expect(event.windowCapacityReached && !event.windowComplete && event.termination == "captureEnd")
    feed(long, start: 240, count: 20) { _, _ in 0.1 }
    #expect(long.report().events[0].termination == "nonzero")
    #expect(!long.report().events[0].windowComplete)

    let repeated = ContinuousEventCapture()
    let runs = ContinuousEventCapture.limit + 8
    feed(repeated, start: 0, count: 20 + runs * 40) { f, c in
        c == 3 && f >= 20 && (f - 20) % 40 < 4 ? 0 : 0.1
    }
    let result = repeated.report()
    #expect(result.events.count == ContinuousEventCapture.limit && result.triggeredEvents == runs && result.omittedEvents == 8)
    #expect(result.events.allSatisfy { $0.windowComplete && $0.frames.count == 36 })
}

@Test func eventCaptureDoesNotJoinTimestampGapsOrWarmup() {
    let state = ContinuousState(seconds: 5, amplitude: 0.1)
    var zero = [Float](repeating: 0, count: 64 * 16)
    callback(state, frame: 0, input: &zero)
    #expect(state.eventCapture.report().events.isEmpty)
    state.inputFrames = 96_000
    callback(state, frame: 64, input: &zero)
    callback(state, frame: 128, input: &zero, inputTime: 1192) // 64-frame gap
    let report = state.eventCapture.report()
    #expect(state.inputDiscontinuities == 1 && report.continuityBreaks == 1)
    #expect(report.events.count == 32)
    #expect(report.events[0].zeroFrames == 64 && report.events[0].termination == "discontinuity")
    #expect(report.events[16].startInputFrame == 96_064)
    #expect(report.events[16].frames.first?.inputSampleTime == 1192)
    #expect(report.events[16].zeroFrames == 64 && !report.events[16].windowComplete)
}

@Test func eventCapturePreservesNonFiniteBitsAndFlagsInvalidTime() throws {
    let state = ContinuousState(seconds: 5, amplitude: 0.1)
    state.inputFrames = 96_000
    var input = [Float](repeating: 0.1, count: 64 * 16)
    for f in 20..<24 { input[f * 16 + 3] = 0 }
    let invalid = Float(bitPattern: 0x7fc00123)
    input[24 * 16 + 3] = invalid
    callback(state, frame: 0, input: &input, inputTime: .nan, valid: false)
    let report = state.eventCapture.report()
    let event = try #require(report.events.first)
    #expect(state.invalidTimestamps == 1 && event.zeroFrames == 4)
    #expect(event.termination == "nonFinite")
    #expect(event.frames[20].sampleBits[3] == invalid.bitPattern)
    #expect(event.frames[20].samples[3] == nil && event.frames[20].inputSampleTime == nil)
    let data = try JSONEncoder().encode(report) // NaN payload cannot break evidence export
    #expect(!data.isEmpty)
    var activity = ChannelActivity()
    for v: Float in [0, 0, .nan, 0, 0] { activity.observe(v) }
    #expect(activity.longestZeroRun == 2 && activity.nonFinite == 1)
}
