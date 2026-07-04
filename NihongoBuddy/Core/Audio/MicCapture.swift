@preconcurrency import AVFoundation

/// AVAudioEngine mic capture producing 16 kHz mono Float32 — Gemma's expected
/// rate; we resample ourselves, correctly, once (§5.1).
///
/// Manual turn-taking: start() on Speak tap, finish() only on Done tap.
/// A rolling 300 ms pre-roll buffer runs while idle so the first syllable
/// after the tap isn't clipped (§5.4).
///
/// The tap callback runs on the audio IO thread: everything there is
/// synchronous and lock-protected — no actors, no per-buffer Tasks, or the
/// HAL IO work loop overloads and drops cycles.
final class MicCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let preRollSeconds: Double = 0.3
    static let maxUtteranceSeconds: Double = 60

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var recording = false
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var buffersSinceLevelUpdate = 0

    /// Request permission and start the idle tap (pre-roll + level metering).
    /// `levelHandler` is called on the main queue, throttled to ~15 Hz.
    func prepare(levelHandler: @escaping @Sendable (Float) -> Void) async throws {
        self.levelHandler = levelHandler

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard granted else { throw MicError.permissionDenied }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.sampleRate,
                                               channels: 1, interleaved: false) else {
            throw MicError.formatUnavailable
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, targetFormat: targetFormat)
        }
        try engine.start()
    }

    func start() {
        lock.lock()
        samples = preRoll
        recording = true
        lock.unlock()
    }

    /// Pause the idle tap while the model thinks/speaks — inference saturates
    /// the cores and the starved audio IO thread logs overload warnings.
    /// Pre-roll only matters while idle/listening, so nothing is lost.
    func pauseIdleTap() {
        engine.pause()
    }

    func resumeIdleTap() {
        lock.lock()
        preRoll = []
        lock.unlock()
        try? engine.start()
    }

    /// Stop recording and return the captured utterance (including pre-roll).
    func finish() -> [Float] {
        lock.lock()
        recording = false
        let out = samples
        samples = []
        lock.unlock()
        return out
    }

    var isAtMaxLength: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate >= Self.maxUtteranceSeconds
    }

    /// Runs on the audio IO thread — synchronous, allocation-light, no await.
    private func ingest(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0,
              let channel = converted.floatChannelData else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))

        lock.lock()
        if recording {
            samples.append(contentsOf: chunk)
        } else {
            preRoll.append(contentsOf: chunk)
            let maxPreRoll = Int(Self.sampleRate * Self.preRollSeconds)
            if preRoll.count > maxPreRoll {
                preRoll.removeFirst(preRoll.count - maxPreRoll)
            }
        }
        buffersSinceLevelUpdate += 1
        let shouldEmitLevel = buffersSinceLevelUpdate >= 3
        if shouldEmitLevel { buffersSinceLevelUpdate = 0 }
        lock.unlock()

        if shouldEmitLevel, let levelHandler {
            let level = SpeechLevelMeter.rms(chunk)
            DispatchQueue.main.async { levelHandler(level) }
        }
    }

    enum MicError: Error {
        case permissionDenied
        case formatUnavailable
    }
}
