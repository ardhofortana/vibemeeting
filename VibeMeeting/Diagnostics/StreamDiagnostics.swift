import AVFoundation
import Foundation

/// Counters for one audio stream (Them or You), from capture to transcript.
/// Updated from audio threads, read by the UI. Never holds transcript text.
final class StreamDiagnostics: @unchecked Sendable {
    struct Snapshot: Equatable {
        var captureState = "Not started"
        var captureBuffers = 0
        var capturedFrames = 0
        /// Capture callbacks whose audio couldn't be read.
        var unreadableBuffers = 0
        var sourceFormat = "–"
        /// Loudest RMS seen so far (0…1). Zero means only digital silence arrived.
        var peakRMS: Float = 0
        var lastSoundAt: Date?

        var transcriberState = "Not started"
        var analyzerFormat = "–"
        var buffersToAnalyzer = 0
        var framesToAnalyzer = 0
        /// Loudest RMS actually sent to speech recognition. Zero while the capture
        /// peak isn't means audio was lost in conversion.
        var analyzerPeakRMS: Float = 0
        var lastAudibleToAnalyzerAt: Date?
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

    /// Records one captured buffer. Cheap enough for the audio thread.
    func recordCapture(_ buffer: AVAudioPCMBuffer, rms: Float) {
        lock.withLock {
            snapshot.captureBuffers += 1
            snapshot.capturedFrames += Int(buffer.frameLength)
            if snapshot.captureBuffers == 1 || snapshot.captureBuffers % 200 == 0 {
                snapshot.sourceFormat = Self.describe(buffer.format)
            }
            if rms > snapshot.peakRMS { snapshot.peakRMS = rms }
            if rms > AudioLevelMeter.silenceRMS { snapshot.lastSoundAt = Date() }
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
    /// Plain-text lines for the copyable report.
    func reportLines(now: Date = Date()) -> [String] {
        func ago(_ date: Date?) -> String {
            guard let date else { return "never" }
            return String(format: "%.1fs ago", now.timeIntervalSince(date))
        }
        return [
            "capture: \(captureState)",
            "  buffers \(captureBuffers), frames \(capturedFrames), unreadable \(unreadableBuffers)",
            "  format \(sourceFormat)",
            String(format: "  peak RMS %.5f, last sound %@", peakRMS, ago(lastSoundAt)),
            "transcriber: \(transcriberState)",
            "  analyzer format \(analyzerFormat)",
            "  to analyzer: chunks \(buffersToAnalyzer), frames \(framesToAnalyzer), dropped \(droppedChunks), conversion failures \(conversionFailures)",
            String(format: "  analyzer peak RMS %.5f, last audible %@", analyzerPeakRMS, ago(lastAudibleToAnalyzerAt)),
            "  last conversion error: \(lastConversionError ?? "none")",
            "  results: volatile \(volatileResults), final \(finalResults), last \(ago(lastResultAt))",
            "  last error: \(lastError ?? "none")",
        ]
    }
}
