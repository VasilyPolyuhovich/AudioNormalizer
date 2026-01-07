import AVFoundation
import Accelerate

/// Audio normalization service for iOS applications
/// Supports peak, RMS, and LUFS normalization methods
/// Requires iOS 18.0+ / macOS 15.0+
public final class AudioNormalizationService: Sendable {
    
    // MARK: - Types
    
    public enum NormalizationMethod: Sendable {
        case peak(targetDB: Float)  // Default: -0.1 dB (prevents clipping)
        case rms(targetDB: Float)   // Default: -20 dB (typical speech level)
        case lufs(targetLUFS: Float, truePeakLimit: Float = -1.0)  // EBU R128: -14 LUFS (Spotify), -16 (Apple), -23 (broadcast)
    }
    
    public enum NormalizationError: Error, Sendable {
        case invalidInputURL
        case invalidOutputURL
        case assetReaderCreationFailed
        case assetWriterCreationFailed
        case noAudioTrack
        case processingFailed(String)
        case insufficientData
    }
    
    public struct AudioAnalysis: Sendable {
        public let peakLevel: Float        // Peak amplitude (0.0 to 1.0)
        public let rmsLevel: Float         // RMS level (0.0 to 1.0)
        public let peakDB: Float           // Sample peak in dB
        public let rmsDB: Float            // RMS in dB
        public let requiredGain: Float     // Gain multiplier needed
        public let channelCount: Int       // Number of audio channels (1=mono, 2=stereo)
        public let perChannelPeakDB: [Float]  // Peak levels per channel in dB
        public let perChannelRmsDB: [Float]   // RMS levels per channel in dB
        
        // LUFS measurements (ITU-R BS.1770-4 / EBU R128)
        public let integratedLUFS: Float   // Integrated loudness (gated)
        public let truePeakDB: Float       // True peak (4x oversampled)
        public let shortTermLUFS: Float?   // Short-term loudness (3s window), nil if audio < 3s
        public let loudnessRange: Float?   // LRA in LU (optional)
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Public Methods
    
    /// Normalize audio file with specified method
    /// - Parameters:
    ///   - inputURL: Source audio file URL
    ///   - outputURL: Destination audio file URL
    ///   - method: Normalization method (peak, RMS, or LUFS)
    ///   - progressHandler: Optional progress callback (0.0 to 1.0)
    /// - Returns: Audio analysis information
    public func normalizeAudio(
        inputURL: URL,
        outputURL: URL,
        method: NormalizationMethod = .peak(targetDB: -0.1),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioAnalysis {
        
        // Validate URLs
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw NormalizationError.invalidInputURL
        }
        
        // Remove existing output file if exists
        try? FileManager.default.removeItem(at: outputURL)
        
        // Step 1: Analyze audio to determine normalization parameters
        progressHandler?(0.1)
        let analysis = try await analyzeAudio(at: inputURL, method: method)
        
        // Step 2: Apply normalization
        progressHandler?(0.3)
        try await applyNormalization(
            inputURL: inputURL,
            outputURL: outputURL,
            gain: analysis.requiredGain,
            progressHandler: { progress in
                // Map 0.0-1.0 to 0.3-1.0 range
                progressHandler?(0.3 + (progress * 0.7))
            }
        )
        
        progressHandler?(1.0)
        return analysis
    }
    
    /// Analyze audio file without normalizing
    /// - Parameters:
    ///   - url: Audio file URL
    ///   - method: Method to calculate required gain
    /// - Returns: Audio analysis information
    public func analyzeAudio(
        at url: URL,
        method: NormalizationMethod = .peak(targetDB: -0.1)
    ) async throws -> AudioAnalysis {
        try await performAnalysis(url: url, method: method)
    }
    
    // MARK: - Private Methods
    
    private func performAnalysis(url: URL, method: NormalizationMethod) async throws -> AudioAnalysis {
        let asset = AVURLAsset(url: url)
        
        // Load tracks using modern async API
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NormalizationError.noAudioTrack
        }
        
        // Load format descriptions
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        
        // Get audio format info
        let channelCount: Int
        let sampleRate: Double
        if let audioFormat = formatDescriptions.first,
           let streamBasic = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat) {
            channelCount = Int(streamBasic.pointee.mChannelsPerFrame)
            sampleRate = streamBasic.pointee.mSampleRate
        } else {
            channelCount = 1
            sampleRate = 44100.0
        }
        
        // Create asset reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NormalizationError.assetReaderCreationFailed
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        
        guard reader.startReading() else {
            throw NormalizationError.processingFailed("Failed to start reading")
        }
        
        // Per-channel statistics
        var channelPeakValues = [Float](repeating: 0.0, count: channelCount)
        var channelSumSquares = [Float](repeating: 0.0, count: channelCount)
        var channelSampleCounts = [Int](repeating: 0, count: channelCount)
        
        // Collect all samples for LUFS/True Peak analysis
        var allSamples: [Float] = []
        
        // Process all samples (synchronous read loop - AVAssetReader is not Sendable)
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            
            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            
            guard let data = dataPointer else { continue }
            
            let totalSamples = length / MemoryLayout<Float>.size
            
            data.withMemoryRebound(to: Float.self, capacity: totalSamples) { floatPointer in
                // Store samples for LUFS/True Peak analysis
                allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: totalSamples))
                
                // Process interleaved samples per channel
                for channel in 0..<channelCount {
                    let samplesPerChannel = totalSamples / channelCount
                    guard samplesPerChannel > 0 else { continue }
                    
                    var localPeak: Float = 0.0
                    vDSP_maxmgv(
                        floatPointer.advanced(by: channel),
                        vDSP_Stride(channelCount),
                        &localPeak,
                        vDSP_Length(samplesPerChannel)
                    )
                    channelPeakValues[channel] = max(channelPeakValues[channel], localPeak)
                    
                    var localSumSquares: Float = 0.0
                    vDSP_svesq(
                        floatPointer.advanced(by: channel),
                        vDSP_Stride(channelCount),
                        &localSumSquares,
                        vDSP_Length(samplesPerChannel)
                    )
                    channelSumSquares[channel] += localSumSquares
                    channelSampleCounts[channel] += samplesPerChannel
                }
            }
        }
        
        // Verify we have data
        let totalSampleCount = channelSampleCounts.reduce(0, +)
        guard totalSampleCount > 0 else {
            throw NormalizationError.insufficientData
        }
        
        // Calculate per-channel RMS and dB values
        var channelRmsValues = [Float](repeating: 0.0, count: channelCount)
        var perChannelPeakDB = [Float](repeating: -Float.infinity, count: channelCount)
        var perChannelRmsDB = [Float](repeating: -Float.infinity, count: channelCount)
        
        for channel in 0..<channelCount {
            if channelSampleCounts[channel] > 0 {
                channelRmsValues[channel] = sqrtf(channelSumSquares[channel] / Float(channelSampleCounts[channel]))
                perChannelPeakDB[channel] = 20 * log10(max(channelPeakValues[channel], 1e-10))
                perChannelRmsDB[channel] = 20 * log10(max(channelRmsValues[channel], 1e-10))
            }
        }
        
        // Sample peak
        let peakValue = channelPeakValues.max() ?? 0.0
        let peakDB = 20 * log10(max(peakValue, 1e-10))
        
        // RMS
        let rmsValue = channelRmsValues.max() ?? 0.0
        let rmsDB = 20 * log10(max(rmsValue, 1e-10))
        
        // LUFS Analysis (ITU-R BS.1770-4 / EBU R128)
        let lufsAnalyzer = LUFSAnalyzer(sampleRate: sampleRate, channelCount: channelCount)
        let lufsResult = lufsAnalyzer.analyze(samples: allSamples)
        
        // True Peak Detection (4x oversampling)
        let truePeakDetector = TruePeakDetector(sampleRate: sampleRate, channelCount: channelCount)
        let truePeakResult = truePeakDetector.detectTruePeak(samples: allSamples)
        
        // Calculate required gain based on method
        let requiredGain: Float
        switch method {
        case .peak(let targetDB):
            let gainDB = targetDB - peakDB
            requiredGain = pow(10, gainDB / 20.0)
            
        case .rms(let targetDB):
            let gainDB = targetDB - rmsDB
            var gain = pow(10, gainDB / 20.0)
            // Limit gain to prevent clipping
            let maxAllowedGain = pow(10, (-0.1 - peakDB) / 20.0)
            gain = min(gain, maxAllowedGain)
            requiredGain = gain
            
        case .lufs(let targetLUFS, let truePeakLimit):
            // Calculate gain based on LUFS difference
            let currentLUFS = lufsResult.integratedLUFS
            guard currentLUFS > -Float.infinity else {
                requiredGain = 1.0
                break
            }
            let gainDB = targetLUFS - currentLUFS
            var gain = pow(10, gainDB / 20.0)
            
            // Limit gain to respect true peak limit
            let currentTruePeak = truePeakResult.truePeakDB
            if currentTruePeak > -Float.infinity {
                let maxGainForTruePeak = pow(10, (truePeakLimit - currentTruePeak) / 20.0)
                gain = min(gain, maxGainForTruePeak)
            }
            requiredGain = gain
        }
        
        return AudioAnalysis(
            peakLevel: peakValue,
            rmsLevel: rmsValue,
            peakDB: peakDB,
            rmsDB: rmsDB,
            requiredGain: requiredGain,
            channelCount: channelCount,
            perChannelPeakDB: perChannelPeakDB,
            perChannelRmsDB: perChannelRmsDB,
            integratedLUFS: lufsResult.integratedLUFS,
            truePeakDB: truePeakResult.truePeakDB,
            shortTermLUFS: lufsResult.shortTermLUFS,
            loudnessRange: lufsResult.loudnessRange
        )
    }
    
    private func applyNormalization(
        inputURL: URL,
        outputURL: URL,
        gain: Float,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        
        // Load tracks and duration using modern async API
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NormalizationError.noAudioTrack
        }
        
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        
        // Load format descriptions
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        
        // Get audio format description
        guard let audioFormat = formatDescriptions.first else {
            throw NormalizationError.noAudioTrack
        }
        
        let audioStreamBasic = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)
        let sampleRate = audioStreamBasic?.pointee.mSampleRate ?? 44100.0
        let channels = audioStreamBasic?.pointee.mChannelsPerFrame ?? 2
        
        // Create asset reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw NormalizationError.assetReaderCreationFailed
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        
        // Create asset writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .m4a) else {
            throw NormalizationError.assetWriterCreationFailed
        }
        
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128000
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)
        
        guard reader.startReading(), writer.startWriting() else {
            throw NormalizationError.processingFailed("Failed to start reading/writing")
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // Process audio data synchronously (AVAssetReader/Writer are not Sendable)
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            
            // Apply gain to sample buffer
            guard let normalizedBuffer = applySampleGain(to: sampleBuffer, gain: gain) else {
                writer.cancelWriting()
                throw NormalizationError.processingFailed("Failed to apply gain")
            }
            
            writerInput.append(normalizedBuffer)
            
            // Update progress
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let progress = min(timestamp / durationSeconds, 1.0)
            progressHandler?(progress)
        }
        
        writerInput.markAsFinished()
        
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? NormalizationError.processingFailed("Reader failed")
        }
        
        // Finish writing
        await writer.finishWriting()
        
        if writer.status == .failed {
            throw writer.error ?? NormalizationError.processingFailed("Writer failed")
        }
    }
    
    private func applySampleGain(to sampleBuffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let data = dataPointer else {
            return nil
        }
        
        // Apply gain using Accelerate framework
        let sampleCount = length / MemoryLayout<Float>.size
        data.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPointer in
            var mutableGain = gain
            vDSP_vsmul(floatPointer, 1, &mutableGain, floatPointer, 1, vDSP_Length(sampleCount))
        }
        
        return sampleBuffer
    }
}

// MARK: - Convenience Extensions

extension AudioNormalizationService.AudioAnalysis: CustomStringConvertible {
    public var description: String {
        var result = """
        Audio Analysis:
        - Channels: \(channelCount) (\(channelCount == 1 ? "Mono" : channelCount == 2 ? "Stereo" : "\(channelCount)-channel"))
        - Sample Peak: \(String(format: "%.2f%%", peakLevel * 100)) (\(String(format: "%.1f dB", peakDB)))
        - True Peak: \(truePeakDB > -Float.infinity ? String(format: "%.1f dBTP", truePeakDB) : "N/A")
        - RMS Level: \(String(format: "%.2f%%", rmsLevel * 100)) (\(String(format: "%.1f dB", rmsDB)))
        - Integrated LUFS: \(integratedLUFS > -Float.infinity ? String(format: "%.1f LUFS", integratedLUFS) : "N/A")
        """
        
        // Add short-term LUFS if available
        if let shortTerm = shortTermLUFS {
            result += "\n        - Short-term LUFS: \(String(format: "%.1f LUFS", shortTerm))"
        }
        
        // Add loudness range if available
        if let lra = loudnessRange {
            result += "\n        - Loudness Range: \(String(format: "%.1f LU", lra))"
        }
        
        result += "\n        - Required Gain: \(String(format: "%.2fx", requiredGain)) (\(String(format: "%+.1f dB", 20 * log10(max(requiredGain, 1e-10)))))"
        
        // Add per-channel details for stereo/multichannel
        if channelCount > 1 {
            result += "\n        - Per-Channel Peak:"
            for (index, peakDb) in perChannelPeakDB.enumerated() {
                let channelName = channelCount == 2 ? (index == 0 ? "L" : "R") : "Ch\(index + 1)"
                result += " [\(channelName): \(String(format: "%.1f dB", peakDb))]"
            }
            result += "\n        - Per-Channel RMS:"
            for (index, rmsDb) in perChannelRmsDB.enumerated() {
                let channelName = channelCount == 2 ? (index == 0 ? "L" : "R") : "Ch\(index + 1)"
                result += " [\(channelName): \(String(format: "%.1f dB", rmsDb))]"
            }
        }
        
        return result
    }
}
