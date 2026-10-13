import Foundation

/// Where one stream's audio capture is (system audio or the mic). Logic checks
/// the case; `label` is only for Audio check and the diagnostics report.
public enum CaptureState: Equatable, Sendable {
    case notStarted
    case starting
    /// Capturing. The detail says how: the mic mode, or IO cycles for the system tap.
    case running(detail: String?)
    case failedToStart
    /// A restart or rebuild failed.
    case failed
    /// The mic delivered no audio after a restart.
    case noAudio
    /// Stopped restarting because the device kept changing.
    case deviceKeepsChanging

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Failed to start, or failed on a restart or rebuild.
    public var hasFailed: Bool { self == .failedToStart || self == .failed }

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .starting: return "Starting"
        case .running(let detail): return detail.map { "Running (\($0))" } ?? "Running"
        case .failedToStart: return "Failed to start"
        case .failed: return "Failed"
        case .noAudio: return "No audio from the microphone"
        case .deviceKeepsChanging: return "Stopped: device keeps changing"
        }
    }
}

/// Where one stream's speech recognizer is. Logic checks the case; `label` is
/// only for Audio check and the diagnostics report.
public enum TranscriberState: Equatable, Sendable {
    case notStarted
    case checkingModel
    case preparingModel
    case startingAnalyzer
    /// Recognizing speech in this locale (BCP 47, e.g. "en-US").
    case running(locale: String)
    case failedToStart
    /// The analyzer threw an error while running.
    case stoppedWithError
    /// The results ended without a stop from the app.
    case endedUnexpectedly
    case stopped

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .checkingModel: return "Checking speech model"
        case .preparingModel: return "Preparing speech model"
        case .startingAnalyzer: return "Starting analyzer"
        case .running(let locale): return "Running (\(locale))"
        case .failedToStart: return "Failed to start"
        case .stoppedWithError: return "Stopped with an error"
        case .endedUnexpectedly: return "Ended unexpectedly"
        case .stopped: return "Stopped"
        }
    }
}
