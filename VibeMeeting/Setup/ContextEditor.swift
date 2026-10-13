import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// Drop zone, pasted notes, and the list of context items with a size estimate.
struct ContextEditor: View {
    @Binding var items: [ContextItem]
    /// Notes typed but not added yet; the parent adds them when the meeting starts.
    @Binding var notes: String
    /// Called with newly added items (used to add context mid-meeting).
    var onAdd: (([ContextItem]) -> Void)?
    var onRemove: ((UUID) -> Void)?

    @State private var isTargeted = false
    @State private var showingImporter = false
    @State private var errors: [String] = []
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            pasteCard

            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !items.isEmpty {
                itemList
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: ContextImporter.allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous)
        return VStack(spacing: 6) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("Drop files or paste notes, chats, proposals, briefs")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
            Text("PDF, DOCX, TXT, MD, or images (max \(ContextImporter.maxFileSizeText) each)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose files…") { showingImporter = true }
                .buttonStyle(SoftGradientButtonStyle(minHeight: 30))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(isTargeted ? Brand.accent.opacity(0.12) : Glass.cardFill, in: shape)
        .overlay(
            shape
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(isTargeted ? Brand.accent : Color.primary.opacity(0.22))
        )
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Paste text (the editor below), Paste screenshot and Add from clipboard,
    /// with the size estimate and Add notes underneath.
    private var pasteCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    notesFocused = true
                } label: {
                    Label("Paste text", systemImage: "doc.text")
                }
                .buttonStyle(ContextTabStyle(selected: true))
                .help("Type or paste notes below")

                Button(action: pasteScreenshot) {
                    Label("Paste screenshot", systemImage: "photo")
                }
                .buttonStyle(ContextTabStyle())
                .help("Add the image on the clipboard, e.g. a screenshot copied with ⌃⇧⌘4")

                Rectangle()
                    .fill(Glass.divider)
                    .frame(width: 1, height: 18)

                Button(action: addFromClipboard) {
                    Label("Add from clipboard", systemImage: "clipboard")
                }
                .buttonStyle(ContextTabStyle())
                .help("Add the files, image or text on the clipboard")

                Spacer(minLength: 0)
            }
            .padding(6)

            Rectangle().fill(Glass.divider).frame(height: 1)

            TextEditor(text: $notes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($notesFocused)
                .padding(10)
                .frame(minHeight: 80, idealHeight: 100, maxHeight: 160)
                .background(Color.black.opacity(0.18))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Paste chats, proposals or notes here…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            Rectangle().fill(Glass.divider).frame(height: 1)

            HStack(spacing: 10) {
                budget
                Spacer(minLength: 8)
                Button {
                    let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    add([.text(text)])
                    notes = ""
                } label: {
                    Label("Add notes", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(GlassButtonStyle(minHeight: 28))
                .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .labelStyle(.titleAndIcon)
        .clipShape(RoundedRectangle(cornerRadius: Glass.cardRadius, style: .continuous))
        .glassCard()
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.isImage ? "photo" : "doc.text")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Glass.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(detail(for: item))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        items.removeAll { $0.id == item.id }
                        onRemove?(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                    .accessibilityLabel("Remove \(item.title)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if item.id != items.last?.id {
                    Rectangle().fill(Glass.divider).frame(height: 1)
                }
            }
        }
        .glassCard()
    }

    private var budget: some View {
        let tokens = items.reduce(0) { $0 + $1.estimatedTokens } + TokenEstimator.tokens(forText: notes)
        let status = ContextBudget.status(forTokens: tokens)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("≈ \(tokens.formatted()) tokens of context")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let warning = status.warning {
                    Text(warning)
                        .font(.system(size: 11.5))
                        .foregroundStyle(status == .tooLarge ? Color.red : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func detail(for item: ContextItem) -> String {
        switch item.content {
        case .text(let text):
            let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(80)
            return "≈ \(item.estimatedTokens.formatted()) tokens · \(preview)"
        case .image(_, _, let width, let height):
            return "\(width)×\(height) · ≈ \(item.estimatedTokens.formatted()) tokens"
        }
    }

    private func pasteScreenshot() {
        if let item = ContextImporter.imageFromPasteboard() {
            errors = []
            add([item])
        } else {
            errors = ["There's no image on the clipboard."]
        }
    }

    private func addFromClipboard() {
        switch ContextImporter.clipboardContent() {
        case .files(let urls):
            importFiles(urls)
        case .item(let item):
            errors = []
            add([item])
        case nil:
            errors = ["There's nothing to add on the clipboard. Copy files, an image or text first."]
        }
    }

    private func importFiles(_ urls: [URL]) {
        var added: [ContextItem] = []
        var failures: [String] = []
        for url in urls {
            do {
                added.append(try ContextImporter.importFile(at: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        errors = failures
        add(added)
    }

    private func add(_ newItems: [ContextItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        onAdd?(newItems)
    }
}

/// A tab along the top of the paste card; the selected one is outlined in the accent.
private struct ContextTabStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, selected: selected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected || hovering ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(selected ? Glass.focusStroke : Color.clear, lineWidth: 1.2))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            if selected { return Brand.accent.opacity(0.1) }
            return hovering ? Glass.fieldHoverFill : Color.clear
        }
    }
}
