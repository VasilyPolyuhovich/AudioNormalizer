import Foundation
import Accelerate

/// Configuration for dynamic audio normalization
/// Adjusts gain frame-by-frame to even out volume differences
public struct DynamicNormalizationConfig: Sendable, Equatable {

    /// Target RMS level in dB (default: -20 dB for speech)
    public let targetRMSdB: Float

    /// Frame duration in seconds (default: 0.5s)
    /// Shorter = more responsive to changes, longer = smoother
    public let frameDuration: Double

    /// Gaussian smoothing window size in frames (must be odd, default: 31)
    /// Larger = smoother transitions between gain changes
    public let gaussianSize: Int

    /// Gaussian sigma (standard deviation) in frames (default: 7.0)
    public let gaussianSigma: Float

    /// Maximum gain in dB to prevent noise amplification (default: 20 dB)
    public let maxGainDB: Float

    /// Minimum gain in dB for attenuation (default: -20 dB)
    public let minGainDB: Float

    /// True peak limit in dB to prevent clipping (default: -1.0 dBTP)
    public let truePeakLimitDB: Float

    /// Threshold below which audio is considered silence (default: -50 dB)
    /// Silence frames won't be amplified to prevent noise boosting
    public let silenceThresholdDB: Float

    public init(
        targetRMSdB: Float = -20.0,
        frameDuration: Double = 0.5,
        gaussianSize: Int = 31,
        gaussianSigma: Float = 7.0,
        maxGainDB: Float = 20.0,
        minGainDB: Float = -20.0,
        truePeakLimitDB: Float = -1.0,
        silenceThresholdDB: Float = -50.0
    ) {
        self.targetRMSdB = targetRMSdB
        self.frameDuration = frameDuration
        // Ensure gaussianSize is odd
        self.gaussianSize = gaussianSize % 2 == 0 ? gaussianSize + 1 : gaussianSize
        self.gaussianSigma = gaussianSigma
        self.maxGainDB = maxGainDB
        self.minGainDB = minGainDB
        self.truePeakLimitDB = truePeakLimitDB
        self.silenceThresholdDB = silenceThresholdDB
    }

    /// Default preset for voice/speech normalization
    public static let voiceDefault = DynamicNormalizationConfig(
        targetRMSdB: -20.0,
        frameDuration: 0.5,
        gaussianSize: 31,
        gaussianSigma: 7.0,
        maxGainDB: 20.0,
        minGainDB: -20.0,
        truePeakLimitDB: -1.0,
        silenceThresholdDB: -50.0
    )

    /// Preset for meditation/prayer recordings with very quiet parts
    /// More aggressive gain with faster response
    public static let meditationDefault = DynamicNormalizationConfig(
        targetRMSdB: -18.0,
        frameDuration: 0.4,
        gaussianSize: 21,
        gaussianSigma: 5.0,
        maxGainDB: 24.0,
        minGainDB: -15.0,
        truePeakLimitDB: -1.0,
        silenceThresholdDB: -45.0
    )

    /// Gentle preset for music with dynamics preservation
    public static let musicDefault = DynamicNormalizationConfig(
        targetRMSdB: -16.0,
        frameDuration: 1.0,
        gaussianSize: 41,
        gaussianSigma: 10.0,
        maxGainDB: 12.0,
        minGainDB: -12.0,
        truePeakLimitDB: -1.0,
        silenceThresholdDB: -60.0
    )
}

/// A spot in the audio that requires significant gain adjustment
public struct ProblemSpot: Sendable, Identifiable {
    public enum SpotType: String, Sendable {
        case tooQuiet = "Too Quiet"
        case tooLoud = "Too Loud"
    }

    public let id: Int  // Frame index as unique ID
    public let type: SpotType
    public let frameIndex: Int
    public let timeSeconds: Double
    public let timeFormatted: String  // "MM:SS" format
    public let levelDB: Float
    public let appliedGainDB: Float
    public let resultingLevelDB: Float

    public init(
        frameIndex: Int,
        type: SpotType,
        timeSeconds: Double,
        levelDB: Float,
        appliedGainDB: Float,
        resultingLevelDB: Float
    ) {
        self.id = frameIndex
        self.frameIndex = frameIndex
        self.type = type
        self.timeSeconds = timeSeconds
        self.levelDB = levelDB
        self.appliedGainDB = appliedGainDB
        self.resultingLevelDB = resultingLevelDB

        // Format time as MM:SS
        let minutes = Int(timeSeconds) / 60
        let seconds = Int(timeSeconds) % 60
        self.timeFormatted = String(format: "%d:%02d", minutes, seconds)
    }
}

/// Dynamic Audio Normalizer
/// Evens out volume differences by applying frame-by-frame gain adjustment
/// with Gaussian smoothing for natural transitions
public final class DynamicNormalizer: Sendable {

    // MARK: - Types

    /// Result of dynamic normalization analysis
    public struct AnalysisResult: Sendable {
        /// Per-frame RMS levels in dB
        public let frameRMSLevels: [Float]

        /// Per-frame peak levels in dB
        public let framePeakLevels: [Float]

        /// Per-frame calculated gains before smoothing (linear)
        public let rawGains: [Float]

        /// Per-frame gains after Gaussian smoothing (linear)
        public let smoothedGains: [Float]

        /// Per-frame gains after peak limiting (linear) - final gains to apply
        public let finalGains: [Float]

        /// Number of samples per frame
        public let frameSizeSamples: Int

        /// Statistics
        public let averageGainDB: Float
        public let maxGainDB: Float
        public let minGainDB: Float
        public let framesProcessed: Int

        /// Frame duration in seconds (for time calculations)
        public let frameDuration: Double

        /// Problem spots requiring significant gain adjustment
        public let problemSpots: [ProblemSpot]

        /// Total audio duration in seconds
        public var totalDuration: Double {
            Double(framesProcessed) * frameDuration
        }
    }

    // MARK: - Properties

    private let config: DynamicNormalizationConfig
    private let sampleRate: Double
    private let channelCount: Int
    private let frameSizeSamples: Int

    // MARK: - Initialization

    public init(
        config: DynamicNormalizationConfig,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.config = config
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameSizeSamples = Int(config.frameDuration * sampleRate) * channelCount
    }

    // MARK: - Public Methods

    /// Analyze audio and build gain envelope
    /// - Parameter samples: Interleaved audio samples (Float, -1.0 to 1.0)
    /// - Returns: Analysis result with per-frame gain envelope
    public func analyze(samples: [Float]) -> AnalysisResult {
        guard samples.count >= frameSizeSamples * 2 else {
            // Too short for dynamic processing, return unity gain
            return AnalysisResult(
                frameRMSLevels: [0],
                framePeakLevels: [0],
                rawGains: [1.0],
                smoothedGains: [1.0],
                finalGains: [1.0],
                frameSizeSamples: frameSizeSamples,
                averageGainDB: 0,
                maxGainDB: 0,
                minGainDB: 0,
                framesProcessed: 1,
                frameDuration: config.frameDuration,
                problemSpots: []
            )
        }

        // Step 1: Calculate per-frame RMS and peak levels
        let (frameRMSLevels, framePeakLevels) = calculateFrameLevels(samples: samples)

        // Step 2: Calculate raw gains
        let rawGains = calculateRawGains(frameRMSLevels: frameRMSLevels)

        // Step 3: Apply Gaussian smoothing
        let smoothedGains = applyGaussianSmoothing(gains: rawGains)

        // Step 4: Apply peak limiting
        let finalGains = applyPeakLimiting(
            gains: smoothedGains,
            framePeakLevels: framePeakLevels
        )

        // Calculate statistics
        let gainDBs = finalGains.map { 20 * log10(max($0, 1e-10)) }
        let avgGainDB = gainDBs.reduce(0, +) / Float(gainDBs.count)
        let maxGainDB = gainDBs.max() ?? 0
        let minGainDB = gainDBs.min() ?? 0

        // Find problem spots (frames with significant gain adjustment)
        let problemSpots = findProblemSpots(
            frameRMSLevels: frameRMSLevels,
            finalGains: finalGains,
            gainDBs: gainDBs
        )

        return AnalysisResult(
            frameRMSLevels: frameRMSLevels,
            framePeakLevels: framePeakLevels,
            rawGains: rawGains,
            smoothedGains: smoothedGains,
            finalGains: finalGains,
            frameSizeSamples: frameSizeSamples,
            averageGainDB: avgGainDB,
            maxGainDB: maxGainDB,
            minGainDB: minGainDB,
            framesProcessed: finalGains.count,
            frameDuration: config.frameDuration,
            problemSpots: problemSpots
        )
    }

    /// Find frames that require significant gain adjustment
    /// - Parameters:
    ///   - frameRMSLevels: RMS levels in dB per frame
    ///   - finalGains: Final gains (linear) per frame
    ///   - gainDBs: Gains in dB per frame
    /// - Returns: Array of problem spots sorted by severity
    private func findProblemSpots(
        frameRMSLevels: [Float],
        finalGains: [Float],
        gainDBs: [Float]
    ) -> [ProblemSpot] {
        // Threshold: consider it a "problem" if gain adjustment > 6 dB
        let problemThresholdDB: Float = 6.0

        var spots: [ProblemSpot] = []

        for (frameIndex, gainDB) in gainDBs.enumerated() {
            let absGainDB = abs(gainDB)

            // Skip if gain is within normal range
            guard absGainDB > problemThresholdDB else { continue }

            // Skip silence frames
            let rmsDB = frameRMSLevels[frameIndex]
            guard rmsDB > config.silenceThresholdDB else { continue }

            let type: ProblemSpot.SpotType = gainDB > 0 ? .tooQuiet : .tooLoud
            let timeSeconds = Double(frameIndex) * config.frameDuration
            let resultingLevelDB = rmsDB + gainDB

            let spot = ProblemSpot(
                frameIndex: frameIndex,
                type: type,
                timeSeconds: timeSeconds,
                levelDB: rmsDB,
                appliedGainDB: gainDB,
                resultingLevelDB: resultingLevelDB
            )
            spots.append(spot)
        }

        // Sort by severity (highest absolute gain first)
        return spots.sorted { abs($0.appliedGainDB) > abs($1.appliedGainDB) }
    }

    /// Apply dynamic gain to samples using pre-computed analysis
    /// - Parameters:
    ///   - samples: Audio samples to process (modified in place)
    ///   - analysisResult: Result from analyze()
    public func apply(to samples: inout [Float], using analysisResult: AnalysisResult) {
        let frameSize = analysisResult.frameSizeSamples
        let gains = analysisResult.finalGains

        guard gains.count > 0 else { return }

        // Build per-sample gain array with interpolation
        var sampleGains = [Float](repeating: 1.0, count: samples.count)

        for sampleIdx in 0..<samples.count {
            let framePosition = Float(sampleIdx) / Float(frameSize)
            let frameIndex = Int(framePosition)
            let fractional = framePosition - Float(frameIndex)

            // Get gains for interpolation
            let currentGain: Float
            let nextGain: Float

            if frameIndex >= gains.count - 1 {
                currentGain = gains[gains.count - 1]
                nextGain = currentGain
            } else if frameIndex < 0 {
                currentGain = gains[0]
                nextGain = currentGain
            } else {
                currentGain = gains[frameIndex]
                nextGain = gains[min(frameIndex + 1, gains.count - 1)]
            }

            // Linear interpolation
            sampleGains[sampleIdx] = currentGain + (nextGain - currentGain) * fractional
        }

        // Apply gains using vDSP for efficiency
        vDSP_vmul(samples, 1, sampleGains, 1, &samples, 1, vDSP_Length(samples.count))
    }

    /// Convenience method: analyze and apply in one step
    /// - Parameter samples: Audio samples to process (modified in place)
    /// - Returns: Analysis result
    @discardableResult
    public func process(samples: inout [Float]) -> AnalysisResult {
        let result = analyze(samples: samples)
        apply(to: &samples, using: result)
        return result
    }

    // MARK: - Private Methods

    /// Calculate RMS and peak levels for each frame
    private func calculateFrameLevels(samples: [Float]) -> (rms: [Float], peak: [Float]) {
        let frameCount = samples.count / frameSizeSamples
        var frameRMSLevels = [Float](repeating: -Float.infinity, count: frameCount)
        var framePeakLevels = [Float](repeating: -Float.infinity, count: frameCount)

        for frameIdx in 0..<frameCount {
            let startIdx = frameIdx * frameSizeSamples
            let endIdx = min(startIdx + frameSizeSamples, samples.count)
            let frameLength = endIdx - startIdx

            guard frameLength > 0 else { continue }

            // Calculate RMS using vDSP
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                let framePtr = buffer.baseAddress! + startIdx
                vDSP_rmsqv(framePtr, 1, &rms, vDSP_Length(frameLength))
            }

            // Calculate peak using vDSP
            var peak: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                let framePtr = buffer.baseAddress! + startIdx
                vDSP_maxmgv(framePtr, 1, &peak, vDSP_Length(frameLength))
            }

            // Convert to dB
            frameRMSLevels[frameIdx] = rms > 0 ? 20 * log10(rms) : -Float.infinity
            framePeakLevels[frameIdx] = peak > 0 ? 20 * log10(peak) : -Float.infinity
        }

        return (frameRMSLevels, framePeakLevels)
    }

    /// Calculate raw gain for each frame based on RMS level
    private func calculateRawGains(frameRMSLevels: [Float]) -> [Float] {
        return frameRMSLevels.map { rmsDB in
            // Don't amplify silence
            if rmsDB < config.silenceThresholdDB || rmsDB == -Float.infinity {
                return Float(1.0)
            }

            // Calculate required gain
            var gainDB = config.targetRMSdB - rmsDB

            // Clamp to limits
            gainDB = max(config.minGainDB, min(config.maxGainDB, gainDB))

            // Convert to linear
            return pow(10, gainDB / 20.0)
        }
    }

    /// Apply Gaussian smoothing to gain envelope
    private func applyGaussianSmoothing(gains: [Float]) -> [Float] {
        guard gains.count > 1 else { return gains }

        // Generate Gaussian kernel
        let kernel = generateGaussianKernel(
            size: min(config.gaussianSize, gains.count),
            sigma: config.gaussianSigma
        )

        // Pad input for convolution (reflect at edges)
        let halfKernel = kernel.count / 2
        var paddedGains = [Float](repeating: 0, count: gains.count + kernel.count - 1)

        // Fill with edge reflection
        for i in 0..<halfKernel {
            paddedGains[i] = gains[min(halfKernel - i, gains.count - 1)]
        }
        for i in 0..<gains.count {
            paddedGains[halfKernel + i] = gains[i]
        }
        for i in 0..<halfKernel {
            paddedGains[halfKernel + gains.count + i] = gains[max(0, gains.count - 1 - i)]
        }

        // Apply convolution using vDSP
        var smoothed = [Float](repeating: 0, count: gains.count)
        vDSP_conv(
            paddedGains, 1,
            kernel, 1,
            &smoothed, 1,
            vDSP_Length(gains.count),
            vDSP_Length(kernel.count)
        )

        return smoothed
    }

    /// Generate normalized Gaussian kernel
    private func generateGaussianKernel(size: Int, sigma: Float) -> [Float] {
        let actualSize = size % 2 == 0 ? size + 1 : size
        let halfSize = actualSize / 2
        var kernel = [Float](repeating: 0, count: actualSize)
        var sum: Float = 0

        for i in 0..<actualSize {
            let x = Float(i - halfSize)
            let value = exp(-(x * x) / (2 * sigma * sigma))
            kernel[i] = value
            sum += value
        }

        // Normalize
        if sum > 0 {
            for i in 0..<actualSize {
                kernel[i] /= sum
            }
        }

        return kernel
    }

    /// Apply peak limiting to prevent clipping
    private func applyPeakLimiting(gains: [Float], framePeakLevels: [Float]) -> [Float] {
        guard gains.count == framePeakLevels.count else { return gains }

        return zip(gains, framePeakLevels).map { gain, peakDB in
            guard peakDB > -Float.infinity else { return gain }

            // Calculate predicted peak after gain
            let gainDB = 20 * log10(max(gain, 1e-10))
            let predictedPeakDB = peakDB + gainDB

            // If predicted peak exceeds limit, reduce gain
            if predictedPeakDB > config.truePeakLimitDB {
                let maxAllowedGainDB = config.truePeakLimitDB - peakDB
                let maxAllowedGain = pow(10, maxAllowedGainDB / 20.0)
                return min(gain, maxAllowedGain)
            }

            return gain
        }
    }
}
