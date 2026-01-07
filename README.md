# AudioNormalizer

Swift library for audio volume normalization on iOS/macOS. Supports industry-standard loudness measurement (LUFS/EBU R128) and true peak detection (ITU-R BS.1770-4).

## Features

- **Peak Normalization** - Normalize to target peak level
- **RMS Normalization** - Normalize to target average loudness  
- **LUFS Normalization** - Industry-standard loudness (Spotify, Apple Music, YouTube, Broadcast)
- **Dynamic Normalization** - Frame-by-frame gain adjustment for even volume (voice, meditation, podcasts)
- **True Peak Detection** - Inter-sample peak detection with 4x oversampling
- **Loudness Range (LRA)** - Dynamic range measurement
- **Problem Spots Detection** - Identify quiet/loud sections with timestamps
- **Swift 6 Ready** - Full `Sendable` compliance, modern async/await APIs
- **Streaming Processing** - Memory efficient, handles files of any length

## Requirements

- iOS 18.0+ / macOS 15.0+
- Swift 5.9+
- Xcode 16.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VasilyPolyuhovich/AudioNormalizer.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → paste the repository URL.

### Manual Installation

Copy the following files to your project:
- `Source/AudioNormalizationService.swift`
- `Source/LUFSAnalyzer.swift`
- `Source/TruePeakDetector.swift`
- `Source/DynamicNormalizer.swift`

Add frameworks: `AVFoundation`, `Accelerate`

## API Reference

### AudioNormalizationService

Main service class for audio analysis and normalization.

```swift
public final class AudioNormalizationService: Sendable {
    public init()
    
    /// Normalize audio file
    public func normalizeAudio(
        inputURL: URL,
        outputURL: URL,
        method: NormalizationMethod,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> AudioAnalysis
    
    /// Analyze audio without normalizing
    public func analyzeAudio(
        at url: URL,
        method: NormalizationMethod
    ) async throws -> AudioAnalysis
}
```

### NormalizationMethod

```swift
public enum NormalizationMethod: Sendable {
    case peak(targetDB: Float)      // Target peak level in dB (default: -0.1)
    case rms(targetDB: Float)       // Target RMS level in dB (default: -20)
    case lufs(targetLUFS: Float, truePeakLimit: Float = -1.0)  // Target LUFS with true peak limit
    case dynamic(config: DynamicNormalizationConfig)  // Frame-by-frame gain adjustment
}
```

### DynamicNormalizationConfig

Configuration for dynamic (frame-by-frame) normalization:

```swift
public struct DynamicNormalizationConfig: Sendable {
    public let targetRMSdB: Float        // Target RMS level (default: -20 dB)
    public let frameDuration: Double     // Frame size in seconds (default: 0.5s)
    public let gaussianSize: Int         // Smoothing window size (default: 31)
    public let gaussianSigma: Float      // Smoothing strength (default: 7.0)
    public let maxGainDB: Float          // Maximum boost (default: 20 dB)
    public let minGainDB: Float          // Maximum attenuation (default: -20 dB)
    public let truePeakLimitDB: Float    // True peak limit (default: -1.0 dBTP)
    public let silenceThresholdDB: Float // Silence detection (default: -50 dB)
    
    // Built-in presets
    public static let voiceDefault: DynamicNormalizationConfig
    public static let meditationDefault: DynamicNormalizationConfig
    public static let musicDefault: DynamicNormalizationConfig
}
```

### AudioAnalysis

Analysis result containing all audio measurements:

```swift
public struct AudioAnalysis: Sendable {
    public let peakLevel: Float        // Peak amplitude (0.0 to 1.0)
    public let rmsLevel: Float         // RMS level (0.0 to 1.0)
    public let peakDB: Float           // Sample peak in dB
    public let rmsDB: Float            // RMS in dB
    public let requiredGain: Float     // Calculated gain multiplier
    public let channelCount: Int       // Number of audio channels
    public let perChannelPeakDB: [Float]
    public let perChannelRmsDB: [Float]
    
    // LUFS measurements (ITU-R BS.1770-4)
    public let integratedLUFS: Float   // Integrated loudness (gated)
    public let truePeakDB: Float       // True peak in dBTP
    public let shortTermLUFS: Float?   // Short-term loudness (3s window)
    public let loudnessRange: Float?   // LRA in LU
    
    // Dynamic normalization (nil for static methods)
    public let dynamicAnalysis: DynamicNormalizer.AnalysisResult?
    
    // Before/after comparison preview
    public let preview: NormalizationPreview?
}
```

### DynamicNormalizer.AnalysisResult

Detailed analysis for dynamic normalization:

```swift
public struct AnalysisResult: Sendable {
    public let frameRMSLevels: [Float]    // Per-frame RMS in dB
    public let framePeakLevels: [Float]   // Per-frame peak in dB
    public let rawGains: [Float]          // Gains before smoothing
    public let smoothedGains: [Float]     // Gains after Gaussian smoothing
    public let finalGains: [Float]        // Final gains after peak limiting
    public let frameSizeSamples: Int      // Samples per frame
    public let frameDuration: Double      // Frame duration in seconds
    
    // Statistics
    public let averageGainDB: Float
    public let maxGainDB: Float
    public let minGainDB: Float
    public let framesProcessed: Int
    
    // Problem spots (sections requiring significant adjustment)
    public let problemSpots: [ProblemSpot]
    
    public var totalDuration: Double { get }
}
```

### ProblemSpot

Identifies sections in audio that require significant gain adjustment:

```swift
public struct ProblemSpot: Sendable, Identifiable {
    public enum SpotType: String, Sendable {
        case tooQuiet = "Too Quiet"
        case tooLoud = "Too Loud"
    }
    
    public let id: Int              // Frame index
    public let type: SpotType
    public let frameIndex: Int
    public let timeSeconds: Double
    public let timeFormatted: String  // "MM:SS" format
    public let levelDB: Float         // Original level
    public let appliedGainDB: Float   // Gain to be applied
    public let resultingLevelDB: Float
}
```

### NormalizationError

```swift
public enum NormalizationError: Error, Sendable {
    case invalidInputURL
    case invalidOutputURL
    case assetReaderCreationFailed
    case assetWriterCreationFailed
    case noAudioTrack
    case processingFailed(String)
    case insufficientData
}
```

## Usage Examples

### Basic Usage

```swift
import AudioNormalizer

let service = AudioNormalizationService()

// Simple normalization to Spotify's target (-14 LUFS)
let inputURL = URL(fileURLWithPath: "/path/to/input.m4a")
let outputURL = URL(fileURLWithPath: "/path/to/output.m4a")

do {
    let analysis = try await service.normalizeAudio(
        inputURL: inputURL,
        outputURL: outputURL,
        method: .lufs(targetLUFS: -14.0, truePeakLimit: -1.0)
    )
    print("Normalized! Gain applied: \(analysis.requiredGain)x")
} catch {
    print("Error: \(error)")
}
```

### Advanced Usage with Analysis

```swift
let service = AudioNormalizationService()

// Step 1: Analyze first to see current levels
let analysis = try await service.analyzeAudio(
    at: inputURL,
    method: .lufs(targetLUFS: -14.0, truePeakLimit: -1.0)
)

print("""
Current Audio Levels:
- Peak: \(String(format: "%.1f", analysis.peakDB)) dB
- True Peak: \(String(format: "%.1f", analysis.truePeakDB)) dBTP
- Integrated LUFS: \(String(format: "%.1f", analysis.integratedLUFS)) LUFS
- Loudness Range: \(analysis.loudnessRange.map { String(format: "%.1f", $0) } ?? "N/A") LU
- Required Gain: \(String(format: "%.2f", analysis.requiredGain))x
""")

// Step 2: Decide on normalization method based on analysis
let method: AudioNormalizationService.NormalizationMethod
if analysis.integratedLUFS < -20 {
    // Very quiet audio - use LUFS normalization
    method = .lufs(targetLUFS: -14.0, truePeakLimit: -1.0)
} else if analysis.peakDB < -6 {
    // Has headroom - use peak normalization
    method = .peak(targetDB: -1.0)
} else {
    // Already loud - just limit true peak
    method = .lufs(targetLUFS: analysis.integratedLUFS, truePeakLimit: -1.0)
}

// Step 3: Normalize with progress tracking
let result = try await service.normalizeAudio(
    inputURL: inputURL,
    outputURL: outputURL,
    method: method,
    progressHandler: { progress in
        print("Progress: \(Int(progress * 100))%")
    }
)
```

### Dynamic Normalization

Dynamic normalization adjusts gain frame-by-frame to even out volume differences. Perfect for:
- Voice recordings with varying volume
- Meditation/prayer audio with quiet passages
- Podcasts with multiple speakers at different levels
- Audiobooks with whispered sections

```swift
let service = AudioNormalizationService()

// Use built-in voice preset
let analysis = try await service.normalizeAudio(
    inputURL: inputURL,
    outputURL: outputURL,
    method: .dynamic(config: .voiceDefault)
)

// Check dynamic analysis results
if let dynamic = analysis.dynamicAnalysis {
    print("""
    Dynamic Normalization Results:
    - Frames processed: \(dynamic.framesProcessed)
    - Duration: \(String(format: "%.1f", dynamic.totalDuration))s
    - Average gain: \(String(format: "%+.1f", dynamic.averageGainDB)) dB
    - Max gain: \(String(format: "%+.1f", dynamic.maxGainDB)) dB
    - Min gain: \(String(format: "%+.1f", dynamic.minGainDB)) dB
    - Problem spots: \(dynamic.problemSpots.count)
    """)
}
```

### Analyzing Problem Spots

Identify sections that need significant volume adjustment:

```swift
let analysis = try await service.analyzeAudio(
    at: inputURL,
    method: .dynamic(config: .voiceDefault)
)

if let dynamic = analysis.dynamicAnalysis {
    print("Problem spots found: \(dynamic.problemSpots.count)")
    
    for spot in dynamic.problemSpots.prefix(5) {
        print("""
        \(spot.timeFormatted) - \(spot.type.rawValue)
          Level: \(String(format: "%.0f", spot.levelDB)) dB
          Gain: \(String(format: "%+.0f", spot.appliedGainDB)) dB
          Result: \(String(format: "%.0f", spot.resultingLevelDB)) dB
        """)
    }
}

// Example output:
// 0:42 - Too Quiet
//   Level: -45 dB
//   Gain: +18 dB
//   Result: -27 dB
// 1:15 - Too Quiet
//   Level: -42 dB
//   Gain: +16 dB
//   Result: -26 dB
```

### Custom Dynamic Configuration

```swift
// Aggressive settings for meditation/prayer recordings
let meditationConfig = DynamicNormalizationConfig(
    targetRMSdB: -18.0,       // Slightly louder target
    frameDuration: 0.4,       // Faster response
    gaussianSize: 21,         // Less smoothing
    gaussianSigma: 5.0,
    maxGainDB: 24.0,          // Allow more boost
    minGainDB: -15.0,
    truePeakLimitDB: -1.0,
    silenceThresholdDB: -45.0 // Lower silence threshold
)

// Gentle settings for music (preserve dynamics)
let musicConfig = DynamicNormalizationConfig(
    targetRMSdB: -16.0,
    frameDuration: 1.0,       // Slower response
    gaussianSize: 41,         // More smoothing
    gaussianSigma: 10.0,
    maxGainDB: 12.0,          // Less aggressive
    minGainDB: -12.0,
    truePeakLimitDB: -1.0,
    silenceThresholdDB: -60.0
)

let result = try await service.normalizeAudio(
    inputURL: inputURL,
    outputURL: outputURL,
    method: .dynamic(config: meditationConfig)
)
```

### Before/After Preview

Get a preview of normalization results before applying:

```swift
let analysis = try await service.analyzeAudio(
    at: inputURL,
    method: .dynamic(config: .voiceDefault)
)

if let preview = analysis.preview {
    print("""
    \(preview.method)
    Gain to apply: \(String(format: "%+.1f", preview.gainDB)) dB
    
    Before:
      Peak: \(String(format: "%.1f", preview.before.peakDB)) dB
      RMS: \(String(format: "%.1f", preview.before.rmsDB)) dB
    
    After:
      Peak: \(String(format: "%.1f", preview.after.peakDB)) dB
      RMS: \(String(format: "%.1f", preview.after.rmsDB)) dB
    """)
}
```

### Platform-Specific Presets

```swift
// Spotify / Most streaming platforms
.lufs(targetLUFS: -14.0, truePeakLimit: -1.0)

// Apple Music / Apple Podcasts
.lufs(targetLUFS: -16.0, truePeakLimit: -1.0)

// YouTube
.lufs(targetLUFS: -13.0, truePeakLimit: -1.0)

// Broadcast (EBU R128)
.lufs(targetLUFS: -23.0, truePeakLimit: -1.0)

// General audio (maximize without clipping)
.peak(targetDB: -0.1)

// Speech/Podcast (RMS-based)
.rms(targetDB: -18.0)
```

### SwiftUI Integration

```swift
struct NormalizerView: View {
    @State private var isProcessing = false
    @State private var progress: Double = 0
    
    private let service = AudioNormalizationService()
    
    var body: some View {
        VStack {
            if isProcessing {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
            }
            
            Button("Normalize") {
                Task { await normalize() }
            }
            .disabled(isProcessing)
        }
    }
    
    func normalize() async {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            _ = try await service.normalizeAudio(
                inputURL: inputURL,
                outputURL: outputURL,
                method: .lufs(targetLUFS: -14.0, truePeakLimit: -1.0),
                progressHandler: { p in
                    Task { @MainActor in progress = p }
                }
            )
        } catch {
            print("Error: \(error)")
        }
    }
}
```

## Target Levels Reference

### Static Normalization

| Platform | Method | Target | True Peak Limit |
|----------|--------|--------|-----------------|
| Spotify | LUFS | -14 LUFS | -1.0 dBTP |
| Apple Music | LUFS | -16 LUFS | -1.0 dBTP |
| Apple Podcasts | LUFS | -16 LUFS | -1.0 dBTP |
| YouTube | LUFS | -13 LUFS | -1.0 dBTP |
| Broadcast (EBU R128) | LUFS | -23 LUFS | -1.0 dBTP |
| General Audio | Peak | -0.1 dB | N/A |

### Dynamic Normalization Presets

| Preset | Target RMS | Frame | Max Gain | Use Case |
|--------|-----------|-------|----------|----------|
| `voiceDefault` | -20 dB | 0.5s | +20 dB | Speech, podcasts, interviews |
| `meditationDefault` | -18 dB | 0.4s | +24 dB | Meditation, prayers, quiet passages |
| `musicDefault` | -16 dB | 1.0s | +12 dB | Music with dynamics preservation |

## Standards Compliance

- **ITU-R BS.1770-4** - Loudness measurement algorithms
- **EBU R128** - Loudness normalization and permitted maximum level
- **True Peak** - 4x oversampling with cubic interpolation

## License

MIT License - see LICENSE file for details.

## Author

Vasily Polyuhovich
