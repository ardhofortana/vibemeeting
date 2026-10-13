# Changelog

All notable changes to VibeMeeting are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow [Semantic Versioning](https://semver.org/):

- **MAJOR (x.0.0)**: changes that make old data or the old way of using the app incompatible.
- **MINOR (0.x.0)**: new features.
- **PATCH (0.0.x)**: fixes only.

Each version has a git tag `vX.Y.Z`. The running version shows in the menu bar menu and in Settings → General.

## Going back to an earlier version

Going back never deletes meeting files. The **Compatibility** notes under each version say what an older version does with meetings saved by a newer one. How to switch versions is in [DEVELOPMENT.md](DEVELOPMENT.md#rollback), and how to release one in [DEVELOPMENT.md](DEVELOPMENT.md#versions-and-releases).

## [Unreleased]

### Added
- **Meetings in other languages.** New meeting has a **Language** section: the language spoken in the call, and the languages for replies and Ask questions and for the recap ("Same as the call" unless you pick another). Both sides of the call are transcribed in the call language. The default is in Settings → General → **Call language**; Automatic picks the first of your Mac's languages that speech recognition supports, else English (United States). If you used an earlier version, new meetings stay in English (United States) until you pick another call language in Settings → General. Each language's speech model downloads once, with progress in Settings, the Welcome window, Audio check and the meeting overlay. Languages not written in the Latin or Cyrillic alphabet (Chinese, Japanese, Korean, Thai, Arabic, Hebrew and others) are marked **preview** for now, in the call language list and in the reply and recap language lists. A meeting's details show its language, and Audio check runs in the default one.
- **Saved meetings never disappear without a word.** If a meeting file can't be read (saved by a newer version of VibeMeeting, or damaged), the main window says how many and offers **Show in Finder**. The file is left exactly as it is. A meeting saved by a newer version that this version can still read opens **read-only**: Star, Rename and creating a recap are off, so nothing the newer version saved is lost. Delete still works.

### Changed
- **The meeting overlay is redesigned** to match the mockup: dark glass with two cards almost as wide as the window.
  - **Header:** window buttons, the app icon and name, the reply style menu, a `00:00:00` timer, Audio check, Add context, Settings, and a red End meeting button.
  - **Transcript column:** a live waveform next to the title. Bars above the line are the call's audio, bars below it your mic. A status word shows only when something's wrong ("Reconnecting…", "Paused"). The other side's words show in bubbles with a dot, name and time; yours show as dimmed text without a bubble.
  - **Responses column:** the meeting goal under the title, and response cards with the time and small buttons.
  - **Bottom bar:** Answer, Clarify, Add, Push back and Ask questions chips with icons. A chip lights up while a response for it is being written. A Steer field with a ✨ icon (click anywhere in its box to type), a gradient Reply button, and the list of hotkeys.
  - The overlay is always dark, whatever the macOS appearance.
  - It starts at 860×680 (Compact 420×640). When it's narrow, chip labels get shorter first and hotkeys you rarely need are hidden. In Compact mode a long reply scrolls, and the Reply bar is never pushed out.
- Overlay window buttons: red and yellow hide the overlay (the meeting keeps running; bring it back with ⌥H or from the menu bar). Green switches between the split and Compact modes (also in Settings → Overlay).
- **Replies sound like someone actually talking.** There are pauses ("um", "well..."), spontaneous reactions and corrections mid-sentence, but only as needed and never in a pattern. The content stays clear and concrete, and a number, price, date or name is always said once, exactly, without hesitating or correcting it. Every built-in style (Friendly Pro, Consultant, Negotiator, Tech Explainer, Short & Sweet, Diplomatic) now has its own way of speaking. Ask questions and Shorter sound natural too, and the bold first sentence is no longer cut off at "...".
- The goal, meeting instructions, About me, context and Steer can be written in any language the model knows (or a mix). Names, brands and numbers are copied exactly. (For the language of replies, Ask questions and recaps, see "Meetings in other languages" above.)
- **A smarter echo filter.** The other side's voice leaking into your mic and transcribed with mishearings (for example "women's healthies" for "Yemen's Halbies") no longer shows up as "You", in live or final text. Only the echoed part is removed: a "Yeah okay" in front of it or your own sentence after it stays, and an answer that reuses their words ("Yes, I can do it in two weeks, no problem.") stays whole.
- **The New meeting and Add context windows** use dark glass, as in the mockup.
  - The goal takes up to 500 characters and the meeting instructions up to 300, each with a counter.
  - Context: an area to drop files, then the Paste text, Paste screenshot and **Add from clipboard** tabs (new: adds files, images or text from the clipboard right away). Files over 50 MB are refused with a clear message.
  - Reply styles show as cards with a short description, and a **Manage styles** link opens the Reply styles tab in Settings.
- **The main window is redesigned** in dark glass.
  - Sidebar: search (⌘K), the All / Recent (7 days) / Recaps / Starred filters, and meetings listed by day (Today, Yesterday, then dates). Each meeting has a "…" menu with Star, Rename and Delete.
  - With no meeting selected: a **New meeting** button, with an arrow menu next to it for **Start now** (start right away without setup, with a choice of style) and Audio check.
  - Meetings can be starred. The star and delete buttons are at the top of a meeting's page.
- **About me starts empty.** An outline shows what to write (name, what you do, who you usually meet, how you want to come across, facts replies may use, things you never say), in any language. "Reset to template" is now **Clear**, and the Welcome window's About me button opens that tab. If you never edited About me, it is empty after this update: write yours in Settings → About me.
- **Neutral framing for any meeting.** Replies, Ask questions and recaps no longer assume a sales call with a client. Firmness on price and scope belongs to the Negotiator style only, the holding line for a missing number no longer promises "today", and recaps cover "a meeting" and what was agreed in it. Built-in styles talk about "the other side", and Negotiator works whichever side you're on. Placeholders and help text use everyday examples.
- **Prompt injection protection.** Replies, Ask questions and recaps treat what's said in the call and what's in the meeting context (files, notes, screenshots) as information, not instructions. The model is told to ignore text there that tries to change its task, reveal its prompt or put words in your mouth (such as "ignore your instructions" or "agree to do it for free"). Only About me, meeting instructions, the goal and Steer direct a reply.
- The diagnostics report lists your preferred languages and whether speech recognition supports each, instead of checking one language. The app's copyright (Finder → Get Info) is "© 2026 Djavaweb".
- **Replies, Ask questions and recaps are no longer English-only.** They're written in the meeting's language, with the hesitations, reactions and fillers native speakers use (the English examples in the instructions are only examples), and formal or informal address follows the meeting and the language. The `[confirm number]` reminder stays the same in every language and is recognized however the model writes it.
- **Echo filter outside English.** Removing a garbled copy of the other side's words from your mic runs only for English calls, because its rules are tuned on English. In other languages only near-verbatim copies are removed, so a garbled double can occasionally show under You; your own words are never removed by mistake.
- The diagnostics report names the call language, and the "speech recognition returns no words" notice names the meeting's language instead of saying English only.
- Audio check and the diagnostics report word a few states differently: the mic shows "Running (echo cancellation on)", and a recognizer that stopped reads "Speech stopped with an error" or "Speech ended unexpectedly".
- **New app identity.** VibeMeeting is published by Djavaweb, with the bundle ID `com.djavaweb.vibemeeting`, so macOS treats it as a new app. On first launch it copies your settings (About me if you wrote one, reply styles, models, audio, overlay and call language) and your hotkeys from the previous version, and tries to copy your Claude API key from the Keychain. macOS may ask you to allow that; if you don't, or it fails, enter the key again in Settings → General. macOS also asks for microphone and system audio permission again, so the Welcome window shows once more. Your meetings stay where they were, in `~/Library/Application Support/VibeMeeting`.
- **Development builds are a separate app.** A build run from Xcode is **VibeMeeting Dev** (`com.djavaweb.vibemeeting.debug`), with its own settings, Keychain key, permissions and meetings folder (`~/Library/Application Support/VibeMeeting Dev`), so it never touches a release install. On its first launch after this update it gets a copy of the earlier app's meetings; after that the two folders are separate. The menu shows which one is running, and the diagnostics report names the bundle ID.
- **Hide from screen sharing is off by default.** Turning it on in Settings → Overlay first explains it: some screen-sharing apps may still capture the overlay, VibeMeeting doesn't support use meant to deceive people (such as covert help in interviews or exams where that isn't allowed), you're responsible for following the law and getting consent from others in the call, and Djavaweb isn't responsible for how you use it. The section footer says the same in short. Existing installs keep it as it was; new installs start with it off.
- For developers: `scripts/bundle-id.sh` prints the release or `debug` bundle ID from project.yml (for example for `tccutil reset`), `scripts/release.sh` takes the compare-link URL from the `origin` remote, and the CI check for personal terms now also covers project.yml, scripts, Configs and docs. The original personal spec is no longer in the repository; docs/PRD.md is the product brief.
- **An accurate privacy note.** Welcome, Settings → General and the macOS permission prompts now say exactly what leaves your Mac: audio never leaves this Mac and meetings are stored only on it; to write replies and recaps, VibeMeeting sends the transcript text, About me, your reply style and what you add to the meeting (name, goal, instructions, Steer and context, including file text and images) to Anthropic with your own API key. The earlier text said only text was sent, but images in the context are sent too.
- Notes meant for developers (a build signed without a Team, where to find CHANGELOG.md) now show only in development builds. The Welcome window is a little taller to fit the privacy note, and the New meeting window's title is in sentence case.
- **Documentation in English.** README.md is now a guide for people who use VibeMeeting (install, permissions, your API key and its cost, privacy, languages, using it honestly), with an Indonesian translation in README.id.md. Building, signing, tests, releases and rollback moved to DEVELOPMENT.md, and this changelog is in English throughout. docs/COPY.md sets the voice, the glossary and the rules for text that can be translated.
- For developers: the app is ready for translation. Its text goes through string catalogs (`Localizable.xcstrings`, and `InfoPlist.xcstrings` for the permission prompts), shared components take localized text, and counts ("1 reply", "2 replies") use plural variants instead of hand-made endings. Nothing is translated yet. CI checks that the catalogs are valid and that the permission prompts match Info.plist.

### Compatibility
- Older meetings load as before. Meeting files now carry a format version (3), action item owners are saved as `you`/`them` instead of the on-screen label, and each meeting saves its languages. Meetings saved before languages existed load as English (United States) for the call, replies and recap, which is what they were. A reply move or kind this version doesn't know (from a newer version) loads as a plain Reply instead of hiding the meeting.
- Rollback across the identity change: earlier versions run under the previous bundle ID, with the settings, Keychain key and permissions they had there (nothing is removed from it, and nothing changed in the new identity carries back). They read meetings from `~/Library/Application Support/VibeMeeting`, the folder the release build uses, so meetings saved by VibeMeeting Dev don't show in them.
- Rollback: every earlier version reads the new owner values correctly. Version 0.6.0 and earlier ignore the format version: they open these meetings normally, but if they save one again (rename, star, recap), its languages are dropped and it comes back as English (United States); the transcript and recap are kept. A development build from between 0.6.0 and this change (format 2) opens them read-only. The notes for earlier versions below still apply.
- Going back to 0.6.0 or earlier: stars don't show, and a meeting loses its star if that version saves it again (when you rename it or create its recap again).

## [0.6.0] - 2026-10-12

### Added
- **A 50:50 split overlay.** The transcript on the left, every response in the meeting (Reply and Ask questions) on the right, from oldest to newest. The response list is kept and scrolls during the meeting, follows new responses, and stops following when you scroll up ("Jump to latest" brings you back). A response you just asked for (Reply, Ask questions, Regenerate, Shorter) always shows right away. The overlay size you set is saved per meeting, and an overlay placed on the left of the screen stays on the left when you switch modes. The newest response is highlighted and has Regenerate and Shorter buttons; every response can be copied. Compact mode (one narrow column) is still there, from the button in the header or Settings → Overlay.
- **An app icon and brand colors.** The VibeMeeting logo is the app icon (in every macOS size) and the menu bar icon (wave bars, in a circle while a meeting runs). The logo's colors (cyan, blue, purple, magenta) are used as accents only: main buttons and highlights use the brand blue, the level meters and the thin line at the top of the overlay use its gradient, and the goal and Ask questions icons are purple. Status colors (green, orange, red) stay as they were.
- `scripts/tag-versions.sh` creates the `vX.Y.Z` tags for every version in the changelog, so you can go back with `git checkout vX.Y.Z`.
- `scripts/release.sh` refuses a version that already exists or is older, and accepts Unreleased notes that aren't committed yet.

## [0.5.0] - 2026-10-12

### Added
- **A meeting goal.** An optional Goal field in New meeting. The goal shows under the overlay header and can be changed any time during the call. Every reply still answers first, then (when it fits) takes one step toward the goal. Steer still comes first.
- **Ask questions** (a button, or ⌥Q). Gives 3–5 short questions to ask the other side, so the meeting's direction gets clear and moves toward the goal. Questions that were already answered are skipped, and it works before anyone has spoken. Steer focuses the questions. Click a question to copy it, or Regenerate for different ones. It's as fast as Reply because it uses the same prompt cache.
- The recap says how far the goal was reached and what's still missing. The goal is in the Markdown export too.
- The version number shows in the app, along with a changelog, version tags and `scripts/release.sh`.

### Changed
- Numbers in the goal, the meeting instructions and the transcript can be used in a reply directly, without [confirm number].
- Ask questions doesn't count toward the reply statistics (regenerate rate, first-word latency).

### Compatibility
- Older meetings still load.
- Going back to a version before 0.5.0: meetings that used Ask questions don't show in that version's History. Their files stay and show up again after you update.
- Going back to a version before 0.5.0: meetings with a goal still show, but without the goal and the goal progress. Don't rename these meetings or create their recap again in the older version: it saves the file again without the goal and goal progress, and neither comes back after you update.

## [0.4.0] - 2026-10-12 (commit 06c13a0)

### Added
- **Speaker bleed suppression (EchoGate).** With speakers, the mic also hears the other side, so their words show up twice, once under "You". The app compares the mic's level with the call audio and mutes the mic for the "You" transcript only where it carries nothing but their voice. The call isn't affected, and when you talk at the same time your voice still gets through. It's on by default and can be turned off in Settings → Audio → *Remove the call's voice from my mic*. Its state shows in Audio check and in the report.

### Fixed
- After review: the suppression lets go quickly when headphones are plugged in or the speaker volume goes down, pauses between syllables while you talk over the other side aren't cut, background noise in the call audio doesn't switch it off, and fast volume increases are recognized.

## [0.3.0] - 2026-10-12 (commit ce3ee33)

### Added
- **Reply reads the whole conversation.** A reply answers the last thing the other side said first, then picks up earlier questions or points that weren't answered, and stays consistent with what you've already said. The earlier transcript is sent in cached chunks, so it stays fast.

### Changed
- Subtitles always follow the conversation, and auto-scroll stops only when you scroll up.
- The text echo filter also catches misheard words, doesn't show live text that copies "Them", and removes a doubled "You" line that arrived first.

### Fixed
- "Reconnecting" no longer gets stuck. The hint for a wrongly chosen source app has its own notice. The echo cancellation notice goes away when it works again.
- A recap no longer overwrites the final transcript when it's created while the meeting is still being saved.
- Quitting during "Saving…" no longer leaves a new meeting behind.

## [0.2.1] - 2026-10-12 (commit 45e1955)

### Fixed
- False permission warnings while the call is silent (muted, in a lobby). The "only silence" diagnosis now shows only if there has never been any sound, and the permission is checked with a probe, as Chromium does.
- Overlay notices: a specific diagnosis replaces the general one, and a notice you closed doesn't come back until its condition changes.
- Echo cancellation now works with the 3.5 mm headphone port connected to speakers.
- The mic turns on again by itself when it's plugged in after a failure.
- Ending a meeting, quitting and starting a new meeting in quick succession no longer loses data.
- An Audio check stopped during a permission prompt no longer starts on its own.

## [0.2.0] - 2026-10-12 (commit 9e98127)

### Added
- **Audio check** (menu bar) and a stethoscope button in the overlay: levels, formats, buffer counts, a verdict for each stage, and **Copy report** without any transcript content. The last meeting's report is kept.
- A warning when the build has no signing Team, because macOS then gives it only silent audio.

### Fixed
- The other side's audio (system audio) didn't come in: the tap is now created without a sub-device, with a clock fallback, limited rebuilds, and a start and stop that don't block the thread.
- Your own voice had a level but wasn't transcribed: mic audio with voice processing is now taken from channel 0.
- Echo cancellation is off by default, because voice processing turns down other apps, the call included.

## [0.1.0] - 2026-10-12 (commit 70513cd)

### Added
- The first version: live subtitles for the other side (system audio) and for you (mic), Reply with Claude (⌥Space) with moves, Steer, Regenerate and Shorter, meeting context (PDF, DOCX, text, images), style presets, a recap after the meeting with Markdown export, local history, and Settings (API key in the Keychain, models, hotkeys, About me).

[Unreleased]: https://github.com/ardhofortana/vibemeeting/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ardhofortana/vibemeeting/releases/tag/v0.1.0
