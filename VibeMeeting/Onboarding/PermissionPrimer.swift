import Foundation
import VibeCore

/// Triggers the permission prompts and the speech model download up front,
/// so the first meeting doesn't stall on them.
@MainActor
enum PermissionPrimer {
    struct Result {
        var microphone: Bool
        var systemAudio: Bool
        var systemAudioStatus: SystemAudioPermission.Status
        var speechModel: Bool
        var speechError: String?
        /// The call language whose model was downloaded (BCP 47).
        var speechLocale: String

        var summary: String {
            var parts: [String] = []
            parts.append(microphone ? "Microphone: allowed." : "Microphone: not allowed. Turn it on in System Settings → Privacy & Security → Microphone.")
            switch systemAudioStatus {
            case .authorized:
                parts.append("System audio: allowed.")
            case .denied:
                parts.append("System audio: not allowed. Turn on VibeMeeting under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
            case .unknown:
                parts.append(systemAudio
                    ? "System audio: requested. If macOS asked, choose Allow."
                    : "System audio: couldn't start. Check System Settings → Privacy & Security → Screen & System Audio Recording.")
            }
            let language = MeetingLanguage.displayName(of: speechLocale)
            parts.append(speechModel ? "Speech model for \(language): ready." : "Speech model for \(language): \(speechError ?? "not available").")
            return parts.joined(separator: "\n")
        }
    }

    /// `locale` is the default call language; its speech model is downloaded.
    static func run(locale: String, onModelProgress: LiveTranscriber.ProgressHandler? = nil) async -> Result {
        let microphone = await MicrophoneCapture.requestPermission()

        _ = await SystemAudioPermission.request()
        // Starting a tap also makes macOS ask, if the request above couldn't.
        var systemAudio = true
        let tap = SystemAudioTap()
        do {
            // Suspends instead of blocking while the prompt is unanswered.
            try await tap.start(source: .allSystemAudio) { _, _ in }
            try? await Task.sleep(for: .seconds(1))
        } catch {
            systemAudio = false
        }
        await tap.stop()

        var speechModel = true
        var speechError: String?
        do {
            try await LiveTranscriber.prepareAssets(for: Locale(identifier: locale), onProgress: onModelProgress)
        } catch {
            speechModel = false
            speechError = error.localizedDescription
        }
        return Result(
            microphone: microphone,
            systemAudio: systemAudio,
            systemAudioStatus: SystemAudioPermission.status,
            speechModel: speechModel,
            speechError: speechError,
            speechLocale: locale
        )
    }
}
