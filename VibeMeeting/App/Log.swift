import Foundation
import os

/// Technical logs only. Never log transcript text, context, or scripts.
enum Log {
    /// The bundle ID, so release and development builds log separately.
    static let subsystem = AppIdentity.bundleID
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let reply = Logger(subsystem: subsystem, category: "reply")
    static let app = Logger(subsystem: subsystem, category: "app")
}
