import AVFoundation
import Foundation

/// Converts capture buffers to the format the speech analyzer wants.
/// SpeechAnalyzer does not resample or downmix on its own.
final class BufferConverter {
    enum Failure: Error {
        case cannotCreateConverter
        case cannotCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if inputFormat == format { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter else { throw Failure.cannotCreateConverter }

        let ratio = format.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.cannotCreateBuffer
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw Failure.conversionFailed(error) }
        return output
    }
}

/// Thread-safe level meter fed from the audio thread and read from the UI.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    private var lastSoundAt: Date?

    /// RMS below this is treated as digital silence (muted or missing audio).
    static let silenceRMS: Float = 0.0001

    func update(with buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(of: buffer)
        // Map roughly -60 dBFS…0 dBFS onto 0…1 for the UI meter.
        let db = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (db + 60) / 60))
        lock.lock()
        level = max(normalized, level * 0.85)
        if rms > Self.silenceRMS { lastSoundAt = Date() }
        lock.unlock()
    }

    /// Current level (0…1) and when sound was last heard.
    func read() -> (level: Float, lastSoundAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        let value = (level, lastSoundAt)
        level *= 0.7
        return value
    }

    func reset() {
        lock.lock()
        level = 0
        lastSoundAt = nil
        lock.unlock()
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        var count = 0
        if let data = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let samples = data[0]
                let total = frames * channels
                for index in 0..<total { sum += samples[index] * samples[index] }
                count = total
            } else {
                for channel in 0..<channels {
                    let samples = data[channel]
                    for index in 0..<frames { sum += samples[index] * samples[index] }
                }
                count = frames * channels
            }
        } else if let data = buffer.int16ChannelData {
            let samples = data[0]
            for index in 0..<frames {
                let sample = Float(samples[index]) / Float(Int16.max)
                sum += sample * sample
            }
            count = frames
        }
        return count == 0 ? 0 : (sum / Float(count)).squareRoot()
    }
}
