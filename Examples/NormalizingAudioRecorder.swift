import AVFoundation
import Accelerate

/// Audio recorder with automatic volume normalization
/// Supports real-time monitoring and post-recording normalization
public final class NormalizingAudioRecorder: NSObject {
    
    // MARK: - Types
    
    public enum RecorderError: Error, Sendable {
        case permissionDenied
        case setupFailed
        case recordingFailed
        case normalizationFailed(String)
    }
    
    public struct RecordingSettings: Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let bitDepth: Int
        public let quality: AVAudioQuality
        
        public static let high = RecordingSettings(
            sampleRate: 48000,
            channels: 1,
            bitDepth: 32,
            quality: .high
        )
        
        public static let medium = RecordingSettings(
            sampleRate: 44100,
            channels: 1,
            bitDepth: 24,
            quality: .medium
        )
    }
    
    // MARK: - Properties
    
    private var audioRecorder: AVAudioRecorder?
    private let normalizationService = AudioNormalizationService()
    private var recordingURL: URL?
    private var levelTimer: Timer?
    
    public var isRecording: Bool {
        audioRecorder?.isRecording ?? false
    }
    
    public var currentLevel: Float {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return 0.0
        }
        recorder.updateMeters()
        // Average power in dB (-160 to 0)
        let avgPower = recorder.averagePower(forChannel: 0)
        // Convert to linear scale (0.0 to 1.0)
        return pow(10, avgPower / 20)
    }
    
    public var peakLevel: Float {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return 0.0
        }
        recorder.updateMeters()
        let peakPower = recorder.peakPower(forChannel: 0)
        return pow(10, peakPower / 20)
    }
    
    // MARK: - Callbacks
    
    public var levelUpdateHandler: (@Sendable (Float, Float) -> Void)?  // (average, peak)
    public var recordingCompletedHandler: (@Sendable (URL) -> Void)?
    public var errorHandler: (@Sendable (Error) -> Void)?
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// Request microphone permission
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// Start recording with automatic normalization
    /// - Parameters:
    ///   - settings: Recording configuration
    ///   - enableMetering: Enable real-time level monitoring
    /// - Returns: Recording file URL
    @discardableResult
    public func startRecording(
        settings: RecordingSettings = .high,
        enableMetering: Bool = true
    ) async throws -> URL {
        
        // Check permission
        guard await requestPermission() else {
            throw RecorderError.permissionDenied
        }
        
        // Setup audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        
        // Generate recording URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let recordingURL = documentsPath.appendingPathComponent("recording_\(timestamp).m4a")
        self.recordingURL = recordingURL
        
        // Configure recorder settings
        let recorderSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: settings.sampleRate,
            AVNumberOfChannelsKey: settings.channels,
            AVEncoderAudioQualityKey: settings.quality.rawValue
        ]
        
        // Create recorder
        audioRecorder = try AVAudioRecorder(url: recordingURL, settings: recorderSettings)
        audioRecorder?.delegate = self
        audioRecorder?.isMeteringEnabled = enableMetering
        
        guard audioRecorder?.record() == true else {
            throw RecorderError.recordingFailed
        }
        
        // Start level monitoring if enabled
        if enableMetering {
            startLevelMonitoring()
        }
        
        return recordingURL
    }
    
    /// Stop recording and optionally normalize the audio
    /// - Parameters:
    ///   - normalize: Whether to normalize after recording
    ///   - method: Normalization method to use
    /// - Returns: Final audio file URL (normalized or original)
    public func stopRecording(
        normalize: Bool = true,
        method: AudioNormalizationService.NormalizationMethod = .peak(targetDB: -0.1)
    ) async throws -> URL {
        
        stopLevelMonitoring()
        
        guard let recorder = audioRecorder, let recordingURL = recordingURL else {
            throw RecorderError.recordingFailed
        }
        
        recorder.stop()
        
        // Deactivate audio session
        try AVAudioSession.sharedInstance().setActive(false)
        
        guard normalize else {
            return recordingURL
        }
        
        // Normalize the recording
        let baseName = recordingURL.deletingPathExtension().lastPathComponent
        let normalizedURL = recordingURL.deletingLastPathComponent()
            .appendingPathComponent(baseName + "_normalized")
            .appendingPathExtension("m4a")
        
        do {
            _ = try await normalizationService.normalizeAudio(
                inputURL: recordingURL,
                outputURL: normalizedURL,
                method: method
            )
            
            // Remove original recording
            try? FileManager.default.removeItem(at: recordingURL)
            
            return normalizedURL
            
        } catch {
            throw RecorderError.normalizationFailed(error.localizedDescription)
        }
    }
    
    /// Cancel current recording without saving
    public func cancelRecording() {
        stopLevelMonitoring()
        audioRecorder?.stop()
        audioRecorder?.deleteRecording()
        
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    // MARK: - Private Methods
    
    private func startLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let avgLevel = self.currentLevel
            let peakLevel = self.peakLevel
            self.levelUpdateHandler?(avgLevel, peakLevel)
        }
    }
    
    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

// MARK: - AVAudioRecorderDelegate

extension NormalizingAudioRecorder: AVAudioRecorderDelegate {
    
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag, let url = recordingURL {
            recordingCompletedHandler?(url)
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            errorHandler?(error)
        }
    }
}

// MARK: - SwiftUI Integration Example

import SwiftUI
import Combine

@MainActor
public class RecorderViewModel: ObservableObject {
    @Published public var isRecording = false
    @Published public var currentLevel: Float = 0.0
    @Published public var peakLevel: Float = 0.0
    @Published public var recordingDuration: TimeInterval = 0
    @Published public var recordedFileURL: URL?
    
    private let recorder = NormalizingAudioRecorder()
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    
    public init() {
        setupRecorder()
    }
    
    private func setupRecorder() {
        recorder.levelUpdateHandler = { [weak self] avg, peak in
            Task { @MainActor in
                self?.currentLevel = avg
                self?.peakLevel = peak
            }
        }
        
        recorder.recordingCompletedHandler = { [weak self] url in
            Task { @MainActor in
                self?.recordedFileURL = url
            }
        }
    }
    
    public func startRecording() {
        Task {
            do {
                isRecording = true
                recordingStartTime = Date()
                startDurationTimer()
                
                _ = try await recorder.startRecording(
                    settings: .high,
                    enableMetering: true
                )
            } catch {
                print("Recording error: \(error)")
                isRecording = false
            }
        }
    }
    
    public func stopRecording() {
        Task {
            do {
                stopDurationTimer()
                let url = try await recorder.stopRecording(
                    normalize: true,
                    method: .peak(targetDB: -0.1)
                )
                recordedFileURL = url
                isRecording = false
                currentLevel = 0
                peakLevel = 0
                recordingDuration = 0
            } catch {
                print("Stop recording error: \(error)")
            }
        }
    }
    
    public func cancelRecording() {
        recorder.cancelRecording()
        stopDurationTimer()
        isRecording = false
        currentLevel = 0
        peakLevel = 0
        recordingDuration = 0
    }
    
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }
}

public struct RecorderView: View {
    @StateObject private var viewModel = RecorderViewModel()
    
    var body: some View {
        VStack(spacing: 30) {
            
            // Level meters
            VStack(spacing: 10) {
                Text("Audio Level")
                    .font(.headline)
                
                // Average level
                VStack(alignment: .leading, spacing: 5) {
                    Text("Average")
                        .font(.caption)
                    ProgressView(value: Double(viewModel.currentLevel))
                        .tint(.blue)
                }
                
                // Peak level
                VStack(alignment: .leading, spacing: 5) {
                    Text("Peak")
                        .font(.caption)
                    ProgressView(value: Double(viewModel.peakLevel))
                        .tint(.orange)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            
            // Duration
            if viewModel.isRecording {
                Text(formatDuration(viewModel.recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundColor(.red)
            }
            
            // Controls
            HStack(spacing: 40) {
                if viewModel.isRecording {
                    Button(action: viewModel.cancelRecording) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                    }
                    
                    Button(action: viewModel.stopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                    }
                } else {
                    Button(action: viewModel.startRecording) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                    }
                }
            }
            
            if let url = viewModel.recordedFileURL {
                Text("Recorded: \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    RecorderView()
}
