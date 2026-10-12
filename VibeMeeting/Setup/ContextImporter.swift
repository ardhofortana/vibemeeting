import AppKit
import PDFKit
import UniformTypeIdentifiers
import VibeCore

/// Turns dropped files and pasted content into context items. Text is
/// extracted once, here, so replies never re-read the files.
enum ContextImporter {
    enum Failure: Error, LocalizedError {
        case unsupported(String)
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "\(name): this file type isn't supported. Use PDF, DOCX, TXT, MD, or an image."
            case .unreadable(let name): return "\(name) couldn't be read."
            case .empty(let name): return "\(name) has no text."
            }
        }
    }

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .rtf, .image]
        for ext in ["md", "markdown", "docx", "doc"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// Longest edge sent for images; larger images are scaled down by the API anyway.
    static let maxImageEdge = 1568

    static func importFile(at url: URL) throws -> ContextItem {
        let name = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        let ext = url.pathExtension.lowercased()

        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url), let item = imageItem(from: image, title: name) else {
                throw Failure.unreadable(name)
            }
            return item
        }

        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            text = document.string ?? ""
        } else if ext == "docx" {
            text = try attributedText(url, type: .officeOpenXML, name: name)
        } else if ext == "doc" {
            text = try attributedText(url, type: .docFormat, name: name)
        } else if type?.conforms(to: .rtf) == true {
            text = try attributedText(url, type: .rtf, name: name)
        } else if type?.conforms(to: .text) == true || ["md", "markdown", "txt"].contains(ext) {
            guard let value = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
                throw Failure.unreadable(name)
            }
            text = value
        } else {
            throw Failure.unsupported(name)
        }

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw Failure.empty(name) }
        return .text(cleaned, title: name)
    }

    private static func attributedText(_ url: URL, type: NSAttributedString.DocumentType, name: String) throws -> String {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } catch {
            throw Failure.unreadable(name)
        }
    }

    /// Scales an image down and encodes it as JPEG on a white background.
    static func imageItem(from image: NSImage, title: String) -> ContextItem? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, Double(maxImageEdge) / Double(max(width, height)))
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(cgImage, in: rect)
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return ContextItem(title: title, content: .image(data: data, mediaType: "image/jpeg", pixelWidth: targetWidth, pixelHeight: targetHeight))
    }

    /// An image on the clipboard (e.g. a screenshot copied with ⌃⇧⌘4).
    static func imageFromPasteboard() -> ContextItem? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        return imageItem(from: image, title: "Pasted screenshot")
    }
}
