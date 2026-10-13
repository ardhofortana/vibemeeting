import Foundation

/// Saves each meeting as one JSON file in a local folder (Application Support
/// in the app). Deleting a meeting removes its file for good.
public final class SessionStore: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// The record came from a newer VibeMeeting; saving it here would drop what this build doesn't know.
        case savedByNewerVersion(schemaVersion: Int)

        public var errorDescription: String? {
            switch self {
            case .savedByNewerVersion(let version):
                return "This meeting was saved by a newer version of VibeMeeting (format \(version)), so this version doesn't change it."
            }
        }
    }

    /// A meeting file that couldn't be read. It stays on disk untouched.
    public struct UnreadableFile: Equatable, Sendable, Identifiable {
        public var url: URL
        /// The format version in the file, when it could be read.
        public var schemaVersion: Int?
        /// Short technical reason, safe to log (no meeting content).
        public var reason: String

        public var id: URL { url }

        /// Written by a newer VibeMeeting; updating the app opens it again.
        public var isFromNewerVersion: Bool { (schemaVersion ?? 0) > MeetingRecord.currentSchemaVersion }
    }

    /// Everything in the folder: the meetings that loaded and the files that didn't.
    public struct LoadResult: Equatable, Sendable {
        /// Newest first. Records from a newer version are included when they decode.
        public var records: [MeetingRecord]
        public var unreadable: [UnreadableFile]
    }

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

    /// Writes the record in the current format. Refuses a record from a newer
    /// version, so its file keeps what this build can't represent.
    public func save(_ record: MeetingRecord) throws {
        guard !record.isFromNewerVersion else {
            throw Failure.savedByNewerVersion(schemaVersion: record.schemaVersion)
        }
        var record = record
        record.schemaVersion = MeetingRecord.currentSchemaVersion
        let data = try Self.encoder.encode(record)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: url(for: record.id), options: [.atomic])
    }

    public func load(id: UUID) throws -> MeetingRecord {
        let data = try Data(contentsOf: url(for: id))
        return try Self.decoder.decode(MeetingRecord.self, from: data)
    }

    /// All meetings, newest first, plus every file that couldn't be read, so
    /// nothing disappears from History without a word.
    public func loadAll() -> LoadResult {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var records: [MeetingRecord] = []
        var unreadable: [UnreadableFile] = []
        for url in files where url.pathExtension == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                unreadable.append(UnreadableFile(url: url, schemaVersion: nil, reason: "Can't read the file: \(error.localizedDescription)"))
                continue
            }
            do {
                records.append(try Self.decoder.decode(MeetingRecord.self, from: data))
            } catch {
                let version = (try? Self.decoder.decode(VersionProbe.self, from: data))?.schemaVersion
                unreadable.append(UnreadableFile(url: url, schemaVersion: version, reason: Self.describe(error)))
            }
        }
        return LoadResult(
            records: records.sorted { $0.startedAt > $1.startedAt },
            unreadable: unreadable.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        )
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Reads only the format version of a file that doesn't decode as a whole.
    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }

    /// Where decoding failed, by field names only (never values).
    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "" : " at \(path)"
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?:
            return "Missing \(key.stringValue)\(path(context))"
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?:
            return "Unexpected value\(path(context))"
        case .dataCorrupted(let context)?:
            return context.codingPath.isEmpty ? "Not valid JSON" : "Unexpected value\(path(context))"
        default:
            return error.localizedDescription
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
