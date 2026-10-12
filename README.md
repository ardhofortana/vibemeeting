# VibeMeeting

Asisten meeting pribadi untuk macOS. VibeMeeting mendengarkan lawan bicara di app call mana pun (Zoom, Meet, Teams, Slack, WhatsApp) tanpa bot, menampilkan subtitle live, dan menyiapkan script jawaban siap baca saat kamu menekan **⌥Space**. Setelah meeting selesai, app membuat rekap berisi ringkasan, poin penting, keputusan, action items, dan pertanyaan terbuka.

Spesifikasi lengkap ada di [`docs/PRD.md`](docs/PRD.md).

> **Status:** kode v1 lengkap (F1–F8). Paket inti `VibeCore` sudah dites (62 unit test). Lapisan app macOS dikompilasi di CI dan **belum diuji di Mac sungguhan**, jadi jalankan dulu checklist M0 di bawah.

## Yang dibutuhkan

- Mac dengan **macOS 26** atau lebih baru. Transkripsi on-device (SpeechAnalyzer) baru ada di macOS 26.
- **Xcode 26**
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- API key Claude dari [platform.claude.com](https://platform.claude.com)

## Build & jalankan

```bash
git clone https://github.com/ardhofortana/vibemeeting.git
cd vibemeeting
xcodegen generate          # membuat VibeMeeting.xcodeproj dari project.yml
open VibeMeeting.xcodeproj
```

Di Xcode, buka target **VibeMeeting → Signing & Capabilities** dan pilih Team kamu (Apple ID gratis/Personal Team cukup). Lalu simpan Team itu supaya tidak hilang setiap `xcodegen generate`:

```bash
scripts/save-signing-team.sh                        # membaca Team yang kamu pilih di Xcode
xcodegen generate
tccutil reset AudioCapture com.ardhofortana.VibeMeeting   # sekali, supaya macOS minta izin lagi untuk build yang sudah bertanda tangan Team
```

Lalu Run (⌘R). Ikon gelombang akan muncul di menu bar.

> **Kenapa Team penting:** tanpa Team, Xcode menandatangani build secara ad-hoc ("Sign to Run Locally"). macOS mengikat izin System Audio Recording ke tanda tangan itu, jadi setiap rebuild dianggap app baru. Toggle di Privacy & Security tetap terlihat menyala, tapi audio sistem yang diterima hanya hening.

### Audio check

Menu bar → **Audio check…** menjalankan seluruh jalur audio → transkripsi tanpa meeting. Putar video YouTube berbahasa Inggris dan ucapkan beberapa kalimat bahasa Inggris. Kedua kolom (Them dan You) harus menunjukkan level dan teks dalam satu-dua detik. **Copy report** menyalin diagnostik (format audio, jumlah buffer, error, status izin, tanda tangan build) tanpa isi transkrip. Saat meeting berjalan, diagnostik yang sama ada di tombol stetoskop di overlay.

Saat pertama kali dibuka, jendela Welcome memandu tiga hal:

1. **Allow audio capture.** macOS akan meminta izin mikrofon dan izin rekam audio sistem, lalu model speech bahasa Inggris on-device diunduh.
2. **API key Claude.** Key disimpan di Keychain.
3. **About me.** Template sudah terisi (Detheme, sejak 2013, stack WordPress dan sebagainya). Lengkapi link portfolio, link booking, milestone, dan aturan harga di Settings → About me.

## Cara pakai

| Fase | Langkah |
| --- | --- |
| Sebelum | Menu bar → **New meeting** → isi nama (opsional), drop file atau paste konteks → pilih **Reply style** → **Start listening** |
| Selama | Subtitle mengalir di overlay. Tekan **⌥Space** setelah lawan bicara selesai bicara. Klik satu giliran untuk menjadikannya target, atau klik dua kali untuk memperbaiki salah dengar |
| Setelah | **End meeting**. Rekap dibuat otomatis, lalu bisa di-**Copy as Markdown** atau di-export ke .md |

Hotkey (bisa diubah di Settings → Hotkeys, dan hanya aktif selama meeting berjalan):

| Aksi | Default |
| --- | --- |
| Reply (Auto) | ⌥Space |
| Answer / Clarify / Add / Push back | ⌥1 / ⌥2 / ⌥3 / ⌥4 |
| Steer (ketik arahan, Enter untuk generate) | ⌥⇧Space |
| Regenerate / Shorter | ⌥R / ⌥S |
| Show/hide overlay | ⌥H |

## Checklist M0 (jalankan di Mac sebelum dipakai di meeting klien)

PRD menetapkan M0 sebagai spike untuk bagian paling berisiko. Kodenya sudah ada; yang tersisa adalah validasi di hardware sungguhan.

1. **Tes inti:** `swift test --package-path Packages/VibeCore`
2. **Latensi Reply:** jalankan enam skenario PRD terhadap API sungguhan:
   ```bash
   cd Packages/VibeCore
   ANTHROPIC_API_KEY=sk-ant-... swift run vibe-latency --model claude-haiku-5-5 --model claude-opus-5-5
   ```
   Target: kata pertama ≤1,5 detik (median) dan ≤3 detik (p90), script lengkap ≤4 detik. Pakai `--context proposal.txt` dan `--about about.txt` untuk mengetes dengan konteks asli. Biaya satu run kira-kira beberapa sen.
3. **Audio lawan bicara:** buka **Audio check**, putar video YouTube, lalu pastikan teks **Them** muncul dalam ≤1 detik. Transkripsi hanya untuk bahasa Inggris.
4. **Echo tanpa headset:** pakai speaker laptop dan pastikan suara lawan tidak muncul sebagai **You**. Bila masih bocor, pakai headset atau cek Settings → Audio.
5. **Hotkey:** coba setiap hotkey saat Zoom atau Chrome sedang fokus. Bila ⌥R/⌥S/⌥H kadang malah mengetik karakter (macOS 26 bisa menyusun ⌥+huruf menjadi karakter seperti ®), ganti ke ⌃⌥R dan seterusnya.
6. **Beban sistem:** pantau CPU di Activity Monitor selama call 30 menit.
7. **Screen share:** cek apakah overlay ikut terlihat di Zoom/Meet (lihat catatan di bawah).

## Arsitektur

```
Audio sistem ──► Core Audio process tap ──► SpeechTranscriber (Them) ──┐
Mic ───────────► AVAudioEngine + voice processing ──► SpeechTranscriber (You) ──┤
                                                                          ▼
                                                   TranscriptStore (giliran Them/You)
                                                                          │ ⌥Space
                                                                          ▼
                     ReplyPromptBuilder ──► Claude Messages API (streaming, prompt cache)
                                                                          │
                                                                          ▼
                                             Overlay (NSPanel non-activating)
```

Audio tidak pernah ditulis ke disk dan tidak pernah keluar dari Mac. Yang dikirim ke Claude hanya teks: jendela transkrip terbaru, konteks, dan instruksi.

```
Packages/VibeCore/        Logika lintas platform, dites di Linux & macOS
  Transcript/             Pengelompokan giliran, target Reply, filter echo
  Prompt/                 Aturan output, susunan prompt berlapis dengan cache
  Claude/                 Klien HTTP + SSE streaming (tidak ada SDK Swift resmi)
  Recap/                  Rekap terstruktur (JSON schema), dipecah untuk meeting panjang
  Storage/                Satu file JSON per meeting
  vibe-latency/           CLI untuk gate latensi M0
VibeMeeting/              App macOS (SwiftUI + AppKit)
  Audio/ Speech/          Process tap, mic, SpeechAnalyzer
  Session/                Orkestrasi satu meeting
  Overlay/                Panel melayang, subtitle, kartu script, bar Reply
  Setup/ History/ Settings/ Onboarding/
project.yml               Spesifikasi XcodeGen
```

### Prompt & latensi

Setiap Reply adalah satu panggilan streaming. Prompt disusun dari bagian paling statis ke paling dinamis, dengan tiga cache breakpoint:

1. Aturan output + About me (`system`) ← cache
2. Konteks meeting (teks + screenshot) ← cache
3. Gaya (preset + instruksi meeting) ← cache
4. Jendela transkrip terbaru + target + intent + Steer (tidak di-cache)

Cache dipanaskan dengan request `max_tokens: 0` saat **Start listening** dan dijaga tetap hangat setiap ±4,5 menit selama meeting. Mengganti preset atau menambah konteks hanya menulis ulang bagian setelahnya.

## Keputusan yang berbeda dari PRD atau perlu kamu tahu

- **Model.** Reply memakai **Claude Haiku 5.5** dengan thinking dimatikan, karena PRD meminta model tercepat untuk Reply. Rekap memakai **Claude Opus 5.5** dengan server-side refusal fallback. Keduanya bisa diganti di Settings, dan pilihan finalnya ditentukan dari hasil `vibe-latency`. Dengan Haiku, biayanya jauh di bawah target US$1 per jam.
- **Penyimpanan memakai file JSON, bukan SwiftData.** Satu file per meeting di `~/Library/Application Support/VibeMeeting/Sessions`. Alasannya: bisa dites di luar Mac, mudah dibaca, tidak perlu migrasi skema, dan hapus berarti file benar-benar terhapus.
- **Hide from screen sharing.** Apple sekarang menganggap `NSWindow.sharingType = .none` sebagai legacy, dan screen share berbasis ScreenCaptureKit di macOS 15+ bisa tetap menangkap overlay. Opsinya tetap ada (default menyala), tapi sembunyikan overlay dengan ⌥H sebelum share screen.
- **Echo cancellation default mati.** Voice processing macOS mengecilkan volume semua app lain (termasuk call-nya) dan bisa membuat mic app call jadi lebih pelan. Sebagai gantinya, `EchoFilter` membuang teks **You** yang hampir identik dengan ucapan **Them** beberapa detik sebelumnya. Kalau dinyalakan di Settings → Audio, app hanya memakainya saat suara keluar lewat speaker dan otomatis kembali ke mic biasa kalau gagal. Dengan voice processing, macOS memecah audio mic jadi beberapa channel dan suara yang sudah diproses ada di channel 0, jadi app mengambil channel itu saja.
- **Hotkey hanya aktif selama meeting**, supaya ⌥Space tetap berfungsi normal di app lain.
- **Pre-draft** (eksperimen opsional M3) belum dibuat.
- **Distribusi** (Developer ID + notarization) belum di-setup. Untuk pemakaian pribadi, Run dari Xcode sudah cukup, asalkan Team sudah dipilih dan disimpan (lihat Build & jalankan).

## Pengembangan

```bash
swift test --package-path Packages/VibeCore      # tes inti (macOS atau Linux)

# Tes transport HTTP nyata terhadap server SSE lokal:
python3 scripts/sse_test_server.py 18777 &
VIBE_LOCAL_SSE_URL=http://127.0.0.1:18777 swift test --package-path Packages/VibeCore
```

CI (`.github/workflows/ci.yml`) menjalankan tes inti di Linux dan build app di runner macOS 26.

Log teknis memakai `os.Logger` (subsystem `com.ardhofortana.VibeMeeting`) dan tidak pernah berisi transkrip, konteks, atau script.
