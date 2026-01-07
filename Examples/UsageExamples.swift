import Foundation
import AVFoundation

// MARK: - Usage Examples

/// Example 1: Simple voice memo normalization
func normalizeVoiceMemo(memoURL: URL) async throws {
    let service = AudioNormalizationService()
    
    let outputURL = memoURL
        .deletingPathExtension()
        .appendingPathComponent("_normalized")
        .appendingPathExtension(memoURL.pathExtension)
    
    let analysis = try await service.normalizeAudio(
        inputURL: memoURL,
        outputURL: outputURL,
        method: .rms(targetDB: -20.0) // Standard speech level
    )
    
    print("Voice memo normalized:")
    print("- Original RMS: \(String(format: "%.1f dB", analysis.rmsDB))")
    print("- Gain applied: \(String(format: "%.1f dB", 20 * log10(analysis.requiredGain)))")
}

/// Example 2: Batch normalize multiple files
func batchNormalizeAudioFiles(urls: [URL]) async throws {
    let service = AudioNormalizationService()
    
    for (index, inputURL) in urls.enumerated() {
        let outputURL = inputURL
            .deletingLastPathComponent()
            .appendingPathComponent("normalized_\(index + 1).m4a")
        
        print("Processing \(index + 1)/\(urls.count): \(inputURL.lastPathComponent)")
        
        let analysis = try await service.normalizeAudio(
            inputURL: inputURL,
            outputURL: outputURL,
            method: .peak(targetDB: -0.1),
            progressHandler: { progress in
                print("  Progress: \(Int(progress * 100))%")
            }
        )
        
        print("  ✓ Complete - Gain: \(String(format: "%.2fx", analysis.requiredGain))\n")
    }
    
    print("Batch normalization complete!")
}

/// Example 3: Compare normalization methods
func compareNormalizationMethods(audioURL: URL) async throws {
    let service = AudioNormalizationService()
    
    // Analyze with both methods
    let peakAnalysis = try await service.analyzeAudio(
        at: audioURL,
        method: .peak(targetDB: -0.1)
    )
    
    let rmsAnalysis = try await service.analyzeAudio(
        at: audioURL,
        method: .rms(targetDB: -20.0)
    )
    
    print("Normalization Method Comparison:")
    print("\nPeak Normalization:")
    print("  Peak Level: \(String(format: "%.1f dB", peakAnalysis.peakDB))")
    print("  Required Gain: \(String(format: "%.2fx (%.1f dB)", peakAnalysis.requiredGain, 20 * log10(peakAnalysis.requiredGain)))")
    
    print("\nRMS Normalization:")
    print("  RMS Level: \(String(format: "%.1f dB", rmsAnalysis.rmsDB))")
    print("  Required Gain: \(String(format: "%.2fx (%.1f dB)", rmsAnalysis.requiredGain, 20 * log10(rmsAnalysis.requiredGain)))")
    
    // Recommendation
    let dynamicRange = peakAnalysis.peakDB - peakAnalysis.rmsDB
    print("\nDynamic Range: \(String(format: "%.1f dB", dynamicRange))")
    
    if dynamicRange > 15 {
        print("Recommendation: Use Peak normalization (high dynamic range content)")
    } else {
        print("Recommendation: Use RMS normalization (consistent level content)")
    }
}

/// Example 4: Real-time recording with custom settings
class VoiceRecorderExample {
    private let recorder = NormalizingAudioRecorder()
    private var startTime: Date?
    
    func startRecordingInterview() async throws {
        // Setup level monitoring
        recorder.levelUpdateHandler = { [weak self] avgLevel, peakLevel in
            self?.updateUI(average: avgLevel, peak: peakLevel)
        }
        
        // Custom settings for voice
        let settings = NormalizingAudioRecorder.RecordingSettings(
            sampleRate: 44100,  // Standard quality
            channels: 1,        // Mono for voice
            bitDepth: 24,       // Good quality, smaller size than 32
            quality: .high
        )
        
        startTime = Date()
        
        let url = try await recorder.startRecording(
            settings: settings,
            enableMetering: true
        )
        
        print("Interview recording started: \(url.lastPathComponent)")
    }
    
    func stopRecordingInterview() async throws -> URL {
        guard let startTime = startTime else {
            throw NSError(domain: "VoiceRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active recording"])
        }
        
        let duration = Date().timeIntervalSince(startTime)
        print("Recording duration: \(formatDuration(duration))")
        
        // Normalize to podcast standard
        let url = try await recorder.stopRecording(
            normalize: true,
            method: .rms(targetDB: -16.0) // Podcast standard
        )
        
        print("Interview saved and normalized: \(url.lastPathComponent)")
        return url
    }
    
    private func updateUI(average: Float, peak: Float) {
        // Update your UI with levels
        // Example: progress bar, waveform visualization, etc.
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

/// Example 5: Music track normalization with metadata preservation
func normalizeMusicTrack(trackURL: URL) async throws {
    let service = AudioNormalizationService()
    
    // First, analyze the track
    let analysis = try await service.analyzeAudio(
        at: trackURL,
        method: .peak(targetDB: -1.0) // Leave headroom for mastering
    )
    
    // Check if normalization is needed
    let gainDB = 20 * log10(analysis.requiredGain)
    guard abs(gainDB) > 0.5 else {
        print("Track already well-normalized (gain: \(String(format: "%.1f dB", gainDB)))")
        return
    }
    
    print("Normalizing music track...")
    print("Current peak: \(String(format: "%.1f dB", analysis.peakDB))")
    print("Will apply: \(String(format: "%.1f dB", gainDB)) gain")
    
    let outputURL = trackURL
        .deletingLastPathComponent()
        .appendingPathComponent("normalized_\(trackURL.lastPathComponent)")
    
    _ = try await service.normalizeAudio(
        inputURL: trackURL,
        outputURL: outputURL,
        method: .peak(targetDB: -1.0),
        progressHandler: { progress in
            if Int(progress * 100) % 10 == 0 {
                print("Progress: \(Int(progress * 100))%")
            }
        }
    )
    
    print("✓ Track normalized successfully")
    
    // Note: For production apps, you might want to:
    // 1. Copy metadata from original file
    // 2. Preserve album art
    // 3. Update ReplayGain tags
}

/// Example 6: Adaptive normalization based on content analysis
func adaptiveNormalization(audioURL: URL) async throws {
    let service = AudioNormalizationService()
    
    // Analyze first with peak method
    let peakAnalysis = try await service.analyzeAudio(
        at: audioURL,
        method: .peak(targetDB: -0.1)
    )
    
    // Calculate dynamic range
    let dynamicRange = peakAnalysis.peakDB - peakAnalysis.rmsDB
    
    // Choose method based on content characteristics
    let method: AudioNormalizationService.NormalizationMethod
    let contentType: String
    
    if dynamicRange > 15 {
        // High dynamic range - likely music or movie audio
        method = .peak(targetDB: -1.0)
        contentType = "Music/Film"
    } else if dynamicRange > 10 {
        // Medium dynamic range - could be podcast with music
        method = .peak(targetDB: -0.5)
        contentType = "Mixed Content"
    } else {
        // Low dynamic range - likely speech/podcast
        method = .rms(targetDB: -16.0)
        contentType = "Speech/Podcast"
    }
    
    print("Content Analysis:")
    print("- Type detected: \(contentType)")
    print("- Dynamic range: \(String(format: "%.1f dB", dynamicRange))")
    print("- Method selected: \(method)")
    
    let outputURL = audioURL
        .deletingLastPathComponent()
        .appendingPathComponent("adaptive_normalized.m4a")
    
    let analysis = try await service.normalizeAudio(
        inputURL: audioURL,
        outputURL: outputURL,
        method: method
    )
    
    print("Normalization complete:")
    print("- Gain applied: \(String(format: "%.1f dB", 20 * log10(analysis.requiredGain)))")
}

/// Example 7: Background processing with notification
func normalizeInBackground(audioURL: URL) async throws {
    let service = AudioNormalizationService()
    
    // Start background task
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    backgroundTaskID = UIApplication.shared.beginBackgroundTask {
        // Called if time expires
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    
    defer {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
    }
    
    let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("normalized_\(Date().timeIntervalSince1970).m4a")
    
    do {
        let analysis = try await service.normalizeAudio(
            inputURL: audioURL,
            outputURL: outputURL,
            method: .peak(targetDB: -0.1),
            progressHandler: { progress in
                print("Background progress: \(Int(progress * 100))%")
            }
        )
        
        // Send local notification on completion
        sendCompletionNotification(outputURL: outputURL, analysis: analysis)
        
    } catch {
        // Send error notification
        sendErrorNotification(error: error)
        throw error
    }
}

private func sendCompletionNotification(outputURL: URL, analysis: AudioNormalizationService.AudioAnalysis) {
    let content = UNMutableNotificationContent()
    content.title = "Audio Normalized"
    content.body = "Gain applied: \(String(format: "%.1f dB", 20 * log10(analysis.requiredGain)))"
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    
    UNUserNotificationCenter.current().add(request)
}

private func sendErrorNotification(error: Error) {
    let content = UNMutableNotificationContent()
    content.title = "Normalization Failed"
    content.body = error.localizedDescription
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    
    UNUserNotificationCenter.current().add(request)
}

/// Example 8: Export for different platforms using LUFS (EBU R128 / ITU-R BS.1770-4)
func normalizeForPlatformLUFS(audioURL: URL, platform: StreamingPlatform) async throws {
    let service = AudioNormalizationService()

    let method: AudioNormalizationService.NormalizationMethod
    let platformName: String

    switch platform {
    case .spotify:
        method = .lufs(targetLUFS: -14.0, truePeakLimit: -1.0)
        platformName = "Spotify"
    case .youtube:
        method = .lufs(targetLUFS: -13.0, truePeakLimit: -1.0)
        platformName = "YouTube"
    case .appleMusic:
        method = .lufs(targetLUFS: -16.0, truePeakLimit: -1.0)
        platformName = "Apple Music"
    case .applePodcasts:
        method = .lufs(targetLUFS: -16.0, truePeakLimit: -1.0)
        platformName = "Apple Podcasts"
    case .broadcast:
        method = .lufs(targetLUFS: -23.0, truePeakLimit: -1.0)
        platformName = "Broadcast (EBU R128)"
    case .custom(let lufs, let truePeak):
        method = .lufs(targetLUFS: lufs, truePeakLimit: truePeak)
        platformName = "Custom"
    }

    let outputURL = audioURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(platformName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(audioURL.lastPathComponent)")

    print("Normalizing for \(platformName) using LUFS...")

    let analysis = try await service.normalizeAudio(
        inputURL: audioURL,
        outputURL: outputURL,
        method: method
    )

    print("✓ Normalized for \(platformName)")
    print("  Integrated LUFS: \(String(format: "%.1f LUFS", analysis.integratedLUFS))")
    print("  True Peak: \(String(format: "%.1f dBTP", analysis.truePeakDB))")
    print("  Gain: \(String(format: "%+.1f dB", 20 * log10(analysis.requiredGain)))")
    print("  Output: \(outputURL.lastPathComponent)")
}

enum StreamingPlatform {
    case spotify          // -14 LUFS, -1 dBTP
    case youtube          // -13 LUFS, -1 dBTP
    case appleMusic       // -16 LUFS, -1 dBTP
    case applePodcasts    // -16 LUFS, -1 dBTP
    case broadcast        // -23 LUFS, -1 dBTP (EBU R128)
    case custom(lufs: Float, truePeak: Float)
}

/// Example 8b: Legacy RMS-based platform normalization (for comparison)
func normalizeForPlatform(audioURL: URL, platform: LegacyPlatform) async throws {
    let service = AudioNormalizationService()

    enum LegacyPlatform {
        case spotify
        case youtube
        case podcast
        case broadcast
        case custom(targetDB: Float)
    }

    let method: AudioNormalizationService.NormalizationMethod
    let platformName: String

    switch platform {
    case .spotify:
        method = .rms(targetDB: -14.0)  // Spotify loudness target
        platformName = "Spotify"
    case .youtube:
        method = .rms(targetDB: -13.0)  // YouTube loudness target
        platformName = "YouTube"
    case .podcast:
        method = .rms(targetDB: -16.0)  // Apple Podcasts standard
        platformName = "Podcast"
    case .broadcast:
        method = .rms(targetDB: -23.0)  // EBU R128 broadcast standard
        platformName = "Broadcast"
    case .custom(let targetDB):
        method = .rms(targetDB: targetDB)
        platformName = "Custom"
    }

    let outputURL = audioURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(platformName.lowercased())_\(audioURL.lastPathComponent)")

    print("Normalizing for \(platformName) (RMS method)...")

    let analysis = try await service.normalizeAudio(
        inputURL: audioURL,
        outputURL: outputURL,
        method: method
    )

    print("✓ Normalized for \(platformName)")
    print("  Target: \(method)")
    print("  Gain: \(String(format: "%.1f dB", 20 * log10(analysis.requiredGain)))")
    print("  Output: \(outputURL.lastPathComponent)")
}

/// Example 9: Professional LUFS analysis with full metrics
func analyzeLUFSMetrics(audioURL: URL) async throws {
    let service = AudioNormalizationService()

    print("Analyzing audio with LUFS metrics (ITU-R BS.1770-4)...")

    let analysis = try await service.analyzeAudio(
        at: audioURL,
        method: .lufs(targetLUFS: -14.0) // Target doesn't affect analysis, only gain calculation
    )

    print("\n=== LUFS Analysis Report ===")
    print("File: \(audioURL.lastPathComponent)")
    print("Channels: \(analysis.channelCount)")
    print("")

    // Peak measurements
    print("Peak Measurements:")
    print("  Sample Peak: \(String(format: "%.1f dB", analysis.peakDB))")
    print("  True Peak:   \(String(format: "%.1f dBTP", analysis.truePeakDB))")
    if analysis.truePeakDB > analysis.peakDB {
        let intersamplePeak = analysis.truePeakDB - analysis.peakDB
        print("  ↳ Inter-sample peak detected: +\(String(format: "%.2f dB", intersamplePeak))")
    }
    print("")

    // Loudness measurements
    print("Loudness Measurements (EBU R128):")
    print("  Integrated LUFS: \(String(format: "%.1f LUFS", analysis.integratedLUFS))")
    if let shortTerm = analysis.shortTermLUFS {
        print("  Short-term Max:  \(String(format: "%.1f LUFS", shortTerm))")
    }
    if let lra = analysis.loudnessRange {
        print("  Loudness Range:  \(String(format: "%.1f LU", lra))")
    }
    print("")

    // Platform compliance check
    print("Platform Compliance:")
    let platforms: [(name: String, lufs: Float, peak: Float)] = [
        ("Spotify", -14.0, -1.0),
        ("YouTube", -13.0, -1.0),
        ("Apple Music", -16.0, -1.0),
        ("Broadcast", -23.0, -1.0)
    ]

    for platform in platforms {
        let lufsDiff = analysis.integratedLUFS - platform.lufs
        let peakOK = analysis.truePeakDB <= platform.peak
        let status = abs(lufsDiff) <= 1.0 && peakOK ? "✓" : "✗"

        print("  \(status) \(platform.name): ", terminator: "")
        if abs(lufsDiff) <= 1.0 {
            print("LUFS OK", terminator: "")
        } else {
            print("needs \(String(format: "%+.1f dB", -lufsDiff))", terminator: "")
        }
        if !peakOK {
            print(", peak exceeds \(String(format: "%.1f dBTP", platform.peak))", terminator: "")
        }
        print("")
    }
}

/// Example 10: Compare LUFS vs RMS normalization
func compareLUFSvsRMS(audioURL: URL) async throws {
    let service = AudioNormalizationService()

    print("Comparing LUFS vs RMS normalization methods...")

    // Analyze with LUFS
    let lufsAnalysis = try await service.analyzeAudio(
        at: audioURL,
        method: .lufs(targetLUFS: -14.0)
    )

    // Analyze with RMS
    let rmsAnalysis = try await service.analyzeAudio(
        at: audioURL,
        method: .rms(targetDB: -14.0)
    )

    let lufsGainDB = 20 * log10(lufsAnalysis.requiredGain)
    let rmsGainDB = 20 * log10(rmsAnalysis.requiredGain)

    print("\n=== Method Comparison ===")
    print("Target: -14 dB/LUFS")
    print("")
    print("LUFS Method (ITU-R BS.1770-4):")
    print("  Integrated LUFS: \(String(format: "%.1f LUFS", lufsAnalysis.integratedLUFS))")
    print("  Required Gain:   \(String(format: "%+.1f dB", lufsGainDB))")
    print("  True Peak:       \(String(format: "%.1f dBTP", lufsAnalysis.truePeakDB))")
    print("")
    print("RMS Method (Simple):")
    print("  RMS Level:       \(String(format: "%.1f dB", rmsAnalysis.rmsDB))")
    print("  Required Gain:   \(String(format: "%+.1f dB", rmsGainDB))")
    print("  Sample Peak:     \(String(format: "%.1f dB", rmsAnalysis.peakDB))")
    print("")

    let gainDifference = abs(lufsGainDB - rmsGainDB)
    print("Difference: \(String(format: "%.1f dB", gainDifference))")

    if gainDifference > 2.0 {
        print("⚠️ Significant difference - audio has strong low/high frequency content")
        print("   LUFS accounts for human hearing perception (K-weighting)")
    } else {
        print("✓ Methods produce similar results for this audio")
    }
}

/// Example 11: Quality check after normalization with LUFS
func normalizeWithQualityCheck(audioURL: URL) async throws {
    let service = AudioNormalizationService()
    
    // Step 1: Normalize
    let outputURL = audioURL
        .deletingLastPathComponent()
        .appendingPathComponent("normalized.m4a")
    
    let analysis = try await service.normalizeAudio(
        inputURL: audioURL,
        outputURL: outputURL,
        method: .peak(targetDB: -0.1)
    )
    
    // Step 2: Quality checks
    var warnings: [String] = []
    
    // Check for excessive gain
    let gainDB = 20 * log10(analysis.requiredGain)
    if gainDB > 12 {
        warnings.append("High gain applied (\(String(format: "%.1f dB", gainDB))) - may introduce noise")
    }
    
    // Check for very low original level
    if analysis.peakDB < -40 {
        warnings.append("Very low input level (\(String(format: "%.1f dB", analysis.peakDB))) - consider re-recording")
    }
    
    // Check dynamic range
    let dynamicRange = analysis.peakDB - analysis.rmsDB
    if dynamicRange < 5 {
        warnings.append("Low dynamic range (\(String(format: "%.1f dB", dynamicRange))) - audio may sound compressed")
    }
    
    // Step 3: Report
    print("Normalization Quality Report:")
    print("- Peak: \(String(format: "%.1f dB", analysis.peakDB)) → -0.1 dB")
    print("- RMS: \(String(format: "%.1f dB", analysis.rmsDB))")
    print("- Dynamic Range: \(String(format: "%.1f dB", dynamicRange))")
    print("- Gain Applied: \(String(format: "%.1f dB", gainDB))")
    
    if warnings.isEmpty {
        print("\n✓ Quality: Good")
    } else {
        print("\n⚠️ Warnings:")
        warnings.forEach { print("  - \($0)") }
    }
}
