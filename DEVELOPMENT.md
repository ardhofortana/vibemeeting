# Developing VibeMeeting

Building, signing, testing, releasing and rolling back VibeMeeting. For using the app, see [README.md](README.md). For wording and translation-ready strings, see [docs/COPY.md](docs/COPY.md). The product brief is [docs/PRD.md](docs/PRD.md).

## Requirements

- A Mac with **macOS 26** or later. On-device transcription (SpeechAnalyzer) is new in macOS 26.
- **Xcode 26**.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- An Anthropic API key, for replies and recaps.

## Build and run

```bash
git clone https://github.com/ardhofortana/vibemeeting.git
cd vibemeeting
xcodegen generate          # creates VibeMeeting.xcodeproj from project.yml
open VibeMeeting.xcodeproj
```

The Xcode project is generated and not committed: change `project.yml`, then run `xcodegen generate` again. New `.swift` files under `VibeMeeting/` are picked up automatically.

### Signing Team

In Xcode, open the **VibeMeeting** target → **Signing & Capabilities** and pick your Team (a free Personal Team is enough). Then save it, so it survives every `xcodegen generate`:

```bash
scripts/save-signing-team.sh                                 # reads the Team you picked in Xcode, or pass the 10-character Team ID
xcodegen generate
tccutil reset AudioCapture "$(scripts/bundle-id.sh debug)"   # once, so macOS asks again for the Team-signed build
```

The Team goes into `Configs/Local.xcconfig`, which git ignores and `Configs/Signing.xcconfig` includes. Then Run (⌘R); the wave icon appears in the menu bar.

**Why the Team matters.** Without one, Xcode signs the build ad hoc ("Sign to Run Locally"). macOS ties the System Audio Recording permission to the signature, so every rebuild counts as a new app: the toggle in Privacy & Security still looks on, but the app only receives silence. The build log warns when there's no Team, and development builds show a notice in New meeting and Audio check. Release builds never show these notices.

### Development and release builds

|  | Release | Development (Debug, what ⌘R builds) |
| --- | --- | --- |
| Bundle ID | `com.djavaweb.vibemeeting` | `com.djavaweb.vibemeeting.debug` |
| Name in Finder and System Settings | VibeMeeting | VibeMeeting Dev |
| Meetings and diagnostics | `~/Library/Application Support/VibeMeeting` | `~/Library/Application Support/VibeMeeting Dev` |

The development build is a separate app with its own settings, Keychain key, privacy permissions and meetings folder, so it never touches a release install. On its first launch after the move from the earlier bundle ID it copies the earlier app's meetings from `VibeMeeting/Sessions`; after that the folders are separate. To see release meetings in it later, copy the files from `VibeMeeting/Sessions` into `VibeMeeting Dev/Sessions`.

`scripts/bundle-id.sh` prints the release bundle ID and `scripts/bundle-id.sh debug` the development one, read from `project.yml`. Scripts and docs use it instead of hardcoding either.

Notes meant for developers (the ad hoc signing notices, where CHANGELOG.md is) are compiled only into development builds, inside `#if DEBUG`. Keep developer instructions out of what release users see.

## Tests

```bash
swift test --package-path Packages/VibeCore       # core tests (macOS or Linux)

# The real HTTP transport against a local SSE server:
python3 scripts/sse_test_server.py 18777 &
VIBE_LOCAL_SSE_URL=http://127.0.0.1:18777 swift test --package-path Packages/VibeCore

python3 scripts/check-catalogs.py                  # string catalogs and permission prompts
```

`Packages/VibeCore` holds everything that doesn't need a Mac, and its tests run on Linux. The app target has no tests of its own; CI builds it on macOS.

### CI

`.github/workflows/ci.yml` runs on every push:

- **personal-terms**: one person's names and business details stay out of the shipped sources (app, VibeCore, `project.yml`, `scripts/`, `Configs/`, `docs/`).
- **catalogs**: `scripts/check-catalogs.py`.
- **core**: the VibeCore tests on Linux, with the local SSE server.
- **app**: the VibeCore tests on macOS 26, then `xcodegen generate` and an unsigned Debug build of the app.

### Reply latency

`vibe-latency` runs sample scenarios, including a prompt-injection attempt, against the real API:

```bash
cd Packages/VibeCore
ANTHROPIC_API_KEY=sk-ant-... swift run vibe-latency --model claude-haiku-5-5 --model claude-opus-5-5
```

Targets: first word within 1.5 s (median) and 3 s (p90), full reply within 4 s. `--context file.txt` and `--about about.txt` test with real context and a real About me, `--language de-DE` with another call language, and `--trials N` sets the runs per scenario. One run costs a few cents.

### Checklist on a real Mac

The app layer is compiled in CI but needs a real Mac for these:

1. **Core tests:** `swift test --package-path Packages/VibeCore`.
2. **Reply latency:** `vibe-latency` as above.
3. **The other side's audio:** open **Audio check…**, play a YouTube video, and check that text appears under **Them** within a second.
4. **Echo without a headset:** use the laptop speakers and check that the other side doesn't show up under **You**. If it leaks, use a headset or check Settings → Audio.
5. **Hotkeys:** try each one while Zoom or Chrome is in front. If ⌥R, ⌥S or ⌥H sometimes types a character (macOS can turn ⌥ + letter into characters such as ®), switch to ⌃⌥R and so on.
6. **System load:** watch CPU in Activity Monitor during a 30-minute call.
7. **Screen sharing:** check whether the overlay shows in Zoom, Meet, Teams and OBS, with Hide from screen sharing on and off.
8. **Languages:** a call in a language other than English, including the speech model download and its progress.

## Architecture

```
System audio ──► Core Audio process tap ──► SpeechTranscriber (Them) ──┐
Mic ───────────► AVAudioEngine + voice processing ──► SpeechTranscriber (You) ──┤
                                                                          ▼
                                                   TranscriptStore (Them/You turns)
                                                                          │ ⌥Space
                                                                          ▼
                     ReplyPromptBuilder ──► Claude Messages API (streaming, prompt cache)
                                                                          │
                                                                          ▼
                                             Overlay (non-activating NSPanel)
```

Audio is never written to disk and never leaves the Mac. What is sent to Anthropic is described by `PrivacyNote.summary` (see [docs/COPY.md](docs/COPY.md#privacy-statement)).

```
Packages/VibeCore/        Cross-platform logic, tested on Linux and macOS
  Transcript/             Turn grouping, reply target, text echo filter
  Audio/                  EchoGate (mutes the call's voice leaking from speakers into the mic), stream states
  Prompt/                 Output rules, layered prompt with cache breakpoints
  Claude/                 HTTP + SSE streaming client (there's no official Swift SDK)
  Recap/                  Structured recap (JSON schema), split up for long meetings
  Models/                 Meeting record, languages, styles, replies
  Storage/                One JSON file per meeting
  vibe-latency/           Latency CLI
VibeMeeting/              The macOS app (SwiftUI + AppKit)
  Audio/ Speech/          Process tap, mic, SpeechAnalyzer
  Session/                Runs one meeting
  Overlay/                Floating panel, subtitles, response cards, reply bar
  Setup/ History/ Settings/ Onboarding/ Diagnostics/
  Localizable.xcstrings   App text (see Localization)
  InfoPlist.xcstrings     Permission prompts
project.yml               XcodeGen spec
```

### Prompts and latency

Every reply is one streaming request. The prompt goes from the most static part to the most dynamic, with four cache breakpoints:

1. Output rules and About me (`system`) ← cached
2. Meeting context (text and screenshots) ← cached
3. Style (preset, meeting instructions, goal, language) ← cached
4. Earlier transcript, in finished chunks of 12 turns ← cached at the last chunk
5. Recent turns, target, move and Steer (not cached). **Ask questions** uses exactly the same prefix 1–4 and differs only here, so it's as fast as a reply.

So a reply sees the whole meeting, not only the last few sentences. It answers the last thing the other side said first, then picks up earlier questions or points that are still open. Finished transcript chunks never change, so each reply reads the previous reply's cache and only writes the new chunk. Very long meetings (more than about 60,000 characters of earlier transcript) drop the oldest chunks.

The cache is warmed with a `max_tokens: 0` request at **Start listening** and kept warm about every 4.5 minutes during the meeting. Changing the style or adding context only rewrites the parts after it.

Meeting content (transcript, context files, screenshots) is data, never instructions: the rules say so, and tests check that it stays inside its own tags.

### Design decisions

- **Models.** Replies use **Claude Haiku 5.5** with thinking off, for the fastest first word. Recaps use **Claude Opus 5.5** with the server-side refusal fallback. Both can be changed in Settings; `vibe-latency` results decide the defaults.
- **Storage is JSON files, not SwiftData.** One file per meeting in `~/Library/Application Support/VibeMeeting/Sessions` (development builds: `VibeMeeting Dev/Sessions`). It's testable off the Mac, easy to read, and deleting a meeting really deletes the file. Each file has a format version (`schemaVersion`): a file from a newer version opens read-only, and files that can't be read are listed in the main window instead of disappearing. Every new field decodes with `decodeIfPresent`, so older meetings keep loading.
- **Hide from screen sharing** is off by default. Apple now treats `NSWindow.sharingType = .none` as legacy, and screen-sharing apps built on ScreenCaptureKit (macOS 15 and later) may still capture the overlay, so the copy never promises it's hidden. Turning it on shows a disclaimer first (see README.md, "Use it honestly").
- **The call's voice leaking into the mic (speakers).** Two layers, both on by default:
  - `EchoGate` compares the mic's level pattern with the call audio. Where the mic carries only the other side's voice from the speakers, it's muted for the **You** transcription only; the call itself isn't affected. When you talk over them, your voice is louder than the expected leak, so it gets through. It can be turned off in Settings → Audio → **Remove the call's voice from my mic**. Its state (lag, levels, seconds muted) is in Audio check and the report.
  - `EchoFilter` drops **You** text that copies **Them**: near-verbatim copies, and, for English calls, badly misheard ones too ("women's healthies" for "Yemen's Halbies"). Words are aligned one by one (same word, similar sound, order) and only the echoed part is removed, so a "Yeah okay" in front stays. Answers that reuse some of their words are kept.
- **Echo cancellation is off by default.** macOS voice processing turns down every other app (the call included) and can make the call app's mic quieter. When it's on, the app uses it except with Bluetooth headphones, AirPods or USB headsets; the 3.5 mm headphone port still counts as possibly speakers. If it fails, the app falls back to the plain mic and says why in the overlay. With voice processing, macOS splits the mic into several channels and the processed voice is channel 0, so the app takes only that one.
- **Hotkeys are active only during a meeting,** so ⌥Space works normally in other apps.
- **Pre-draft** (the optional M3 experiment) isn't built.
- **Distribution** (Developer ID and notarization) isn't set up yet. Until it is, testers build from source with a saved Team.

## Localization

- English is the development language (`developmentLanguage: en` in `project.yml`, `CFBundleDevelopmentRegion` in Info.plist). Nothing is translated yet.
- App text goes through `VibeMeeting/Localizable.xcstrings`; the permission prompts through `VibeMeeting/InfoPlist.xcstrings`. Both sit in `VibeMeeting/` because the target excludes `VibeMeeting/Resources/`.
- `SWIFT_EMIT_LOC_STRINGS` and `LOCALIZATION_PREFERS_STRING_CATALOGS` are on. When you build in Xcode, it adds new keys to the catalogs; commit those changes. Only plural variants and comments need editing by hand.
- After the first build in Xcode, Xcode may also list the bundle name, display name and copyright in InfoPlist.xcstrings. Mark them **Don't Translate**: the display name comes from `APP_DISPLAY_NAME`, which differs per build ("VibeMeeting Dev" for Debug). Check that the development build still shows "VibeMeeting Dev" in System Settings afterwards.
- Before you hand out a Release build (an archive or `xcodebuild`), check its English names: `plutil -p VibeMeeting.app/Contents/Resources/en.lproj/InfoPlist.strings` must not show "VibeMeeting Dev" for `CFBundleDisplayName`. If it does, delete the `CFBundleDisplayName` and `CFBundleName` entries from InfoPlist.xcstrings and build again.
- `scripts/check-catalogs.py` (also in CI) checks that the catalogs are valid JSON and that the English permission prompts in InfoPlist.xcstrings match Info.plist. Keys Info.plist sets from build settings (the bundle and display names) differ per build, so it skips them.
- How to write strings that can be translated: [docs/COPY.md](docs/COPY.md).

## Logging and diagnostics

Logs use `os.Logger` with the bundle ID as subsystem and never contain transcript text, context or replies. To follow them:

```bash
log stream --predicate "subsystem == \"$(scripts/bundle-id.sh debug)\""
```

**Audio check → Copy report** copies the diagnostics (audio formats, buffer counts, errors, permissions, signing, languages) without any transcript text. During a meeting the same panel is behind the stethoscope button in the overlay.

## Versions and releases

Versions follow [Semantic Versioning](https://semver.org/): MAJOR for changes that break old data or how the app is used, MINOR for features, PATCH for fixes. Each version has a git tag `vX.Y.Z`, and the running version shows in the menu bar menu and in Settings → General.

To release:

1. Write the changes under **[Unreleased]** in [CHANGELOG.md](CHANGELOG.md), in English. They may still be uncommitted; the release commit takes them.
2. Run `scripts/release.sh 0.7.0` (with the new version). It moves the Unreleased notes under the new version, sets `MARKETING_VERSION` and the next `CURRENT_PROJECT_VERSION` in `project.yml`, adds the compare link (from the `origin` remote), commits "Release X.Y.Z" and tags `vX.Y.Z`. It refuses a version that exists already or isn't newer.
3. Push: `git push origin HEAD --follow-tags`. If the release was made somewhere else, `scripts/tag-versions.sh` creates the missing tags.

Signed, notarized downloads (Developer ID) come later; see the roadmap in [docs/PRD.md](docs/PRD.md).

## Rollback

Once after `git pull`, create the version tags on your Mac:

```bash
scripts/tag-versions.sh
```

Then switch to the version you want:

```bash
git checkout v0.4.0          # the version you want
xcodegen generate            # then ⌘R in Xcode
```

Without tags, use the commit in the version's heading in CHANGELOG.md (`git checkout 06c13a0`); for releases (0.5.0 and later) it's the "Release X.Y.Z" commit.

To go back to the latest version:

```bash
git checkout claude/admiring-archimedes-ihmqku
git pull
xcodegen generate
```

Notes:

- A rollback never deletes meeting files. Versions after 0.6.0 list meetings they can't read and open meetings from a newer version read-only. Version 0.6.0 and earlier just leave a meeting they can't read out of History until you update. But if an older version saves a newer meeting again (for example when you rename it or create its recap again), what it doesn't know about is lost. The **Compatibility** notes in CHANGELOG.md say what for each version.
- Versions up to 0.6.0 run under the bundle ID from before the Djavaweb identity, with the settings, Keychain key and permissions they had there. They read meetings from `~/Library/Application Support/VibeMeeting`, so meetings saved by VibeMeeting Dev don't show in them.
- From 0.2.0 on, the signing Team (`Configs/Local.xcconfig`) doesn't change when you switch versions, so the audio permission stays.
- v0.1.0 doesn't read `Configs/Local.xcconfig`. After `xcodegen generate`, pick the same Team by hand in the VibeMeeting target → Signing & Capabilities before ⌘R. Without a Team the build is ad hoc and system audio is silent. If system audio is then silent in a version from 0.2.0 to 0.6.0, run `tccutil reset AudioCapture` with the bundle ID from before the Djavaweb identity (`IdentityMigration.legacyBundleID`) and allow it again. The latest version has its own bundle ID and isn't affected.
- Versions 0.1.0 to 0.4.0 were tagged later. Builds of them show 0.1.0 in the app, because the version number is only set from 0.5.0 on.
- To get the tags on GitHub too, run `git push origin --tags` from your Mac.

## Documentation

- [README.md](README.md) is for people who use the app, in English; [README.id.md](README.id.md) is its Indonesian translation. English is the source: change README.md first, then the translation.
- [CHANGELOG.md](CHANGELOG.md) is in English and written for users. Developer details go here.
- [docs/COPY.md](docs/COPY.md): voice, glossary and translation-ready strings.

## Comparing speech engines

`scripts/asr-compare.sh "<YouTube URL>" [minutes]` transcribes the first minutes of a video with human-made English subtitles twice, with Apple's on-device engine (via [yap](https://github.com/finnvoor/yap)) and with NVIDIA Parakeet TDT 0.6B v3 (via [parakeet-mlx](https://github.com/senstella/parakeet-mlx)), and prints each one's word error rate against the subtitles. It installs its tools with Homebrew and uv and works in `~/Desktop/asr-test/<video id>`; the app is not involved.

To score the app itself, copy a meeting's transcript (Transcript → Copy transcript, then `pbpaste > app.txt`):

- `scripts/asr-compare.sh --score <video id> app.txt` scores the Them lines of a meeting that played the same video, next to the two engines.
- `scripts/asr-compare.sh --against reference.txt app.txt [them|you]` scores the Them (or You) lines against any text known to be what was said, such as a voice assistant's replies copied from its chat, or a passage read aloud into the mic (`scripts/asr-passage.txt` is one, with numbers kept small so number formatting doesn't count as errors).

`'d` and `'s` after a pronoun match either full form, so "I'd" against "I had" is not counted as an error.
