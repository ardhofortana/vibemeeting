import AppKit
import Observation
import SwiftUI
import VibeCore

/// Runs the full capture → transcription pipeline without a meeting, so audio
/// can be checked with a YouTube video and a few spoken words.
@MainActor
@Observable
final class AudioCheckModel {
    enum State: Equatable {
        case idle
        case starting
        case running
    }

    private(set) var state: State = .idle
    private(set) var transcript = TranscriptStore()
    private(set) var events: [String] = []
    private(set) var pipeline: CapturePipeline?

    func start(settings: AppSettings) async {
        guard state == .idle else { return }
        state = .starting
        transcript = TranscriptStore()
        events = []

        if SystemAudioPermission.status == .unknown {
            let granted = await SystemAudioPermission.request()
            events.append("System audio permission prompt answered: \(granted ? "allowed" : "not allowed")")
        }
        if !MicrophoneCapture.permissionGranted {
            _ = await MicrophoneCapture.requestPermission()
        }

        let pipeline = CapturePipeline()
        pipeline.onUpdate = { [weak self] update in self?.transcript.apply(update) }
        pipeline.onEvent = { [weak self] event in self?.events.append(Self.describe(event)) }
        self.pipeline = pipeline
        let source: SystemAudioTap.Source = settings.audioSourceBundleID.map { .app(bundleID: $0) } ?? .allSystemAudio
        await pipeline.start(.init(source: source, voiceProcessing: settings.voiceProcessing))
        state = .running
    }

    func stop() async {
        guard let pipeline, state != .idle else { return }
        await pipeline.stop()
        state = .idle
    }

    static func describe(_ event: CapturePipeline.Event) -> String {
        switch event {
        case .transcriberFailed(let speaker, let error): return "Transcriber \(speaker.label) failed: \(LiveTranscriber.describe(error))"
        case .systemAudioFailed(let error): return "System audio failed: \(String(describing: error))"
        case .systemAudioProblem(let problem): return MeetingSession.message(for: problem)
        case .systemAudioReconnected: return "System audio reconnected"
        case .appAudioNotFound: return "Chosen app not playing; using all system audio"
        case .micFailed(let error): return "Microphone failed: \(String(describing: error))"
        case .micReconnected: return "Microphone reconnected"
        case .voiceProcessingUnavailable: return "Voice processing unavailable; plain mic in use"
        }
    }
}

struct AudioCheckView: View {
    @Environment(AppModel.self) private var app
    private var model: AudioCheckModel { app.audioCheck }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio check")
                .font(.title2.weight(.semibold))

            if CodeSigning.isAdHoc {
                Label {
                    Text("This build is signed without a Team (\"Sign to Run Locally\"). macOS resets its System Audio Recording permission on every rebuild, so system audio can arrive as pure silence even though the toggle looks on. Pick your Team under Signing & Capabilities and run `scripts/save-signing-team.sh` so it sticks.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            LabeledContent("System audio permission", value: SystemAudioPermission.status.rawValue)
                .font(.callout)

            if let session = app.activeSession, session.isActive {
                Text("A meeting is running, so this shows its live audio.")
                    .foregroundStyle(.secondary)
                DiagnosticsPanel(pipeline: session.pipeline, transcript: session.transcript)
            } else {
                Text("Play a YouTube video (or any sound) and say a few words. Both meters should move and text should appear on both sides within a second or two.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    switch model.state {
                    case .idle:
                        Button("Start check") { Task { await model.start(settings: app.settings) } }
                            .buttonStyle(.borderedProminent)
                    case .starting:
                        ProgressView().controlSize(.small)
                        Text("Starting… the speech model may download the first time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .running:
                        Button("Stop") { Task { await model.stop() } }
                    }
                }
                if let pipeline = model.pipeline {
                    DiagnosticsPanel(pipeline: pipeline, transcript: model.transcript)
                }
                if !model.events.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                            Label(event, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onDisappear { Task { await model.stop() } }
    }
}

/// Live meters, recent text and counters for both streams, plus Copy report.
struct DiagnosticsPanel: View {
    let pipeline: CapturePipeline
    let transcript: TranscriptStore
    @State private var them = StreamDiagnostics.Snapshot()
    @State private var you = StreamDiagnostics.Snapshot()
    @State private var themLevel: Float = 0
    @State private var youLevel: Float = 0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                column(title: "Them · system audio", level: themLevel, snapshot: them, speaker: .them)
                column(title: "You · microphone", level: youLevel, snapshot: you, speaker: .you)
            }
            HStack {
                Button(copied ? "Copied" : "Copy report") {
                    Task {
                        let report = await pipeline.report()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }
                }
                Text("The report has formats, counters and errors, but no transcript text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                them = pipeline.themDiagnostics.read()
                you = pipeline.youDiagnostics.read()
                themLevel = pipeline.themMeter.peek()
                youLevel = pipeline.youMeter.peek()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func column(title: String, level: Float, snapshot: StreamDiagnostics.Snapshot, speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ProgressView(value: Double(level))
                .tint(level > 0.05 ? .green : .secondary)
            let lines = transcript.turns.filter { $0.speaker == speaker }.suffix(3)
            Group {
                if lines.isEmpty {
                    Text("No text yet").foregroundStyle(.tertiary)
                } else {
                    Text(lines.map(\.text).joined(separator: "\n"))
                        .lineLimit(6)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            Group {
                row("Capture", snapshot.captureState)
                row("Buffers in", "\(snapshot.captureBuffers)" + (snapshot.unreadableBuffers > 0 ? " (\(snapshot.unreadableBuffers) unreadable)" : ""))
                row("Format", snapshot.sourceFormat)
                row("Loudest", String(format: "%.4f", snapshot.peakRMS) + (snapshot.captureBuffers > 0 && snapshot.peakRMS <= AudioLevelMeter.silenceRMS ? " · only silence" : ""))
                row("Transcriber", snapshot.transcriberState)
                row("To speech", "\(snapshot.buffersToAnalyzer) chunks" + (snapshot.conversionFailures > 0 ? " · \(snapshot.conversionFailures) failed" : ""))
                row("Speech gets", snapshot.buffersToAnalyzer == 0 ? "–" : (snapshot.analyzerPeakRMS > AudioLevelMeter.silenceRMS ? String(format: "sound (%.4f)", snapshot.analyzerPeakRMS) : "only silence"))
                row("Results", "\(snapshot.volatileResults) live · \(snapshot.finalResults) final")
                if let error = snapshot.lastError ?? snapshot.lastConversionError {
                    row("Error", error)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
