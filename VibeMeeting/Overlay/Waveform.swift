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
            // The newest samples, right-aligned (the bar count can change with the width).
            let recent = Array(samples.suffix(barCount))
            let missing = barCount - recent.count
            var path = Path()
            for index in 0..<barCount {
                let sample = index < missing ? Sample(them: 0, you: 0) : recent[index - missing]
                let up = Self.extent(sample.them, max: mid)
                let down = Self.extent(sample.you, max: mid)
                let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: mid - up, width: barWidth, height: up + down)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
            }
            if isLive {
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.31, green: 0.65, blue: 0.93), Brand.blue, Brand.violet, Brand.magenta]),
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
        .accessibilityHidden(true)
    }

    /// Half the bar height for a level. Background noise stays a dot; speech
    /// (about −35…−10 dBFS) fills most of the height.
    private static func extent(_ level: Float, max: CGFloat) -> CGFloat {
        let shown = CGFloat(Swift.min(1, Swift.max(0, (level - 0.3) / 0.5)))
        return 0.9 + shown * Swift.max(0, max - 0.9)
    }
}
