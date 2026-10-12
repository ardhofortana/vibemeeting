import AVFoundation
import Foundation

/// How a capture buffer is folded to mono before it reaches the speech analyzer.
enum MonoFold: Sendable {
    /// Channel 0 only, for the microphone. With voice processing on, macOS presents
    /// 3 to 9 discrete channels (channel 0 is the processed voice, the others can be
    /// echo references). AVAudioConverter has no mix for that layout: it returns
    /// correctly sized buffers full of zeros and reports success.
    case firstChannel
    /// The mean of all channels, for the stereo system-audio tap.
    case average
}

enum MonoMixer {
    /// A private mono Float32 copy at the source sample rate, or nil for empty or
    /// unsupported buffers. Never aliases the input, so it's safe for Core Audio
    /// buffers that only live for the duration of a callback.
    static func mix(_ buffer: AVAudioPCMBuffer, fold: MonoFold) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, buffer.format.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        let used = fold == .firstChannel ? 1 : channels
        // 1 for deinterleaved buffers; the channel count for interleaved ones, whose
        // channel pointers are then offset by one sample each.
        let step = buffer.stride

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            let scale = 1 / Float(used)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += data[channel][frame * step] }
                destination[frame] = sum * scale
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            let scale = 1 / (Float(used) * 32_768)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += Float(data[channel][frame * step]) }
                destination[frame] = sum * scale
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            let scale = 1 / (Float(used) * 2_147_483_648)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<used { sum += Float(data[channel][frame * step]) }
                destination[frame] = sum * scale
            }
        default:
            return nil
        }
        return output
    }
}

/// Converts private mono buffers to the analyzer's format (measured on macOS 26:
/// 16 kHz, mono, Int16, interleaved). SpeechAnalyzer never resamples or converts.
final class BufferConverter {
    enum Failure: Error, CustomStringConvertible {
        case cannotCreateConverter(from: String, to: String)
        case cannotCreateBuffer
        case conversionFailed(String)

        var description: String {
            switch self {
            case .cannotCreateConverter(let from, let to): return "no converter from \(from) to \(to)"
            case .cannotCreateBuffer: return "couldn't allocate a conversion buffer"
            case .conversionFailed(let detail): return "conversion failed: \(detail)"
            }
        }
    }

    private var converter: AVAudioConverter?

    /// Returns nil when this call produced no frames, which is normal while the
    /// resampler fills. Never send an empty buffer to the analyzer.
    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        // Callers pass private copies (MonoMixer output), so handing the input on is safe.
        if buffer.format == format { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            guard let made = AVAudioConverter(from: buffer.format, to: format) else {
                throw Failure.cannotCreateConverter(from: StreamDiagnostics.describe(buffer.format), to: StreamDiagnostics.describe(format))
            }
            // As in Apple's SpeechAnalyzer sample: no priming, so output time doesn't drift.
            made.primeMethod = .none
            converter = made
        }
        guard let converter else { throw Failure.cannotCreateBuffer }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.cannotCreateBuffer
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                // .noDataNow keeps the stream open for the next buffer (.endOfStream would end it).
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        // .inputRanDry is normal for streaming input; only .error is a failure.
        if status == .error {
            throw Failure.conversionFailed(error?.localizedDescription ?? "unknown error")
        }
        return output.frameLength > 0 ? output : nil
    }
}

/// Packs small converted buffers into ~100 ms chunks. The system tap delivers
/// ~10 ms buffers; larger chunks keep the analyzer's input queue short.
/// Requires a mono analyzer format (one AudioBuffer per AVAudioPCMBuffer).
final class ChunkAccumulator {
    private let format: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private let bytesPerFrame: Int
    private var pending: AVAudioPCMBuffer?

    init?(format: AVAudioFormat, seconds: Double = 0.1) {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard format.channelCount == 1, bytesPerFrame > 0, format.sampleRate > 0 else { return nil }
        self.format = format
        self.bytesPerFrame = bytesPerFrame
        self.chunkFrames = AVAudioFrameCount(max(1, (format.sampleRate * seconds).rounded()))
    }

    /// Appends `buffer` (which must be in `format`) and returns any full chunks.
    func append(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard buffer.format == format, let source = buffer.audioBufferList.pointee.mBuffers.mData else { return [] }
        var ready: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if pending == nil {
                pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
            }
            guard let chunk = pending, let destination = chunk.mutableAudioBufferList.pointee.mBuffers.mData else { break }
            let take = min(chunk.frameCapacity - chunk.frameLength, buffer.frameLength - offset)
            memcpy(destination + Int(chunk.frameLength) * bytesPerFrame,
                   source + Int(offset) * bytesPerFrame,
                   Int(take) * bytesPerFrame)
            chunk.frameLength += take
            offset += take
            if chunk.frameLength == chunk.frameCapacity {
                ready.append(chunk)
                pending = nil
            }
        }
        return ready
    }

    /// The partial chunk, at the end of a stream.
    func flush() -> AVAudioPCMBuffer? {
        defer { pending = nil }
        guard let pending, pending.frameLength > 0 else { return nil }
        return pending
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
