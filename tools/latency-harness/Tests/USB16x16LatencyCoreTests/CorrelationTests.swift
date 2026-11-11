import Testing
@testable import USB16x16LatencyCore

@Test func findsKnownPositiveImpulseDelay() throws {
    let markers = stride(from: 512, through: 8_192, by: 512).map { $0 }
    let expectedDelay = 137
    var capture = [Float](repeating: 0, count: 9_000)
    for (offset, marker) in markers.enumerated() {
        capture[marker + expectedDelay] = offset.isMultiple(of: 2) ? 0.8 : 1.0
    }
    let result = try ImpulseCorrelation.analyze(
        capture: capture,
        impulseMarkers: markers,
        sampleRate: 48_000,
        maximumLag: 512
    )
    #expect(result.estimatedLagSamples == expectedDelay)
    #expect(result.perImpulseDelaySamples.allSatisfy { $0 == expectedDelay })
    #expect(result.statistics.medianSamples == Double(expectedDelay))
}

@Test func toleratesInvertedImpulsePolarity() throws {
    let markers = [128, 256, 384, 512]
    var capture = [Float](repeating: 0, count: 700)
    for marker in markers { capture[marker + 41] = -1 }
    let result = try ImpulseCorrelation.analyze(
        capture: capture,
        impulseMarkers: markers,
        sampleRate: 48_000,
        maximumLag: 100
    )
    #expect(result.estimatedLagSamples == 41)
    #expect(result.score == 1)
}

@Test func interpolatesPercentiles() {
    let statistics = ImpulseCorrelation.statistics(
        [100, 101, 102, 103, 104],
        sampleRate: 48_000
    )
    #expect(statistics.medianSamples == 102)
    #expect(statistics.maximumSamples == 104)
    #expect(statistics.minimumSamples == 100)
}

@Test func representativeChannelLoadIsDeterministicAndBounded() {
    var first = DeterministicChannelLoad()
    var second = DeterministicChannelLoad()
    let a = (0..<1_000).map { _ in first.next(amplitude: 0.05) }
    let b = (0..<1_000).map { _ in second.next(amplitude: 0.05) }
    #expect(a == b)
    #expect(a.allSatisfy { abs($0) <= 0.05 })
    #expect(a.contains { abs($0) > 0.04 })
}
