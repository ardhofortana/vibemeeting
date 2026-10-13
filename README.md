# VibeMeeting

A meeting assistant for your Mac. VibeMeeting listens to your calls in any call app (Zoom, Google Meet, Microsoft Teams, Slack, WhatsApp and others) without adding a bot to the call. It shows live subtitles for both sides and, when you press a hotkey, drafts what you could say next in your own voice. After the call it writes a recap with the key points, decisions, action items and open questions.

[Bahasa Indonesia](README.id.md) · [What's new](CHANGELOG.md) · [For developers](DEVELOPMENT.md)

> **Free beta.** VibeMeeting is published by Djavaweb and is free while it's in beta. Expect rough edges.

## What it does

- **Live subtitles** for the other side (from your Mac's sound) and for you (from the microphone), transcribed on your Mac.
- **Replies on a hotkey.** Press ⌥Space when the other side stops talking, and VibeMeeting drafts a short reply you can read out or put in your own words. It answers what they just said first, then moves toward your goal for the meeting. You can ask for a specific move (Answer, Clarify, Add, Push back), type a quick direction (Steer), or make the reply shorter.
- **Ask questions.** Three to five questions to ask the other side, to move the meeting toward its goal.
- **Context.** Add files (PDF, Word, text, Markdown), notes and screenshots before or during the meeting, and replies can use the facts in them.
- **Your voice.** Write a few lines about yourself in Settings → About me, and pick a reply style.
- **Recap** after every meeting, including how far you got toward the goal. Copy it as Markdown or export it.
- **History** of your meetings, searchable, stored on your Mac.

## Requirements

- A Mac with **macOS 26** or later. Apple silicon is recommended; Intel Macs haven't been tested.
- Your own **Anthropic API key** (see [Your API key and cost](#your-api-key-and-cost)).
- An internet connection for replies and recaps. Transcription works offline once the speech model for your language is downloaded.

## Install

Signed and notarized downloads are being set up for the beta. Until the first one is out, beta testers build VibeMeeting themselves: see [DEVELOPMENT.md](DEVELOPMENT.md). With a download:

1. Open the downloaded file and drag **VibeMeeting** into your **Applications** folder.
2. Open VibeMeeting. It lives in the **menu bar** (the wave icon at the top right of your screen) and has no Dock icon unless one of its windows is open.

## First launch and permissions

The Welcome window walks you through three steps:

1. **Audio.** Click **Allow audio capture**. macOS asks for two permissions:
   - **Microphone**, to transcribe what you say.
   - **System Audio Recording**, to transcribe the other side. If you miss the prompt, turn VibeMeeting on in System Settings → Privacy & Security → Screen & System Audio Recording, under **System Audio Recording Only**.

   VibeMeeting also downloads the on-device speech model for your call language. This happens once per language.
2. **API key.** Paste your Anthropic API key. It's stored in the macOS Keychain.
3. **About me.** Optional, but replies sound much more like you with it. Settings → About me shows an outline: your name, what you do, who you usually meet, how you want to come across, facts replies may use, and things you never say. Write it in any language.

To check that everything works, choose **Audio check…** from the menu bar icon, play a video with speech and say a few words. Both meters should move and text should appear on both sides within a second or two.

## Your API key and cost

VibeMeeting uses Anthropic's Claude models with **your own API key**, so Anthropic bills your account directly for what you use. There's no VibeMeeting account and no server in between.

1. Sign in to Anthropic's developer platform at [platform.claude.com](https://platform.claude.com) and add credit to your account.
2. Create an API key. A separate workspace for VibeMeeting with a monthly spend limit keeps costs predictable.
3. Paste the key in the Welcome window or in Settings → General, and click **Test connection**.

What it costs depends on how long your meetings are and how often you ask for replies. Rough guide; your usage page on platform.claude.com shows the real numbers:

- With the default models (Claude Haiku 5.5 for replies, Claude Opus 5.5 for recaps), an hour-long meeting usually costs well under one US dollar, often tens of cents.
- Drafting replies with Opus costs several times more. Chinese, Japanese and Korean use more tokens than English for the same words.
- While a meeting runs, VibeMeeting refreshes the prompt cache about every four and a half minutes so replies stay fast, which costs a little even when you don't ask for anything. End the meeting when the call ends.

Each meeting's details show an estimated cost. New Anthropic accounts start with low rate limits, so a very long recap can fail at first; open the meeting and click **Try again** later.

## Privacy

Audio never leaves this Mac and meetings are stored only on it; to write replies and recaps, VibeMeeting sends the transcript text, About me and what you add to the meeting (goal, instructions, Steer and context, including file text and images) to Anthropic with your own API key.

In more detail:

- **Audio** is transcribed on your Mac by macOS's own speech recognition. It's never saved and never sent anywhere.
- **What's sent** goes straight from your Mac to Anthropic's API under your own Anthropic account and terms. Djavaweb doesn't receive your meetings, your key or anything else; VibeMeeting has no server and no analytics.
- **Meetings** are saved as files in `~/Library/Application Support/VibeMeeting/Sessions`. Deleting a meeting in the main window deletes its file.
- **Your API key** is stored in the macOS Keychain.
- **Diagnostics.** The Audio check report and the app's logs never contain transcript text, context or replies. The report stays on your Mac unless you copy it and share it yourself.
- **Other people in the call** are transcribed too, and their words are sent to Anthropic when you ask for a reply or a recap. Tell them you use VibeMeeting and get their consent where the law requires it.

## Languages

- **Call language.** Each meeting has one language that both sides speak. You can choose any language that macOS's on-device speech recognition supports; the list is in Settings → General → **Call language** and in the New meeting window. The default (Automatic) is the first of your Mac's preferred languages that speech recognition supports, or English (United States) if none is.
- **Replies, Ask questions and the recap** are written in the call language unless you pick another one in New meeting. You can choose from 35 languages there.
- **Your own text** (About me, goal, meeting instructions, Steer, context) can be in any language, or a mix.
- **Preview languages.** Languages that aren't written in the Latin or Cyrillic alphabet (such as Chinese, Japanese, Korean, Thai, Arabic and Hebrew) work, but are marked "preview": sentence splitting, word counts and the echo filter are tuned for the others.
- **The app itself** is in English for now. It's ready for translation, and other languages will follow.

## Using VibeMeeting

**Before the call.** Choose **New meeting** from the menu bar icon (or the main window). Give the meeting a name and a **Goal** (both optional), check the **Language**, add **Context** (drop files, paste text or a screenshot, or **Add from clipboard**), and pick a **Reply style**. **Meeting instructions** add rules for this meeting's replies. Then click **Start listening**. In a hurry? In the main window, the arrow next to New meeting has **Start now**.

**During the call.** The overlay floats above your other windows:

- **Transcript** on the left: the other side's words in bubbles, yours as plain text. Click a turn to make it the one the next reply answers; double-click it to fix a word the transcription misheard.
- **Responses** on the right: every reply and question list in this meeting. The newest has **Regenerate** and **Shorter**; any of them can be copied.
- The **goal** is under the Responses title. Click it to change it.
- The bar at the bottom has the moves (Answer, Clarify, Add, Push back), **Ask questions**, the **Steer** field and **Reply**.
- The green window button switches to a compact one-column overlay; the red one hides the overlay without ending the meeting (⌥H brings it back).

**After the call.** Click **End meeting**. The recap is created automatically. Open the meeting in the main window to read it, **Copy as Markdown**, or **Export .md…**.

### Hotkeys

Hotkeys work only while a meeting is running, so they never get in the way in other apps. Change them in Settings → Hotkeys.

| Action | Default |
| --- | --- |
| Reply (VibeMeeting picks the move) | ⌥Space |
| Answer · Clarify · Add · Push back | ⌥1 · ⌥2 · ⌥3 · ⌥4 |
| Steer (type a direction, then Enter) | ⌥⇧Space |
| Ask questions | ⌥Q |
| Regenerate · Shorter | ⌥R · ⌥S |
| Show or hide the overlay | ⌥H |

## Use it honestly

VibeMeeting is an assistant you use openly. It doesn't support use meant to deceive people, for example getting covert help where that isn't allowed, such as in job interviews or exams. You're responsible for following the law where you and the other people in the call are, including getting their consent to transcription where it's required. Djavaweb isn't responsible for how you use VibeMeeting.

**Hide from screen sharing** (Settings → Overlay) is off by default. It asks macOS to leave the overlay out of screen sharing, but some screen-sharing apps may still capture it, so hide the overlay with ⌥H before you share your screen. Turning the setting on shows the same disclaimer first.

## Troubleshooting

- **Nothing appears under Them.** Open **Audio check…**. If the call's meter stays flat, turn VibeMeeting on in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then start the meeting again. If you picked one app under Settings → Audio → Listen to, try **All system audio** (needed for calls in Safari).
- **The other side's words show up under You.** Your mic is picking up your speakers. Use headphones, or keep **Remove the call's voice from my mic** on in Settings → Audio.
- **A hotkey types a character instead.** Some ⌥ + letter combinations type characters on some keyboard layouts. Change the hotkey to ⌃⌥ + letter in Settings → Hotkeys.
- **Replies don't come.** In Settings → General, click **Test connection**. Check that your Anthropic account has credit.
- **"Saved meetings can't be opened."** A newer version of VibeMeeting saved them, or the files are damaged. They're kept as they are; update VibeMeeting to open them.

---

VibeMeeting is closed-source software. © 2026 Djavaweb. All rights reserved.
