import Foundation

/// What leaves the Mac, in one sentence. Welcome and Settings show it and the
/// README repeats it; the permission prompts (Info.plist and
/// InfoPlist.xcstrings) say its audio half. Change them together.
enum PrivacyNote {
    static let summary: LocalizedStringResource = "Audio never leaves this Mac and meetings are stored only on it; to write replies and recaps, VibeMeeting sends the transcript text, About me and what you add to the meeting (goal, instructions, Steer and context, including file text and images) to Anthropic with your own API key."
}
