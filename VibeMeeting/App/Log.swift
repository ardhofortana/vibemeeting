import os

/// Technical logs only. Never log transcript text, context, or scripts.
enum Log {
    static let subsystem = "com.ardhofortana.VibeMeeting"
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let reply = Logger(subsystem: subsystem, category: "reply")
    static let app = Logger(subsystem: subsystem, category: "app")
}
