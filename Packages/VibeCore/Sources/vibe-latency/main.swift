// M0 latency check: runs the six PRD scenarios through the real Reply prompt
// and reports time to first token. Usage:
//
//   ANTHROPIC_API_KEY=sk-... swift run vibe-latency [--model ID]... [--trials N] [--context FILE] [--about FILE]
//
// Defaults: Claude Haiku 5.5, 3 trials per scenario, built-in sample context.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VibeCore

struct Scenario {
    var name: String
    var said: String
    var intent: ReplyIntent = .auto
    var steer: String = ""
}

let scenarios = [
    Scenario(name: "Pricing", said: "What would something like this cost, roughly?"),
    Scenario(name: "Technical", said: "Will this work with our WooCommerce subscriptions?"),
    Scenario(name: "Objection", said: "Another agency quoted us half that."),
    Scenario(name: "Opinion to clarify", said: "I think we can launch in two weeks."),
    Scenario(
        name: "Add a point",
        said: "We're planning to run Instagram ads and an email campaign the week we launch, mostly to our existing customers.",
        intent: .add
    ),
    Scenario(
        name: "Smooth phrasing (Steer)",
        said: "So how do revisions work with you?",
        steer: "bilang 2x revisi gratis per milestone, revisi tambahan dihitung per jam, harga per jam jangan disebut"
    ),
]

let sampleContext = """
SAMPLE PROPOSAL (test data for the latency check)
Client: Northwind Coffee. Goal: WooCommerce store with coffee subscriptions.
Scope: custom Elementor Pro theme (home, shop, product, subscription landing page), WooCommerce Subscriptions setup with monthly and quarterly plans, Stripe payments, JetEngine for brewing guides, basic SEO setup.
Not included: copywriting, product photography, ongoing maintenance.
Milestone 1: design and prototype, 2 weeks, $1,400.
Milestone 2: build, subscriptions, testing and launch, 4 weeks, $2,600.
Total: $4,000. Two rounds of revisions per milestone.
Hosting recommendation: Pressable.
Fiverr chat notes: client wants to launch before the holiday season and asked if existing customers can be imported.
"""

let sampleAboutMe = """
Name: Ardho Fortana
Role: CEO of a WordPress agency, Top Rated seller on Fiverr.
Brand to use with clients: Detheme. In business since 2013.
Stack: WordPress, Elementor Pro, WooCommerce, JetEngine.
Rules: lock the scope before talking price. Projects run in two milestones.
"""

// MARK: - Arguments

var models: [String] = []
var trials = 3
var contextText = sampleContext
var aboutMe = sampleAboutMe

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data("Missing value for \(flag)\n".utf8))
            exit(2)
        }
        return arguments.removeFirst()
    }
    switch flag {
    case "--model": models.append(value())
    case "--trials": trials = max(1, Int(value()) ?? 3)
    case "--context": contextText = (try? String(contentsOfFile: value(), encoding: .utf8)) ?? contextText
    case "--about": aboutMe = (try? String(contentsOfFile: value(), encoding: .utf8)) ?? aboutMe
    case "-h", "--help":
        print("Usage: vibe-latency [--model ID]... [--trials N] [--context FILE] [--about FILE]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("Unknown argument \(flag)\n".utf8))
        exit(2)
    }
}
if models.isEmpty { models = [ClaudeModel.defaultReplyModelID] }

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
    FileHandle.standardError.write(Data("Set ANTHROPIC_API_KEY first.\n".utf8))
    exit(1)
}

// MARK: - Run

let client = ClaudeClient(apiKey: apiKey)
let meeting = MeetingPromptContext(aboutMe: aboutMe, context: [.text(contextText, title: "proposal.txt")], preset: .friendlyPro, meetingInstructions: "")

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func format(_ value: Double?) -> String {
    value.map { String(format: "%.2fs", $0) } ?? "–"
}

for modelID in models {
    let model = ClaudeModel.resolve(modelID)
    let builder = ReplyPromptBuilder(model: model)
    print("\n=== \(model.displayName) (\(model.id)) ===")

    do {
        let warm = try await client.warm(builder.warmupRequest(meeting: meeting))
        print("Cache warmed: \(warm.cacheCreationInputTokens) written, \(warm.cacheReadInputTokens) read")
    } catch {
        print("Warmup failed: \(error.localizedDescription)")
    }

    var firstTokens: [Double] = []
    var totals: [Double] = []
    var usage = TokenUsage()

    for scenario in scenarios {
        print("\n[\(scenario.name)] Them: \(scenario.said)")
        let turn = TranscriptTurn(speaker: .them, finalText: scenario.said, startedAt: Date())
        let ask = ReplyAsk(
            target: ReplyTarget(turnIDs: [turn.id], speaker: .them, text: scenario.said, isLive: false),
            recentTurns: [turn],
            intent: scenario.intent,
            steer: scenario.steer
        )
        for trial in 1...trials {
            let clock = ContinuousClock()
            let start = clock.now
            var firstToken: Double?
            var text = ""
            do {
                for try await event in client.stream(builder.request(meeting: meeting, ask: ask)) {
                    switch event {
                    case .textDelta(let delta):
                        if firstToken == nil { firstToken = seconds(start.duration(to: clock.now)) }
                        text += delta
                    case .discardPartialOutput:
                        text = ""
                    case .finished(let stopReason, let final):
                        usage += final
                        if stopReason == "refusal" { text = "(refused)" }
                    case .started:
                        break
                    }
                }
                let total = seconds(start.duration(to: clock.now))
                if let firstToken { firstTokens.append(firstToken) }
                totals.append(total)
                print("  #\(trial) first word \(format(firstToken)), done \(format(total))")
                if trial == 1 { print("  You: \(ScriptText.sanitize(text))") }
            } catch {
                print("  #\(trial) failed: \(error.localizedDescription)")
            }
        }
    }

    print("\nSummary for \(model.id)")
    print("  First word  median \(format(SessionStats.percentile(firstTokens, 0.5)))  p90 \(format(SessionStats.percentile(firstTokens, 0.9)))   target ≤1.5s / ≤3s")
    print("  Full script median \(format(SessionStats.percentile(totals, 0.5)))   target ≤4s")
    print("  Tokens: \(usage.inputTokens) input, \(usage.cacheReadInputTokens) cache read, \(usage.cacheCreationInputTokens) cache write, \(usage.outputTokens) output")
    if let pricing = model.pricing {
        print(String(format: "  Cost of this run: $%.4f", pricing.cost(of: usage)))
    }
}
