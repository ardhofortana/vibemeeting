import AVFoundation
import Foundation

/// Captures the user's own voice. Apple voice processing cancels echo, so the
/// other side's voice coming out of the speakers isn't transcribed as "You".
final class MicrophoneCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private var engine = AVAudioEngine()
    private var handler: BufferHandler?
    private var wantsVoiceProcessing = true
    private var configurationObserver: NSObjectProtocol?

    /// Whether echo cancellation is actually running (it can fail on some
    /// device combinations, e.g. a Bluetooth mic with the built-in speakers).
    private(set) var voiceProcessingActive = false

    /// Called on the main queue after the input device changed and capture restarted.
    var onReconnect: ((Result<Void, Error>) -> Void)?

    private let diagnostics: StreamDiagnostics?

    init(diagnostics: StreamDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func start(voiceProcessing: Bool, handler: @escaping BufferHandler) throws {
        self.handler = handler
        wantsVoiceProcessing = voiceProcessing
        try startEngine(voiceProcessing: voiceProcessing)
        observeConfigurationChanges()
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        stopEngine()
        handler = nil
    }

    private func startEngine(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        voiceProcessingActive = false

        if voiceProcessing {
            do {
                // Must be set while the engine is stopped; it enables the output side too.
                _ = engine.outputNode
                try input.setVoiceProcessingEnabled(true)
                // Keep the meeting app as loud as possible while we listen.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                voiceProcessingActive = true
            } catch {
                Log.audio.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        // With voice processing on, the input can report several channels; the converter downmixes.
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handler?(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            Log.audio.info("Mic started (voice processing: \(self.voiceProcessingActive, privacy: .public))")
        } catch let error where voiceProcessingActive {
            // Some input/output device pairs reject voice processing. Fall back to a plain mic.
            Log.audio.error("Mic with voice processing failed, retrying without: \(error.localizedDescription, privacy: .public)")
            stopEngine()
            try startEngine(voiceProcessing: false)
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? AVAudioEngine) === self.engine, self.handler != nil else { return }
            Log.audio.info("Audio configuration changed; restarting mic")
            self.stopEngine()
            do {
                try self.startEngine(voiceProcessing: self.wantsVoiceProcessing)
                self.onReconnect?(.success(()))
            } catch {
                self.onReconnect?(.failure(error))
            }
        }
    }
}
