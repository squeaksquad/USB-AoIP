// The streaming engine (SPIKE_PLAN.md, step 1): both isochronous directions of a
// captured USB-AoIP started on one bus frame, every sample numbered from that frame.
//
// OUT (0x01, async): each microframe carries the number of frames the feedback
// endpoint (0x82, 16.16 frames per microframe, once a millisecond) asks for, through
// an accumulator. IN (0x83): whatever the gadget sends. Both counts start at the
// first microframe of the same frame, so an impulse sent at OUT index k and found at
// IN index j has a round trip of j - k samples by construction, with no CoreAudio
// timeline in between. A transaction that fails or comes back short breaks that
// numbering: it is counted, and the run is reported as broken rather than averaged.

import Foundation
import IOKit
import IOUSBHost

let kChannels = 16
let kBytesPerFrame = kChannels * 3
let kMaxPacket = 624                    // 13 frames, the size the gadget's rate list sets
let kMicroframesPerFrame = 8
let kFramesPerRequest = 4               // bus frames (1 ms) each request covers
let kRequestsInFlight = 8               // per pipe: 32 ms queued ahead. How early a request is
                                        // queued does not change the frame its samples travel in,
                                        // so depth costs the measurement nothing; 12 ms was once
                                        // too little for the feedback pipe (IsoTooOld, 2026-10-30).
let kStartMargin: UInt64 = 20           // bus frames between now and the anchor frame
let kImpulsePeriod = 4800               // OUT frames between impulses (100 ms at 48 kHz)
let kImpulseOffset = 2400
let kImpulseFirst = 48000               // no impulse in the first second (the Pi primes)
let kImpulseAmplitude: Int32 = 0x400000 // half scale, channel 1

struct StreamReport {
    var anchorFrame: UInt64 = 0
    var seconds = 0.0
    var outFrames = 0
    var inFrames = 0
    var outTransactions = 0
    var inTransactions = 0
    var feedbackTransactions = 0
    var outFailed = 0                   // status not success, or fewer bytes than asked
    var inFailed = 0
    var feedbackFailed = 0
    var feedbackSkips = 0               // feedback requests re-queued later after IsoTooOld; harmless
    var enqueueFailures: [String] = []
    var feedbackMin = Double.infinity
    var feedbackMax = 0.0
    var feedbackLast = 0.0
    var impulsesSent = 0
    var lags: [Int] = []                // one per impulse found on IN channel 1
    var unmatched = 0                   // onsets on IN channel 1 with no impulse before them

    var broken: Bool { outFailed + inFailed > 0 || !enqueueFailures.isEmpty }
}

// One queued request: its data, its transaction list, and the bus frame it starts on.
final class Slot {
    let data: NSMutableData
    let list: UnsafeMutablePointer<IOUSBHostIsochronousTransaction>
    let count: Int
    init(transactions: Int, bytesEach: Int) {
        count = transactions
        data = NSMutableData(length: transactions * bytesEach)!
        list = .allocate(capacity: transactions)
        list.initialize(repeating: IOUSBHostIsochronousTransaction(), count: transactions)
    }
    deinit { list.deallocate() }
}

final class StreamEngine {
    let queue = DispatchQueue(label: "usb-aoip-spike.stream", qos: .userInteractive)
    let outPipe: IOUSBHostPipe
    let feedbackPipe: IOUSBHostPipe
    let inPipe: IOUSBHostPipe
    let currentFrame: () -> UInt64
    private(set) var report = StreamReport()
    private var stopping = false
    private var pending = 0
    private var nextOutFrame: UInt64 = 0
    private var nextInFrame: UInt64 = 0
    private var nextFeedbackFrame: UInt64 = 0
    private var feedback = 6.0          // frames per microframe until the gadget says otherwise
    private var accumulator = 0.0
    private var outIndex = 0            // OUT frames written so far, from the anchor
    private var inIndex = 0             // IN frames received so far, from the anchor
    private var lastImpulse = -1        // OUT index of the latest impulse sent
    private var sentImpulses: [Int] = []
    private var inAbove = false

    init(outPipe: IOUSBHostPipe, feedbackPipe: IOUSBHostPipe, inPipe: IOUSBHostPipe, currentFrame: @escaping () -> UInt64) {
        self.outPipe = outPipe
        self.feedbackPipe = feedbackPipe
        self.inPipe = inPipe
        self.currentFrame = currentFrame
    }

    // Start all three pipes on `anchor`, run for `seconds`, stop, and return the report.
    func run(anchor: UInt64, seconds: Double) -> StreamReport {
        queue.sync {
            report.anchorFrame = anchor
            nextOutFrame = anchor
            nextInFrame = anchor
            nextFeedbackFrame = anchor
            for _ in 0..<kRequestsInFlight {
                enqueueFeedback(Slot(transactions: kFramesPerRequest, bytesEach: 4))
                enqueueIn(Slot(transactions: kFramesPerRequest * kMicroframesPerFrame, bytesEach: kMaxPacket))
                enqueueOut(Slot(transactions: kFramesPerRequest * kMicroframesPerFrame, bytesEach: kMaxPacket))
            }
        }
        let started = Date()
        Thread.sleep(forTimeInterval: seconds)
        queue.sync { stopping = true }
        // Let what is queued complete (at most kRequestsInFlight requests a pipe), then abort the rest.
        let deadline = Date().addingTimeInterval(1.0)
        while queue.sync(execute: { pending }) > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        for pipe in [outPipe, inPipe, feedbackPipe] { try? pipe.__abort(with: .synchronous) }
        return queue.sync {
            report.seconds = Date().timeIntervalSince(started)
            report.outFrames = outIndex
            report.inFrames = inIndex
            report.impulsesSent = sentImpulses.count
            return report
        }
    }

    // MARK: OUT

    private func enqueueOut(_ slot: Slot) {
        let bytes = slot.data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        for t in 0..<slot.count {
            accumulator += feedback
            let frames = min(Int(accumulator), kMaxPacket / kBytesPerFrame)
            accumulator -= Double(frames)
            memset(bytes + offset, 0, frames * kBytesPerFrame)
            for f in 0..<frames {
                let index = outIndex + f
                if index >= kImpulseFirst && index % kImpulsePeriod == kImpulseOffset {
                    write24(kImpulseAmplitude, to: bytes + offset + f * kBytesPerFrame)
                    sentImpulses.append(index)
                }
            }
            outIndex += frames
            slot.list[t] = IOUSBHostIsochronousTransaction(
                status: kIOReturnInvalid, requestCount: UInt32(frames * kBytesPerFrame), offset: UInt32(offset),
                completeCount: 0, timeStamp: 0, options: [])
            offset += frames * kBytesPerFrame
        }
        let frame = nextOutFrame
        nextOutFrame += UInt64(kFramesPerRequest)
        enqueue(outPipe, slot, frame, "out") { [unowned self] status, list in
            for t in 0..<slot.count {
                report.outTransactions += 1
                if list[t].status != kIOReturnSuccess || list[t].completeCount != list[t].requestCount { report.outFailed += 1 }
            }
            if !stopping { enqueueOut(slot) }
        }
    }

    // MARK: feedback

    private func enqueueFeedback(_ slot: Slot) {
        for t in 0..<slot.count {
            slot.list[t] = IOUSBHostIsochronousTransaction(
                status: kIOReturnInvalid, requestCount: 4, offset: UInt32(t * 4), completeCount: 0, timeStamp: 0, options: [])
        }
        var frame = nextFeedbackFrame
        if frame <= currentFrame() + 1 {
            // Late: the feedback is not part of the sample numbering, so skip ahead instead of failing.
            frame = currentFrame() + 2 * UInt64(kFramesPerRequest)
            report.feedbackSkips += 1
        }
        nextFeedbackFrame = frame + UInt64(kFramesPerRequest)
        enqueue(feedbackPipe, slot, frame, "feedback") { [unowned self] status, list in
            let bytes = slot.data.bytes.assumingMemoryBound(to: UInt8.self)
            for t in 0..<slot.count {
                report.feedbackTransactions += 1
                guard list[t].status == kIOReturnSuccess, list[t].completeCount >= 3 else { report.feedbackFailed += 1; continue }
                let p = bytes + Int(list[t].offset)
                let raw = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | (list[t].completeCount >= 4 ? UInt32(p[3]) << 24 : 0)
                let value = Double(raw) / 65536.0
                guard value > 4.0 && value < 8.0 else { report.feedbackFailed += 1; continue }
                feedback = value
                report.feedbackLast = value
                report.feedbackMin = min(report.feedbackMin, value)
                report.feedbackMax = max(report.feedbackMax, value)
            }
            if !stopping { enqueueFeedback(slot) }
        }
    }

    // MARK: IN

    private func enqueueIn(_ slot: Slot) {
        for t in 0..<slot.count {
            slot.list[t] = IOUSBHostIsochronousTransaction(
                status: kIOReturnInvalid, requestCount: UInt32(kMaxPacket), offset: UInt32(t * kMaxPacket),
                completeCount: 0, timeStamp: 0, options: [])
        }
        let frame = nextInFrame
        nextInFrame += UInt64(kFramesPerRequest)
        enqueue(inPipe, slot, frame, "in") { [unowned self] status, list in
            let bytes = slot.data.bytes.assumingMemoryBound(to: UInt8.self)
            for t in 0..<slot.count {
                report.inTransactions += 1
                // Short IN packets are normal (5, 6 or 7 frames); only a failed one breaks the count.
                guard list[t].status == kIOReturnSuccess else { report.inFailed += 1; continue }
                let frames = Int(list[t].completeCount) / kBytesPerFrame
                let p = bytes + Int(list[t].offset)
                for f in 0..<frames {
                    let sample = read24(p + f * kBytesPerFrame)
                    let above = abs(sample) >= kImpulseAmplitude / 4
                    if above && !inAbove { onset(at: inIndex + f) }
                    inAbove = above
                }
                inIndex += frames
            }
            if !stopping { enqueueIn(slot) }
        }
    }

    // An onset on IN channel 1 at IN index `j`: matched to the latest impulse sent before it.
    private func onset(at j: Int) {
        guard let k = sentImpulses.last(where: { $0 <= j }), j - k < kImpulsePeriod else { report.unmatched += 1; return }
        report.lags.append(j - k)
    }

    // MARK: plumbing

    private func enqueue(_ pipe: IOUSBHostPipe, _ slot: Slot, _ frame: UInt64, _ name: String,
                         _ done: @escaping (IOReturn, UnsafeMutablePointer<IOUSBHostIsochronousTransaction>) -> Void) {
        do {
            try pipe.enqueueIORequest(with: slot.data, transactionList: slot.list, transactionListCount: slot.count,
                                      firstFrameNumber: frame, options: []) { [unowned self] status, list in
                // Completions arrive on the pipe's own queue; all state lives on ours.
                queue.async {
                    self.pending -= 1
                    done(status, list)
                }
            }
            pending += 1
        } catch where pipe === feedbackPipe {
            // That slot is dropped (one fewer feedback request in flight); the numbering is untouched.
            report.feedbackFailed += 1
        } catch {
            report.enqueueFailures.append("\(name) at frame \(frame): \(error)")
            stopping = true
        }
    }
}

func write24(_ value: Int32, to p: UnsafeMutablePointer<UInt8>) {
    p[0] = UInt8(truncatingIfNeeded: value)
    p[1] = UInt8(truncatingIfNeeded: value >> 8)
    p[2] = UInt8(truncatingIfNeeded: value >> 16)
}

func read24(_ p: UnsafePointer<UInt8>) -> Int32 {
    Int32(bitPattern: UInt32(p[0]) << 8 | UInt32(p[1]) << 16 | UInt32(p[2]) << 24) >> 8
}
