import SwiftUI
import AVFoundation

/// SwiftUI view for audio normalization with progress tracking
public struct AudioNormalizationView: View {

    @StateObject private var viewModel = AudioNormalizationViewModel()
    
    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // Audio file selection
                    GroupBox(label: Label("Input Audio", systemImage: "waveform")) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let url = viewModel.inputURL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No file selected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Button("Select Audio File") {
                                viewModel.selectAudioFile()
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Normalization method selection
                    GroupBox(label: Label("Normalization Method", systemImage: "slider.horizontal.3")) {
                        VStack(alignment: .leading, spacing: 15) {
                            Picker("Method", selection: $viewModel.selectedMethod) {
                                Text("Peak").tag(NormalizationMethodType.peak)
                                Text("RMS").tag(NormalizationMethodType.rms)
                                Text("LUFS").tag(NormalizationMethodType.lufs)
                            }
                            .pickerStyle(.segmented)

                            switch viewModel.selectedMethod {
                            case .peak:
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Target Peak Level: \(String(format: "%.1f dB", viewModel.targetPeakDB))")
                                        .font(.caption)
                                    Slider(value: $viewModel.targetPeakDB, in: -3...0, step: 0.1)
                                }

                            case .rms:
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Target RMS Level: \(String(format: "%.1f dB", viewModel.targetRMSDB))")
                                        .font(.caption)
                                    Slider(value: $viewModel.targetRMSDB, in: -30...(-10), step: 1)
                                }

                            case .lufs:
                                LUFSSettingsView(viewModel: viewModel)
                            }
                        }
                    }

                    // Analysis results
                    if let analysis = viewModel.analysisResult {
                        GroupBox(label: Label("Audio Analysis", systemImage: "chart.bar")) {
                            VStack(alignment: .leading, spacing: 8) {
                                AnalysisRow(title: "Channels", value: "\(analysis.channelCount) (\(analysis.channelCount == 1 ? "Mono" : "Stereo"))")
                                Divider()

                                // Peak measurements
                                AnalysisRow(title: "Sample Peak", value: String(format: "%.1f dB", analysis.peakDB))
                                AnalysisRow(title: "True Peak", value: analysis.truePeakDB > -Float.infinity
                                    ? String(format: "%.1f dBTP", analysis.truePeakDB) : "N/A")
                                Divider()

                                // Loudness measurements
                                AnalysisRow(title: "RMS Level", value: String(format: "%.1f dB", analysis.rmsDB))
                                AnalysisRow(title: "Integrated LUFS", value: analysis.integratedLUFS > -Float.infinity
                                    ? String(format: "%.1f LUFS", analysis.integratedLUFS) : "N/A")

                                if let shortTerm = analysis.shortTermLUFS {
                                    AnalysisRow(title: "Short-term LUFS", value: String(format: "%.1f LUFS", shortTerm))
                                }

                                if let lra = analysis.loudnessRange {
                                    AnalysisRow(title: "Loudness Range", value: String(format: "%.1f LU", lra))
                                }

                                Divider()
                                AnalysisRow(title: "Required Gain",
                                    value: String(format: "%+.1f dB", 20 * log10(max(analysis.requiredGain, 1e-10))))
                            }
                        }
                    }

                    // Progress
                    if viewModel.isProcessing {
                        GroupBox(label: Label("Progress", systemImage: "timer")) {
                            VStack(spacing: 10) {
                                ProgressView(value: viewModel.progress)
                                Text("\(Int(viewModel.progress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Action buttons
                    VStack(spacing: 12) {
                        Button(action: {
                            Task {
                                await viewModel.analyzeAudio()
                            }
                        }) {
                            Label("Analyze Audio", systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.inputURL == nil || viewModel.isProcessing)

                        Button(action: {
                            Task {
                                await viewModel.normalizeAudio()
                            }
                        }) {
                            Label("Normalize Audio", systemImage: "waveform.badge.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.inputURL == nil || viewModel.isProcessing)
                    }
                }
                .padding()
            }
            .navigationTitle("Audio Normalization")
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
            .alert("Success", isPresented: $viewModel.showSuccess) {
                Button("OK", role: .cancel) {}
                Button("Share") {
                    viewModel.shareNormalizedAudio()
                }
            } message: {
                Text("Audio normalized successfully!")
            }
        }
    }
}

// MARK: - LUFS Settings View

public struct LUFSSettingsView: View {
    @ObservedObject var viewModel: AudioNormalizationViewModel
    
    public init(viewModel: AudioNormalizationViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Presets
            Text("Platform Preset")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LUFSPreset.allCases, id: \.self) { preset in
                        PresetButton(
                            preset: preset,
                            isSelected: viewModel.selectedLUFSPreset == preset,
                            action: {
                                viewModel.applyPreset(preset)
                            }
                        )
                    }
                }
            }

            Divider()

            // Target LUFS slider
            VStack(alignment: .leading, spacing: 5) {
                Text("Target LUFS: \(String(format: "%.1f LUFS", viewModel.targetLUFS))")
                    .font(.caption)
                Slider(value: $viewModel.targetLUFS, in: -24...(-9), step: 0.5)
                    .onChange(of: viewModel.targetLUFS) { _ in
                        viewModel.selectedLUFSPreset = .custom
                    }
            }

            // True Peak limit slider
            VStack(alignment: .leading, spacing: 5) {
                Text("True Peak Limit: \(String(format: "%.1f dBTP", viewModel.truePeakLimit))")
                    .font(.caption)
                Slider(value: $viewModel.truePeakLimit, in: -3...0, step: 0.1)
            }
        }
    }
}

public struct PresetButton: View {
    let preset: LUFSPreset
    let isSelected: Bool
    let action: () -> Void
    
    public init(preset: LUFSPreset, isSelected: Bool, action: @escaping () -> Void) {
        self.preset = preset
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(preset.name)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(String(format: "%.0f LUFS", preset.targetLUFS))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct AnalysisRow: View {
    let title: String
    let value: String
    
    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
}

// MARK: - LUFS Presets

public enum LUFSPreset: CaseIterable, Sendable {
    case spotify
    case youtube
    case appleMusic
    case applePodcasts
    case broadcast
    case custom

    public var name: String {
        switch self {
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        case .appleMusic: return "Apple Music"
        case .applePodcasts: return "Podcasts"
        case .broadcast: return "Broadcast"
        case .custom: return "Custom"
        }
    }

    public var targetLUFS: Float {
        switch self {
        case .spotify: return -14.0
        case .youtube: return -13.0
        case .appleMusic: return -16.0
        case .applePodcasts: return -16.0
        case .broadcast: return -23.0
        case .custom: return -14.0
        }
    }

    public var truePeakLimit: Float {
        switch self {
        case .spotify: return -1.0
        case .youtube: return -1.0
        case .appleMusic: return -1.0
        case .applePodcasts: return -1.0
        case .broadcast: return -1.0
        case .custom: return -1.0
        }
    }
}

// MARK: - ViewModel

public enum NormalizationMethodType: Hashable, Sendable {
    case peak
    case rms
    case lufs
}

@MainActor
public class AudioNormalizationViewModel: ObservableObject {

    @Published public var inputURL: URL?
    @Published public var outputURL: URL?
    @Published public var selectedMethod: NormalizationMethodType = .peak
    @Published public var targetPeakDB: Double = -0.1
    @Published public var targetRMSDB: Double = -20.0
    @Published public var targetLUFS: Double = -14.0
    @Published public var truePeakLimit: Double = -1.0
    @Published public var selectedLUFSPreset: LUFSPreset = .spotify
    @Published public var progress: Double = 0.0
    @Published public var isProcessing = false
    @Published public var analysisResult: AudioNormalizationService.AudioAnalysis?
    @Published public var showError = false
    @Published public var showSuccess = false
    @Published public var errorMessage = ""

    private let normalizationService = AudioNormalizationService()
    
    public init() {}

    public func selectAudioFile() {
        // In real app, use UIDocumentPickerViewController or similar
        // For demo purposes, you can set a test file URL
        #if DEBUG
        // Example: Set a test file from documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        inputURL = documentsPath.appendingPathComponent("test_audio.m4a")
        #endif
    }

    public func applyPreset(_ preset: LUFSPreset) {
        selectedLUFSPreset = preset
        if preset != .custom {
            targetLUFS = Double(preset.targetLUFS)
            truePeakLimit = Double(preset.truePeakLimit)
        }
    }

    public func analyzeAudio() async {
        guard let inputURL = inputURL else { return }

        isProcessing = true
        progress = 0.0

        do {
            let method = getSelectedNormalizationMethod()
            let analysis = try await normalizationService.analyzeAudio(at: inputURL, method: method)
            analysisResult = analysis
            print("Analysis complete: \(analysis)")
        } catch {
            errorMessage = "Analysis failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
        progress = 0.0
    }

    public func normalizeAudio() async {
        guard let inputURL = inputURL else { return }

        isProcessing = true
        progress = 0.0
        analysisResult = nil

        // Generate output URL
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputFileName = "normalized_\(timestamp).m4a"
        let outputURL = documentsPath.appendingPathComponent(outputFileName)
        self.outputURL = outputURL

        do {
            let method = getSelectedNormalizationMethod()
            let analysis = try await normalizationService.normalizeAudio(
                inputURL: inputURL,
                outputURL: outputURL,
                method: method,
                progressHandler: { @Sendable [weak self] progress in
                    Task { @MainActor in
                        self?.progress = progress
                    }
                }
            )

            analysisResult = analysis
            showSuccess = true
            print("Normalization complete: \(analysis)")
            print("Output saved to: \(outputURL.path)")

        } catch {
            errorMessage = "Normalization failed: \(error.localizedDescription)"
            showError = true
        }

        isProcessing = false
    }

    public func shareNormalizedAudio() {
        guard let outputURL = outputURL else { return }

        // Present share sheet
        let activityVC = UIActivityViewController(
            activityItems: [outputURL],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func getSelectedNormalizationMethod() -> AudioNormalizationService.NormalizationMethod {
        switch selectedMethod {
        case .peak:
            return .peak(targetDB: Float(targetPeakDB))
        case .rms:
            return .rms(targetDB: Float(targetRMSDB))
        case .lufs:
            return .lufs(targetLUFS: Float(targetLUFS), truePeakLimit: Float(truePeakLimit))
        }
    }
}

// MARK: - Preview

#Preview {
    AudioNormalizationView()
}
