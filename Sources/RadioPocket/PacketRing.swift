import Foundation

/// One compressed audio packet and how many PCM frames it decodes to.
struct AudioPacket {
    var data: Data
    var frames: UInt32
}

/// Time-shift store between the network/demuxer thread and the audio pump. It retains up to `maxSeconds`
/// of compressed packets (the unplayed live edge plus already-played history), so pausing keeps the
/// connection drained and rewinding is a cursor move. Appending never blocks.
final class PacketRing {
    private let lock = NSCondition()
    private var packets: [AudioPacket] = []
    private var ends: [UInt64] = []     // cumulative frames at the end of each retained packet
    private var head = 0                // index of the oldest retained packet
    private var firstSeq = 0            // absolute sequence number of packets[head]
    private var baseFrames: UInt64 = 0  // frames before packets[head]
    private var cursor = 0              // absolute sequence number of the next packet to play
    private var bytes = 0
    private var closed = false
    private var generation = 0
    private(set) var sampleRate = 44100.0
    let maxSeconds: Double
    let maxBytes: Int

    init(maxSeconds: Double = 300, maxBytes: Int = 48 * 1024 * 1024) { self.maxSeconds = maxSeconds; self.maxBytes = maxBytes }

    func configure(sampleRate: Double) { lock.lock(); self.sampleRate = max(8000, sampleRate); lock.unlock() }

    private var endSeq: Int { firstSeq + packets.count - head }
    private var totalFrames: UInt64 { ends.last ?? baseFrames }
    private func frames(before seq: Int) -> UInt64 { seq <= firstSeq ? baseFrames : ends[head + seq - firstSeq - 1] }

    func append(_ packet: AudioPacket) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        packets.append(packet); ends.append(totalFrames + UInt64(max(1, packet.frames))); bytes += packet.data.count
        // Drop the oldest history beyond the time or memory budget; a stalled cursor is pushed forward with it.
        let limit = UInt64(maxSeconds * sampleRate)
        while head < packets.count - 1, totalFrames - baseFrames > limit || bytes > maxBytes {
            baseFrames = ends[head]; bytes -= packets[head].data.count
            packets[head].data = Data(); head += 1; firstSeq += 1
        }
        if head > 4096 { packets.removeFirst(head); ends.removeFirst(head); head = 0 }
        cursor = max(cursor, firstSeq)
        lock.broadcast()
    }

    /// Blocks until a packet is available at the play cursor. Returns nil once closed.
    /// `epoch` changes whenever the cursor was moved by a seek, so the caller can flush what it already queued.
    func next(epoch: inout Int) -> AudioPacket? {
        lock.lock(); defer { lock.unlock() }
        while !closed {
            if generation != epoch { epoch = generation }
            if cursor < endSeq {
                let packet = packets[head + cursor - firstSeq]
                cursor += 1
                return packet
            }
            lock.wait()
        }
        return nil
    }
    var currentEpoch: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// Seconds of audio between the play cursor and the live edge (not counting what the audio queue already holds).
    var secondsBehindLive: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(totalFrames - frames(before: min(cursor, endSeq))) / sampleRate
    }
    /// Seconds of history currently retained (how far back a rewind can go from the live edge).
    var retainedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(totalFrames - baseFrames) / sampleRate }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return packets.count == head }

    /// Moves the play cursor by `seconds` (negative = back) measured from `reference`, clamped to the retained window.
    /// `alreadyQueued` is the audio the output holds past the cursor, so the move is relative to what is audible.
    @discardableResult func seek(by seconds: Double, alreadyQueued: Double = 0) -> Double {
        lock.lock(); defer { lock.unlock() }
        let audible = Double(frames(before: min(cursor, endSeq))) - alreadyQueued * sampleRate
        let target = max(Double(baseFrames), min(Double(totalFrames), audible + seconds * sampleRate))
        var low = firstSeq, high = endSeq
        while low < high { let mid = (low + high) / 2; if Double(frames(before: mid)) < target { low = mid + 1 } else { high = mid } }
        cursor = low; generation += 1
        lock.broadcast()
        return Double(totalFrames - frames(before: cursor)) / sampleRate
    }

    func goLive() { lock.lock(); cursor = endSeq; generation += 1; lock.broadcast(); lock.unlock() }

    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }
}
