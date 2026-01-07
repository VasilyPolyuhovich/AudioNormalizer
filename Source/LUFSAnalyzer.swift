import Foundation
import Accelerate

/// LUFS Analyzer implementing ITU-R BS.1770-4 / EBU R128 standard
/// Provides integrated loudness measurement with K-weighting and gating
public final class LUFSAnalyzer {
    
    // MARK: - Types
    
    public struct LUFSResult: Sendable {
        public let integratedLUFS: Float      // Integrated loudness (gated)
        public let shortTermLUFS: Float?      // Max short-term loudness (3s window)
        public let momentaryLUFS: Float?      // Max momentary loudness (400ms)
        public let loudnessRange: Float?      // LRA in LU
    }
    
    // MARK: - Properties
    
    private let sampleRate: Double
    private let channelCount: Int
    private var kWeightingFilters: [BiquadFilter] = []
    
    // MARK: - Initialization
    
    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.kWeightingFilters = Self.createKWeightingFilters(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
    
    // MARK: - Public Methods
    
    /// Calculate LUFS from audio samples
    /// - Parameter samples: Interleaved audio samples (Float, -1.0 to 1.0)
    /// - Returns: LUFS measurement result
    public func analyze(samples: [Float]) -> LUFSResult {
        guard samples.count > 0 else {
            return LUFSResult(
                integratedLUFS: -Float.infinity,
                shortTermLUFS: nil,
                momentaryLUFS: nil,
                loudnessRange: nil
            )
        }
        
        // Apply K-weighting filter
        var filteredSamples = samples
        for filter in kWeightingFilters {
            filter.process(&filteredSamples, channelCount: channelCount)
        }
        
        // Calculate block loudness values
        let blockLoudness = calculateBlockLoudness(filteredSamples)
        
        guard !blockLoudness.isEmpty else {
            return LUFSResult(
                integratedLUFS: -Float.infinity,
                shortTermLUFS: nil,
                momentaryLUFS: nil,
                loudnessRange: nil
            )
        }
        
        // Apply gating and calculate integrated loudness
        let integrated = calculateIntegratedLoudness(blockLoudness)
        
        // Calculate short-term (3s) and momentary (400ms) loudness
        let shortTerm = calculateShortTermLoudness(blockLoudness)
        let momentary = blockLoudness.max()
        
        // Calculate loudness range
        let lra = calculateLoudnessRange(blockLoudness, integratedLUFS: integrated)
        
        return LUFSResult(
            integratedLUFS: integrated,
            shortTermLUFS: shortTerm,
            momentaryLUFS: momentary,
            loudnessRange: lra
        )
    }
    
    /// Reset filter states (call between different audio files)
    public func reset() {
        for filter in kWeightingFilters {
            filter.reset()
        }
    }
}

// MARK: - Private Implementation

private extension LUFSAnalyzer {
    
    /// Calculate loudness for each 400ms block with 75% overlap
    func calculateBlockLoudness(_ samples: [Float]) -> [Float] {
        let blockSizeFrames = Int(0.4 * sampleRate)  // 400ms
        let hopSizeFrames = Int(0.1 * sampleRate)    // 100ms (75% overlap)
        let blockSizeSamples = blockSizeFrames * channelCount
        let hopSizeSamples = hopSizeFrames * channelCount
        
        guard blockSizeSamples > 0, hopSizeSamples > 0 else { return [] }
        
        // Channel weights per ITU-R BS.1770-4
        let channelWeights = getChannelWeights()
        
        var blockLoudness: [Float] = []
        var position = 0
        
        while position + blockSizeSamples <= samples.count {
            var blockSum: Float = 0.0
            
            samples.withUnsafeBufferPointer { buffer in
                for channel in 0..<channelCount {
                    // Use vDSP for efficient sum of squares
                    let startIdx = position + channel
                    let stride = vDSP_Stride(channelCount)
                    var sumSq: Float = 0

                    vDSP_svesq(
                        buffer.baseAddress!.advanced(by: startIdx),
                        stride,
                        &sumSq,
                        vDSP_Length(blockSizeFrames)
                    )

                    let meanSquare = sumSq / Float(blockSizeFrames)
                    let weight = channel < channelWeights.count ? channelWeights[channel] : 1.0
                    blockSum += weight * meanSquare
                }
            }
            
            // Convert to LUFS (-0.691 is the K-weighting offset)
            let blockLUFS: Float = -0.691 + 10.0 * log10(max(blockSum, 1e-10))
            blockLoudness.append(blockLUFS)
            
            position += hopSizeSamples
        }
        
        return blockLoudness
    }
    
    /// Apply EBU R128 gating and calculate integrated loudness
    func calculateIntegratedLoudness(_ blockLoudness: [Float]) -> Float {
        // Gate 1: Absolute threshold (-70 LUFS)
        let absoluteThreshold: Float = -70.0
        let gatedBlocks1 = blockLoudness.filter { $0 > absoluteThreshold }
        
        guard !gatedBlocks1.isEmpty else { return -70.0 }
        
        // Calculate ungated mean loudness
        let ungatedSum = gatedBlocks1.reduce(Float(0)) { 
            $0 + pow(10.0, $1 / 10.0) 
        }
        let ungatedLoudness = 10.0 * log10(ungatedSum / Float(gatedBlocks1.count))
        
        // Gate 2: Relative threshold (-10 LU below ungated)
        let relativeThreshold = ungatedLoudness - 10.0
        let gatedBlocks2 = gatedBlocks1.filter { $0 > relativeThreshold }
        
        guard !gatedBlocks2.isEmpty else { return ungatedLoudness }
        
        // Final integrated loudness
        let integratedSum = gatedBlocks2.reduce(Float(0)) { 
            $0 + pow(10.0, $1 / 10.0) 
        }
        return 10.0 * log10(integratedSum / Float(gatedBlocks2.count))
    }
    
    /// Calculate maximum short-term loudness (3 second window)
    func calculateShortTermLoudness(_ blockLoudness: [Float]) -> Float? {
        let blocksIn3Seconds = Int(3.0 / 0.1)  // 30 blocks
        guard blockLoudness.count >= blocksIn3Seconds else { return nil }
        
        var maxShortTerm: Float = -Float.infinity
        
        for i in 0...(blockLoudness.count - blocksIn3Seconds) {
            let window = blockLoudness[i..<(i + blocksIn3Seconds)]
            let windowSum = window.reduce(Float(0)) { 
                $0 + pow(10.0, $1 / 10.0) 
            }
            let windowLUFS = 10.0 * log10(windowSum / Float(blocksIn3Seconds))
            maxShortTerm = max(maxShortTerm, windowLUFS)
        }
        
        return maxShortTerm
    }
    
    /// Calculate Loudness Range (LRA) per EBU R128
    func calculateLoudnessRange(_ blockLoudness: [Float], integratedLUFS: Float) -> Float? {
        // Apply relative gating for LRA calculation
        let relativeThreshold = integratedLUFS - 20.0
        let gatedBlocks = blockLoudness.filter { $0 > relativeThreshold }
        
        guard gatedBlocks.count >= 20 else { return nil }
        
        let sorted = gatedBlocks.sorted()
        let lowIdx = Int(Float(sorted.count) * 0.10)   // 10th percentile
        let highIdx = Int(Float(sorted.count) * 0.95) // 95th percentile
        
        return sorted[highIdx] - sorted[lowIdx]
    }
    
    /// Get channel weights per ITU-R BS.1770-4
    func getChannelWeights() -> [Float] {
        switch channelCount {
        case 1: return [1.0]           // Mono
        case 2: return [1.0, 1.0]      // Stereo L, R
        case 6: return [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]  // 5.1: L, R, C, LFE, Ls, Rs
        default: return [Float](repeating: 1.0, count: channelCount)
        }
    }
}

// MARK: - K-Weighting Filters

private extension LUFSAnalyzer {
    
    /// Create K-weighting filter chain per ITU-R BS.1770-4
    static func createKWeightingFilters(sampleRate: Double, channelCount: Int) -> [BiquadFilter] {
        // Stage 1: High-shelf filter (head acoustics model)
        let highShelf = createHighShelfFilter(sampleRate: sampleRate, channelCount: channelCount)
        
        // Stage 2: High-pass filter (RLB weighting)
        let highPass = createHighPassFilter(sampleRate: sampleRate, channelCount: channelCount)
        
        return [highShelf, highPass]
    }
    
    static func createHighShelfFilter(sampleRate: Double, channelCount: Int) -> BiquadFilter {
        // ITU-R BS.1770-4 high-shelf coefficients
        let f0: Double = 1681.974450955533
        let G: Double = 3.999843853973347  // ~4dB boost
        let Q: Double = 0.7071752369554196
        
        let K = tan(.pi * f0 / sampleRate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        
        let a0 = 1.0 + K / Q + K * K
        let b0 = Float((Vh + Vb * K / Q + K * K) / a0)
        let b1 = Float(2.0 * (K * K - Vh) / a0)
        let b2 = Float((Vh - Vb * K / Q + K * K) / a0)
        let a1 = Float(2.0 * (K * K - 1.0) / a0)
        let a2 = Float((1.0 - K / Q + K * K) / a0)
        
        return BiquadFilter(
            coefficients: BiquadCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2),
            channelCount: channelCount
        )
    }
    
    static func createHighPassFilter(sampleRate: Double, channelCount: Int) -> BiquadFilter {
        // RLB (Revised Low-frequency B-weighting) high-pass
        let f0: Double = 38.13547087602444
        let Q: Double = 0.5003270373238773
        
        let K = tan(.pi * f0 / sampleRate)
        let a0 = 1.0 + K / Q + K * K
        let b0 = Float(1.0 / a0)
        let b1 = Float(-2.0 / a0)
        let b2 = Float(1.0 / a0)
        let a1 = Float(2.0 * (K * K - 1.0) / a0)
        let a2 = Float((1.0 - K / Q + K * K) / a0)
        
        return BiquadFilter(
            coefficients: BiquadCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2),
            channelCount: channelCount
        )
    }
}

// MARK: - Biquad Filter

/// Biquad filter coefficients
public struct BiquadCoefficients: Sendable {
    public let b0, b1, b2: Float
    public let a1, a2: Float
}

/// Biquad filter with per-channel state
final class BiquadFilter: @unchecked Sendable {
    private let coeffs: BiquadCoefficients
    private var z1: [Float]
    private var z2: [Float]
    
    init(coefficients: BiquadCoefficients, channelCount: Int) {
        self.coeffs = coefficients
        self.z1 = [Float](repeating: 0, count: channelCount)
        self.z2 = [Float](repeating: 0, count: channelCount)
    }
    
    func reset() {
        z1 = [Float](repeating: 0, count: z1.count)
        z2 = [Float](repeating: 0, count: z2.count)
    }
    
    /// Process interleaved samples in-place using Direct Form II Transposed
    func process(_ samples: inout [Float], channelCount: Int) {
        let frameCount = samples.count / channelCount
        
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let idx = frame * channelCount + channel
                let input = samples[idx]
                
                let output = coeffs.b0 * input + z1[channel]
                z1[channel] = coeffs.b1 * input - coeffs.a1 * output + z2[channel]
                z2[channel] = coeffs.b2 * input - coeffs.a2 * output
                
                samples[idx] = output
            }
        }
    }
}
