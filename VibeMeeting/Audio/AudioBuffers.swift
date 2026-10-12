import AVFoundation
import Foundation

/// Converts capture buffers to the format the speech analyzer wants.
///
/// SpeechAnalyzer does not resample or downmix on its own, and AVAudioConverter
/// can't always downmix unusual layouts (voice processing input reports 3, 5 or
/// 9 channels). So every buffer is first mixed to mono Float32 by hand, and the
/// converter only changes sample rate and sample type.
final class BufferConverter {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedSourceFormat(String)
        case cannotCreateConverter(from: String, to: String)
        case cannotCreateBuffer
        case conversionFailed(String)

        var description: String {
            switch self {
            case .unsupportedSourceFormat(let format): return "unsupported source format \(format)"
            case .cannotCreateConverter(let from, let to): return "no converter from \(from) to \(to)"
            case .cannotCreateBuffer: return "couldn't allocate a conversion buffer"
            case .conversionFailed(let detail): return "conversion failed: \(detail)"
            }
        }
    }

    private var converter: AVAudioConverter?

    /// Returns nil when the converter produced no output yet (it may buffer a little).
    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let mono = MonoMixer.mix(buffer) else {
            throw Failure.unsupportedSourceFormat(StreamDiagnostics.describe(buffer.format))
        }
        if mono.format == format { return mono }

        if converter == nil || converter?.inputFormat != mono.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: mono.format, to: format)
            // Avoid timestamp drift from priming, as Apple's SpeechAnalyzer sample does.
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw Failure.cannotCreateConverter(from: StreamDiagnostics.describe(mono.format), to: StreamDiagnostics.describe(format))
        }

        let ratio = format.sampleRate / mono.format.sampleRate
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up)) + 16
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
            return mono
        }
        if status == .error {
            throw Failure.conversionFailed(error?.localizedDescription ?? "unknown error")
        }
        return output.frameLength > 0 ? output : nil
    }
}

/// Mixes any PCM buffer down to a mono Float32 copy at the same sample rate.
enum MonoMixer {
    static func mix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Stereo is averaged. With more channels (voice processing), the processed
        // voice is on the first channel and the rest would only dilute it.
        let used = channels <= 2 ? channels : 1
        let scale = 1 / Float(used)
        let interleaved = buffer.format.isInterleaved

        func sample(_ read: (Int) -> Float) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used {
                    sum += read(interleaved ? frame * channels + channel : channel * frames + frame)
                }
                destination[frame] = sum * scale
            }
        }

        if let source = buffer.floatChannelData {
            if interleaved {
                let data = source[0]
                sample { data[$0] }
            } else {
                sample { index in source[index / frames][index % frames] }
            }
        } else if let source = buffer.int16ChannelData {
            let factor: Float = 1 / 32_768
            if interleaved {
                let data = source[0]
                sample { Float(data[$0]) * factor }
            } else {
                sample { index in Float(source[index / frames][index % frames]) * factor }
            }
        } else if let source = buffer.int32ChannelData {
            let factor: Float = 1 / 2_147_483_648
            if interleaved {
                let data = source[0]
                sample { Float(data[$0]) * factor }
            } else {
                sample { index in Float(source[index / frames][index % frames]) * factor }
            }
        } else {
            return nil
        }
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

    /// Returns the buffer's RMS.
    @discardableResult
    func update(with buffer: AVAudioPCMBuffer) -> Float {
        let rms = Self.rms(of: buffer)
        // Map roughly -60 dBFS…0 dBFS onto 0…1 for the UI meter.
        let db = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (db + 60) / 60))
        lock.lock()
        level = max(normalized, level * 0.85)
        if rms > Self.silenceRMS { lastSoundAt = Date() }
        lock.unlock()
        return rms
    }

    /// Current level (0…1) and when sound was last heard.
    func read() -> (level: Float, lastSoundAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        let value = (level, lastSoundAt)
        level *= 0.7
        return value
    }

    /// Current level (0…1) without the display decay `read()` applies.
    func peek() -> Float {
        lock.withLock { level }
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
