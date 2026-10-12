import SwiftUI
import VibeCore

/// Saved meetings on the left, the selected meeting on the right.
struct MainWindowView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selectedRecordID) {
                ForEach(filteredRecords) { record in
                    RecordRow(record: record, isLive: app.activeSession?.id == record.id && app.activeSession?.isActive == true)
                        .tag(record.id)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
            .overlay {
                if app.records.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Start one from the menu bar or with the + button."))
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button {
                        app.windows.showNewMeeting()
                    } label: {
                        Label("New meeting", systemImage: "plus")
                    }
                    .help("New meeting")
                }
            }
        } detail: {
            if let id = app.selectedRecordID, app.record(id: id) != nil {
                SessionDetailView(recordID: id)
                    .id(id)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var filteredRecords: [MeetingRecord] {
        app.records.filter { $0.matches(query) }
    }
}

private struct RecordRow: View {
    let record: MeetingRecord
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(record.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if isLive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.red, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.duration { parts.append(Recap.formatDuration(duration)) }
        if record.recap != nil { parts.append("Recap") }
        return parts.joined(separator: " · ")
    }
}
