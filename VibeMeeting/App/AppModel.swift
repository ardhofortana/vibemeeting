import AppKit
import Foundation
import Observation
import VibeCore

/// App-wide state: settings, saved meetings, and the live session.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let store: SessionStore
    let transport = URLSessionTransport()
    let overlay = OverlayController()
    @ObservationIgnored private(set) lazy var windows = WindowManager(app: self)
    /// The Audio check window's pipeline, stopped whenever a meeting starts.
    let audioCheck = AudioCheckModel()

    private(set) var records: [MeetingRecord] = []
    private(set) var activeSession: MeetingSession?
    private(set) var recapsInProgress: Set<UUID> = []
    /// Diagnostics from the last meeting (formats, counters, errors; no transcript text),
    /// so the report can still be copied after the call ends.
    private(set) var lastMeetingReport: String?
    var selectedRecordID: UUID?
    /// Stopping and saving the meeting being ended. Quit and New meeting wait for it.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    /// Set once Quit is accepted; no meeting starts after that.
    @ObservationIgnored var isTerminating = false

    init() {
        if let store = try? SessionStore(directory: SessionStore.defaultDirectory()) {
            self.store = store
        } else {
            Log.app.error("Application Support unavailable; saving sessions to a temporary folder")
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("VibeMeeting/Sessions")
            // A temporary directory is always creatable.
            self.store = try! SessionStore(directory: fallback)
        }
        records = store.loadAll()
        Hotkeys.install(app: self)
    }

    /// First-launch onboarding.
    func launch() {
        if !settings.hasCompletedOnboarding {
            windows.showWelcome()
        }
    }

    func record(id: UUID) -> MeetingRecord? {
        if let activeSession, activeSession.id == id { return activeSession.record }
        return records.first { $0.id == id }
    }

    // MARK: - Meetings

    func startMeeting(name: String, context: [ContextItem], preset: StylePreset, instructions: String) async {
        if let previous = activeSession {
            let previousID = previous.id
            let wasActive = previous.isActive
            // Joins an End that is still saving. The recap runs alongside the new
            // meeting instead of delaying its capture.
            await endMeeting(thenRecap: false)
            if wasActive { Task { await generateRecap(for: previousID) } }
        }
        if !MicrophoneCapture.permissionGranted {
            _ = await MicrophoneCapture.requestPermission()
        }
        // Only one capture pipeline at a time. After the permission prompt, so an
        // Audio check can't start while it's up.
        await audioCheck.stop()
        // Quit was chosen while this waited: don't start a meeting nobody ends.
        guard !isTerminating else { return }

        let record = MeetingRecord(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            presetID: preset.id,
            presetName: preset.name,
            meetingInstructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context,
            replyModel: settings.replyModelID
        )
        let session = MeetingSession(record: record, preset: preset, settings: settings, store: store, transport: transport)
        session.onSave = { [weak self] record in self?.upsert(record) }
        activeSession = session
        selectedRecordID = record.id
        overlay.show(session: session, app: self)
        Hotkeys.setEnabled(true)
        await session.start()
    }

    /// Stops listening, saves, then shows the meeting and writes its recap.
    /// When quitting, the recap is skipped; it can be created later from the main window.
    func endMeeting(thenRecap: Bool = true) async {
        if let teardown {
            // Already ending (End, then Quit or New meeting): wait for its save.
            await teardown.value
            return
        }
        guard let session = activeSession else { return }
        Hotkeys.setEnabled(false)
        overlay.close()
        let task = Task { @MainActor [self] in
            await session.end()
            if let report = session.diagnosticsReport {
                lastMeetingReport = report
                Self.saveDiagnostics(report)
            }
            upsert(session.record)
            // Never clear a newer meeting.
            if activeSession === session { activeSession = nil }
            selectedRecordID = session.id
        }
        teardown = task
        await task.value
        if teardown == task { teardown = nil }
        guard thenRecap else { return }
        windows.showMain()
        await generateRecap(for: session.id)
    }

    /// ~/Library/Application Support/VibeMeeting/Diagnostics/last-meeting.txt
    static var diagnosticsFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VibeMeeting/Diagnostics/last-meeting.txt")
    }

    private static func saveDiagnostics(_ report: String) {
        guard let file = diagnosticsFile else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("Saving diagnostics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func toggleOverlay() {
        guard let activeSession, activeSession.isActive else { return }
        overlay.toggle(session: activeSession, app: self)
    }

    // MARK: - Recap

    func generateRecap(for id: UUID) async {
        // Never from the live copy: while a meeting is still saving, the final
        // record would be overwritten with an older one when the recap returns.
        guard activeSession?.id != id, var record = record(id: id), !recapsInProgress.contains(id) else { return }
        guard settings.hasAPIKey else {
            record.recapError = "Add your Claude API key in Settings to create a recap."
            save(record)
            return
        }
        guard record.turns.contains(where: { !$0.text.isEmpty }) else {
            record.recapError = "Nothing was transcribed, so there's nothing to recap."
            save(record)
            return
        }
        recapsInProgress.insert(id)
        defer { recapsInProgress.remove(id) }

        let model = settings.recapModel
        let generator = RecapGenerator(
            client: ClaudeClient(apiKey: settings.apiKey, transport: transport),
            builder: RecapPromptBuilder(model: model)
        )
        do {
            let result = try await generator.generate(record: record, aboutMe: settings.aboutMe)
            record.recap = result.recap
            record.recapError = nil
            record.recapModel = model.id
            record.stats.recapUsage += result.usage
            record.stats.estimatedCost += model.pricing?.cost(of: result.usage) ?? 0
        } catch {
            Log.app.error("Recap failed: \(error.localizedDescription, privacy: .public)")
            record.recapError = "Couldn't create the recap. \(error.localizedDescription)"
        }
        save(record)
    }

    // MARK: - Storage

    func delete(id: UUID) {
        guard activeSession?.id != id else { return }
        do {
            try store.delete(id: id)
            records.removeAll { $0.id == id }
            if selectedRecordID == id { selectedRecordID = records.first?.id }
        } catch {
            Log.app.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func rename(id: UUID, to name: String) {
        guard var record = record(id: id), activeSession?.id != id else { return }
        record.name = name
        save(record)
    }

    private func save(_ record: MeetingRecord) {
        do {
            try store.save(record)
        } catch {
            Log.app.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
        upsert(record)
    }

    private func upsert(_ record: MeetingRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }
}
