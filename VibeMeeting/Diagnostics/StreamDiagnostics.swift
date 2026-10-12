import AVFoundation
import Foundation

/// Counters for one audio stream (Them or You), from capture to transcript.
/// Updated from audio threads, read by the UI. Never holds transcript text.
final class StreamDiagnostics: @unchecked Sendable {
    struct Snapshot: Equatable {
        // Capture
        var captureState = "Not started"
        /// How capture is set up: the tap stream and aggregate input streams for
        /// Them; the device route and voice processing for You. Set by the capture
        /// object; per-buffer updates never overwrite it.
        var deviceDetail = "–"
        var captureBuffers = 0
        var capturedFrames = 0
        /// Capture callbacks whose audio couldn't be read.
        var unreadableBuffers = 0
        /// Buffer-list layout of an unreadable IO cycle, e.g. "3 buffers: 1ch/2048B … 1ch/2048B".
        var unreadableLayout: String?
        /// Format of the buffers handed to speech (mono after the fold).
        var sourceFormat = "–"
        /// Loudest RMS (0…1) of the audio handed to speech. Zero: only digital silence.
        var peakRMS: Float = 0
        /// Loudest RMS per raw input channel before the mono fold (mic only). With
        /// voice processing on, channel 0 should be the processed voice.
        var channelPeakRMS: [Float] = []
        var lastSoundAt: Date?
        /// When capture first carried clearly audible audio (RMS above speech level).
        var firstLoudCaptureAt: Date?
        /// Seconds since the source last delivered a non-zero sample (system tap,
        /// across rebuilds). nil while a call plays = macOS hands this build silence.
        var secondsSinceNonZero: Double?
        /// One app is chosen as the source and it's silent while another app plays.
        var chosenAppIdle = false
        /// True for streams that track non-zero samples (the system tap).
        var tracksNonZero = false
        var rebuilds = 0
        var lastRebuildReason: String?
        var problem: String?

        // Speech
        var transcriberState = "Not started"
        var analyzerFormat = "–"
        var buffersToAnalyzer = 0
        var framesToAnalyzer = 0
        /// Loudest RMS actually sent to speech recognition. Zero while the capture
        /// peak isn't means audio was lost in conversion.
        var analyzerPeakRMS: Float = 0
        var lastAudibleToAnalyzerAt: Date?
        /// 100 ms chunks sent to speech at speech level (RMS > 0.01, about -40 dBFS).
        var speechLevelChunks = 0
        var droppedChunks = 0
        var conversionFailures = 0
        var lastConversionError: String?
        var volatileResults = 0
        var finalResults = 0
        var lastResultAt: Date?
        var lastError: String?
    }

    let name: String
    private let lock = NSLock()
    private var snapshot = Snapshot()

    init(name: String) {
        self.name = name
    }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&snapshot) }
    }

    func read() -> Snapshot {
        lock.withLock { snapshot }
    }

    func reset() {
        lock.withLock { snapshot = Snapshot() }
    }

    /// Records one buffer handed to speech. Not for the Core Audio IO thread.
    func recordCapture(_ buffer: AVAudioPCMBuffer, rms: Float) {
        lock.withLock {
            snapshot.captureBuffers += 1
            snapshot.capturedFrames += Int(buffer.frameLength)
            if snapshot.captureBuffers == 1 || snapshot.captureBuffers % 200 == 0 {
                snapshot.sourceFormat = Self.describe(buffer.format)
            }
            if rms > snapshot.peakRMS { snapshot.peakRMS = rms }
            if rms > AudioLevelMeter.silenceRMS { snapshot.lastSoundAt = Date() }
            if rms > LiveTranscriber.speechLevelRMS, snapshot.firstLoudCaptureAt == nil {
                snapshot.firstLoudCaptureAt = Date()
            }
        }
    }

    /// Keeps the loudest RMS seen on each raw input channel.
    func recordChannels(_ channelRMS: [Float]) {
        guard !channelRMS.isEmpty else { return }
        lock.withLock {
            if snapshot.channelPeakRMS.count != channelRMS.count {
                snapshot.channelPeakRMS = channelRMS
            } else {
                for index in channelRMS.indices where channelRMS[index] > snapshot.channelPeakRMS[index] {
                    snapshot.channelPeakRMS[index] = channelRMS[index]
                }
            }
        }
    }

    static func describe(_ format: AVAudioFormat) -> String {
        let sampleType: String
        switch format.commonFormat {
        case .pcmFormatFloat32: sampleType = "Float32"
        case .pcmFormatFloat64: sampleType = "Float64"
        case .pcmFormatInt16: sampleType = "Int16"
        case .pcmFormatInt32: sampleType = "Int32"
        default: sampleType = "other"
        }
        return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(sampleType), \(format.isInterleaved ? "interleaved" : "non-interleaved")"
    }
}

extension StreamDiagnostics.Snapshot {
    /// The first thing that looks wrong, in pipeline order, or nil if nothing does.
    /// Shown at the top of each column so the next test names the broken stage.
    func verdict() -> String? {
        if captureBuffers == 0 && unreadableBuffers > 0 {
            return "Capture: every buffer is unreadable (layout mismatch)"
        }
        if captureBuffers == 0 {
            return captureState.hasPrefix("Failed") ? "Capture failed to start" : "Capture: no buffers yet"
        }
        if peakRMS <= AudioLevelMeter.silenceRMS {
            if tracksNonZero && secondsSinceNonZero == nil {
                return "Capture: only exact zeros so far (nothing playing yet, or no permission)"
            }
            return "Capture: only silence so far (nothing playing, or wrong mic channel)"
        }
        if transcriberState == "Stopped with an error" || transcriberState == "Ended unexpectedly" {
            return "Speech stopped (\(transcriberState.lowercased())); see the error below"
        }
        if buffersToAnalyzer == 0 {
            return conversionFailures > 0 ? "Conversion fails before speech" : "Nothing reaches speech (\(transcriberState))"
        }
        if lostInConversion() {
            return "Speech only receives silence (lost in conversion)"
        }
        if volatileResults + finalResults == 0 && speechLevelChunks >= 50 {
            return "Speech hears speech but returns no words (language? model?)"
        }
        return nil
    }

    /// Capture has carried clearly audible audio for over 2 s (far longer than the
    /// ≤100 ms chunking and resampler delay), yet speech got almost none of it.
    /// The 40 dB margin covers 10 ms vs 100 ms windows, the 8 kHz low-pass and
    /// the L/R average.
    func lostInConversion(now: Date = Date()) -> Bool {
        guard let first = firstLoudCaptureAt, now.timeIntervalSince(first) > 2,
              buffersToAnalyzer > 0 else { return false }
        return analyzerPeakRMS < peakRMS * 0.01
    }

    /// Plain-text lines for the copyable report.
    func reportLines(now: Date = Date()) -> [String] {
        func ago(_ date: Date?) -> String {
            guard let date else { return "never" }
            return String(format: "%.1fs ago", now.timeIntervalSince(date))
        }
        let channels = channelPeakRMS.isEmpty ? "–" : channelPeakRMS.map { String(format: "%.4f", $0) }.joined(separator: " ")
        let nonZero = tracksNonZero ? (secondsSinceNonZero.map { String(format: "%.1fs ago", $0) } ?? "never (only exact zeros)") : "–"
        return [
            "verdict: \(verdict() ?? "ok")",
            "capture: \(captureState)",
            "  device \(deviceDetail)",
            "  buffers \(captureBuffers), frames \(capturedFrames), unreadable \(unreadableBuffers)",
            "  unreadable layout: \(unreadableLayout ?? "–")",
            "  format \(sourceFormat)",
            String(format: "  peak RMS %.5f, last sound %@", peakRMS, ago(lastSoundAt)),
            "  raw channel peaks: \(channels)",
            "  last non-zero sample: \(nonZero)",
            "  rebuilds \(rebuilds), last reason: \(lastRebuildReason ?? "–"), problem: \(problem ?? "none")",
            "  chosen app idle while another app plays: \(chosenAppIdle)",
            "transcriber: \(transcriberState)",
            "  analyzer format \(analyzerFormat)",
            "  to analyzer: chunks \(buffersToAnalyzer), frames \(framesToAnalyzer), speech-level \(speechLevelChunks), dropped \(droppedChunks), conversion failures \(conversionFailures)",
            String(format: "  analyzer peak RMS %.5f, last audible %@", analyzerPeakRMS, ago(lastAudibleToAnalyzerAt)),
            "  last conversion error: \(lastConversionError ?? "none")",
            "  results: volatile \(volatileResults), final \(finalResults), last \(ago(lastResultAt))",
            "  last error: \(lastError ?? "none")",
        ]
    }
}
