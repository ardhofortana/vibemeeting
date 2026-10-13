> **Archived.** This is the original v1 spec, written in Indonesian when VibeMeeting was a personal tool for one user. It is kept for history only and no longer describes the product. The current product brief is [`docs/PRD.md`](../PRD.md).

# PRD — VibeMeeting: Live Meeting Response Assistant (macOS)

Oct 12, 2026 · @Ardho Fortana

## Ringkasan

VibeMeeting adalah app macOS pribadi yang mendengarkan lawan bicara di meeting online mana pun. App ini menampilkan subtitle live, lalu menyiapkan script jawaban siap baca saat Ardho menekan satu hotkey. Versi pertama hanya untuk Ardho, untuk meeting berbahasa Inggris, dan berjalan tanpa backend.

**Masalah.** Di meeting dengan klien global, Ardho sering butuh bantuan cepat: soal harga dan estimasi, pertanyaan teknis, objection, atau sekadar merangkai kalimat Inggris yang luwes. Cara sekarang adalah mengetik keyword ke Claude di tengah meeting. Cara ini memecah fokus dan selalu terlambat beberapa detik.

**Tujuan v1**

- Subtitle live lawan bicara dari Zoom, Google Meet, Teams, dan app call lain, tanpa bot yang ikut join.
- Satu hotkey menghasilkan script siap baca untuk ucapan terakhir lawan bicara. Script bisa menjawab pertanyaan, mengklarifikasi, atau menanggapi opini.
- Konteks per meeting (chat, proposal, catatan) dan gaya bahasa (preset plus instruksi bebas) membentuk setiap script.
- Setelah meeting, rekap otomatis berisi ringkasan, poin penting, dan action items.

**Non-goals v1**

- Dijual ke publik, multi-user, login, atau billing.
- Bahasa selain Inggris.
- Versi Windows, iPhone, atau web.
- Bot yang ikut join meeting, jawaban otomatis tanpa hotkey, atau text-to-speech.
- Library konteks per klien yang tersimpan permanen.

**Keputusan dari interview**

| Topik | Keputusan |
| --- | --- |
| Tujuan | Tool pribadi |
| Bahasa meeting | Inggris |
| Bahasa UI | Inggris |
| Bentuk jawaban | Script lengkap siap dibaca |
| Trigger | Hotkey global |
| Yang direspons | Ucapan terakhir lawan bicara, termasuk opini, bukan hanya pertanyaan |
| Konteks | Diberikan per meeting: chat, proposal, catatan lain |
| Gaya | Preset plus instruksi teks bebas yang detail |
| Setelah meeting | Rekap, poin penting, action items |
| Privasi | Transkripsi on-device; transkrip boleh disimpan lokal |
| Screen share | Jarang |
| Device | Mac dengan macOS versi terbaru |

Tiga hal tidak punya preferensi, jadi PRD memakai default ini:

- **Profil tetap "About me"** di Settings, opsional, selalu ikut ke setiap respons.
- **Angka harga** boleh muncul hanya jika ada di konteks atau profil. AI tidak pernah mengarang angka.
- **Script dibuat lewat Claude API.** Audio tidak pernah meninggalkan Mac; yang dikirim hanya teks.

## Pengguna & skenario

Pengguna tunggal v1 adalah Ardho. Ia CEO agency dan seller Fiverr Top Rated yang rutin meeting dalam bahasa Inggris dengan klien dan agency dari berbagai negara. Enam skenario di bawah menjadi acuan uji setiap fitur.

| Skenario | Lawan bicara berkata | Yang dibutuhkan dari script |
| --- | --- | --- |
| Harga | "What would something like this cost, roughly?" | Kisaran dari proposal yang di-drop, plus kalimat untuk mengunci scope dulu |
| Teknis | "Will this work with our WooCommerce subscriptions?" | Jawaban awam, asumsi disebut jelas, tawaran konfirmasi tertulis bila belum pasti |
| Objection | "Another agency quoted us half that." | Mengakui keberatan, menjelaskan perbedaan nilai, tanpa menjatuhkan kompetitor |
| Opini perlu diklarifikasi | "I think we can launch in two weeks." | Meluruskan timeline dengan sopan, berdasarkan scope di konteks |
| Menambahkan poin | Klien menjelaskan rencana marketing | Tambahan ide yang relevan dari konteks, tanpa mengambil alih percakapan |
| Kalimat luwes | Ardho tahu isi jawabannya, tapi butuh kalimat Inggris yang natural | Ardho mengetik arahan singkat (Steer); script mengubahnya jadi kalimat lisan yang rapi |

Skenario terakhir adalah versi otomatis dari workflow Ardho sekarang: memberi keyword, lalu menerima jawaban gaya lisan.

## Alur pengguna

Satu sesi berjalan dalam tiga fase. Persiapan dibuat cukup singkat supaya bisa dilakukan sesaat sebelum meeting dimulai.

**Sebelum meeting**

1. Klik ikon VibeMeeting di menu bar, lalu pilih **New meeting**.
2. Isi nama meeting (opsional), lalu drop file atau paste teks konteks: chat Fiverr, proposal, brief, catatan.
3. Pilih preset gaya, dan tambahkan instruksi khusus untuk meeting ini bila perlu.
4. Tekan **Start listening**. Overlay kecil muncul di pojok layar.

**Selama meeting**

5. Subtitle lawan bicara mengalir di overlay. Ucapan Ardho tampil lebih redup sebagai konteks.
6. Saat lawan bicara selesai bicara, Ardho menekan ⌥Space (**Reply**). Script mulai muncul dalam hitungan detik.
7. Opsional: pilih intent (Answer, Clarify, Add, Push back) atau ketik arahan singkat lewat Steer sebelum generate.
8. Ardho membaca script. Jika kurang pas, ia bisa Regenerate, Shorter, atau klik baris transkrip lain sebagai target.

**Setelah meeting**

9. Tekan **End meeting**. VibeMeeting membuat rekap: ringkasan, poin penting, keputusan, action items.
10. Rekap, transkrip, dan script tersimpan lokal, dan rekap bisa di-copy sebagai Markdown.

## Kebutuhan fungsional

Delapan kebutuhan di bawah membentuk v1. F1 sampai F5 adalah inti bantuan live, sedangkan F6 sampai F8 melengkapinya setelah meeting.

### F1. Tangkap audio

- Menangkap audio sistem (lawan bicara) dan mic (Ardho) sebagai dua stream terpisah.
- Bekerja untuk app apa pun: Zoom, Meet di browser, Teams, Slack huddle, WhatsApp. Default menangkap semua audio sistem; opsional memilih satu app.
- Menampilkan indikator level untuk kedua stream. Ada peringatan bila salah satu stream sunyi lama selama sesi aktif.
- Echo cancellation pada mic, supaya suara lawan dari speaker tidak terbaca sebagai ucapan Ardho.
- File audio tidak pernah disimpan.

### F2. Subtitle live

- Transkripsi on-device dalam bahasa Inggris. Hasil sementara tampil langsung, lalu dikunci saat final.
- Dikelompokkan per giliran bicara dengan label **Them** dan **You**. Pemisahan berdasarkan sumber audio, bukan diarization.
- Di v1, semua peserta remote dihitung sebagai Them.
- Auto-scroll berhenti saat Ardho scroll ke atas, dan tombol **Jump to live** mengembalikannya.
- Klik satu giliran untuk menjadikannya target Reply. Teks target bisa diedit cepat bila transkripsi salah dengar.

### F3. Konteks per meeting

- Drop file (PDF, DOCX, TXT, MD, gambar seperti screenshot chat) atau paste teks bebas.
- Konteks bisa ditambah selama sesi berjalan.
- App menampilkan perkiraan ukuran konteks dan memberi peringatan bila terlalu besar.
- Profil **About me** di Settings bersifat opsional dan ikut ke setiap respons.

### F4. Reply (inti)

- Target default adalah giliran Them terakhir. Bila lawan bicara masih bicara, app memakai teks sementara terakhir.
- Mode **Auto** memilih sendiri langkah terbaik: menjawab, mengklarifikasi, menambahkan, atau menanggapi opini.
- Intent eksplisit opsional: **Answer**, **Clarify**, **Add**, **Push back**.
- **Steer** adalah input satu baris untuk arahan cepat, boleh dalam bahasa Indonesia. Contoh: "tawarkan 2 revisi, jangan sebut harga dulu".
- Output berupa script siap baca yang di-stream. Panjangnya mengikuti preset, default 2 sampai 5 kalimat.
- Aksi pada script: **Regenerate**, **Shorter**, **Copy**.
- Semua script dalam satu sesi tersimpan dan bisa dilihat ulang.
- Angka (harga, tanggal, durasi) hanya boleh diambil dari konteks atau profil. Bila tidak ada, script memakai kalimat penunda yang natural dan menandai **\[confirm number\]**.

### F5. Gaya & instruksi

- Enam preset bawaan (lihat UX), plus preset buatan sendiri.
- Setiap preset terdiri dari nama, instruksi teks panjang, dan target panjang script.
- Instruksi khusus per meeting ditambahkan di atas preset.
- Preset bisa diganti di tengah sesi lewat overlay.

### F6. Rekap setelah meeting

- Dibuat setelah **End meeting**, dari transkrip penuh dan konteks.
- Isinya: ringkasan, poin penting, keputusan, action items (pemilik You atau Them, dengan tenggat bila disebut), dan pertanyaan terbuka.
- Tersedia **Copy as Markdown** dan export .md.

### F7. Penyimpanan & riwayat

- Setiap sesi tersimpan lokal: metadata, transkrip, salinan konteks, script, dan rekap.
- Daftar sesi ada di window utama, bisa dicari dan dihapus permanen.
- Tidak ada sync cloud di v1.

### F8. Settings

- API key (disimpan di Keychain), pilihan model, hotkey, About me, preset, dan sumber audio.
- Posisi dan transparansi overlay.
- Opsi **Hide from screen sharing**, default menyala.

## UX & copywriting

Aksi utama diberi label **Reply** dengan hotkey ⌥Space. Satu kata kerja paling cepat dibaca saat sedang tertekan di tengah meeting. Label ini juga mencakup pertanyaan maupun opini.

Alternatif yang dipertimbangkan:

- "Respond to this": jelas, tapi terlalu panjang untuk dilirik.
- "Help me answer": terkesan hanya untuk pertanyaan.
- "What do I say?": akrab, tapi kurang rapi untuk tombol.

### Overlay

- Panel melayang, selalu di atas, semi transparan, bisa dipindah dan di-resize. Tidak mencuri fokus dari app meeting.
- Urutan dari atas ke bawah: header (status, preset aktif, timer), area subtitle, kartu script, footer petunjuk hotkey.
- **Mode ringkas** hanya menampilkan dua giliran terakhir dan script. **Mode penuh** menampilkan seluruh transkrip.
- Kalimat pertama script ditebalkan, supaya Ardho bisa langsung mulai bicara sambil membaca sisanya.
- Kartu script menampilkan potongan teks target di atasnya, supaya jelas apa yang sedang dijawab.

### Hotkey

Semua hotkey bisa diubah di Settings.

| Aksi | Default | Catatan |
| --- | --- | --- |
| Reply (Auto) | ⌥Space | Aksi utama; AI memilih langkah terbaik |
| Answer | ⌥1 | Menjawab pertanyaan |
| Clarify | ⌥2 | Meluruskan atau menanyakan balik |
| Add | ⌥3 | Menambahkan poin |
| Push back | ⌥4 | Tidak setuju dengan sopan |
| Steer | ⌥⇧Space | Fokus ke input arahan; Enter untuk generate |
| Regenerate | ⌥R | Script baru untuk target yang sama |
| Shorter | ⌥S | Memendekkan script terakhir |
| Show/hide overlay | ⌥H | Menyembunyikan overlay tanpa menghentikan sesi |

### Copy UI

| Lokasi | Copy |
| --- | --- |
| Menu bar | New meeting · Open VibeMeeting · Settings… · Quit |
| Judul sheet | New meeting |
| Field nama | Meeting name (optional) |
| Drop zone konteks | Drop files or paste notes: chats, proposals, briefs |
| Keterangan drop zone | PDF, DOCX, TXT, MD, or images |
| Pemilih gaya | Reply style |
| Placeholder instruksi | Anything specific for this call? e.g. Keep pricing vague until scope is clear. |
| Tombol mulai | Start listening |
| Status overlay | Listening · Paused · Reconnecting audio… |
| Label pembicara | Them · You |
| Subtitle kosong | Waiting for someone to speak… |
| Tombol utama | Reply ⌥Space |
| Chip intent | Answer · Clarify · Add · Push back |
| Placeholder Steer | Steer the reply (optional), e.g. offer 2 revisions |
| Saat generate | Drafting… |
| Aksi script | Regenerate · Shorter · Copy |
| Penanda angka | \[confirm number\] |
| Kembali ke live | Jump to live |
| Tombol selesai | End meeting |
| Judul rekap | Meeting recap |
| Bagian rekap | Summary · Key points · Decisions · Action items · Open questions |
| Aksi rekap | Copy as Markdown |
| Onboarding izin | VibeMeeting needs to hear your calls. Audio stays on this Mac. Only text is sent to Claude to draft replies. |
| Tombol izin | Allow audio capture |
| Error audio | Can't hear the call. Check that VibeMeeting has audio capture permission. · Open Settings |
| Error API | Couldn't draft a reply. Check your connection or API key. · Try again |
| Belum ada target | Nothing to reply to yet. |
| Mic sunyi | Your mic seems silent. |

### Preset bawaan

| Preset | Karakter | Panjang |
| --- | --- | --- |
| Friendly Pro (default) | Hangat, jelas, santai-profesional | 2–4 kalimat |
| Consultant | Terstruktur, percaya diri, memimpin arah diskusi | 3–5 kalimat |
| Negotiator | Tegas soal scope dan harga, tetap sopan, tidak mudah memberi diskon | 2–4 kalimat |
| Tech Explainer | Hal teknis dalam bahasa awam, dengan satu analogi bila membantu | 3–5 kalimat |
| Short & Sweet | Langsung ke inti | 1–2 kalimat |
| Diplomatic | Klarifikasi atau tidak setuju tanpa menyinggung | 2–4 kalimat |

## Response engine & desain prompt

Setiap Reply adalah satu panggilan Claude API yang di-stream. Prompt disusun dari bagian yang paling statis ke yang paling dinamis. Dengan begitu, bagian awal bisa di-cache dan respons tetap cepat sepanjang meeting.

| Urutan | Lapisan | Isi | Di-cache |
| --- | --- | --- | --- |
| 1 | Aturan output | Gaya lisan, larangan, aturan angka | Ya |
| 2 | About me | Identitas, brand, stack, portfolio, aturan scope dan harga | Ya |
| 3 | Konteks meeting | File, chat, catatan yang di-drop | Ya |
| 4 | Gaya | Preset aktif plus instruksi khusus meeting | Ya |
| 5 | Transkrip terbaru | Giliran terakhir dengan label Them dan You, jendela dibatasi | Tidak |
| 6 | Permintaan | Teks target, intent, Steer | Tidak |

**About me awal** diisi dari workflow meeting assistant yang sudah Ardho pakai. Isinya: brand Detheme untuk balasan ke klien (bukan Djavaweb), sejak 2013, stack WordPress, Elementor Pro, WooCommerce, JetEngine, contoh portfolio, link booking, rekomendasi hosting Pressable, serta aturan scope dan dua milestone.

### Aturan output bawaan

- Bicara sebagai Ardho, orang pertama, dalam bahasa Inggris lisan yang sederhana karena klien mungkin bukan penutur asli.
- Pakai kontraksi dan ritme natural. Tidak boleh terdengar seperti tulisan AI.
- Tanpa pembuka seperti "Great question!", "Certainly!", atau "Absolutely!".
- Tanpa emoji, asterisk, em dash, bullet, atau label. Hasilnya teks polos yang siap dibaca.
- Default 2 sampai 4 kalimat, kecuali preset meminta lain.
- Angka hanya dari konteks atau About me. Bila tidak ada, pakai kalimat penunda dan **\[confirm number\]**.
- Jangan mengarang fakta proyek. Bila tidak tahu, tawarkan untuk mengecek dan follow up.

### Perilaku intent

| Intent | Instruksi ke model |
| --- | --- |
| Auto | Pilih sendiri: jawab bila itu pertanyaan, tanggapi bila itu opini, klarifikasi bila ada yang salah atau ambigu |
| Answer | Jawab langsung di kalimat pertama, lalu satu atau dua kalimat pendukung |
| Clarify | Luruskan atau tanyakan balik dengan sopan, sebut asumsi yang sedang diuji |
| Add | Akui poin mereka, lalu tambahkan satu ide relevan dari konteks |
| Push back | Tidak setuju dengan hormat, beri alasan, tawarkan alternatif |

Steer selalu menang atas preset bila keduanya bertentangan.

### Strategi latensi

- Prompt caching untuk lapisan 1 sampai 4. Cache dipanaskan saat **Start listening**, sebelum Reply pertama.
- Jendela transkrip dibatasi, supaya ukuran prompt tidak tumbuh sepanjang meeting.
- Model tercepat untuk Reply, model yang lebih kuat untuk rekap. Pilihan akhir diputuskan dari uji latensi di M0.
- Eksperimen opsional (M3): **Pre-draft**. App diam-diam menyiapkan draft Auto setiap giliran Them selesai, dan menampilkannya hanya saat hotkey ditekan.

### Rekap

- Satu panggilan terpisah setelah **End meeting**, memakai transkrip penuh plus konteks.
- Output terstruktur (Summary, Key points, Decisions, Action items, Open questions), lalu dirender oleh app.
- Untuk meeting panjang, transkrip diringkas per bagian dulu, baru digabung.

## Arsitektur teknis

VibeMeeting adalah app native Swift tanpa backend. Kode disimpan di repo GitHub privat, dan tidak ada server yang perlu di-deploy.

&#91;embedded content: arsitektur v1 · semua di Mac, satu panggilan cloud\]

Dua stream audio ditranskripsi terpisah di Mac, sehingga label Them dan You sudah benar tanpa diarization. Satu-satunya yang keluar dari Mac adalah teks prompt saat Reply dan rekap.

| Komponen | Pilihan | Catatan |
| --- | --- | --- |
| UI | SwiftUI; overlay sebagai NSPanel non-activating; MenuBarExtra | Overlay tidak mencuri fokus dari app meeting |
| Audio lawan bicara | Core Audio process tap (macOS 14.2+) | Cadangan: audio lewat ScreenCaptureKit |
| Audio mic | AVAudioEngine dengan voice processing | Echo cancellation bawaan |
| Transkripsi | SpeechAnalyzer dan SpeechTranscriber (macOS 26), locale Inggris | Dua instance, Them dan You, on-device |
| Hotkey global | Library KeyboardShortcuts | Bisa diubah di Settings |
| Baca konteks | PDFKit untuk PDF, NSAttributedString untuk DOCX; gambar dikirim sebagai image block | Teks diekstrak sekali saat file di-drop |
| LLM | Claude Messages API, streaming, prompt caching | URLSession langsung, tanpa backend |
| Penyimpanan | SwiftData di Application Support | Sesi, transkrip, script, rekap |
| Rahasia | Keychain | API key pribadi |
| Distribusi | Developer ID plus notarization, di luar Mac App Store | Tool pribadi tidak perlu review App Store |
| Sembunyi dari share | NSWindow.sharingType = .none | Efektivitas perlu diuji per app meeting; prioritas rendah karena jarang share screen |

## Kebutuhan non-fungsional

Target terpenting adalah kecepatan Reply: kata pertama script harus muncul paling lama 1,5 detik setelah hotkey (median). Semua angka target di bawah adalah usulan awal dan divalidasi di M0.

| Area | Target atau aturan |
| --- | --- |
| Latensi subtitle | Teks muncul paling lama 1 detik setelah diucapkan |
| Latensi Reply | Kata pertama paling lama 1,5 detik (median) dan 3 detik (p90); script lengkap paling lama 4 detik |
| Latensi rekap | Paling lama 30 detik untuk meeting 60 menit |
| Privasi audio | Audio tidak pernah ditulis ke disk dan tidak pernah dikirim keluar dari Mac |
| Data ke cloud | Hanya teks (jendela transkrip, konteks, instruksi), lewat Claude API dengan API key pribadi |
| Penyimpanan | Sesi di folder Application Support, API key di Keychain; hapus sesi berarti hapus permanen |
| Log | Log teknis tanpa isi transkrip maupun konteks |
| Ketahanan | Bila API gagal, subtitle tetap jalan dan Reply bisa dicoba ulang; bila audio putus, app menyambung ulang otomatis |
| Beban sistem | Tidak membuat app meeting tersendat; CPU dan memori diukur di M0 |
| Platform | macOS 26 atau lebih baru, syarat untuk transkripsi on-device |
| Biaya | Transkripsi on-device gratis; biaya hanya token Claude; target di bawah US$1 per jam meeting |

## Milestone & rencana rilis

v1 dibangun dalam empat milestone. Setiap milestone punya gate yang harus lolos sebelum lanjut, dan durasinya ditetapkan setelah M0 selesai.

&#91;embedded content: roadmap v1 · 4 milestone, masing-masing dengan gate\]

M0 sengaja dibuat sebagai spike untuk membuktikan bagian paling berisiko lebih dulu: tangkap audio, transkripsi on-device, dan latensi Reply. Bila gate M0 gagal, opsi cadangannya adalah STT cloud atau ScreenCaptureKit, sebelum UI dibangun.

## Metrik, risiko & pertanyaan terbuka

v1 dianggap berhasil bila Ardho memakai VibeMeeting di hampir semua meeting klien dan membaca script tanpa banyak mengulang generate.

### Metrik keberhasilan

| Metrik | Target | Cara ukur |
| --- | --- | --- |
| Pemakaian | Dipakai di 80% meeting klien setelah satu bulan | Jumlah sesi dibanding meeting di kalender |
| Script terpakai | Regenerate di bawah 30% dari semua Reply | Log lokal jumlah Reply dan Regenerate |
| Kecepatan | Median kata pertama paling lama 1,5 detik | Timer lokal dari hotkey ke token pertama |
| Rekap berguna | Rekap dikirim atau disalin tanpa edit besar | Penilaian Ardho per sesi |
| Biaya | Di bawah US$1 per jam meeting | Token usage dari API |

### Risiko

| Risiko | Dampak | Mitigasi |
| --- | --- | --- |
| Salah dengar pada aksen non-native | Script menjawab hal yang salah | Teks target tampil di atas script; target bisa diklik dan diedit cepat |
| Reply lebih dari 3 detik | Jeda canggung di percakapan | Prompt caching, cache dipanaskan saat mulai, jendela transkrip dibatasi, model cepat |
| Echo tanpa headset | Label Them dan You tertukar | Echo cancellation di mic; sarankan headset |
| Model mengarang angka atau fakta | Janji keliru ke klien | Aturan angka hanya dari konteks, penanda \[confirm number\] |
| Terdengar seperti membaca | Klien merasa aneh | Script pendek, kalimat lisan, kalimat pertama ditebalkan |
| Update macOS mengubah izin audio atau overlay | Fitur mati mendadak | Uji di setiap update besar macOS; jalur cadangan lewat ScreenCaptureKit |
| Aturan persetujuan transkripsi di sebagian yurisdiksi klien | Risiko reputasi atau hukum | Audio tidak disimpan, transkrip hanya lokal; pertimbangkan kalimat pemberitahuan singkat ke klien |

### Pertanyaan terbuka

- [x] Nama final app: VibeMeeting.
- [ ] Perlu pemisahan per orang bila ada lebih dari satu lawan bicara, atau cukup Them?
- [ ] Apakah tim Djavaweb nanti ikut memakai? Bila ya, perlu distribusi dan API key per orang.
- [ ] Perlu kalimat pemberitahuan ke klien saat transkripsi aktif?
- [ ] Model mana untuk Reply dan rekap, setelah uji latensi di M0.
