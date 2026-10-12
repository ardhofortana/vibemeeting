import Foundation

/// A piece of meeting context: a dropped file, a screenshot, or pasted notes.
public struct ContextItem: Identifiable, Codable, Equatable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case text(String)
        /// Image bytes plus a media type the API accepts (image/png, image/jpeg, image/gif, image/webp).
        case image(data: Data, mediaType: String, pixelWidth: Int, pixelHeight: Int)
    }

    public let id: UUID
    /// File name, or "Pasted notes".
    public var title: String
    public var content: Content
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, content: Content, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.addedAt = addedAt
    }

    public static func text(_ text: String, title: String = "Pasted notes") -> ContextItem {
        ContextItem(title: title, content: .text(text))
    }

    public var isImage: Bool {
        if case .image = content { return true }
        return false
    }

    public var textValue: String? {
        if case .text(let text) = content { return text }
        return nil
    }

    /// Rough token cost of this item.
    public var estimatedTokens: Int {
        switch content {
        case .text(let text):
            return TokenEstimator.tokens(forText: text) + TokenEstimator.tokens(forText: title) + 8
        case .image(_, _, let width, let height):
            return TokenEstimator.tokens(forImageWidth: width, height: height)
        }
    }
}
