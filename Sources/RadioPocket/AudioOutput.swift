import Foundation
import AudioToolbox
import CEQ

/// Plays compressed packets from a `PacketRing` through an AudioQueue. The processing tap runs the EQ and
/// captures samples for the visualizer; pausing pauses only the queue, so the ring keeps filling.
final class AudioOutput: @unchecked Sendable {
    static let bufferCapacity: UInt32 = 16384
    static let bufferCount = 8
    static let prebufferSeconds = 1.0
    let dsp: OpaquePointer
    var playing: (() -> Void)?
    var failed: ((String) -> Void)?
    private let ring: PacketRing
    private let condition = NSCondition()
    private let queueLock = NSLock()       // serializes AudioQueueEnqueueBuffer against AudioQueueReset
    private var queue: AudioQueueRef?
    private var tap: AudioQueueProcessingTapRef?
    private var format = AudioStreamBasicDescription()
    private var available: [AudioQueueBufferRef] = []
    private var bufferFrames: [UnsafeMutableRawPointer: UInt32] = [:]
    private var inFlight: UInt64 = 0
    private var stopping = false
    private var started = false
    private var paused = false
    private var thread: Thread?
    private var failureReported = false
    private let panLock = NSLock()
    private var pan: Float = 0
    private var streamChannels: UInt32 = 2

    init(dsp: OpaquePointer, ring: PacketRing) { self.dsp = dsp; self.ring = ring }

    /// Mono streams have no left or right channel for the DSP to turn down, so the queue pans them instead.
    func setBalance(_ value: Float) {
        panLock.lock(); pan = value; panLock.unlock()
        applyPan()
    }
    private func applyPan() {
        panLock.lock(); let value = streamChannels == 1 ? pan : 0; panLock.unlock()
        queueLock.lock(); if let queue { AudioQueueSetParameter(queue, kAudioQueueParam_Pan, value) }; queueLock.unlock()
    }

    /// Seconds of audio the queue holds that the ring’s cursor has already passed.
    var queuedSeconds: Double { condition.lock(); defer { condition.unlock() }; return Double(inFlight) / ring.sampleRate }

    private var isStopping: Bool { condition.lock(); defer { condition.unlock() }; return stopping }
    private func report(_ message: String) {
        guard !isStopping, !failureReported else { return }
        failureReported = true
        DispatchQueue.main.async { [weak self] in self?.failed?(message) }
    }

    func configure(_ description: AudioStreamBasicDescription, cookie: Data?) {
        guard queue == nil else { return }
        format = description
        ring.configure(sampleRate: description.mSampleRate)
        let info = Unmanaged.passUnretained(self).toOpaque()
        var created: AudioQueueRef?
        let status = AudioQueueNewOutput(&format, { info, _, buffer in
            let owner = Unmanaged<AudioOutput>.fromOpaque(info!).takeUnretainedValue()
            owner.condition.lock()
            owner.inFlight -= UInt64(owner.bufferFrames.removeValue(forKey: UnsafeMutableRawPointer(buffer)) ?? 0)
            owner.available.append(buffer); owner.condition.broadcast(); owner.condition.unlock()
        }, info, nil, nil, 0, &created)
        guard status == noErr, let created else { report("Unsupported stream audio format (\(status))."); return }
        queue = created
        if let cookie, !cookie.isEmpty {
            cookie.withUnsafeBytes { _ = AudioQueueSetProperty(created, kAudioQueueProperty_MagicCookie, $0.baseAddress!, UInt32($0.count)) }
        }
        var maxFrames: UInt32 = 0
        var processing = AudioStreamBasicDescription()
        let tapStatus = AudioQueueProcessingTapNew(created, { info, tap, count, time, flags, frames, buffers in
            let owner = Unmanaged<AudioOutput>.fromOpaque(info).takeUnretainedValue()
            guard AudioQueueProcessingTapGetSourceAudio(tap, count, time, flags, frames, buffers) == noErr else { frames.pointee = 0; return }
            var channel: UInt32 = 0
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { rp_eq_process(owner.dsp, data.assumingMemoryBound(to: Float.self), frames.pointee, buffer.mNumberChannels, channel) }
                channel += buffer.mNumberChannels
            }
        }, info, .postEffects, &maxFrames, &processing, &tap)
        guard tapStatus == noErr, processing.mBitsPerChannel == 32, processing.mFormatFlags & kAudioFormatFlagIsFloat != 0, processing.mChannelsPerFrame <= 8 else {
            report("The stream’s decoded audio format cannot be equalized (\(tapStatus))."); return
        }
        rp_eq_prepare(dsp, processing.mSampleRate)
        rp_eq_channels(dsp, processing.mChannelsPerFrame)
        panLock.lock(); streamChannels = processing.mChannelsPerFrame; panLock.unlock()
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(created, Self.bufferCapacity, &buffer) == noErr, let buffer else { report("Could not allocate an audio buffer."); return }
            available.append(buffer)
        }
        AudioQueueSetParameter(created, kAudioQueueParam_Volume, 1)
        applyPan()
        let pump = Thread { [weak self] in self?.pump() }
        pump.qualityOfService = .userInitiated; pump.name = "RadioPocket audio pump"
        thread = pump; pump.start()
    }

    private func acquire() -> AudioQueueBufferRef? {
        condition.lock(); defer { condition.unlock() }
        while available.isEmpty && !stopping { condition.wait() }
        return stopping ? nil : available.removeFirst()
    }

    private func pump() {
        var epoch = ring.currentEpoch
        var descriptions: [AudioStreamPacketDescription] = []
        descriptions.reserveCapacity(512)
        var buffer: AudioQueueBufferRef?
        var used: UInt32 = 0, frames: UInt32 = 0
        let variable = format.mFramesPerPacket == 0
        let constantRate = format.mBytesPerPacket != 0      // PCM: packets need no descriptions
        while !isStopping {
            if buffer == nil {
                guard let next = acquire() else { break }
                buffer = next; used = 0; frames = 0; descriptions.removeAll(keepingCapacity: true)
            }
            var seen = epoch
            guard let packet = ring.next(epoch: &seen) else { break }
            if seen != epoch { epoch = seen; used = 0; frames = 0; descriptions.removeAll(keepingCapacity: true) }
            let size = UInt32(packet.data.count)
            guard size > 0, size <= Self.bufferCapacity else { continue }
            if used + size > Self.bufferCapacity || (!constantRate && descriptions.count == 512), let full = buffer {
                guard enqueue(full, used: used, frames: frames, descriptions: descriptions) else { return }
                guard let next = acquire() else { break }
                buffer = next; used = 0; frames = 0; descriptions.removeAll(keepingCapacity: true)
            }
            guard let current = buffer else { break }
            packet.data.withUnsafeBytes { memcpy(current.pointee.mAudioData.advanced(by: Int(used)), $0.baseAddress!, $0.count) }
            if !constantRate { descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(used), mVariableFramesInPacket: variable ? packet.frames : 0, mDataByteSize: size)) }
            used += size; frames += packet.frames
            // Compressed packets are small, so flush early; PCM fills most of a buffer so eight of them hold real time.
            if used >= (constantRate ? Self.bufferCapacity * 3 / 4 : 4096) || ring.isEmpty {
                guard enqueue(current, used: used, frames: frames, descriptions: descriptions) else { return }
                buffer = nil
            }
        }
    }

    private func enqueue(_ buffer: AudioQueueBufferRef, used: UInt32, frames: UInt32, descriptions: [AudioStreamPacketDescription]) -> Bool {
        guard let queue, used > 0, !isStopping else { return !isStopping }
        buffer.pointee.mAudioDataByteSize = used
        condition.lock(); bufferFrames[UnsafeMutableRawPointer(buffer)] = frames; inFlight += UInt64(frames); condition.unlock()
        queueLock.lock()
        let status = descriptions.isEmpty ? AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            : descriptions.withUnsafeBufferPointer { AudioQueueEnqueueBuffer(queue, buffer, UInt32($0.count), $0.baseAddress) }
        queueLock.unlock()
        if status == kAudioQueueErr_EnqueueDuringReset {
            // A seek flushed the queue under us; this buffer is from before the move, so recycle it.
            condition.lock(); inFlight -= UInt64(bufferFrames.removeValue(forKey: UnsafeMutableRawPointer(buffer)) ?? 0)
            available.append(buffer); condition.broadcast(); condition.unlock()
            return true
        }
        guard status == noErr else { report("The decoder rejected an audio packet (\(status))."); return false }
        condition.lock(); let queued = Double(inFlight) / ring.sampleRate; condition.unlock()
        condition.lock(); let outOfBuffers = available.isEmpty; condition.unlock()
        // Start with a short pre-buffer, but never wait on a prebuffer the eight queue buffers cannot hold.
        if !started, queued >= Self.prebufferSeconds || outOfBuffers || ring.isEmpty && queued >= 0.25 { startQueue() }
        return true
    }

    private func startQueue() {
        guard let queue, !started else { return }
        started = true
        guard !paused else { return }
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else { report("The audio output could not start (\(status))."); return }
        DispatchQueue.main.async { [weak self] in self?.playing?() }
    }

    func pause() {
        paused = true
        if let queue, started { AudioQueuePause(queue) }
    }
    func resume() {
        guard paused else { return }
        paused = false
        guard let queue else { return }
        if started { if AudioQueueStart(queue, nil) == noErr { DispatchQueue.main.async { [weak self] in self?.playing?() } } }
        else { startQueue() }
    }
    /// Discards audio already handed to the queue (after the ring cursor moved).
    func flush() { if let queue { queueLock.lock(); AudioQueueReset(queue); queueLock.unlock() } }

    func stop() {
        condition.lock(); stopping = true; condition.broadcast(); condition.unlock()
        ring.close()
        if let queue { AudioQueueStop(queue, true) }
        // The pump exits once the ring is closed and the condition is signalled; dispose after it has.
        let pump = thread; thread = nil
        let queue = self.queue; self.queue = nil; tap = nil
        DispatchQueue.global(qos: .utility).async {
            while let pump, !pump.isFinished && pump.isExecuting { usleep(2000) }
            if let queue { AudioQueueDispose(queue, true) }
        }
    }
}
