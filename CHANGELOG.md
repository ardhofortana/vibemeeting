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
- Meeting yang tersimpan tidak pernah dihapus saat rollback. Kalau versi lama tidak bisa membaca meeting dari versi yang lebih baru, meeting itu hanya tidak tampil di History, lalu muncul lagi setelah update. Detail per versi ada di bagian **Kompatibilitas** di bawah.
- Team signing (`Configs/Local.xcconfig`) tidak ikut berubah saat pindah versi, jadi izin audio tetap aman.
- Versi 0.1.0 sampai 0.4.0 ditandai belakangan. Build dari versi-versi itu menampilkan 0.1.0 di app, karena nomor versi baru diisi sejak 0.5.0.
- Supaya tag-nya juga ada di GitHub, jalankan `git push origin --tags` dari Mac-mu.

## Cara merilis versi baru

1. Tulis perubahannya di bagian **[Unreleased]** di bawah.
2. Jalankan `scripts/release.sh 0.6.0` (ganti dengan versi baru). Script ini memindahkan catatan Unreleased ke versi baru, mengisi nomor versi dan build di `project.yml`, lalu membuat commit dan tag.
3. Push: `git push origin HEAD --follow-tags`. Kalau rilisnya dibuat di tempat lain, `scripts/tag-versions.sh` membuat tag yang belum ada.

## [Unreleased]

### Ditambahkan
- **Overlay split 50:50.** Transkrip di kiri, semua respon meeting (Reply dan Ask questions) di kanan, dari yang terlama sampai yang terbaru. Daftar respon tersimpan dan bisa di-scroll selama meeting, ikut turun saat ada respon baru, dan berhenti mengikuti kalau kamu scroll ke atas ("Jump to latest" untuk kembali). Respon terbaru disorot dan punya tombol Regenerate/Shorter; semua respon bisa di-Copy. Mode Compact (satu kolom sempit) tetap ada lewat tombol di header atau Settings → Overlay.
- **App icon dan warna brand.** Logo VibeMeeting jadi app icon (semua ukuran macOS) dan ikon menu bar (bar gelombang; dalam lingkaran saat meeting berjalan). Warna dari logo (cyan, biru, ungu, magenta) dipakai sebagai aksen saja: tombol utama dan sorotan pakai biru brand, meter level dan garis tipis di atas overlay pakai gradasinya, ikon goal dan Ask questions pakai ungu. Warna status (hijau/oranye/merah) tetap seperti biasa.
- `scripts/tag-versions.sh`: membuat tag `vX.Y.Z` untuk semua versi di changelog, supaya rollback bisa pakai `git checkout vX.Y.Z`.

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

[Unreleased]: https://github.com/ardhofortana/vibemeeting/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/ardhofortana/vibemeeting/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ardhofortana/vibemeeting/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ardhofortana/vibemeeting/releases/tag/v0.1.0
