import SwiftUI

/// The live audio of the last few seconds, newest on the right: bars above the
/// center line are the call (Them), bars below are your mic (You). Silence is a
/// row of dots.
struct LevelWaveform: View {
    /// Current levels (0…1) of the call and the mic. Read ten times a second.
    let read: @MainActor () -> (them: Float, you: Float)
    let isLive: Bool
    var barCount = 26

    @State private var samples: [Sample] = []

    private struct Sample {
        var them: Float
        var you: Float
    }

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(barCount)
            let barWidth = max(1.5, step * 0.55)
            let mid = size.height / 2
            let missing = max(0, barCount - samples.count)
            var path = Path()
            for index in 0..<barCount {
                let sample = index < missing ? Sample(them: 0, you: 0) : samples[index - missing]
                let up = Self.extent(sample.them, max: mid)
                let down = Self.extent(sample.you, max: mid)
                let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: mid - up, width: barWidth, height: up + down)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
            }
            if isLive {
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [Brand.cyan, Brand.blue, Brand.violet, Brand.magenta]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ))
            } else {
                context.fill(path, with: .color(Color.secondary.opacity(0.5)))
            }
        }
        .task(id: isLive) {
            while !Task.isCancelled {
                let levels = isLive ? read() : (them: Float(0), you: Float(0))
                samples.append(Sample(them: levels.them, you: levels.you))
                if samples.count > barCount { samples.removeFirst(samples.count - barCount) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .help("Live audio. Above the line: the call. Below: your mic.")
        .accessibilityHidden(true)
    }

    /// Half the bar height for a level. Background noise stays a dot; speech
    /// (about −35…−10 dBFS) fills most of the height.
    private static func extent(_ level: Float, max: CGFloat) -> CGFloat {
        let shown = CGFloat(Swift.min(1, Swift.max(0, (level - 0.3) / 0.5)))
        return 0.9 + shown * Swift.max(0, max - 0.9)
    }
}

/// The Responses column's counterpart to the live audio: still while ready,
/// moving while a response is being written.
struct ActivityWaveform: View {
    let isActive: Bool
    var isFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A fixed waveform shape, tallest in the middle.
    private static let profile: [CGFloat] = [
        0.14, 0.24, 0.36, 0.26, 0.5, 0.7, 0.46, 0.82, 1.0, 0.68, 0.9, 0.58, 0.78,
        0.5, 0.66, 0.4, 0.56, 0.34, 0.46, 0.26, 0.36, 0.2, 0.26, 0.14,
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let moving = isActive && !reduceMotion
            Canvas { context, size in
                let count = Self.profile.count
                let step = size.width / CGFloat(count)
                let barWidth = max(1.5, step * 0.55)
                let mid = size.height / 2
                var path = Path()
                for (index, shape) in Self.profile.enumerated() {
                    let wave = moving ? 0.35 + 0.65 * abs(sin(time * 3.4 + Double(index) * 0.55)) : 0.6
                    let half = max(0.9, shape * CGFloat(wave) * mid)
                    let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: mid - half, width: barWidth, height: half * 2)
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
                }
                if isFailed {
                    context.fill(path, with: .color(Color.secondary.opacity(0.45)))
                } else {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [Brand.cyan, Brand.blue, Brand.violet, Brand.magenta]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ))
                }
            }
        }
        .opacity(isActive || isFailed ? 1 : 0.7)
        .accessibilityHidden(true)
    }
}

/// A waveform with a one-word status under it, for a column header.
struct WaveformBadge<Wave: View>: View {
    let caption: String
    var color: Color = .secondary
    var width: CGFloat = 104
    @ViewBuilder let wave: () -> Wave

    var body: some View {
        VStack(spacing: 4) {
            wave()
                .frame(width: width, height: 24)
            Text(caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize()
    }
}
