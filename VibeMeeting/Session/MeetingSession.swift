import AppKit
import AVFoundation
import Foundation
import Observation
import VibeCore

/// One live meeting: audio in, subtitles, replies, autosave.
@MainActor
@Observable
final class MeetingSession: Identifiable {
    enum Status: Equatable {
        case starting
        case listening
        case reconnecting
        case ending
        case ended
        case failed(String)

        var label: String {
            switch self {
            case .starting: return "Starting…"
            case .listening: return "Listening"
            case .reconnecting: return "Reconnecting audio…"
            case .ending: return "Ending…"
            case .ended: return "Ended"
            case .failed: return "Paused"
            }
        }
    }

    enum ReplyState: Equatable {
        case idle
        case drafting
        case streaming
        case done
        case failed(String)
    }

    struct Notice: Identifiable, Equatable {
        enum Kind: Equatable {
            case cantHearCall
            case micSilent
            case micUnavailable
            case appAudioNotFound
            case themTranscriptionFailed
            case youTranscriptionFailed
            case echoCancellationOff
        }

        let kind: Kind
        let message: String
        var id: Kind { kind }

        /// Opens the matching System Settings privacy pane.
        var settingsURL: URL? {
            switch kind {
            case .cantHearCall:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .micSilent, .micUnavailable:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            default:
                return nil
            }
        }
    }

    // MARK: - Observable state

    let id: UUID
    private(set) var record: MeetingRecord
    private(set) var transcript = TranscriptStore()
    private(set) var status: Status = .starting
    private(set) var preset: StylePreset
    var selectedTurnID: UUID?
    var steerText = ""
    private(set) var currentScript: ReplyScript?
    private(set) var replyState: ReplyState = .idle
    private(set) var themLevel: Float = 0
    private(set) var youLevel: Float = 0
    private(set) var notices: [Notice] = []
    /// Incremented to ask the overlay to focus the Steer field.
    private(set) var steerFocusRequest = 0

    // MARK: - Dependencies

    private let settings: AppSettings
    private let store: SessionStore
    private let transport: ClaudeTransport
    /// Audio capture and transcription for both streams.
    let pipeline = CapturePipeline()

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    @ObservationIgnored private var lastAsk: ReplyAsk?
    @ObservationIgnored private var lastCacheTouch: Date?
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var listeningSince = Date()

    /// Called after every save so the history list stays current.
    @ObservationIgnored var onSave: ((MeetingRecord) -> Void)?

    init(record: MeetingRecord, preset: StylePreset, settings: AppSettings, store: SessionStore, transport: ClaudeTransport) {
        self.id = record.id
        self.record = record
        self.preset = preset
        self.settings = settings
        self.store = store
        self.transport = transport
    }

    var isActive: Bool {
        switch status {
        case .starting, .listening, .reconnecting, .failed: return true
        case .ending, .ended: return false
        }
    }

    // MARK: - Lifecycle

    func start() async {
        status = .starting
        listeningSince = Date()
        save()

        pipeline.onUpdate = { [weak self] update in self?.apply(update) }
        pipeline.onEvent = { [weak self] event in self?.handle(event) }
        let source: SystemAudioTap.Source = settings.audioSourceBundleID.map { .app(bundleID: $0) } ?? .allSystemAudio
        await pipeline.start(.init(source: source, voiceProcessing: settings.voiceProcessing))
        guard status == .starting else { return }

        status = .listening
        listeningSince = Date()
        startTicking()
        warmCache()
    }

    func end() async {
        guard isActive else { return }
        status = .ending
        tickTask?.cancel()
        replyTask?.cancel()
        await pipeline.stop()
        // Let queued recognizer updates land before locking the transcript.
        await Task.yield()
        transcript.finalizeAll()
        record.turns = transcript.turns
        record.endedAt = Date()
        if let currentScript, replyState == .streaming || replyState == .drafting {
            record.scripts.append(currentScript)
        }
        save()
        status = .ended
    }

    private static let cantHearMessage = "Can't hear the call. Check that VibeMeeting has audio capture permission, or open Audio check."
    private static let micMessage = "Can't use the microphone. Check that VibeMeeting has microphone permission."

    private func handle(_ event: CapturePipeline.Event) {
        switch event {
        case .transcriberFailed(let speaker, let error):
            let kind: Notice.Kind = speaker == .them ? .themTranscriptionFailed : .youTranscriptionFailed
            addNotice(kind, "Transcription for \(speaker.label) stopped: \(error.localizedDescription)")
        case .systemAudioFailed(let error):
            if status == .listening { status = .reconnecting }
            addNotice(.cantHearCall, "\(Self.cantHearMessage) (\(error.localizedDescription))")
        case .systemAudioReconnected:
            removeNotice(.cantHearCall)
            if status == .reconnecting { status = .listening }
        case .appAudioNotFound:
            addNotice(.appAudioNotFound, "The chosen app isn't playing audio yet. Listening to all system audio.")
        case .micFailed(let error):
            if status == .listening { status = .reconnecting }
            addNotice(.micUnavailable, "\(Self.micMessage) (\(error.localizedDescription))")
        case .micReconnected:
            removeNotice(.micUnavailable)
            if status == .reconnecting { status = .listening }
        case .voiceProcessingUnavailable:
            addNotice(.echoCancellationOff, "Echo cancellation is off for this audio setup. A headset keeps Them and You apart.")
        }
    }

    // MARK: - Transcript

    private func apply(_ update: TranscriptUpdate) {
        guard status != .ended else { return }
        transcript.apply(update)
        isDirty = true
    }

    func editTurn(_ id: UUID, text: String) {
        transcript.edit(turnID: id, text: text)
        isDirty = true
    }

    func toggleTarget(_ id: UUID) {
        selectedTurnID = selectedTurnID == id ? nil : id
    }

    /// The text the next Reply will answer, for the overlay preview.
    var pendingTarget: ReplyTarget? { transcript.replyTarget(selectedTurnID: selectedTurnID) }

    // MARK: - Context and style

    func addContext(_ items: [ContextItem]) {
        guard !items.isEmpty else { return }
        record.context.append(contentsOf: items)
        save()
        warmCache()
    }

    func removeContext(_ id: UUID) {
        record.context.removeAll { $0.id == id }
        save()
        warmCache()
    }

    func setPreset(_ preset: StylePreset) {
        guard preset.id != self.preset.id else { return }
        self.preset = preset
        record.presetID = preset.id
        record.presetName = preset.name
        save()
        warmCache()
    }

    func requestSteerFocus() {
        steerFocusRequest += 1
    }

    // MARK: - Reply

    private var promptContext: MeetingPromptContext {
        MeetingPromptContext(
            aboutMe: settings.aboutMe,
            context: record.context,
            preset: preset,
            meetingInstructions: record.meetingInstructions
        )
    }

    private var client: ClaudeClient {
        ClaudeClient(apiKey: settings.apiKey, transport: transport)
    }

    /// ⌥Space and the intent hotkeys.
    func reply(intent: ReplyIntent = .auto) {
        guard let target = transcript.replyTarget(selectedTurnID: selectedTurnID) else {
            replyState = .failed("Nothing to reply to yet.")
            return
        }
        let steer = steerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = ReplyAsk(
            target: target,
            recentTurns: transcript.recentTurns(),
            intent: intent,
            steer: steer,
            variant: .fresh
        )
        steerText = ""
        selectedTurnID = nil
        run(ask)
    }

    /// ⌥R: a new script for the same target.
    func regenerate() {
        guard let previous = currentScript ?? record.scripts.last else {
            reply()
            return
        }
        run(followUp(to: previous, variant: .regenerate))
    }

    /// ⌥S: a shorter version of the last script.
    func shorter() {
        guard let previous = currentScript ?? record.scripts.last, !previous.text.isEmpty else { return }
        run(followUp(to: previous, variant: .shorter))
    }

    func retry() {
        guard let lastAsk else { return }
        run(lastAsk)
    }

    /// Shows an earlier script from this meeting again.
    func showScript(_ script: ReplyScript) {
        guard replyState != .drafting && replyState != .streaming else { return }
        currentScript = script
        replyState = .done
    }

    private func followUp(to previous: ReplyScript, variant: ReplyVariant) -> ReplyAsk {
        // Use the latest text of the same turns, in case they were still being spoken.
        let turns = previous.targetTurnIDs.compactMap(transcript.turn(id:))
        let text = turns.isEmpty ? previous.targetText : turns.map(\.text).joined(separator: " ")
        let target = ReplyTarget(
            turnIDs: previous.targetTurnIDs,
            speaker: turns.first?.speaker ?? .them,
            text: text,
            isLive: turns.contains(where: \.isLive)
        )
        return ReplyAsk(
            target: target,
            recentTurns: transcript.recentTurns(),
            intent: previous.intent,
            steer: previous.steer,
            variant: variant,
            previousScript: previous.text
        )
    }

    private func run(_ ask: ReplyAsk) {
        replyTask?.cancel()
        if let currentScript, replyState == .streaming {
            // Keep the interrupted draft in the history.
            record.scripts.append(currentScript)
        }
        lastAsk = ask

        let model = settings.replyModel
        let request = ReplyPromptBuilder(model: model).request(meeting: promptContext, ask: ask)
        let initialScript = ReplyScript(
            targetTurnIDs: ask.target.turnIDs,
            targetText: ask.target.text,
            intent: ask.intent,
            steer: ask.steer,
            variant: ask.variant,
            presetName: preset.name,
            model: model.id
        )
        currentScript = initialScript
        replyState = .drafting
        switch ask.variant {
        case .fresh: record.stats.replyCount += 1
        case .regenerate: record.stats.regenerateCount += 1
        case .shorter: record.stats.shorterCount += 1
        }

        let client = self.client
        let clock = ContinuousClock()
        let start = clock.now
        replyTask = Task { [weak self] in
            var script = initialScript
            var attempt = 0
            while true {
                attempt += 1
                do {
                    for try await event in client.stream(request) {
                        guard let self, !Task.isCancelled else { return }
                        switch event {
                        case .started:
                            self.lastCacheTouch = Date()
                        case .textDelta(let delta):
                            if script.firstTokenLatency == nil {
                                script.firstTokenLatency = Self.seconds(start.duration(to: clock.now))
                            }
                            script.text += delta
                            self.currentScript = script
                            self.replyState = .streaming
                        case .discardPartialOutput:
                            script.text = ""
                            self.currentScript = script
                        case .finished(let stopReason, let usage):
                            script.stopReason = stopReason
                            script.usage = usage
                        }
                    }
                    guard let self, !Task.isCancelled else { return }
                    if script.stopReason == "refusal" {
                        throw ClaudeError.refusal(category: nil)
                    }
                    script.totalLatency = Self.seconds(start.duration(to: clock.now))
                    script.text = ScriptText.sanitize(script.text)
                    self.finish(script, model: model)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    let claudeError = error as? ClaudeError
                    // One quick retry for overload or network blips, if nothing was shown yet.
                    if attempt == 1, script.text.isEmpty, claudeError?.isRetryable == true, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(400))
                        continue
                    }
                    guard let self, !Task.isCancelled else { return }
                    Log.reply.error("Reply failed: \(error.localizedDescription, privacy: .public)")
                    self.record.stats.failedCount += 1
                    self.replyState = .failed(Self.message(for: error))
                    return
                }
            }
        }
    }

    private func finish(_ script: ReplyScript, model: ClaudeModel) {
        currentScript = script
        replyState = .done
        record.scripts.append(script)
        if let latency = script.firstTokenLatency {
            record.stats.firstTokenLatencies.append(latency)
        }
        if let usage = script.usage {
            record.stats.usage += usage
            record.stats.estimatedCost += model.pricing?.cost(of: usage) ?? 0
        }
        Log.reply.info("Reply done: first token \(script.firstTokenLatency ?? -1, privacy: .public)s, cache read \(script.usage?.cacheReadInputTokens ?? 0, privacy: .public)")
        save()
    }

    static func message(for error: Error) -> String {
        if case .refusal = error as? ClaudeError {
            return "Claude declined this one. Try rephrasing with Steer."
        }
        return "Couldn't draft a reply. Check your connection or API key."
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Prompt cache

    /// Writes layers 1–4 to the prompt cache so the first Reply is fast.
    func warmCache() {
        guard settings.hasAPIKey else { return }
        let request = ReplyPromptBuilder(model: settings.replyModel).warmupRequest(meeting: promptContext)
        let client = self.client
        let model = settings.replyModel
        lastCacheTouch = Date()
        Task { [weak self] in
            do {
                let usage = try await client.warm(request)
                self?.record.stats.usage += usage
                self?.record.stats.estimatedCost += model.pricing?.cost(of: usage) ?? 0
                Log.reply.info("Cache warmed: \(usage.cacheCreationInputTokens, privacy: .public) written, \(usage.cacheReadInputTokens, privacy: .public) read")
            } catch {
                Log.reply.error("Cache warmup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Periodic work

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        let them = pipeline.themMeter.read()
        let you = pipeline.youMeter.read()
        themLevel = them.level
        youLevel = you.level

        if status == .listening {
            let listenedFor = now.timeIntervalSince(listeningSince)
            let themQuiet = now.timeIntervalSince(them.lastSoundAt ?? listeningSince)
            let youQuiet = now.timeIntervalSince(you.lastSoundAt ?? listeningSince)
            if listenedFor > 60, themQuiet > 60 {
                addNotice(.cantHearCall, Self.cantHearMessage)
            } else if themQuiet < 1 {
                removeNotice(.cantHearCall)
            }
            if listenedFor > 30, youQuiet > 30 {
                addNotice(.micSilent, "Your mic seems silent.")
            } else if youQuiet < 1 {
                removeNotice(.micSilent)
            }
        }

        // Keep the 5-minute prompt cache alive between replies (cheap cache reads).
        if let lastCacheTouch, now.timeIntervalSince(lastCacheTouch) > 270, isActive {
            warmCache()
        }

        if isDirty, now.timeIntervalSince(lastSave) > 15 {
            record.turns = transcript.turns
            save()
        }
    }

    private func addNotice(_ kind: Notice.Kind, _ message: String) {
        guard !notices.contains(where: { $0.kind == kind }) else { return }
        notices.append(Notice(kind: kind, message: message))
    }

    private func removeNotice(_ kind: Notice.Kind) {
        notices.removeAll { $0.kind == kind }
    }

    func dismissNotice(_ kind: Notice.Kind) {
        removeNotice(kind)
    }

    // MARK: - Saving

    func save() {
        record.turns = transcript.turns
        do {
            try store.save(record)
            isDirty = false
            lastSave = Date()
            onSave?(record)
        } catch {
            Log.app.error("Saving session failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
