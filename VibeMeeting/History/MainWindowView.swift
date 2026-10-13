import SwiftUI
import VibeCore

/// Saved meetings on the left, the selected meeting on the right, on dark glass.
struct MainWindowView: View {
    static let sidebarWidth: CGFloat = 300

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WindowTitleBar(title: "VibeMeeting") {
                    Button {
                        app.windows.showNewMeeting()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .keyboardShortcut("n")
                    .help("New meeting (⌘N)")
                    .accessibilityLabel("New meeting")
                }
                MeetingList()
            }
            .frame(width: Self.sidebarWidth)
            .ignoresSafeArea(.container, edges: .top)

            Glass.divider
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)

            // Below the transparent title bar, which stays empty so the window can be dragged by it.
            VStack(spacing: 0) {
                Glass.divider.frame(height: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = app.selectedRecordID, app.record(id: id) != nil {
            SessionDetailView(recordID: id)
                .id(id)
        } else {
            DetailPlaceholder()
        }
    }
}

// MARK: - Sidebar

/// Search, filters, and the meetings grouped by day, newest first.
private struct MeetingList: View {
    enum Filter: CaseIterable, Identifiable {
        case all
        case recent
        case recaps
        case starred
        var id: Self { self }

        var title: String {
            switch self {
            case .all: return "All"
            case .recent: return "Recent"
            case .recaps: return "Recaps"
            case .starred: return "Starred"
            }
        }

        func includes(_ record: MeetingRecord, since weekAgo: Date) -> Bool {
            switch self {
            case .all: return true
            case .recent: return record.startedAt >= weekAgo
            case .recaps: return record.recap != nil
            case .starred: return record.isStarred
            }
        }
    }

    private enum Focus: Hashable {
        case search
        case list
    }

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var renaming: MeetingRecord?
    @State private var draftName = ""
    @State private var deleting: MeetingRecord?
    @FocusState private var focus: Focus?

    var body: some View {
        let sections = self.sections
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 6)
            filterChips
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if !app.unreadableFiles.isEmpty {
                GlassNotice(
                    text: Self.unreadableMessage(app.unreadableFiles),
                    systemImage: "exclamationmark.triangle.fill",
                    action: "Show in Finder"
                ) { app.revealUnreadableFiles() }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if app.records.isEmpty {
                emptyState("No meetings yet", "Start one with the + button or from the menu bar.", systemImage: "waveform")
            } else if sections.isEmpty {
                noResults
            } else {
                list(sections)
            }
        }
        .defaultFocus($focus, .list)
        .alert("Rename meeting", isPresented: isPresented($renaming), presenting: renaming) { record in
            TextField("Meeting name", text: $draftName)
            Button("Rename") { app.rename(id: record.id, to: draftName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.displayName ?? "")” permanently?", isPresented: isPresented($deleting), presenting: deleting) { record in
            Button("Delete", role: .destructive) { app.delete(id: record.id) }
        } message: { _ in
            Text("The transcript, scripts, context and recap are removed from this Mac. This can't be undone.")
        }
    }

    /// Why some saved meetings aren't in the list. Their files are never changed.
    static func unreadableMessage(_ files: [SessionStore.UnreadableFile]) -> String {
        let newer = files.allSatisfy(\.isFromNewerVersion)
        if files.count == 1 {
            return newer
                ? "1 saved meeting can't be opened because a newer version of VibeMeeting saved it. Update VibeMeeting to open it. Its file is kept as it is."
                : "1 saved meeting can't be opened. A newer version of VibeMeeting saved it, or its file is damaged. The file is kept as it is."
        }
        return newer
            ? "\(files.count) saved meetings can't be opened because a newer version of VibeMeeting saved them. Update VibeMeeting to open them. Their files are kept as they are."
            : "\(files.count) saved meetings can't be opened. A newer version of VibeMeeting saved them, or their files are damaged. The files are kept as they are."
    }

    // MARK: Search and filters

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search meetings…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .search)
                .onSubmit(openFirstResult)
                .onExitCommand {
                    query = ""
                    focus = .list
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            Button {
                focus = .search
            } label: {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Search meetings (⌘K)")
            .accessibilityLabel("Search meetings")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassField(focused: focus == .search, radius: 10)
        // A click anywhere in the box, not just on the text line, starts typing.
        .contentShape(shape)
        .onTapGesture { focus = .search }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { item in
                Button(item.title) { filter = item }
                    .buttonStyle(FilterChipStyle(selected: filter == item))
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: List

    private struct DaySection: Identifiable {
        let day: Date
        var records: [MeetingRecord]
        var id: Date { day }
    }

    private var sections: [DaySection] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let records = app.records
            .filter { filter.includes($0, since: weekAgo) && $0.matches(query) }
            .sorted { $0.startedAt > $1.startedAt }
        var sections: [DaySection] = []
        for record in records {
            let day = calendar.startOfDay(for: record.startedAt)
            if sections.last?.day == day {
                sections[sections.count - 1].records.append(record)
            } else {
                sections.append(DaySection(day: day, records: [record]))
            }
        }
        return sections
    }

    private func list(_ sections: [DaySection]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.records) { record in
                                row(record)
                                    .id(record.id)
                            }
                        } header: {
                            DayHeader(day: section.day, isFirst: section.id == sections.first?.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            // Arrow keys move the selection while the list has focus (after a click in it).
            // Edit interactions keep it focusable with Keyboard navigation off.
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onMoveCommand { direction in
                moveSelection(direction, in: sections)
            }
            .onChange(of: app.selectedRecordID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func row(_ record: MeetingRecord) -> some View {
        let isLive = app.activeSession?.id == record.id
        return MeetingRow(
            record: record,
            isSelected: app.selectedRecordID == record.id,
            isLive: isLive,
            select: {
                app.selectedRecordID = record.id
                focus = .list
            },
            star: { app.toggleStar(id: record.id) },
            rename: {
                draftName = record.name
                renaming = record
            },
            delete: { deleting = record }
        )
    }

    /// Return in the search field: show the first match unless the selected meeting is one.
    private func openFirstResult() {
        let ids = sections.flatMap { $0.records.map(\.id) }
        if let first = ids.first, !ids.contains(where: { $0 == app.selectedRecordID }) {
            app.selectedRecordID = first
        }
        focus = .list
    }

    private func moveSelection(_ direction: MoveCommandDirection, in sections: [DaySection]) {
        let ids = sections.flatMap { $0.records.map(\.id) }
        guard !ids.isEmpty else { return }
        let current = app.selectedRecordID.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up:
            app.selectedRecordID = ids[max((current ?? 0) - 1, 0)]
        case .down:
            app.selectedRecordID = ids[current.map { min($0 + 1, ids.count - 1) } ?? 0]
        default:
            break
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private var noResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            emptyState(
                "No results",
                filter == .all ? "Nothing matches “\(trimmed)”." : "Nothing in \(filter.title) matches “\(trimmed)”.",
                systemImage: "magnifyingglass",
                action: ("Clear search", { query = "" })
            )
        } else {
            emptyState(
                Self.emptyTitle(filter),
                Self.emptyDetail(filter),
                systemImage: filter == .starred ? "star" : "tray",
                action: ("Show all", { filter = .all })
            )
        }
    }

    private static func emptyTitle(_ filter: Filter) -> String {
        switch filter {
        case .all: return "No meetings"
        case .recent: return "Nothing recent"
        case .recaps: return "No recaps yet"
        case .starred: return "No starred meetings"
        }
    }

    private static func emptyDetail(_ filter: Filter) -> String {
        switch filter {
        case .all: return ""
        case .recent: return "No meetings in the last 7 days."
        case .recaps: return "A recap is written when a meeting ends."
        case .starred: return "Star a meeting from its … menu to find it here."
        }
    }

    private func emptyState(
        _ title: String,
        _ detail: String,
        systemImage: String,
        action: (title: String, run: () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(GlassButtonStyle(minHeight: 30))
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

/// "TODAY", "YESTERDAY", then e.g. "MON, 12 OCT", over a thin line.
private struct DayHeader: View {
    let day: Date
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Glass.divider
                .frame(height: 1)
                .padding(.horizontal, 6)
            Text(Self.title(for: day).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        .padding(.top, isFirst ? 0 : 14)
        .accessibilityAddTraits(.isHeader)
    }

    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        return calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? day.formatted(style)
            : day.formatted(style.year())
    }
}

/// One meeting: name, when and how long, Recap; a "…" menu on the right.
/// Selected: a blue tint and border with an accent bar on the left.
private struct MeetingRow: View {
    let record: MeetingRecord
    let isSelected: Bool
    let isLive: Bool
    let select: () -> Void
    let star: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if record.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
                    if isLive {
                        LiveBadge()
                    }
                }
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.trailing, 40)
            .padding(.vertical, 8)
            .background { rowBackground(shape) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            menu.padding(.trailing, 8)
        }
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            Text(Self.whenAndHowLong(record))
                .lineLimit(1)
            if record.recap != nil {
                Image(systemName: "doc.text")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text("Recap")
                    .fixedSize()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func rowBackground(_ shape: RoundedRectangle) -> some View {
        if isSelected {
            shape.fill(Brand.accent.opacity(0.2))
                .overlay(alignment: .leading) {
                    Brand.accent.frame(width: 4)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Brand.accent.opacity(0.75)))
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.05 : 0))
        }
    }

    private var menu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Star, rename or delete")
        .accessibilityLabel("Actions for \(record.displayName)")
    }

    /// Off while the meeting is live; its record is still being saved. A meeting
    /// from a newer version can only be deleted.
    @ViewBuilder
    private var actions: some View {
        Button(record.isStarred ? "Unstar" : "Star", action: star)
            .disabled(isLive || record.isFromNewerVersion)
        Button("Rename…", action: rename)
            .disabled(isLive || record.isFromNewerVersion)
        Divider()
        Button("Delete…", role: .destructive, action: delete)
            .disabled(isLive)
    }

    /// e.g. "12 Oct 2026 at 22.31 · 6 min"
    static func whenAndHowLong(_ record: MeetingRecord) -> String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.duration { parts.append(Recap.formatDuration(duration)) }
        return parts.joined(separator: " · ")
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.red, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }
}

/// A filter above the list; the selected one is tinted blue.
private struct FilterChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(selected ? Brand.accent.opacity(0.7) : Color.clear))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if selected { return Brand.accent.opacity(0.22) }
            if configuration.isPressed { return Color.primary.opacity(0.1) }
            return hovering ? Color.primary.opacity(0.06) : .clear
        }
    }
}

// MARK: - Placeholder

/// Nothing selected: the logo, a hint, and ways to start a meeting.
private struct DetailPlaceholder: View {
    @Environment(AppModel.self) private var app
    @State private var starting = false
    @State private var menuHovering = false

    var body: some View {
        VStack(spacing: 0) {
            LogoMark(height: 110)
                .padding(.bottom, 26)
            Text(app.records.isEmpty ? "No meetings yet" : "Select a meeting")
                .font(.system(size: 28, weight: .bold))
                .padding(.bottom, 10)
            Text(app.records.isEmpty
                ? "Start a meeting and its transcript, responses, and recap appear here."
                : "Choose a meeting from the sidebar to view the transcript, responses, and recap.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 26)
            HStack(spacing: 12) {
                Button {
                    app.windows.showNewMeeting()
                } label: {
                    HStack(spacing: 10) {
                        LogoMark(height: 18)
                            // White on the gradient.
                            .brightness(1)
                        Text("New meeting")
                    }
                }
                .buttonStyle(PrimaryGradientButtonStyle(minHeight: 44))
                startMenu
            }
        }
        .padding(24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The square chevron next to New meeting: a plain menu button drawn like `GlassButtonStyle`.
    private var startMenu: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let busy = starting || app.activeSession != nil
        return Menu {
            Button("Start now") { start(app.settings.defaultPreset) }
                .disabled(busy)
            Menu("Start now with style") {
                ForEach(app.settings.allPresets) { preset in
                    Button(preset.name) { start(preset) }
                }
            }
            .disabled(busy)
            Divider()
            Button("Audio check…") { app.windows.showAudioCheck() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Color.primary.opacity(menuHovering ? 0.1 : 0.06), in: shape)
        .overlay(shape.strokeBorder(Glass.fieldStroke))
        .onHover { menuHovering = $0 }
        .help("Start now, or check your audio")
        .accessibilityLabel("More ways to start")
    }

    /// Starts right away with no setup.
    private func start(_ preset: StylePreset) {
        starting = true
        Task {
            await app.startMeeting(name: "", goal: "", context: [], preset: preset, instructions: "")
            starting = false
        }
    }
}
