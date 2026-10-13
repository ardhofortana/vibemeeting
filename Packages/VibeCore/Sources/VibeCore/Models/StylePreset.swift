import Foundation

/// A reply style: a name, a long instruction, and a target length.
public struct StylePreset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String
    public var minSentences: Int
    public var maxSentences: Int
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        minSentences: Int,
        maxSentences: Int,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.minSentences = max(1, minSentences)
        self.maxSentences = max(self.minSentences, maxSentences)
        self.isBuiltIn = isBuiltIn
    }
}

extension StylePreset {
    public static let friendlyProID = "builtin.friendly-pro"

    /// Each one describes how that kind of person talks on a call. The first
    /// sentence is a short plain description, shown as the style's summary.
    public static let builtIns: [StylePreset] = [
        StylePreset(
            id: friendlyProID,
            name: "Friendly Pro",
            instructions: """
            Warm, relaxed and professional, like a helpful expert who enjoys the work. \
            Talks the easy way you'd chat with someone you get along with: small, genuine reactions ("oh, nice", \
            "yeah, that makes sense") and a "you know" or "I mean" now and then while explaining something. \
            Smooth and sure about their own work, a bit more careful when something is still unclear. \
            Plain, friendly words throughout.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.consultant",
            name: "Consultant",
            instructions: """
            Thinks out loud like an experienced advisor, but always lands a clear recommendation and next step. \
            Sounds like someone who has seen this problem many times. Gives the gist of the recommendation first, \
            then reasons through it the way people do when talking, weighing an option or two out loud \
            ("okay, so the real question is...", "you could do it that way, but...") with the odd "hmm". \
            The recommendation itself is said plainly, without hedging. Ends with a concrete next step, \
            said casually, not like a summary.
            """,
            minSentences: 3, maxSentences: 5, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.negotiator",
            name: "Negotiator",
            instructions: """
            Calm, unhurried and friendly, but firm on price, terms and scope. \
            Says less than everyone else and doesn't rush to fill a silence or over-explain. Hardly any filler, \
            no nervous hesitation and no apologizing, and no softeners like "just" or "maybe" when holding the line. \
            A relaxed "yeah, I hear you" or "right" before standing firm is enough. Stays steady when pushed, \
            whichever side the user is on. Doesn't offer concessions unprompted, and trades any concession for \
            something in return, so a change in price goes with a change in scope or terms. Keeps coming back to \
            the value and what each side gets.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.tech-explainer",
            name: "Tech Explainer",
            instructions: """
            Explains technical things in everyday words, with one simple comparison when it helps. \
            Knows the tech well, so the facts come out fluently, but searches out loud for the clearest way \
            to put it ("it's kind of like... okay, think of it as..."). Uses one everyday comparison, not a string \
            of them. Says assumptions plainly as they come up ("this is assuming you keep the current setup") \
            and avoids jargon unless the other side used it first.
            """,
            minSentences: 3, maxSentences: 5, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.short-sweet",
            name: "Short & Sweet",
            instructions: """
            Quick and casual, straight to the point. \
            Talks like someone answering in passing: at most a quick "yeah" or "sure" up front, then the answer. \
            No warm-up, no recap of what they said, no explaining unless asked. Short, natural fragments are fine.
            """,
            minSentences: 1, maxSentences: 2, isBuiltIn: true
        ),
        StylePreset(
            id: "builtin.diplomatic",
            name: "Diplomatic",
            instructions: """
            Gently clarifies or disagrees without making anyone feel wrong. \
            Acknowledges where they're coming from in a few words, then softens with hedges ("I wonder if...", "maybe", \
            "I'm not totally sure, but...", "it might be worth..."). Hesitates a little more than usual, \
            like someone choosing their words carefully, and frames a correction as working it out together \
            ("so maybe we could..."). Still gets the point across clearly: soft, not vague.
            """,
            minSentences: 2, maxSentences: 4, isBuiltIn: true
        ),
    ]

    public static var friendlyPro: StylePreset { builtIns[0] }
}
