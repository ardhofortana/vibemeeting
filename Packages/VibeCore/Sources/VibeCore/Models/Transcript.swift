import Foundation

/// Who said a line. Separation comes from the audio source, not diarization:
/// system audio is always `them`, the microphone is always `you`.
public enum Speaker: String, Codable, Sendable, CaseIterable {
    case them
    case you

    public var label: String {
        switch self {
        case .them: return "Them"
        case .you: return "You"
        }
    }
}

/// One speaking turn in the live transcript.
public struct TranscriptTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var speaker: Speaker
    /// Text the recognizer has locked in.
    public var finalText: String
    /// In-progress text that may still change.
    public var volatileText: String
    /// Manual correction typed by the user. Wins over recognized text.
    public var editedText: String?
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        speaker: Speaker,
        finalText: String = "",
        volatileText: String = "",
        editedText: String? = nil,
        startedAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.finalText = finalText
        self.volatileText = volatileText
        self.editedText = editedText
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    /// Best current text for display and prompting.
    public var text: String {
        if let editedText { return editedText }
        return Self.join(finalText, volatileText)
    }

    /// True while the recognizer may still revise the tail of this turn.
    public var isLive: Bool { editedText == nil && !volatileText.isEmpty }

    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// A recognizer event for one audio stream.
public struct TranscriptUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Replaces the stream's current in-progress text.
        case volatile
        /// Locks text in and clears the in-progress text.
        case final
    }

    public var speaker: Speaker
    public var kind: Kind
    public var text: String

    public init(speaker: Speaker, kind: Kind, text: String) {
        self.speaker = speaker
        self.kind = kind
        self.text = text
    }
}
