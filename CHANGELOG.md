# Changelog

Semua perubahan penting di VibeMeeting dicatat di sini. Formatnya mengikuti [Keep a Changelog](https://keepachangelog.com/id-ID/1.1.0/), dan nomor versinya mengikuti [Semantic Versioning](https://semver.org/lang/id/):

- **MAJOR (x.0.0)**: perubahan besar yang membuat data atau cara pakai lama tidak cocok lagi.
- **MINOR (0.x.0)**: fitur baru.
- **PATCH (0.0.x)**: perbaikan saja.

Setiap versi punya tag git `vX.Y.Z`. Versi yang sedang jalan terlihat di menu bar dan di Settings → General.

## Cara rollback

Sekali saja setelah `git pull`, buat tag versinya di Mac-mu:

```
scripts/tag-versions.sh
```

Lalu pindah ke versi yang diinginkan:

```
git checkout v0.4.0          # ganti dengan versi yang diinginkan
xcodegen generate            # lalu ⌘R di Xcode
```

Tanpa tag juga bisa: `git checkout 06c13a0`, memakai commit yang tertulis di judul versi di bawah. Untuk versi rilis (0.5.0 ke atas), commit-nya adalah commit "Release X.Y.Z".

Untuk kembali ke versi terbaru:

```
git checkout claude/admiring-archimedes-ihmqku
git pull
xcodegen generate
```

Catatan:
- File meeting tidak pernah dihapus saat rollback. Kalau versi lama tidak bisa membaca meeting dari versi yang lebih baru, meeting itu hanya tidak tampil di History, lalu muncul lagi setelah update. Tapi kalau versi lama menyimpan ulang meeting yang lebih baru (misalnya rename atau membuat ulang rekap), data dari fitur yang belum dikenalnya ikut hilang. Detail per versi ada di bagian **Kompatibilitas** di bawah.
- Mulai 0.2.0, Team signing (`Configs/Local.xcconfig`) tidak ikut berubah saat pindah versi, jadi izin audio tetap aman.
- v0.1.0 belum membaca `Configs/Local.xcconfig`. Setelah `xcodegen generate`, pilih Team yang sama secara manual di target VibeMeeting → Signing & Capabilities sebelum ⌘R. Tanpa Team, build-nya ad-hoc dan audio sistem hanya hening. Kalau audio jadi hening setelah kembali ke versi terbaru, jalankan `tccutil reset AudioCapture "$(scripts/bundle-id.sh debug)"` lalu beri izin lagi.
- Versi 0.1.0 sampai 0.4.0 ditandai belakangan. Build dari versi-versi itu menampilkan 0.1.0 di app, karena nomor versi baru diisi sejak 0.5.0.
- Supaya tag-nya juga ada di GitHub, jalankan `git push origin --tags` dari Mac-mu.

## Cara merilis versi baru

1. Tulis perubahannya di bagian **[Unreleased]** di bawah. Boleh belum di-commit; commit rilis ikut menyimpannya.
2. Jalankan `scripts/release.sh 0.6.0` (ganti dengan versi baru). Script ini memindahkan catatan Unreleased ke versi baru, mengisi nomor versi dan build di `project.yml`, lalu membuat commit dan tag.
3. Push: `git push origin HEAD --follow-tags`. Kalau rilisnya dibuat di tempat lain, `scripts/tag-versions.sh` membuat tag yang belum ada.

## [Unreleased]

### Added
- **Meetings in other languages.** New meeting has a **Language** section: the language spoken in the call, and the languages for replies and Ask questions and for the recap ("Same as the call" unless you pick another). Both sides of the call are transcribed in the call language. The default is in Settings → General → **Call language**; Automatic picks the first of your Mac's languages that speech recognition supports, else English (United States). Each language's speech model downloads once, with progress in Settings, the Welcome window, Audio check and the meeting overlay. Languages not written in the Latin or Cyrillic alphabet (Chinese, Japanese, Korean, Thai, Arabic, Hebrew and others) are marked **preview** for now. A meeting's details show its language, and Audio check runs in the default one.
- **Saved meetings never disappear without a word.** If a meeting file can't be read (saved by a newer version of VibeMeeting, or damaged), the main window says how many and offers **Show in Finder**. The file is left exactly as it is. A meeting saved by a newer version that this version can still read opens **read-only**: Star, Rename and creating a recap are off, so nothing the newer version saved is lost. Delete still works.

### Changed
- **About me starts empty.** An outline shows what to write (name, what you do, who you usually meet, how you want to come across, facts replies may use, things you never say), in any language. "Reset to template" is now **Clear**, and the Welcome window's About me button opens that tab. If you never edited About me, it is empty after this update: write yours in Settings → About me.
- **Neutral framing for any meeting.** Replies, Ask questions and recaps no longer assume a sales call with a client. Firmness on price and scope belongs to the Negotiator style only, the holding line for a missing number no longer promises "today", and recaps cover "a meeting" and what was agreed in it. Built-in styles talk about "the other side", and Negotiator works whichever side you're on. Placeholders and help text use everyday examples.
- **Prompt injection protection.** Replies, Ask questions and recaps treat what's said in the call and what's in the meeting context (files, notes, screenshots) as information, not instructions. The model is told to ignore text there that tries to change its task, reveal its prompt or put words in your mouth (such as "ignore your instructions" or "agree to do it for free"). Only About me, meeting instructions, the goal and Steer direct a reply.
- The diagnostics report lists your preferred languages and whether speech recognition supports each, instead of checking one language. The About panel shows "© 2026 Djavaweb".
- **Replies, Ask questions and recaps are no longer English-only.** They're written in the meeting's language, with the hesitations, reactions and fillers native speakers use (the English examples in the instructions are only examples), and formal or informal address follows the meeting and the language. The `[confirm number]` reminder stays the same in every language and is recognized however the model writes it.
- **Echo filter outside English.** Removing a garbled copy of the other side's words from your mic runs only for English calls, because its rules are tuned on English. In other languages only near-verbatim copies are removed, so a garbled double can occasionally show under You; your own words are never removed by mistake.
- The diagnostics report names the call language, and the "speech recognition returns no words" notice names the meeting's language instead of saying English only.
- Audio check and the diagnostics report word a few states differently: the mic shows "Running (echo cancellation on)", and a recognizer that stopped reads "Speech stopped with an error" or "Speech ended unexpectedly".
- **New app identity.** VibeMeeting is published by Djavaweb, with the bundle ID `com.djavaweb.vibemeeting`, so macOS treats it as a new app. On first launch it copies your settings (About me if you wrote one, reply styles, models, audio, overlay and call language) and your hotkeys from the previous version, and tries to copy your Claude API key from the Keychain. macOS may ask you to allow that; if you don't, or it fails, enter the key again in Settings → General. macOS also asks for microphone and system audio permission again, so the Welcome window shows once more. Your meetings stay where they were, in `~/Library/Application Support/VibeMeeting`.
- **Development builds are a separate app.** A build run from Xcode is **VibeMeeting Dev** (`com.djavaweb.vibemeeting.debug`), with its own settings, Keychain key, permissions and meetings folder (`~/Library/Application Support/VibeMeeting Dev`), so it never touches a release install. It starts with no meetings: to see earlier ones in it, copy the files from `VibeMeeting/Sessions` into `VibeMeeting Dev/Sessions`. The menu shows which one is running, and the diagnostics report names the bundle ID.
- **Hide from screen sharing is off by default.** Turning it on in Settings → Overlay first explains it: some screen-sharing apps may still capture the overlay, VibeMeeting doesn't support use meant to deceive people (such as covert help in interviews or exams where that isn't allowed), you're responsible for following the law and getting consent from others in the call, and Djavaweb isn't responsible for how you use it. The section footer says the same in short. A choice you saved before is kept; if you never changed it, it's now off.
- For developers: `scripts/bundle-id.sh` prints the release or `debug` bundle ID from project.yml (for example for `tccutil reset`), `scripts/release.sh` takes the compare-link URL from the `origin` remote, and the CI check for personal terms now also covers project.yml, scripts and Configs.

### Compatibility
- Older meetings load as before. Meeting files now carry a format version (3), action item owners are saved as `you`/`them` instead of the on-screen label, and each meeting saves its languages. Meetings saved before languages existed load as English (United States) for the call, replies and recap, which is what they were. A reply move or kind this version doesn't know (from a newer version) loads as a plain Reply instead of hiding the meeting.
- Rollback across the identity change: earlier versions run under the previous bundle ID, with the settings, Keychain key and permissions they had there (nothing is removed from it, and nothing changed in the new identity carries back). They read meetings from `~/Library/Application Support/VibeMeeting`, the folder the release build uses, so meetings saved by VibeMeeting Dev don't show in them.
- Rollback: every earlier version reads the new owner values correctly. Version 0.6.0 and earlier ignore the format version: they open these meetings normally, but if they save one again (rename, star, recap), its languages are dropped and it comes back as English (United States); the transcript and recap are kept. A development build from between 0.6.0 and this change (format 2) opens them read-only. The notes for earlier versions below still apply.

### Diubah
- **Halaman meeting didesain ulang** mengikuti mockup: kaca gelap dengan dua kartu yang hampir selebar jendela.
  - **Header:** tombol jendela, ikon dan nama app, menu gaya reply, timer `00:00:00`, Audio check, Add context, Settings, dan tombol merah End meeting.
  - **Kolom Transcript:** waveform live di samping judul. Bar di atas garis adalah audio call, di bawah garis mic-mu. Teks status hanya muncul kalau ada masalah ("Reconnecting…", "Paused"). Ucapan mereka tampil dalam bubble dengan titik, nama, dan jam; ucapanmu tampil sebagai teks redup tanpa bubble.
  - **Kolom Responses:** goal meeting di bawah judul, dan kartu respon dengan jam serta tombol kecil.
  - **Bar bawah:** chip Answer, Clarify, Add, Push back, dan Ask questions dengan ikon. Chip menyala selama respon intent itu ditulis. Kolom Steer berikon ✨ (klik di mana saja di kotaknya untuk mengetik), tombol Reply bergradien, dan daftar hotkey.
  - Overlay selalu gelap, apa pun tema macOS-nya.
  - Ukuran awal 860×680 (Compact 420×640). Kalau sempit, label chip dipendekkan dulu dan hotkey yang jarang dipakai disembunyikan. Di mode Compact, script yang panjang bisa di-scroll dan bar Reply tidak pernah terdorong keluar.
- Tombol jendela overlay: merah dan kuning menyembunyikan overlay (meeting tetap jalan; tampilkan lagi dengan ⌥H atau menu bar). Hijau mengganti antara mode split dan Compact (juga lewat Settings → Overlay).
- **Script balasan terdengar seperti orang ngomong beneran.** Ada jeda ("um", "well..."), reaksi spontan, dan koreksi di tengah kalimat, tapi seperlunya dan tidak berpola. Isinya tetap jelas dan konkret, dan angka, harga, tanggal, atau nama selalu diucapkan sekali dengan tepat, tanpa ragu atau dikoreksi. Semua gaya bawaan (Friendly Pro, Consultant, Negotiator, Tech Explainer, Short & Sweet, Diplomatic) kini punya cara bicara masing-masing. Ask questions dan Shorter ikut natural, dan kalimat pertama yang tebal tidak lagi terpotong di "...".
- Goal, instruksi meeting, About me, konteks, dan Steer boleh ditulis dalam bahasa apa pun yang dikenali model (atau campur). Nama, merek, dan angka disalin persis. (Bahasa script, Ask questions, dan rekap: lihat "Meetings in other languages" di atas.)
- **Filter gema lebih pintar.** Suara lawan bicara yang bocor ke mic dan ditranskripsi dengan salah dengar (misalnya "women's healthies" untuk "Yemen's Halbies") tidak lagi muncul sebagai "You", baik di teks live maupun teks final. Hanya bagian yang benar-benar gema yang dibuang: "Yeah okay" di depannya atau kalimatmu setelahnya tetap ada, dan jawaban yang memakai ulang kata-kata mereka ("Yes, I can do it in two weeks, no problem.") tetap utuh.
- **Jendela New meeting dan Add context** memakai kaca gelap sesuai mockup.
  - Goal maksimal 500 karakter dan instruksi meeting maksimal 300, masing-masing dengan penghitung.
  - Konteks: area drop file, lalu tab Paste text, Paste screenshot, dan **Add from clipboard** (baru: langsung menambahkan file, gambar, atau teks dari clipboard). File di atas 50 MB ditolak dengan pesan yang jelas.
  - Gaya balasan tampil sebagai kartu berisi deskripsi singkatnya, dengan link **Manage styles** yang membuka tab Reply styles di Settings.
- **Jendela utama** didesain ulang dengan kaca gelap.
  - Sidebar: pencarian (⌘K), filter All / Recent (7 hari) / Recaps / Starred, dan daftar meeting per hari (Today, Yesterday, lalu tanggal). Tiap meeting punya menu "…" untuk Star, Rename, dan Delete.
  - Tanpa meeting terpilih: tombol **New meeting**, dan menu panah di sebelahnya untuk **Start now** (langsung mulai tanpa setup, bisa pilih gaya), serta Audio check.
  - Meeting bisa diberi bintang. Tombol bintang dan hapus ada di bagian atas halaman detail meeting.

### Kompatibilitas
- Meeting lama tetap terbaca. Rollback ke versi di bawah ini: bintang tidak tampil, dan hilang kalau meeting itu disimpan ulang di versi lama (rename atau buat ulang rekap).

## [0.6.0] - 2026-10-12

### Ditambahkan
- **Overlay split 50:50.** Transkrip di kiri, semua respon meeting (Reply dan Ask questions) di kanan, dari yang terlama sampai yang terbaru. Daftar respon tersimpan dan bisa di-scroll selama meeting, ikut turun saat ada respon baru, dan berhenti mengikuti kalau kamu scroll ke atas ("Jump to latest" untuk kembali). Respon yang baru kamu minta (Reply, Ask questions, Regenerate, Shorter) selalu langsung terlihat. Ukuran overlay yang kamu atur disimpan per meeting, dan overlay yang ditaruh di kiri layar tetap di kiri saat ganti mode. Respon terbaru disorot dan punya tombol Regenerate/Shorter; semua respon bisa di-Copy. Mode Compact (satu kolom sempit) tetap ada lewat tombol di header atau Settings → Overlay.
- **App icon dan warna brand.** Logo VibeMeeting jadi app icon (semua ukuran macOS) dan ikon menu bar (bar gelombang; dalam lingkaran saat meeting berjalan). Warna dari logo (cyan, biru, ungu, magenta) dipakai sebagai aksen saja: tombol utama dan sorotan pakai biru brand, meter level dan garis tipis di atas overlay pakai gradasinya, ikon goal dan Ask questions pakai ungu. Warna status (hijau/oranye/merah) tetap seperti biasa.
- `scripts/tag-versions.sh`: membuat tag `vX.Y.Z` untuk semua versi di changelog, supaya rollback bisa pakai `git checkout vX.Y.Z`.
- `scripts/release.sh` menolak versi yang sudah ada atau lebih lama, dan menerima catatan Unreleased yang belum di-commit.

## [0.5.0] - 2026-10-12

### Ditambahkan
- **Goal meeting.** Kolom Goal di New meeting, opsional. Goal tampil di bawah header overlay dan bisa diubah kapan saja selama call. Setiap Reply tetap menjawab dulu, lalu (kalau pas) mengambil satu langkah ke arah goal. Steer tetap diutamakan.
- **Ask questions** (tombol, atau ⌥Q). Memberi 3–5 pertanyaan singkat untuk lawan bicara supaya arah meeting jelas dan mengarah ke goal. Pertanyaan yang sudah terjawab dilewati, dan fitur ini bisa dipakai sebelum ada yang bicara. Steer memfokuskan pertanyaannya. Klik satu pertanyaan untuk menyalinnya, Regenerate untuk pertanyaan lain. Kecepatannya sama dengan Reply karena memakai cache prompt yang sama.
- Rekap menyebut seberapa jauh goal tercapai dan apa yang masih kurang. Goal juga ikut di export Markdown.
- Nomor versi tampil di app, plus changelog, tag versi, dan `scripts/release.sh`.

### Diubah
- Angka di goal, instruksi meeting, dan transkrip boleh dipakai langsung di script tanpa [confirm number].
- Ask questions tidak dihitung di statistik Reply (regenerate rate, latency kata pertama).

### Kompatibilitas
- Meeting lama tetap terbaca.
- Rollback ke versi di bawah 0.5.0: meeting yang memakai Ask questions tidak tampil di History versi lama. File-nya tetap ada dan muncul lagi setelah update.
- Rollback ke versi di bawah 0.5.0: meeting yang punya Goal tetap tampil, tapi tanpa goal dan progres goal. Jangan rename meeting itu atau buat ulang rekapnya di versi lama, karena file-nya akan disimpan ulang tanpa goal dan progres goal, dan keduanya tidak kembali setelah update.

## [0.4.0] - 2026-10-12 (commit 06c13a0)

### Ditambahkan
- **Peredam suara bocor (EchoGate).** Saat memakai speaker, mic ikut mendengar lawan bicara sehingga teks "You" dobel. App membandingkan level mic dengan audio call, lalu membisukan mic khusus untuk transkrip "You" di bagian yang isinya hanya suara mereka. Call-nya tidak terpengaruh, dan kalau kamu bicara bersamaan suaramu tetap masuk. Aktif secara default dan bisa dimatikan di Settings → Audio → *Remove the call's voice from my mic*. Status peredam ada di Audio check dan di report.

### Diperbaiki
- Setelah review: peredam lepas dengan cepat saat headphone dicolok atau volume speaker diturunkan, jeda antar suku kata saat bicara bersamaan tidak terpotong, noise latar di audio call tidak membuat peredam mati, dan kenaikan volume cepat dikenali.

## [0.3.0] - 2026-10-12 (commit ce3ee33)

### Ditambahkan
- **Reply membaca seluruh percakapan.** Script menjawab hal terakhir yang mereka katakan dulu, lalu menanggapi pertanyaan atau poin sebelumnya yang belum terjawab, dan tetap konsisten dengan yang sudah kamu ucapkan. Transkrip lama dikirim per potongan yang di-cache, jadi tetap cepat.

### Diubah
- Subtitle selalu mengikuti pembicaraan, dan auto-scroll berhenti hanya kalau kamu scroll ke atas.
- Filter echo teks juga menangkap kata yang salah dengar, tidak menampilkan teks live yang meniru "Them", dan menghapus baris "You" dobel yang muncul lebih dulu.

### Diperbaiki
- Status "Reconnecting" tidak lagi macet. Hint untuk app sumber yang salah pilih punya notifikasi sendiri. Notifikasi echo cancellation hilang saat fitur itu jalan lagi.
- Rekap tidak lagi menimpa transkrip final kalau dibuat saat meeting masih disimpan.
- Quit saat "Saving…" tidak lagi membuat meeting baru yang tertinggal.

## [0.2.1] - 2026-10-12 (commit 45e1955)

### Diperbaiki
- Peringatan izin palsu saat call sedang hening (muted, lobby). Diagnosis "hanya hening" sekarang hanya muncul kalau belum pernah ada suara sama sekali, dan izin dicek dengan probe seperti di Chromium.
- Notifikasi overlay: diagnosis yang spesifik menggantikan yang umum, dan notifikasi yang ditutup tidak muncul lagi sampai kondisinya berubah.
- Echo cancellation sekarang bisa dipakai di port headphone 3.5 mm yang tersambung ke speaker.
- Mic otomatis menyala lagi saat dicolok setelah sempat gagal.
- Urutan End, Quit, dan New meeting tidak lagi kehilangan data.
- Audio check yang dihentikan saat prompt izin tidak lagi jalan sendiri.

## [0.2.0] - 2026-10-12 (commit 9e98127)

### Ditambahkan
- **Audio check** (menu bar) dan tombol stetoskop di overlay: level, format, jumlah buffer, verdict per tahap, dan **Copy report** tanpa isi transkrip. Report meeting terakhir disimpan.
- Peringatan saat build tidak punya signing Team, karena macOS lalu hanya memberi audio hening.

### Diperbaiki
- Audio lawan bicara (system audio) tidak masuk: tap dibuat ulang tanpa sub-device, dengan fallback clock, rebuild yang dibatasi, dan start/stop tanpa memblokir thread.
- Suara sendiri ada level-nya tapi tidak ditranskripsi: audio mic dengan voice processing sekarang diambil dari channel 0.
- Echo cancellation default mati, karena voice processing mengecilkan volume app lain termasuk suara call.

## [0.1.0] - 2026-10-12 (commit 70513cd)

### Ditambahkan
- Versi pertama: subtitle live untuk lawan bicara (system audio) dan kamu (mic), Reply dengan Claude (⌥Space) beserta intent, Steer, Regenerate, dan Shorter, konteks meeting (PDF/DOCX/teks/gambar), preset gaya, rekap setelah meeting dengan export Markdown, history lokal, dan Settings (API key di Keychain, model, hotkey, About me).

[Unreleased]: https://github.com/ardhofortana/vibemeeting/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ardhofortana/vibemeeting/releases/tag/v0.1.0
