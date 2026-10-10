import Testing
@testable import USB16x16LatencyCore

// What macOS does to this device, as measured: a gain of 0.999998 each way,
// rounded to the nearest code on the way out. Float and double arithmetic
// are both tried, since which one the host uses is not known.
private func hostOut(_ value: Float, double: Bool) -> Int32 {
    double ? Int32((Double(value) * Double(BitExactSequence.hostGain) * 8_388_608).rounded())
           : Int32((value * BitExactSequence.hostGain * 8_388_608).rounded())
}
private func hostIn(_ wire: Int32, double: Bool) -> Float {
    double ? Float(Double(wire) / 8_388_608 * Double(BitExactSequence.hostGain))
           : Float(wire) / 8_388_608 * BitExactSequence.hostGain
}

@Test func bitExactEveryWireCodeSurvivesTheHostBothWays() {
    for double in [false, true] {
        var wrong = 0
        for wire in -BitExactSequence.limit...BitExactSequence.limit {
            let sent = hostOut(BitExactSequence.sample(wire: wire), double: double)
            let back = BitExactSequence.received(hostIn(sent, double: double))
            if sent != wire || back.code != wire || back.error > 0.3 { wrong += 1 }
        }
        #expect(wrong == 0)
    }
}

@Test func bitExactSequenceLocksThroughTheHostForAWholePeriod() {
    var channel = BitExactChannel()
    var code: UInt32 = 0
    for frame in 0..<(1 << 24) + 2 {
        code = BitExactSequence.next(code, channel: 4)
        let sent = hostOut(BitExactSequence.sample(wire: BitExactSequence.wire(code)), double: false)
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

@Test func bitExactCountsAFlippedBitADropAndAnOffGridSample() {
    var channel = BitExactChannel()
    var code: UInt32 = 7
    for frame in 0..<4_000 {
        code = BitExactSequence.next(code, channel: 0)
        var wire = BitExactSequence.wire(code)
        if frame == 1_000 { wire ^= 1 }                                        // one LSB
        if frame == 2_000 { code = BitExactSequence.next(code, channel: 0); wire = BitExactSequence.wire(code) } // one sample dropped
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

@Test func bitExactNamesTheChannelASequenceCameFrom() {
    var channel = BitExactChannel()
    var code: UInt32 = 99
    for frame in 0..<100 {
        code = BitExactSequence.next(code, channel: 11)
        channel.observe(hostIn(BitExactSequence.wire(code), double: false), frame: frame)
    }
    #expect(channel.source == 12)
    var silent = BitExactChannel()
    for frame in 0..<100 { silent.observe(0, frame: frame) }
    #expect(silent.source == 0 && silent.firstLockFrame == -1 && silent.mismatchesAfterLock == 0)
}
