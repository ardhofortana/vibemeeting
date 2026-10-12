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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone

            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Paste chats, proposals or notes here")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button("Paste screenshot") {
                        if let item = ContextImporter.imageFromPasteboard() {
                            add([item])
                        } else {
                            errors = ["There's no image on the clipboard."]
                        }
                    }
                    Spacer()
                    Button("Add notes") {
                        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        add([.text(text)])
                        notes = ""
                    }
                    .disabled(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            }

            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !items.isEmpty {
                itemList
            }
            budget
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: ContextImporter.allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Drop files or paste notes: chats, proposals, briefs")
                .font(.callout)
            Text("PDF, DOCX, TXT, MD, or images")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose files…") { showingImporter = true }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(isTargeted ? Brand.accent.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isTargeted ? Brand.accent : Color.secondary.opacity(0.4))
        )
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isImage ? "photo" : "doc.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(detail(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        items.removeAll { $0.id == item.id }
                        onRemove?(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var budget: some View {
        let tokens = items.reduce(0) { $0 + $1.estimatedTokens } + TokenEstimator.tokens(forText: notes)
        let status = ContextBudget.status(forTokens: tokens)
        return HStack(spacing: 6) {
            Text("≈ \(tokens.formatted()) tokens of context")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = status.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(status == .tooLarge ? Color.red : Color.orange)
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
