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

    private(set) var records: [MeetingRecord] = []
    private(set) var activeSession: MeetingSession?
    private(set) var recapsInProgress: Set<UUID> = []
    var selectedRecordID: UUID?

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
        if let activeSession, activeSession.isActive {
            await endMeeting()
        }
        if !MicrophoneCapture.permissionGranted {
            _ = await MicrophoneCapture.requestPermission()
        }

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
        guard let session = activeSession else { return }
        Hotkeys.setEnabled(false)
        overlay.close()
        await session.end()
        upsert(session.record)
        activeSession = nil
        selectedRecordID = session.id
        guard thenRecap else { return }
        windows.showMain()
        await generateRecap(for: session.id)
    }

    func toggleOverlay() {
        guard let activeSession else { return }
        overlay.toggle(session: activeSession, app: self)
    }

    // MARK: - Recap

    func generateRecap(for id: UUID) async {
        guard var record = record(id: id), !recapsInProgress.contains(id) else { return }
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
