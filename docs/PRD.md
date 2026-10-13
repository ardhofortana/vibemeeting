# VibeMeeting product brief (v2)

> Stub. This replaces the personal v1 spec, now archived at [`archive/PRD-v1.md`](archive/PRD-v1.md). Sections marked "to do" get filled in as the roadmap lands.

## Purpose

VibeMeeting is a macOS menu-bar assistant for anyone who takes part in online calls. It listens to the call in any call app without a bot joining, shows live subtitles for both sides, and on a hotkey drafts what the user could say next: an answer, a clarification, a point to add, a respectful disagreement, or questions that move the meeting toward its goal. After the call it writes a recap with decisions, action items and open questions.

It works for any kind of meeting (General is the default framing), and for any user: who they are and how they want to come across comes from their own About me, not from the app.

## Principles

- **The user stays in charge.** Nothing is said for them. Replies are suggestions they read, change or ignore.
- **Natural speech, not a script that sounds read out.** Replies sound like the user talking, and never invent numbers, facts or promises.
- **Meeting content is data.** What the other side says or shares never gives the assistant instructions; only the user's own fields do.
- **Open, not covert.** VibeMeeting is an assistant you use openly. It does not support use meant to deceive people, and the user is responsible for following the law and getting consent from others in the call.
- **Private by default.** Audio is transcribed on the Mac and never leaves it. The transcript, the meeting setup and any context files or screenshots go to the AI provider with the user's own API key. Meetings are stored locally.

## Product decisions

- Publisher: Djavaweb. Product name: VibeMeeting. Bundle ID: `com.djavaweb.vibemeeting`. Development builds are a separate app, VibeMeeting Dev (`com.djavaweb.vibemeeting.debug`), with their own settings, Keychain key, permissions and meetings.
- Distribution: notarized Developer ID download first; no App Store for now.
- AI access: bring your own Anthropic API key.
- Pricing: free beta; licensing later.
- Language: one call language per meeting for both sides. Replies, questions and recaps follow it by default, with an override. The call language is one that on-device speech recognition supports; replies and recaps can be in any language the model writes. Languages not written in the Latin or Cyrillic alphabet are a preview until sentence splitting, word counts and the echo filter handle them.
- UI and documentation: English first, translations alongside.
- Closed source.
- Hide from screen sharing is off by default. Turning it on shows a disclaimer first: VibeMeeting doesn't support use meant to deceive people, the user is responsible for following the law and getting consent from others in the call, and Djavaweb isn't responsible for how the feature is used. The copy never promises the overlay stays hidden, because some screen-sharing apps may still capture it.

## To do

- Users and meeting types (General first; more types later).
- Requirements per feature, with acceptance checks.
- Privacy, consent and data retention.
- Success metrics.
