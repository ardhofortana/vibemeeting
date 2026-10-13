import AppKit
import PDFKit
import UniformTypeIdentifiers
import VibeCore

/// Turns dropped files and pasted content into context items. Text is
/// extracted once, here, so replies never re-read the files.
enum ContextImporter {
    enum Failure: Error, LocalizedError {
        case unsupported(String)
        case tooLarge(String)
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "\(name): this file type isn't supported. Use PDF, DOCX, TXT, MD, or an image."
            case .tooLarge(let name): return "\(name) is larger than \(ContextImporter.maxFileSizeText). Use a smaller file, or paste just the part you need."
            case .unreadable(let name): return "\(name) couldn't be read."
            case .empty(let name): return "\(name) has no text."
            }
        }
    }

    /// What "Add from clipboard" found.
    enum ClipboardContent {
        /// Files copied in Finder; imported like dropped files.
        case files([URL])
        case item(ContextItem)
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

    /// Largest file accepted, in bytes as Finder counts them.
    static let maxFileSize = 50_000_000

    /// "50 MB".
    static var maxFileSizeText: String {
        Int64(maxFileSize).formatted(.byteCount(style: .file))
    }

    static func importFile(at url: URL) throws -> ContextItem {
        let name = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
            throw Failure.tooLarge(name)
        }

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
    static func imageFromPasteboard(_ pasteboard: NSPasteboard = .general, title: String = "Pasted screenshot") -> ContextItem? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return imageItem(from: image, title: title)
    }

    /// Whatever useful is on the clipboard: copied files first, then text, then an image.
    static func clipboardContent(_ pasteboard: NSPasteboard = .general) -> ClipboardContent? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Text wins over an image, since Word or Excel also copy a picture of the
        // text, except a bare link: Copy Image in a browser adds the image's address.
        if text.isEmpty || isWebAddress(text), let image = imageFromPasteboard(pasteboard, title: "Pasted image") {
            return .item(image)
        }
        return text.isEmpty ? nil : .item(.text(text, title: "Pasted from clipboard"))
    }

    private static func isWebAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let scheme = URL(string: text)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
