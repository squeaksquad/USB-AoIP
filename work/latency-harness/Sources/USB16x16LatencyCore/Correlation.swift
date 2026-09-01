import Foundation

public enum CorrelationError: Error, CustomStringConvertible {
    case emptyCapture
    case noMarkers
    case invalidLagRange
    case markerOutsideCapture(Int)
    case noCorrelationSignal

    public var description: String {
        switch self {
        case .emptyCapture:
            return "capture contains no samples"
        case .noMarkers:
            return "reference contains no impulse markers"
        case .invalidLagRange:
            return "lag range is empty or negative"
        case let .markerOutsideCapture(marker):
            return "marker \(marker) cannot be evaluated inside the capture"
        case .noCorrelationSignal:
            return "capture contains no signal at any candidate impulse lag"
        }
    }
}

public struct LatencyStatistics: Codable, Equatable, Sendable {
    public let count: Int
    public let medianSamples: Double
    public let p95Samples: Double
    public let p99Samples: Double
    public let maximumSamples: Int
    public let minimumSamples: Int
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let maximumMilliseconds: Double
}

public struct CorrelationResult: Codable, Equatable, Sendable {
    public let estimatedLagSamples: Int
    public let score: Double
    public let perImpulseDelaySamples: [Int]
    public let statistics: LatencyStatistics
}

public enum ImpulseCorrelation {
    public static func analyze(
        capture: [Float],
        impulseMarkers: [Int],
        sampleRate: Double,
        minimumLag: Int = 0,
        maximumLag: Int,
        peakSearchRadius: Int = 4
    ) throws -> CorrelationResult {
        guard !capture.isEmpty else { throw CorrelationError.emptyCapture }
        guard !impulseMarkers.isEmpty else { throw CorrelationError.noMarkers }
        guard minimumLag >= 0, maximumLag >= minimumLag else {
            throw CorrelationError.invalidLagRange
        }

        var bestLag = minimumLag
        var bestScore = -Double.infinity
        for lag in minimumLag...maximumLag {
            var signedSum = 0.0
            var energy = 0.0
            var count = 0
            for marker in impulseMarkers {
                let index = marker + lag
                guard capture.indices.contains(index) else { continue }
                let sample = Double(capture[index])
                signedSum += sample
                energy += sample * sample
                count += 1
            }
            guard count == impulseMarkers.count, energy > 0 else { continue }
            let score = abs(signedSum) / sqrt(energy * Double(count))
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestScore.isFinite else {
            throw CorrelationError.noCorrelationSignal
        }

        var delays: [Int] = []
        delays.reserveCapacity(impulseMarkers.count)
        for marker in impulseMarkers {
            let center = marker + bestLag
            let lower = max(marker + minimumLag, center - peakSearchRadius)
            let upper = min(marker + maximumLag, center + peakSearchRadius)
            guard lower <= upper, capture.indices.contains(lower), capture.indices.contains(upper) else {
                throw CorrelationError.markerOutsideCapture(marker)
            }
            var peakIndex = lower
            var peakMagnitude = abs(capture[lower])
            if lower < upper {
                for index in (lower + 1)...upper {
                    let magnitude = abs(capture[index])
                    if magnitude > peakMagnitude {
                        peakMagnitude = magnitude
                        peakIndex = index
                    }
                }
            }
            delays.append(peakIndex - marker)
        }

        return CorrelationResult(
            estimatedLagSamples: bestLag,
            score: bestScore,
            perImpulseDelaySamples: delays,
            statistics: statistics(delays, sampleRate: sampleRate)
        )
    }

    public static func statistics(
        _ delays: [Int],
        sampleRate: Double
    ) -> LatencyStatistics {
        let sorted = delays.sorted()
        let median = percentile(sorted, probability: 0.50)
        let p95 = percentile(sorted, probability: 0.95)
        let p99 = percentile(sorted, probability: 0.99)
        let maximum = sorted.last ?? 0
        let minimum = sorted.first ?? 0
        let scale = 1_000.0 / sampleRate
        return LatencyStatistics(
            count: sorted.count,
            medianSamples: median,
            p95Samples: p95,
            p99Samples: p99,
            maximumSamples: maximum,
            minimumSamples: minimum,
            medianMilliseconds: median * scale,
            p95Milliseconds: p95 * scale,
            p99Milliseconds: p99 * scale,
            maximumMilliseconds: Double(maximum) * scale
        )
    }

    private static func percentile(_ sorted: [Int], probability: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return Double(sorted[0]) }
        let position = probability * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return Double(sorted[lower]) }
        let fraction = position - Double(lower)
        return Double(sorted[lower]) * (1 - fraction) + Double(sorted[upper]) * fraction
    }
}
