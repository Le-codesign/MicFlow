import CoreAudio
import Foundation
import os

enum BoostError: LocalizedError {
    case noChannels(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noChannels(let device): return "\(device) has no usable audio channels."
        case .coreAudio(let step, let status): return "\(step) failed (CoreAudio error \(status))."
        }
    }
}

/// Reads one device's input, applies gain plus a peak limiter, and writes the result to another
/// device's output. Used both ways round:
/// - mic boost: real microphone -> BlackHole 2ch, whose input side other apps use as their mic;
/// - speaker boost: BlackHole 16ch (the Mac's default output) -> real speakers or earphones.
///
/// Each device gets its own IOProc, joined by a ring buffer. (An aggregate device would share one
/// clock, but Bluetooth outputs inside an aggregate stay silent.) The two clocks drift slightly, so
/// the reader re-primes on underrun and skips ahead when too much audio has piled up.
final class BoostEngine {
    /// Linear gain the audio thread glides toward; set from the UI.
    var targetGain: Float = 1
    /// Peak of the most recent output buffer (0...1), read by the level meter.
    private(set) var peakLevel: Float = 0
    private(set) var isRunning = false
    /// Called on the main queue when either device changes sample rate (e.g. Bluetooth earphones
    /// switching to call mode), so the owner can restart the route.
    var onFormatChange: (() -> Void)?

    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var inputProc: AudioDeviceIOProcID?
    private var outputProc: AudioDeviceIOProcID?
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var ring = RingBuffer(channels: 1, capacity: 1)

    // DSP state, touched only by the output IOProc while running.
    private var gain: Float = 1
    private var envelope: Float = 0
    private var gainSmoothing: Float = 0.001
    private var release: Float = 0.9999
    private var primeFrames = 0
    private var maxFrames = 0
    private let ceiling: Float = 0.89 // -1 dBFS

    /// `clock` is whichever of the two is real hardware; the other one follows its sample rate.
    func start(source: AudioDevice, destination: AudioDevice, clock: AudioDevice) throws {
        stop()
        do {
            try startRoute(source: source, destination: destination, clock: clock)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let inputProc {
            AudioDeviceStop(inputDevice, inputProc)
            AudioDeviceDestroyIOProcID(inputDevice, inputProc)
            self.inputProc = nil
        }
        if let outputProc {
            AudioDeviceStop(outputDevice, outputProc)
            AudioDeviceDestroyIOProcID(outputDevice, outputProc)
            self.outputProc = nil
        }
        for (device, listener) in rateListeners {
            var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &addr, .main, listener)
        }
        rateListeners = []
        isRunning = false
        peakLevel = 0
    }

    private func startRoute(source: AudioDevice, destination: AudioDevice, clock: AudioDevice) throws {
        // Both sides must run at the same rate; the virtual device follows the hardware.
        let follower = clock == source ? destination : source
        let rate = CA.nominalSampleRate(clock.id) ?? 48_000
        CA.setNominalSampleRate(follower.id, rate)

        guard let sourceChannels = CA.streamChannels(source.id, scope: kAudioObjectPropertyScopeInput).first,
              sourceChannels > 0 else { throw BoostError.noChannels(source.name) }
        guard let outputChannels = CA.streamChannels(destination.id, scope: kAudioObjectPropertyScopeOutput).first,
              outputChannels > 0 else { throw BoostError.noChannels(destination.name) }

        let sampleRate = Float(rate)
        gainSmoothing = 1 - exp(-1 / (0.02 * sampleRate))
        release = exp(-1 / (0.15 * sampleRate))
        gain = targetGain
        envelope = 0
        primeFrames = Int(sampleRate * 0.03)
        maxFrames = primeFrames + Int(sampleRate * 0.1)
        ring = RingBuffer(channels: outputChannels, capacity: 1 << 16)

        inputDevice = source.id
        outputDevice = destination.id
        let ring = self.ring
        var status = AudioDeviceCreateIOProcIDWithBlock(&inputProc, source.id, nil) { _, input, _, _, _ in
            guard let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { return }
            let channels = Int(buffer.mNumberChannels)
            ring.write(data, frames: Int(buffer.mDataByteSize) / (channels * 4), channels: channels)
        }
        guard status == noErr else { throw BoostError.coreAudio("Opening \(source.name)", status) }
        status = AudioDeviceCreateIOProcIDWithBlock(&outputProc, destination.id, nil) { [unowned self] _, _, _, output, _ in
            self.render(output)
        }
        guard status == noErr else { throw BoostError.coreAudio("Opening \(destination.name)", status) }

        status = AudioDeviceStart(source.id, inputProc)
        guard status == noErr else { throw BoostError.coreAudio("Starting \(source.name)", status) }
        status = AudioDeviceStart(destination.id, outputProc)
        guard status == noErr else { throw BoostError.coreAudio("Starting \(destination.name)", status) }
        isRunning = true

        // Setting the follower's rate above may still notify; only a rate other than the one we
        // started with means the route needs rebuilding.
        for device in [source.id, destination.id] {
            var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isRunning, CA.nominalSampleRate(device) != rate else { return }
                self.onFormatChange?()
            }
            if AudioObjectAddPropertyListenerBlock(device, &addr, .main, listener) == noErr {
                rateListeners.append((device, listener))
            }
        }
    }

    private func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard let buffer = outs.first, let dst = buffer.mData?.assumingMemoryBound(to: Float.self),
              buffer.mNumberChannels > 0 else { return }
        let channels = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (channels * 4)
        guard ring.read(into: dst, frames: frames, primeFrames: primeFrames, maxFrames: maxFrames) else {
            peakLevel = 0
            return
        }

        let target = targetGain
        var g = gain, env = envelope, peak: Float = 0
        for frame in 0..<frames {
            g += (target - g) * gainSmoothing
            let base = frame * channels
            var framePeak: Float = 0
            for c in 0..<channels { framePeak = max(framePeak, abs(dst[base + c])) }
            framePeak *= g
            // Instant attack, smooth release: output never exceeds the ceiling.
            env = max(framePeak, env * release)
            let scale = env > ceiling ? g * ceiling / env : g
            for c in 0..<channels { dst[base + c] *= scale }
            peak = max(peak, framePeak * scale / g)
        }
        gain = g
        envelope = env
        peakLevel = peak
    }
}

/// Single-producer, single-consumer buffer of interleaved frames. The writer maps whatever channel
/// count it gets onto `channels` (a mono source is copied to every channel).
final class RingBuffer {
    private let channels: Int
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var written = 0
    private var read = 0
    private var primed = false

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        storage = .allocate(capacity: channels * capacity)
        storage.initialize(repeating: 0, count: channels * capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    private func counts() -> (written: Int, read: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (written, read)
    }

    func write(_ src: UnsafePointer<Float>, frames: Int, channels sourceChannels: Int) {
        let (w, r) = counts()
        guard w - r + frames <= capacity else { return } // reader stalled; drop rather than overwrite
        for frame in 0..<frames {
            let slot = ((w + frame) % capacity) * channels
            for c in 0..<channels { storage[slot + c] = src[frame * sourceChannels + min(c, sourceChannels - 1)] }
        }
        os_unfair_lock_lock(lock)
        written += frames
        os_unfair_lock_unlock(lock)
    }

    /// Fills `dst` and returns true, or returns false (leaving `dst` alone) while waiting for
    /// enough audio to build up.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int, primeFrames: Int, maxFrames: Int) -> Bool {
        var (w, r) = counts()
        var available = w - r
        if !primed {
            guard available >= primeFrames + frames else { return false }
            primed = true
        }
        guard available >= frames else {
            primed = false
            return false
        }
        if available > maxFrames + frames {
            r = w - (primeFrames + frames)
            available = primeFrames + frames
        }
        for frame in 0..<frames {
            let slot = ((r + frame) % capacity) * channels
            for c in 0..<channels { dst[frame * channels + c] = storage[slot + c] }
        }
        os_unfair_lock_lock(lock)
        read = r + frames
        os_unfair_lock_unlock(lock)
        return true
    }
}
