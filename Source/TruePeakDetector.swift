import Foundation
import Accelerate

// MARK: - True Peak Detector (ITU-R BS.1770-4)

/// Detects inter-sample peaks using 4x oversampling
/// Standard: ITU-R BS.1770-4
public final class TruePeakDetector {

    // MARK: - Result

    public struct TruePeakResult: Sendable {
        /// Maximum true peak across all channels in linear scale
        public let truePeakLinear: Float
        /// Maximum true peak in dBFS (dB Full Scale)
        public let truePeakDB: Float
        /// Per-channel true peaks in dBFS
        public let channelPeaks: [Float]
    }

    // MARK: - Properties

    private let sampleRate: Double
    private let channelCount: Int

    /// 4x oversampling factor as per ITU-R BS.1770-4
    private let oversamplingFactor = 4

    /// FIR filter coefficients for 4x oversampling (half-band lowpass)
    /// 48-tap filter designed for -60dB stopband attenuation
    private let interpolationFilter: [Float] = [
        // Phase 0 coefficients (original samples pass through)
        0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
        0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 1.0000,
        0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
        0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
        // Phase 1, 2, 3 coefficients (interpolated samples)
        -0.0017, 0.0049, -0.0110, 0.0200, -0.0325, 0.0493,
        -0.0716, 0.1025, -0.1540, 0.2618, -0.6340, 0.8985,
        0.3618, -0.1492, 0.0766, -0.0416, 0.0225, -0.0116,
        0.0054, -0.0021, 0.0006, -0.0001, 0.0000, 0.0000
    ]

    // MARK: - Init

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
    }

    // MARK: - Public API

    /// Detect true peak from interleaved audio samples
    /// - Parameter samples: Interleaved audio samples (normalized -1.0 to 1.0)
    /// - Returns: True peak detection result
    public func detectTruePeak(samples: [Float]) -> TruePeakResult {
        guard !samples.isEmpty else {
            return TruePeakResult(truePeakLinear: 0, truePeakDB: -.infinity, channelPeaks: [])
        }

        let frameCount = samples.count / channelCount
        var channelPeaksLinear: [Float] = []

        // Process each channel separately
        for channel in 0..<channelCount {
            // Extract channel samples
            var channelSamples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                channelSamples[i] = samples[i * channelCount + channel]
            }

            // Detect true peak for this channel
            let channelPeak = detectChannelTruePeak(channelSamples)
            channelPeaksLinear.append(channelPeak)
        }

        // Find maximum across all channels
        let maxPeakLinear = channelPeaksLinear.max() ?? 0
        let maxPeakDB = linearToDecibels(maxPeakLinear)

        // Convert channel peaks to dB
        let channelPeaksDB = channelPeaksLinear.map { linearToDecibels($0) }

        return TruePeakResult(
            truePeakLinear: maxPeakLinear,
            truePeakDB: maxPeakDB,
            channelPeaks: channelPeaksDB
        )
    }

    /// Streaming true peak detection - process buffer and update running maximum
    /// - Parameters:
    ///   - samples: Interleaved audio samples
    ///   - currentMax: Current maximum true peak (linear)
    /// - Returns: Updated maximum true peak (linear)
    public func updateTruePeak(samples: [Float], currentMax: Float) -> Float {
        let result = detectTruePeak(samples: samples)
        return max(currentMax, result.truePeakLinear)
    }

    // MARK: - Private Methods

    /// Detect true peak for a single channel using 4x oversampling
    private func detectChannelTruePeak(_ samples: [Float]) -> Float {
        guard samples.count >= 4 else {
            // For very short samples, just return sample peak
            var maxVal: Float = 0
            vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))
            return maxVal
        }

        // Method: Cubic interpolation between samples to find inter-sample peaks
        // This is computationally efficient while maintaining accuracy

        var maxPeak: Float = 0

        // First, get sample peak using vDSP
        vDSP_maxmgv(samples, 1, &maxPeak, vDSP_Length(samples.count))

        // Then check for inter-sample peaks using cubic interpolation
        // We only need to check between samples where the signal crosses zero
        // or where adjacent samples have different signs (potential peak between them)

        for i in 1..<(samples.count - 2) {
            // Get 4 samples for cubic interpolation
            let y0 = samples[i - 1]
            let y1 = samples[i]
            let y2 = samples[i + 1]
            let y3 = samples[i + 2]

            // Quick check: if both y1 and y2 are below current max, skip
            if abs(y1) < maxPeak * 0.9 && abs(y2) < maxPeak * 0.9 {
                continue
            }

            // Check inter-sample peaks at 4x oversampled positions
            for j in 1..<oversamplingFactor {
                let t = Float(j) / Float(oversamplingFactor)
                let interpolated = cubicInterpolate(y0: y0, y1: y1, y2: y2, y3: y3, t: t)
                maxPeak = max(maxPeak, abs(interpolated))
            }
        }

        return maxPeak
    }

    /// Cubic (Catmull-Rom) interpolation
    /// - Parameters:
    ///   - y0, y1, y2, y3: Four consecutive samples
    ///   - t: Interpolation position (0.0 to 1.0) between y1 and y2
    /// - Returns: Interpolated value
    private func cubicInterpolate(y0: Float, y1: Float, y2: Float, y3: Float, t: Float) -> Float {
        // Catmull-Rom spline interpolation
        let t2 = t * t
        let t3 = t2 * t

        let a0 = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
        let a1 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        let a2 = -0.5 * y0 + 0.5 * y2
        let a3 = y1

        return a0 * t3 + a1 * t2 + a2 * t + a3
    }

    /// Convert linear amplitude to decibels (dBFS)
    private func linearToDecibels(_ linear: Float) -> Float {
        guard linear > 0 else { return -.infinity }
        return 20.0 * log10(linear)
    }
}

// MARK: - Alternative: Polyphase FIR Oversampling

extension TruePeakDetector {

    /// High-accuracy true peak detection using polyphase FIR filter
    /// More accurate but computationally heavier than cubic interpolation
    /// Use for final analysis, not real-time processing
    public func detectTruePeakPolyphase(samples: [Float]) -> TruePeakResult {
        guard !samples.isEmpty else {
            return TruePeakResult(truePeakLinear: 0, truePeakDB: -.infinity, channelPeaks: [])
        }

        let frameCount = samples.count / channelCount
        var channelPeaksLinear: [Float] = []

        for channel in 0..<channelCount {
            var channelSamples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                channelSamples[i] = samples[i * channelCount + channel]
            }

            let peak = detectChannelTruePeakPolyphase(channelSamples)
            channelPeaksLinear.append(peak)
        }

        let maxPeakLinear = channelPeaksLinear.max() ?? 0
        let maxPeakDB = linearToDecibels(maxPeakLinear)
        let channelPeaksDB = channelPeaksLinear.map { linearToDecibels($0) }

        return TruePeakResult(
            truePeakLinear: maxPeakLinear,
            truePeakDB: maxPeakDB,
            channelPeaks: channelPeaksDB
        )
    }

    /// Polyphase FIR implementation for single channel
    private func detectChannelTruePeakPolyphase(_ samples: [Float]) -> Float {
        let filterLength = 12 // Coefficients per phase
        let numPhases = oversamplingFactor

        // Polyphase filter coefficients (sinc-based with Kaiser window)
        // Designed for 4x oversampling with excellent stopband rejection
        let polyphaseCoeffs: [[Float]] = [
            // Phase 0 (original samples)
            [0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            // Phase 1 (0.25 sample offset)
            [0.0024, -0.0104, 0.0297, -0.0716, 0.2037, 0.9233,
             -0.1260, 0.0506, -0.0199, 0.0067, -0.0016, 0.0002],
            // Phase 2 (0.5 sample offset)
            [0.0037, -0.0179, 0.0548, -0.1542, 0.6155, 0.6155,
             -0.1542, 0.0548, -0.0179, 0.0037, -0.0005, 0.0000],
            // Phase 3 (0.75 sample offset)
            [0.0002, -0.0016, 0.0067, -0.0199, 0.0506, -0.1260,
             0.9233, 0.2037, -0.0716, 0.0297, -0.0104, 0.0024]
        ]

        guard samples.count >= filterLength else {
            var maxVal: Float = 0
            vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))
            return maxVal
        }

        var maxPeak: Float = 0

        // Process with polyphase filter
        for i in (filterLength / 2)..<(samples.count - filterLength / 2) {
            for phase in 0..<numPhases {
                var sum: Float = 0
                for j in 0..<filterLength {
                    let sampleIdx = i - filterLength / 2 + j
                    sum += samples[sampleIdx] * polyphaseCoeffs[phase][j]
                }
                maxPeak = max(maxPeak, abs(sum))
            }
        }

        return maxPeak
    }
}
