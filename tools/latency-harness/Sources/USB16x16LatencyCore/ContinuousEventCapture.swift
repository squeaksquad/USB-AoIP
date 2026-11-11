import Foundation

public struct ContinuousEventFrame: Encodable, Sendable {
    public let inputFrame: Int
    public let inputSampleTime: Double?
    // Output callback paired with this input frame, not its returned source frame.
    public let outputCallbackFirstFrame: Int
    public let outputCallbackSampleTime: Double?
    public let outputCallbackFrames: Int
    public let samples: [Float?]
    public let sampleBits: [UInt32]
}

public struct ContinuousZeroEvent: Encodable, Sendable {
    public let channel: Int // one-based
    public let startInputFrame: Int
    public let zeroFrames: Int
    public let termination: String
    public let windowComplete: Bool
    public let windowCapacityReached: Bool
    public let frames: [ContinuousEventFrame]
}

public struct ContinuousEventReport: Encodable, Sendable {
    public let version = 1
    public let stimulus = "xorshift32-interleaved-float32"
    public let stimulusSeed: UInt32 = 0x9e3779b9
    public let thresholdFrames = ContinuousEventCapture.threshold
    public let beforeFrames = ContinuousEventCapture.before
    public let afterFrames = ContinuousEventCapture.after
    public let frameLimitPerEvent = ContinuousEventCapture.window
    public let eventLimit = ContinuousEventCapture.limit
    public let triggeredEvents: Int
    public let omittedEvents: Int
    public let continuityBreaks: Int
    public let events: [ContinuousZeroEvent]
}

// All callback storage is flat and allocated before AudioDeviceStart. No sample
// arrays, report objects or JSON are constructed while audio is running.
final class ContinuousEventCapture {
    static let threshold = 4
    static let before = 16
    static let after = 16
    static let window = 96
    static let limit = 512
    private static let historySize = before + threshold

    private struct Stamp {
        var inputFrame = 0
        var inputTime: Double?
        var outputFrame = 0
        var outputTime: Double?
        var outputFrames = 0
    }
    private enum End: String { case ongoing, nonzero, nonFinite, discontinuity }
    private struct Slot {
        var channel = 0
        var start = 0
        var zeroFrames = 0
        var end = End.ongoing
        var count = 0
        var collecting = true
        var postRemaining = -1
        var capped = false
    }
    private var historyBits = [UInt32](repeating: 0, count: historySize * 16)
    private var historyStamps = [Stamp](repeating: Stamp(), count: historySize)
    private var historyNext = 0
    private var historyCount = 0
    private var sampleBits = [UInt32](repeating: 0, count: limit * window * 16)
    private var stamps = [Stamp](repeating: Stamp(), count: limit * window)
    private var slots = [Slot](repeating: Slot(), count: limit)
    private var runs = [Int](repeating: 0, count: 16)
    private var active = [Int](repeating: -1, count: 16)
    private var used = 0
    private var triggered = 0
    private var breaks = 0

    func breakContinuity() {
        breaks += 1
        for i in 0..<used {
            if slots[i].end == .ongoing { slots[i].end = .discontinuity }
            slots[i].collecting = false
        }
        for c in 0..<16 { runs[c] = 0; active[c] = -1 }
        historyCount = 0
        historyNext = 0
    }

    private func appendHistory(_ historyIndex: Int, to slot: Int) {
        let destination = slot * Self.window + slots[slot].count
        stamps[destination] = historyStamps[historyIndex]
        for c in 0..<16 {
            sampleBits[destination * 16 + c] = historyBits[historyIndex * 16 + c]
        }
        slots[slot].count += 1
    }

    func observe(_ values: UnsafePointer<Float>, inputFrame: Int, inputTime: Double?,
                 outputFrame: Int, outputTime: Double?, outputFrames: Int,
                 armed: Bool) {
        let current = historyNext
        historyStamps[current] = Stamp(inputFrame: inputFrame, inputTime: inputTime,
            outputFrame: outputFrame, outputTime: outputTime, outputFrames: outputFrames)
        for c in 0..<16 { historyBits[current * 16 + c] = values[c].bitPattern }
        historyNext = (historyNext + 1) % Self.historySize
        historyCount = min(historyCount + 1, Self.historySize)

        for i in 0..<used where slots[i].collecting {
            appendHistory(current, to: i)
            if slots[i].postRemaining > 0 {
                slots[i].postRemaining -= 1
                if slots[i].postRemaining == 0 { slots[i].collecting = false }
            }
            if slots[i].count == Self.window && slots[i].collecting {
                slots[i].capped = true
                slots[i].collecting = false
            }
        }
        guard armed else { return }
        for c in 0..<16 {
            if values[c] == 0 {
                runs[c] += 1
                if active[c] >= 0 { slots[active[c]].zeroFrames = runs[c] }
                if runs[c] == Self.threshold {
                    triggered += 1
                    if used < Self.limit {
                        let index = used
                        used += 1
                        slots[index] = Slot(channel: c + 1, start: inputFrame + 1 - runs[c],
                                            zeroFrames: runs[c])
                        active[c] = index
                        let oldest = (historyNext + Self.historySize - historyCount) % Self.historySize
                        for offset in 0..<historyCount {
                            appendHistory((oldest + offset) % Self.historySize, to: index)
                        }
                    }
                }
            } else {
                if active[c] >= 0 {
                    let index = active[c]
                    slots[index].end = values[c].isFinite ? .nonzero : .nonFinite
                    // The first nonzero frame was appended above.
                    slots[index].postRemaining = Self.after - 1
                }
                active[c] = -1
                runs[c] = 0
            }
        }
    }

    // Call only after AudioDeviceStop (or after a synthetic test has stopped).
    func report() -> ContinuousEventReport {
        let events = (0..<used).map { i in
            let slot = slots[i]
            let frames = (0..<slot.count).map { f in
                let index = i * Self.window + f
                let stamp = stamps[index]
                let bits = Array(sampleBits[(index * 16)..<((index + 1) * 16)])
                return ContinuousEventFrame(inputFrame: stamp.inputFrame,
                    inputSampleTime: stamp.inputTime, outputCallbackFirstFrame: stamp.outputFrame,
                    outputCallbackSampleTime: stamp.outputTime, outputCallbackFrames: stamp.outputFrames,
                    samples: bits.map { let v = Float(bitPattern: $0); return v.isFinite ? v : nil },
                    sampleBits: bits)
            }
            return ContinuousZeroEvent(channel: slot.channel, startInputFrame: slot.start,
                zeroFrames: slot.zeroFrames,
                termination: slot.end == .ongoing ? "captureEnd" : slot.end.rawValue,
                windowComplete: slot.postRemaining == 0 && !slot.capped &&
                    (slot.end == .nonzero || slot.end == .nonFinite) &&
                    frames.first?.inputFrame == slot.start - Self.before,
                windowCapacityReached: slot.capped, frames: frames)
        }
        return ContinuousEventReport(triggeredEvents: triggered, omittedEvents: triggered - used,
                                     continuityBreaks: breaks, events: events)
    }
}
