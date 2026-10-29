import Testing
@testable import USB16x16LatencyCore

// What macOS has done to this device: a gain of 0.999998 each way, rounded to
// the nearest code on the way out (2026-10-10), and unity (2026-10-27). Float
// and double arithmetic are both tried, since which one the host uses is not known.
private let old: Float = 0.999998
private func hostOut(_ value: Float, double: Bool, gain: Float = old) -> Int32 {
    double ? Int32((Double(value) * Double(gain) * 8_388_608).rounded())
           : Int32((value * gain * 8_388_608).rounded())
}
private func hostIn(_ wire: Int32, double: Bool, gain: Float = old) -> Float {
    double ? Float(Double(wire) / 8_388_608 * Double(gain))
           : Float(wire) / 8_388_608 * gain
}
/// The gains as the calibration measures them: the steady returns of its levels through `hostOut`/`hostIn`.
private func measured(_ gain: Float, double: Bool = false) throws -> HostGain {
    let readings = (0..<HostGainCalibration.steps).map { step in
        (0..<16).map { channel in
            hostIn(hostOut(HostGainCalibration.sample(step: step, channel: channel), double: double, gain: gain),
                   double: double, gain: gain)
        }
    }
    return try HostGainCalibration.solve(readings)
}

@Test func hostGainIsMeasuredForEitherHost() throws {
    for double in [false, true] {
        let then = try measured(old, double: double)
        // Within one float32 step of the nominal gain: a host multiplying in float32 has an effective
        // output gain about 3e-8 from it, and that effective gain is what the calibration measures.
        #expect(abs(then.outputGain - Double(old)) < 6e-8 && abs(then.inputGain - Double(old)) < 6e-8)
        #expect(then.outputGainWidth < 1e-8 && then.inputGainWidth < 1e-8)
        #expect(then.limit == 8_388_590)
        let now = try measured(1, double: double)
        #expect(abs(now.outputGain - 1) < 6e-8 && abs(now.inputGain - 1) < 6e-8)
        #expect(now.limit == 8_388_607)
    }
}

@Test func hostGainRefusesReadingsThatDisagree() throws {
    var readings = (0..<HostGainCalibration.steps).map { step in
        (0..<16).map { channel in hostIn(hostOut(HostGainCalibration.sample(step: step, channel: channel), double: false), double: false) }
    }
    readings[0][3] = -readings[0][3]                                           // a polarity flip
    #expect(throws: HostGainError.self) { try HostGainCalibration.solve(readings) }
    readings[0][3] = -readings[0][3]
    readings[3][9] = readings[3][9].nextUp.nextUp.nextUp                      // off the grid
    #expect(throws: HostGainError.self) { try HostGainCalibration.solve(readings) }
    // A volume well below unity is not a host the sequence can be defined on.
    let quieter = (0..<HostGainCalibration.steps).map { step in
        (0..<16).map { channel in hostIn(hostOut(HostGainCalibration.sample(step: step, channel: channel), double: false, gain: 0.5), double: false, gain: 0.5) }
    }
    #expect(throws: HostGainError.self) { try HostGainCalibration.solve(quieter) }
}

@Test func bitExactEveryWireCodeSurvivesTheHostBothWays() throws {
    for gain in [old, 1] {
        for double in [false, true] {
            let model = try measured(gain, double: double)
            var wrong = 0
            for wire in -model.limit...model.limit {
                let sent = hostOut(BitExactSequence.sample(wire: wire, model), double: double, gain: gain)
                let back = BitExactSequence.received(hostIn(sent, double: double, gain: gain), model)
                if sent != wire || back.code != wire || back.error > 0.3 { wrong += 1 }
            }
            #expect(wrong == 0)
        }
    }
}

@Test func bitExactFailsWhenTheModelIsTheOtherHost() throws {
    // The 2026-10-27 failure: the sequence predicted for 0.999998 through a unity host.
    let stale = try measured(old)
    var channel = BitExactChannel(gain: stale)
    var code: UInt32 = 0
    for frame in 0..<4_000 {
        code = BitExactSequence.next(code, channel: 2)
        channel.observe(hostIn(hostOut(BitExactSequence.sample(wire: BitExactSequence.wire(code, stale), stale),
                                       double: false, gain: 1), double: false, gain: 1), frame: frame)
    }
    #expect(channel.matches < 400)
}

@Test func bitExactSequenceLocksThroughTheHostForAWholePeriod() throws {
    let model = try measured(old)
    var channel = BitExactChannel(gain: model)
    var code: UInt32 = 0
    for frame in 0..<(1 << 24) + 2 {
        code = BitExactSequence.next(code, channel: 4)
        let sent = hostOut(BitExactSequence.sample(wire: BitExactSequence.wire(code, model), model), double: false)
        channel.observe(hostIn(sent, double: false), frame: frame)
    }
    #expect(channel.source == 5)
    #expect(channel.mismatchesAfterLock == 0 && channel.lostLocks == 0 && channel.offGridAfterLock == 0)
    // 18 codes at each end are clamped (8388590...8388607, -8388608...-8388590 is 19).
    #expect(channel.positiveLimit == 18 && channel.negativeLimit == 19)
    #expect(channel.unjudged == 37)
    #expect(channel.matches + channel.unjudged >= (1 << 24))
    #expect(channel.longestZeroRunAfterLock == 1)
}

@Test func bitExactCountsAFlippedBitADropAndAnOffGridSample() throws {
    let model = try measured(old)
    var channel = BitExactChannel(gain: model)
    var code: UInt32 = 7
    for frame in 0..<4_000 {
        code = BitExactSequence.next(code, channel: 0)
        var wire = BitExactSequence.wire(code, model)
        if frame == 1_000 { wire ^= 1 }                                        // one LSB
        if frame == 2_000 { code = BitExactSequence.next(code, channel: 0); wire = BitExactSequence.wire(code, model) } // one sample dropped
        var value = hostIn(wire, double: false)
        if frame == 3_000 { value += 1 / (2 * BitExactSequence.scale) }        // half an LSB
        channel.observe(value, frame: frame)
    }
    #expect(channel.source == 1)
    #expect(channel.lostLocks == 3)
    // A flipped sample breaks the pair before it and the pair after it; a drop breaks one pair.
    #expect(channel.mismatchesAfterLock == 2 + 1 + 1)
    #expect(channel.offGridAfterLock == 1)
}

@Test func bitExactNamesTheChannelASequenceCameFrom() throws {
    let model = try measured(old)
    var channel = BitExactChannel(gain: model)
    var code: UInt32 = 99
    for frame in 0..<100 {
        code = BitExactSequence.next(code, channel: 11)
        channel.observe(hostIn(BitExactSequence.wire(code, model), double: false), frame: frame)
    }
    #expect(channel.source == 12)
    var silent = BitExactChannel(gain: model)
    for frame in 0..<100 { silent.observe(0, frame: frame) }
    #expect(silent.source == 0 && silent.firstLockFrame == -1 && silent.mismatchesAfterLock == 0)
}

// A loop narrower than the device (2026-10-29: 8 channels at 96 kHz, where MADI
// halves): channels past the loop return nothing, and only the looped ones are judged.
@Test func hostGainReadsOnlyTheLoopedChannels() throws {
    let readings = (0..<HostGainCalibration.steps).map { step in
        (0..<16).map { channel -> Float in
            channel < 8 ? hostIn(hostOut(HostGainCalibration.sample(step: step, channel: channel), double: false, gain: 1),
                                  double: false, gain: 1) : 0
        }
    }
    #expect(throws: HostGainError.self) { try HostGainCalibration.solve(readings) }
    let gain = try HostGainCalibration.solve(readings, loopChannels: 8)
    #expect(abs(gain.outputGain - 1) < 6e-8 && abs(gain.inputGain - 1) < 6e-8)
}

@Test func bitExactJudgesOnlyTheLoopedChannels() {
    let model = HostGain.unity
    var channels = [BitExactChannel](repeating: BitExactChannel(gain: model), count: 16)
    var codes: [UInt32] = (0..<16).map { UInt32($0) &* 0x0001_0001 }
    for frame in 0..<2_000 {
        for channel in 0..<16 {
            codes[channel] = BitExactSequence.next(codes[channel], channel: channel)
            let value = channel < 8 ? BitExactSequence.sample(wire: BitExactSequence.wire(codes[channel], model), model) : 0
            channels[channel].observe(value, frame: frame)
        }
    }
    #expect(!BitExactReport.passes(channels, loopChannels: 16, fullScaleDue: false,
                                   inputDiscontinuities: 0, outputDiscontinuities: 0, invalidBuffers: 0))
    #expect(BitExactReport.passes(channels, loopChannels: 8, fullScaleDue: false,
                                  inputDiscontinuities: 0, outputDiscontinuities: 0, invalidBuffers: 0))
    #expect(!BitExactReport.passes(channels, loopChannels: 8, fullScaleDue: false,
                                   inputDiscontinuities: 1, outputDiscontinuities: 0, invalidBuffers: 0))
}
