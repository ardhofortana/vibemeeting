import Foundation

/// Builds the post-meeting recap request. Long meetings are first summarized
/// part by part, then the notes are combined into one recap.
public struct RecapPromptBuilder: Sendable {
    public var model: ClaudeModel
    public var maxTokens: Int
    /// Transcripts longer than this are summarized in parts first (~120K tokens).
    public var singlePassCharacterLimit: Int
    /// Size of each part for long transcripts.
    public var chunkCharacterLimit: Int

    public init(model: ClaudeModel, maxTokens: Int = 16_000, singlePassCharacterLimit: Int = 400_000, chunkCharacterLimit: Int = 200_000) {
        self.model = model
        self.maxTokens = maxTokens
        self.singlePassCharacterLimit = singlePassCharacterLimit
        self.chunkCharacterLimit = chunkCharacterLimit
    }

    /// Transcript parts. One part means a single pass is enough.
    public func transcriptParts(for record: MeetingRecord) -> [String] {
        let transcript = record.transcriptText()
        guard transcript.count > singlePassCharacterLimit else { return [transcript] }
        return Self.chunk(lines: transcript.components(separatedBy: "\n"), limit: chunkCharacterLimit)
    }

    /// Notes request for one part of a long meeting.
    public func partRequest(record: MeetingRecord, aboutMe: String, part: String, index: Int, total: Int) -> MessagesRequest {
        request(
            aboutMe: aboutMe,
            content: [.text("Part \(index + 1) of \(total) of the meeting transcript:\n<transcript>\n\(part)\n</transcript>\n\n\(Prompts.recapChunkInstruction)")],
            jsonSchema: nil
        )
    }

    /// The final recap request, over the full transcript or over part notes.
    public func recapRequest(record: MeetingRecord, aboutMe: String, partNotes: [String]? = nil) -> MessagesRequest {
        var content = ReplyPromptBuilder.contextBlocks(record.context)
        var text = ""
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { text += "Meeting name: \(name)\n\n" }
        let goal = record.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        text += goal.isEmpty ? "No meeting goal was given.\n\n" : "<meeting_goal>\n\(goal)\n</meeting_goal>\n\n"
        if let partNotes, partNotes.count > 1 {
            let notes = partNotes.enumerated().map { "<part number=\"\($0.offset + 1)\">\n\($0.element)\n</part>" }
            text += "The meeting was long, so it was summarized in parts first.\n<meeting_notes>\n\(notes.joined(separator: "\n"))\n</meeting_notes>"
        } else {
            let transcript = record.transcriptText()
            text += "<transcript>\n\(transcript.isEmpty ? "(The transcript is empty.)" : transcript)\n</transcript>"
        }
        text += "\n\nWrite the recap of this meeting."
        content.append(.text(text))
        return request(aboutMe: aboutMe, content: content, jsonSchema: Recap.jsonSchema)
    }

    private func request(aboutMe: String, content: [ContentBlock], jsonSchema: JSONValue?) -> MessagesRequest {
        let profile = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = MessagesRequest(
            model: model.id,
            maxTokens: maxTokens,
            system: [
                .text(Prompts.recapRules),
                .text("<about_me>\n\(profile.isEmpty ? Prompts.emptyAboutMe : profile)\n</about_me>"),
            ],
            messages: [.user(content)],
            stream: true,
            outputConfig: (model.recapEffort != nil || jsonSchema != nil)
                ? OutputConfig(effort: model.recapEffort, jsonSchema: jsonSchema)
                : nil
        )
        if model.supportsDefaultFallback {
            request.fallbacks = "default"
            request.betas = [ClaudeModel.serverFallbackBeta]
        }
        return request
    }

    /// Splits lines into parts no longer than `limit` characters (a single
    /// longer line becomes its own part).
    public static func chunk(lines: [String], limit: Int) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count + 1 > limit, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    /// Decodes the model's JSON output.
    public static func parse(_ text: String) throws -> Recap {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end {
            json = String(json[start...end])
        }
        guard let data = json.data(using: .utf8) else { throw ClaudeError.invalidResponse("recap is not UTF-8") }
        do {
            return try JSONDecoder().decode(Recap.self, from: data)
        } catch {
            throw ClaudeError.invalidResponse("recap JSON did not match the schema")
        }
    }
}
