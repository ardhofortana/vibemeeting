import Foundation

/// Triggers the permission prompts and the speech model download up front,
/// so the first meeting doesn't stall on them.
@MainActor
enum PermissionPrimer {
    struct Result {
        var microphone: Bool
        var systemAudio: Bool
        var speechModel: Bool
        var speechError: String?

        var summary: String {
            var parts: [String] = []
            parts.append(microphone ? "Microphone: allowed." : "Microphone: not allowed. Turn it on in System Settings → Privacy & Security → Microphone.")
            parts.append(systemAudio
                ? "System audio: requested. If macOS asked, choose Allow."
                : "System audio: couldn't start. Check System Settings → Privacy & Security → Screen & System Audio Recording.")
            parts.append(speechModel ? "English speech model: ready." : "English speech model: \(speechError ?? "not available").")
            return parts.joined(separator: "\n")
        }
    }

    static func run() async -> Result {
        let microphone = await MicrophoneCapture.requestPermission()

        // Starting a tap is what makes macOS ask for system audio access.
        var systemAudio = true
        let tap = SystemAudioTap()
        do {
            try tap.start(source: .allSystemAudio) { _ in }
            try? await Task.sleep(for: .seconds(1))
        } catch {
            systemAudio = false
        }
        tap.stop()

        var speechModel = true
        var speechError: String?
        do {
            try await LiveTranscriber.prepareAssets()
        } catch {
            speechModel = false
            speechError = error.localizedDescription
        }
        return Result(microphone: microphone, systemAudio: systemAudio, speechModel: speechModel, speechError: speechError)
    }
}
