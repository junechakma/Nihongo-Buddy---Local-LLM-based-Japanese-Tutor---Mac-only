import Foundation
import Accelerate

/// Level/VAD signals for UI feedback ONLY — never starts or ends a turn (§5.3).
enum SpeechLevelMeter {
    /// RMS level of a chunk, normalized roughly to 0…1 for the UI meter.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        // Map typical speech RMS (~0.005–0.15) onto a visible 0–1 range.
        return min(value * 8, 1)
    }

    /// Whether an utterance plausibly contains speech at all — used for the
    /// "I didn't hear anything" path when Done is tapped on silence.
    static func containsSpeech(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        guard !samples.isEmpty else { return false }
        let frame = 1600 // 100 ms at 16 kHz
        var i = 0
        while i < samples.count {
            let end = min(i + frame, samples.count)
            if rms(Array(samples[i..<end])) > threshold { return true }
            i = end
        }
        return false
    }
}
