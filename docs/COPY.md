# VibeMeeting copy guide

How VibeMeeting talks to people, the words it uses, and how to write strings that can be translated. English is the base language of the app and the documentation (owner decisions D8 and D9). Read this before you add or change any text a user sees.

## Voice and tone

- **Plain, friendly, direct.** Short sentences. Say what happens and what the person can do next. No marketing words, no exclamation marks, no "Oops".
- **Talk to "you".** The app is "VibeMeeting", never "we" or "I".
- **Sentence case everywhere:** window titles, buttons, menu items, tabs, section headers ("New meeting", "Reply styles", "Audio check…"). Proper names keep their capitals: VibeMeeting, Anthropic, Claude, macOS, Zoom.
- **Buttons say what they do,** with a verb: "Start listening", "Create recap", "Show in Finder". Add "…" (one character) when the button opens a window that asks for more ("Settings…", "Audio check…"), and use it for ongoing states ("Starting…").
- **No jargon in the UI.** No "tokens", "p90", "OSStatus", "TCC", "locale", "prompt" or "SSE". Technical detail belongs in the diagnostics report or behind a "Technical details" disclosure. (A few older strings still break this rule, such as the token estimate under About me and the latency figures in meeting details; they get fixed in the full copy pass.)
- **Errors** say what happened, why if we know, and what to do next. They never blame the person.
- **Be honest about limits.** Don't promise what hasn't been verified. "Hide from screen sharing" never says the overlay stays hidden. Never use covert-use language ("undetectable", "nobody can tell"): VibeMeeting is an assistant people use openly.
- **Name the provider only where it matters:** API key setup, the privacy statement, model names and provider errors. Everywhere else, describe what the feature does.
- **Paths** use arrows: Settings → General → Call language.

## Glossary

Current names. Renames under discussion (such as Hint for Steer, Disagree for Push back) are not adopted yet; until they are, use these.

| Term | Meaning |
| --- | --- |
| Meeting | One call in VibeMeeting, from Start listening to End meeting, saved on this Mac with its transcript, replies, context and recap. |
| Call | The live conversation in the call app (Zoom, Meet, Teams…). Say "call" for the conversation and the call app, "meeting" for what VibeMeeting runs and saves. |
| The other side | Everyone else in the call. Use it in sentences. |
| Them / You | Tags in the transcript for the other side and for you. Use them only as tags, never in sentences. In prompts they are fixed tokens and are never translated. |
| Transcript | Live text of what both sides say, transcribed on this Mac. |
| Call language | The language spoken in the call. Both sides are transcribed in it, and replies, questions and the recap use it unless you pick another language. |
| Speech model | The on-device model macOS uses to transcribe one language. It downloads once per language. |
| Reply | A short text VibeMeeting drafts for you to say next, in your own voice. The overlay lists replies under "Responses". Avoid "script" in new copy. |
| Moves (intents) | What a reply does: Auto picks the best move; Answer answers the question; Clarify corrects politely or asks back; Add adds a point; Push back disagrees politely. The code and the overlay's hotkey hints say "intents"; new copy says "move". |
| Steer | A short direction you type during the call to focus the next reply or questions. |
| Ask questions | Three to five questions to ask the other side that move the meeting toward its goal. |
| Regenerate / Shorter | Draft the last reply again, or make it shorter. |
| Goal | What you want from this meeting. Replies and questions move toward it, and the recap says how far you got. |
| Meeting instructions | Rules for the replies in one meeting, such as "Keep it informal". |
| Context | Files, notes and screenshots you add to a meeting. Replies may use the facts in them; text in them never gives VibeMeeting instructions. |
| Reply style | How replies sound and how long they are. Built-in styles (Friendly Pro, Negotiator…) or your own. |
| About me | Who you are and how you want to come across, in your own words. Sent with every reply and recap. |
| Recap | What VibeMeeting writes after the meeting: summary, key points, decisions, action items, open questions and progress on the goal. |
| Overlay | The floating panel during a meeting: transcript on the left, responses on the right. Compact mode shows one narrow column. |
| Audio check | The window that tests system audio, the mic and transcription without a meeting. |
| API key | Your own Anthropic API key. The UI calls it "Claude API key". |

## Privacy statement

There is one privacy sentence, `PrivacyNote.summary` in `VibeMeeting/App/PrivacyNote.swift`. Welcome and Settings show it, and README.md repeats it. Don't paraphrase it elsewhere in the app. The permission prompts in `VibeMeeting/Resources/Info.plist` (and the same text in `VibeMeeting/InfoPlist.xcstrings`) say its audio half. When what VibeMeeting sends changes, update all of them together.

## Strings that can be translated

The app's text lives in `VibeMeeting/Localizable.xcstrings`; the permission prompts in `VibeMeeting/InfoPlist.xcstrings`. The build extracts strings from the code (`SWIFT_EMIT_LOC_STRINGS`), and Xcode adds new keys to the catalog when you build in Xcode. Nothing is translated yet.

1. **Every user-facing string goes through the catalog.** In SwiftUI, a string literal passed to `Text`, `Button`, `Label`, `Toggle`, `Picker` and friends is a `LocalizedStringKey` and is extracted. Outside views, use `String(localized:)`.
2. **Shared components take `LocalizedStringKey`** (views: `WindowTitleBar`, `GlassSectionHeader`, `GlassNotice`, `ColumnHeader`, Welcome's steps) **or `LocalizedStringResource`** (data and constants: `Hotkeys.Entry`, `PrivacyNote`, window titles). Never `String` for UI text.
3. **A `String` variable is shown as is.** `Text(name)` with a `String` is not translated; use that only for the person's own content (meeting names, transcript, file names).
4. **No sentences built from pieces.** One key per whole sentence. Put values in with interpolation (`"Calls are transcribed in \(language)."`), never with `+` or by joining fragments, because word order differs between languages.
5. **Plurals use one key and plural variants.** Write `"\(count) replies"` and add the "one" and "other" variants in the catalog (see "%lld replies"). Never `count == 1 ? "" : "s"`.
6. **Hotkeys stay outside sentences.** Show a hotkey as its own label or keycap next to the text ("Reply ⌥Space"), not inside a sentence ("Press ⌥Space to reply"): word order changes and people change their hotkeys. (Some older strings still put the hotkey inside a sentence; the full copy pass fixes them.)
7. **Dates, times, durations and numbers use formatters** (`.formatted()`), never hand-built text.
8. **Help translators.** Add a comment (`comment:` in code, or in the catalog) when a short string is ambiguous ("Add" is a verb). Leave room: translations are often 30–40% longer than English.
9. **Markdown.** `Text` renders inline Markdown in a localized string (`*`, `_`, backticks, links). Keep those characters out of plain text, or use `Text(verbatim:)`.
10. **VibeCore is not localized.** It runs on Linux and has no resource bundle. The display labels it returns (`Speaker.label`, `ReplyIntent.label`, `ReplyFailure.message`, the stream state labels) are English for now and move into the app in the full copy pass. Prompt text in `Prompts.swift` is never translated: it is written for the model, and the output language comes from the meeting's `<language>` block. The prompt tokens (`Them`, `You`, `[confirm number]`) never change.
11. **Check before you push.** `python3 scripts/check-catalogs.py` (also run in CI) checks that the catalogs are valid and that the permission prompts in InfoPlist.xcstrings match Info.plist.
