import Foundation

/// Saves each meeting as one JSON file in a local folder (Application Support
/// in the app). Deleting a meeting removes its file for good.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `~/Library/Application Support/VibeMeeting/Sessions` on macOS.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("VibeMeeting", isDirectory: true).appendingPathComponent("Sessions", isDirectory: true)
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ record: MeetingRecord) throws {
        let data = try Self.encoder.encode(record)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: url(for: record.id), options: [.atomic])
    }

    public func load(id: UUID) throws -> MeetingRecord {
        let data = try Data(contentsOf: url(for: id))
        return try Self.decoder.decode(MeetingRecord.self, from: data)
    }

    /// All readable meetings, newest first. Unreadable files are skipped.
    public func loadAll() -> [MeetingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(MeetingRecord.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static let encoder: JSONEncoder = {
        // Default date strategy: exact round trips (ISO 8601 drops sub-seconds).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}
