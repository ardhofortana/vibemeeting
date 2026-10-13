# VibeMeeting

Asisten meeting untuk Mac. VibeMeeting mendengarkan call kamu di app call mana pun (Zoom, Google Meet, Microsoft Teams, Slack, WhatsApp, dan lainnya) tanpa menambahkan bot ke call. App ini menampilkan subtitle live untuk kedua pihak dan, saat kamu menekan hotkey, menyiapkan apa yang bisa kamu katakan berikutnya dengan gaya bicaramu sendiri. Setelah call selesai, app menulis rekap berisi poin penting, keputusan, action item, dan pertanyaan yang masih terbuka.

> Ini terjemahan dari [README.md](README.md) (bahasa Inggris). Kalau ada yang berbeda, versi bahasa Inggris yang berlaku.

[English](README.md) · [Yang baru](CHANGELOG.md) · [Untuk developer](DEVELOPMENT.md)

> **Beta gratis.** VibeMeeting diterbitkan oleh Djavaweb dan gratis selama masa beta. Mungkin masih ada yang belum mulus.

## Yang bisa dilakukan

- **Subtitle live** untuk lawan bicara (dari suara Mac-mu) dan untuk kamu (dari mikrofon), ditranskripsi di Mac-mu.
- **Jawaban lewat hotkey.** Tekan ⌥Space saat lawan bicara selesai bicara, dan VibeMeeting menyiapkan jawaban singkat yang bisa kamu baca atau ucapkan dengan kata-katamu sendiri. Jawabannya menanggapi hal yang baru mereka katakan dulu, lalu mengarah ke goal meeting-mu. Kamu bisa meminta langkah tertentu (Answer, Clarify, Add, Push back), mengetik arahan singkat (Steer), atau membuat jawabannya lebih pendek.
- **Ask questions.** Tiga sampai lima pertanyaan untuk lawan bicara, supaya meeting bergerak ke arah goal-nya.
- **Konteks.** Tambahkan file (PDF, Word, teks, Markdown), catatan, dan screenshot sebelum atau selama meeting, dan jawaban bisa memakai fakta di dalamnya.
- **Gaya bicaramu.** Tulis beberapa baris tentang dirimu di Settings → About me, lalu pilih gaya jawaban (reply style).
- **Rekap** setelah setiap meeting, termasuk seberapa jauh goal tercapai. Salin sebagai Markdown atau export.
- **Riwayat** meeting-mu, bisa dicari, tersimpan di Mac-mu.

## Yang dibutuhkan

- Mac dengan **macOS 26** atau lebih baru. Apple silicon disarankan; Mac Intel belum dites.
- **API key Anthropic** milikmu sendiri (lihat [API key dan biaya](#api-key-dan-biaya)).
- Koneksi internet untuk jawaban dan rekap. Transkripsi tetap jalan tanpa internet setelah model speech untuk bahasamu terunduh.

## Instalasi

Download yang sudah ditandatangani dan dinotarisasi sedang disiapkan untuk beta. Sampai yang pertama keluar, penguji beta mem-build VibeMeeting sendiri: lihat [DEVELOPMENT.md](DEVELOPMENT.md). Kalau sudah punya file download-nya:

1. Buka file yang diunduh, lalu seret **VibeMeeting** ke folder **Applications**.
2. Buka VibeMeeting. App ini ada di **menu bar** (ikon gelombang di kanan atas layar) dan tidak punya ikon Dock kecuali salah satu jendelanya sedang terbuka.

## Pertama kali dibuka dan izin

Jendela Welcome memandu tiga langkah:

1. **Audio.** Klik **Allow audio capture**. macOS akan meminta dua izin:
   - **Microphone**, untuk mentranskripsi ucapanmu.
   - **System Audio Recording**, untuk mentranskripsi lawan bicara. Kalau prompt-nya terlewat, nyalakan VibeMeeting di System Settings → Privacy & Security → Screen & System Audio Recording, di bagian **System Audio Recording Only**.

   VibeMeeting juga mengunduh model speech on-device untuk bahasa call-mu. Ini hanya sekali per bahasa.
2. **API key.** Tempel API key Anthropic-mu. Key disimpan di Keychain macOS.
3. **About me.** Opsional, tapi jawaban jauh lebih terdengar seperti kamu kalau diisi. Settings → About me menampilkan outline: namamu, pekerjaanmu, siapa yang biasa kamu temui, kesan yang ingin kamu berikan, fakta yang boleh dipakai di jawaban, dan hal yang tidak pernah kamu katakan. Boleh ditulis dalam bahasa apa pun.

Untuk memastikan semuanya jalan, pilih **Audio check…** dari ikon menu bar, putar video yang ada suara orang bicara, lalu ucapkan beberapa kata. Kedua meter harus bergerak dan teks harus muncul di kedua sisi dalam satu-dua detik.

## API key dan biaya

VibeMeeting memakai model Claude dari Anthropic dengan **API key milikmu sendiri**, jadi Anthropic menagih akunmu langsung sesuai pemakaian. Tidak ada akun VibeMeeting dan tidak ada server di tengah.

1. Masuk ke platform developer Anthropic di [platform.claude.com](https://platform.claude.com) dan isi saldo akunmu.
2. Buat API key. Workspace terpisah untuk VibeMeeting dengan batas pengeluaran bulanan membuat biayanya lebih mudah diperkirakan.
3. Tempel key itu di jendela Welcome atau di Settings → General, lalu klik **Test connection**.

Biayanya tergantung lama meeting dan seberapa sering kamu meminta jawaban. Perkiraan kasarnya (angka sebenarnya ada di halaman usage di platform.claude.com):

- Dengan model default (Claude Haiku 5.5 untuk jawaban, Claude Opus 5.5 untuk rekap), meeting satu jam biasanya jauh di bawah satu dolar AS, sering hanya puluhan sen.
- Menyiapkan jawaban dengan Opus beberapa kali lebih mahal. Bahasa Mandarin, Jepang, dan Korea memakai lebih banyak token daripada bahasa Inggris untuk kata yang sama.
- Selama meeting berjalan, VibeMeeting menyegarkan cache prompt kira-kira setiap empat setengah menit supaya jawaban tetap cepat, dan itu ada biayanya walau kamu tidak meminta apa-apa. Akhiri meeting begitu call selesai.

Detail setiap meeting menampilkan perkiraan biayanya. Akun Anthropic yang baru mulai dengan rate limit rendah, jadi rekap yang sangat panjang bisa gagal di awal; buka meeting-nya dan klik **Try again** nanti.

## Privasi

Audio tidak pernah keluar dari Mac ini dan meeting hanya disimpan di Mac ini; untuk menulis jawaban dan rekap, VibeMeeting mengirim teks transkrip, About me, dan apa yang kamu tambahkan ke meeting (goal, instruksi, Steer, dan konteks, termasuk teks file dan gambar) ke Anthropic dengan API key milikmu sendiri.

Lebih rincinya:

- **Audio** ditranskripsi di Mac-mu oleh speech recognition bawaan macOS. Audio tidak pernah disimpan dan tidak pernah dikirim ke mana pun.
- **Yang dikirim** langsung dari Mac-mu ke API Anthropic, di bawah akun dan ketentuan Anthropic milikmu sendiri. Djavaweb tidak menerima meeting-mu, key-mu, atau apa pun; VibeMeeting tidak punya server dan tidak memakai analytics.
- **Meeting** disimpan sebagai file di `~/Library/Application Support/VibeMeeting/Sessions`. Menghapus meeting di jendela utama menghapus file-nya.
- **API key** disimpan di Keychain macOS.
- **Diagnostik.** Report Audio check dan log app tidak pernah berisi teks transkrip, konteks, atau jawaban. Report tetap di Mac-mu kecuali kamu sendiri yang menyalin dan membagikannya.
- **Orang lain di call** ikut ditranskripsi, dan kata-kata mereka dikirim ke Anthropic saat kamu meminta jawaban atau rekap. Beri tahu mereka bahwa kamu memakai VibeMeeting, dan minta persetujuan mereka kalau hukum mewajibkannya.

## Bahasa

- **Bahasa call.** Setiap meeting punya satu bahasa yang diucapkan kedua pihak. Kamu bisa memilih bahasa apa pun yang didukung speech recognition on-device macOS; daftarnya ada di Settings → General → **Call language** dan di jendela New meeting. Default-nya (Automatic) adalah bahasa pertama di daftar bahasa Mac-mu yang didukung speech recognition, atau English (United States) kalau tidak ada.
- **Jawaban, Ask questions, dan rekap** ditulis dalam bahasa call, kecuali kamu memilih bahasa lain di New meeting. Ada 35 bahasa yang bisa dipilih di sana.
- **Teksmu sendiri** (About me, goal, instruksi meeting, Steer, konteks) boleh dalam bahasa apa pun, atau campuran.
- **Bahasa preview.** Bahasa yang tidak ditulis dengan alfabet Latin atau Sirilik (misalnya Mandarin, Jepang, Korea, Thai, Arab, dan Ibrani) bisa dipakai, tapi ditandai "preview": pemenggalan kalimat, hitungan kata, dan filter gema disetel untuk bahasa lainnya.
- **Tampilan app** masih dalam bahasa Inggris. App sudah siap diterjemahkan, dan bahasa lain akan menyusul.

## Cara pakai

**Sebelum call.** Pilih **New meeting** dari ikon menu bar (atau dari jendela utama). Beri nama meeting dan **Goal** (keduanya opsional), cek **Language**, tambahkan **Context** (drop file, tempel teks atau screenshot, atau **Add from clipboard**), lalu pilih **Reply style**. **Meeting instructions** menambahkan aturan untuk jawaban di meeting ini. Lalu klik **Start listening**. Buru-buru? Di jendela utama, tombol panah di samping New meeting punya **Start now**.

**Selama call.** Overlay melayang di atas jendela lain:

- **Transcript** di kiri: ucapan lawan bicara dalam bubble, ucapanmu sebagai teks biasa. Klik satu giliran untuk menjadikannya yang dijawab oleh jawaban berikutnya; klik dua kali untuk memperbaiki kata yang salah dengar.
- **Responses** di kanan: semua jawaban dan daftar pertanyaan di meeting ini. Yang terbaru punya **Regenerate** dan **Shorter**; semuanya bisa disalin.
- **Goal** ada di bawah judul Responses. Klik untuk mengubahnya.
- Bar di bawah berisi langkah-langkah (Answer, Clarify, Add, Push back), **Ask questions**, kolom **Steer**, dan **Reply**.
- Tombol jendela hijau mengganti ke overlay ringkas satu kolom; tombol merah menyembunyikan overlay tanpa mengakhiri meeting (⌥H untuk menampilkannya lagi).

**Setelah call.** Klik **End meeting**. Rekap dibuat otomatis. Buka meeting-nya di jendela utama untuk membaca, **Copy as Markdown**, atau **Export .md…**.

### Hotkey

Hotkey hanya aktif selama meeting berjalan, jadi tidak pernah mengganggu app lain. Ubah di Settings → Hotkeys.

| Aksi | Default |
| --- | --- |
| Reply (VibeMeeting memilih langkahnya) | ⌥Space |
| Answer · Clarify · Add · Push back | ⌥1 · ⌥2 · ⌥3 · ⌥4 |
| Steer (ketik arahan, lalu Enter) | ⌥⇧Space |
| Ask questions | ⌥Q |
| Regenerate · Shorter | ⌥R · ⌥S |
| Tampilkan atau sembunyikan overlay | ⌥H |

## Pakai dengan jujur

VibeMeeting adalah asisten yang kamu pakai secara terbuka. App ini tidak mendukung pemakaian untuk menipu orang, misalnya mendapat bantuan diam-diam di tempat yang tidak membolehkannya, seperti wawancara kerja atau ujian. Kamu bertanggung jawab mematuhi hukum di tempatmu dan di tempat peserta call lainnya, termasuk meminta persetujuan mereka untuk ditranskripsi kalau diwajibkan. Djavaweb tidak bertanggung jawab atas cara kamu memakai VibeMeeting.

**Hide from screen sharing** (Settings → Overlay) mati secara default. Pengaturan ini meminta macOS untuk tidak menyertakan overlay saat screen sharing, tapi beberapa app screen sharing mungkin tetap menangkapnya, jadi sembunyikan overlay dengan ⌥H sebelum kamu share screen. Saat dinyalakan, disclaimer yang sama tampil lebih dulu.

## Kalau ada masalah

- **Tidak ada teks di Them.** Buka **Audio check…**. Kalau meter call tetap datar, nyalakan VibeMeeting di System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, lalu mulai meeting lagi. Kalau kamu memilih satu app di Settings → Audio → Listen to, coba **All system audio** (wajib untuk call di Safari).
- **Ucapan lawan bicara muncul di You.** Mic-mu menangkap suara dari speaker. Pakai headphone, atau biarkan **Remove the call's voice from my mic** menyala di Settings → Audio.
- **Hotkey malah mengetik karakter.** Beberapa kombinasi ⌥ + huruf mengetik karakter di layout keyboard tertentu. Ganti hotkey-nya ke ⌃⌥ + huruf di Settings → Hotkeys.
- **Jawaban tidak muncul.** Di Settings → General, klik **Test connection**. Pastikan akun Anthropic-mu punya saldo.
- **"Saved meetings can't be opened."** Meeting itu disimpan oleh versi VibeMeeting yang lebih baru, atau file-nya rusak. File-nya tetap utuh; update VibeMeeting untuk membukanya.

---

VibeMeeting adalah software closed source. © 2026 Djavaweb. Hak cipta dilindungi.
