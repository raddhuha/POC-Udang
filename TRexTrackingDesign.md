# Tracking kinematik sederhana mengikuti alur TRex

Implementasi ini adalah **adaptasi bbox/iOS yang terinspirasi TRex**, mengikuti permintaan agar tetap sederhana. Model Core ML menyediakan deteksi; backend kinematik menghubungkan deteksi antarframe. Ini bukan port penuh TRex, dan ID live tetap merupakan hipotesis lintasan sementara.

## Acuan yang diverifikasi

- Paper: Walter & Couzin (2021), [TRex, eLife 10:e64000](https://doi.org/10.7554/eLife.64000). Bagian Tracking, Appendix D/Appendix 4 membahas graph assignment; Appendix 10 menjelaskan probabilitas. Paper menjelaskan penjumlahan bobot pasangan satu-ke-satu, pilihan *null*, tree search, dan fallback Hungarian. Visual identification merupakan tahap tersendiri.
- Source yang dipatok: tag **`1.0`**, commit **`37648566b448d80e12b130f95743b520fa23967f`**, tanggal commit **2020-10-12**. Tag ini mendahului publikasi 2021; keduanya diperiksa terpisah dan tidak diasumsikan identik. [Source permanen](https://github.com/mooch443/trex/tree/37648566b448d80e12b130f95743b520fa23967f).
- [Dokumentasi parameter saat diperiksa](https://trex.run/docs/parameters_trex.html) dan [visual identification](https://trex.run/docs/identification.html) diperiksa 19 Oktober 2026 sebagai konteks versi baru. Default dan nama parameter terbaru tidak digunakan sebagai default algoritma iOS.

### Mapping source

Seluruh path berikut relatif terhadap commit yang dipatok:

| Mekanisme | File/simbol yang diperiksa | Keputusan implementasi sederhana |
|---|---|---|
| Prediksi dari riwayat | [`Application/src/tracker/tracking/Individual.cpp`, `Individual::cache_for_frame`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/tracking/Individual.cpp#L1509) | Prediksi kecepatan konstan yang dihaluskan, menggunakan delta timestamp aktual. Tidak menyalin integrasi arah/percepatan/decay TRex. |
| Bobot kandidat | [`Individual::position_probability`, `time_probability`, `probability`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/tracking/Individual.cpp#L1806) | Score residual posisi dan gate gerakan bbox; score bukan probabilitas TRex yang terkalibrasi. IoU positif tidak diwajibkan. |
| Assignment | [`Application/src/tracker/tracking/PairingGraph.cpp`, `PairingGraph::get_optimal_pairing`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/tracking/PairingGraph.cpp#L902) | Hungarian langsung dengan pilihan unmatched, satu pengukuran untuk maksimum satu track. Tidak ada tree solver atau fallback ke greedy. |
| Batas tracklet | [`Individual::update_add_segment`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/tracking/Individual.cpp#L1098) | Bedakan ID live dan tracklet; kualitas rendah/gap memutus kontinuitas tracklet tanpa mengklaim individu baru. |
| Default versi acuan | [`Application/src/tracker/misc/default_config.cpp`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/misc/default_config.cpp#L327) | Parameter iOS adalah parameter adaptasi yang perlu dikalibrasi dari video benur. |

Source `1.0` menghitung residual posisi dengan bentuk `S = (1 + ||b − p̂|| / (Δt_local · v_max))⁻²`; faktor arah diterapkan hanya jika perpindahan aktual dan prediksi masing-masing melebihi satu piksel. Faktor tersebut `A = 0.9 + 0.1(1 − |θ|/π)²`; hasil digabungkan dengan faktor waktu. Rumus ini adalah catatan source, **bukan klaim bahwa score iOS identik**. Pembacaan memakai kode executable, karena beberapa komentar persamaan berbeda dengan implementasinya.

Prediksi source merata-ratakan kecepatan terbaru yang dibatasi, memakai median besar kecepatan, arah/percepatan dan bobot decay. Pada source ini, kehilangan satu frame sudah menjadi alasan batas segmen (`LostForOneFrame`). Alasan lain mencakup probabilitas rendah, timestamp terlalu jauh, dan kecepatan tidak wajar.

Source `1.0` memakai `matching_probability_threshold = 0.1`, `track_trusted_probability = 0.5`, `track_max_reassign_time = 0.5 s`, dan `track_speed_decay = 0.7`. Dokumentasi terbaru memiliki nama/default berbeda, misalnya `match_min_probability` dan trust `0.25`; nilai-nilai tersebut tidak boleh dipindahkan langsung ke score adaptasi. Di source, Hungarian memakai kolom null dengan cost nol dan cost negatif untuk bobot valid. Jalur exception di [`Tracker.cpp`](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/Application/src/tracker/tracking/Tracker.cpp#L2854) benar-benar memanggil Hungarian meski pesan log lama menyebut approximate.

## Alur yang dipilih

```text
frame + timestamp → Core ML → bbox/center pixel → backend terpilih
    → prediksi → gate kandidat → Hungarian + unmatched
    → observed / missing / removed → evaluasi trust → tracklet
    → konfirmasi ID → overlay + arsip sesi
```

BoT-SORT tersedia sebagai baseline terpisah. Satu frame memakai tepat satu backend. Pemilihan/penggantian backend memulai state sesi/epoch baru, sehingga nomor lokal yang kembali ke 1 tetap mempunyai konteks identitas yang berbeda.

Mapping aplikasi: `Services/TrackingBackend.swift` menampung `TrackingBackend`, `TRexKinematicBackend`, dan `ExistingBoTSORTBackend`; `AppConfig.swift` menampung `KinematicTrackingConfiguration`. `LocalVideoProcessor` memilih backend dan `TrackPresentation` mengonfirmasi ID tampilan. `Services/TrackingJournal.swift` menyimpan rekaman JSONL per sesi melalui writer yang digunakan pada actor pemrosesan. Metadata mencakup backend/config, versi analisis, scope ID dan status appearance; baris frame mencatat pengukuran, asosiasi, tracklet serta event. Arsip dapat dibagikan dari UI.

Writer membatasi batch tersimpan pada 64 KiB/16 record; record tunggal yang lebih besar langsung ditulis. Batas raw default adalah 128 MiB per sesi. Setelah batas tercapai, tracking berlanjut tetapi observasi berikutnya tidak disimpan; marker `truncated` dan footer `archiveTruncated`/`discardedRecords` menjelaskan ketidaklengkapan arsip. Marker/footer dapat sedikit melampaui batas. File baru memakai nama UUID dan pembuatan eksklusif agar hasil lama tidak ditimpa. `sourceReference` hanya petunjuk nama file, bukan referensi media/crop yang dijamin masih tersedia; video/crop tidak disalin oleh journal.

Prediksi adaptasi menggunakan pusat bbox terakhir dan kecepatan yang dihaluskan: `p̂(t) = p_last + v_smoothed · (t − t_last)`. Objek diam valid; arah kepala/tubuh tidak disimpulkan dari bbox. Jarak/kecepatan dihitung pada koordinat pixel sumber dan timestamp media. Bbox/center yang diberikan ke UI tetap dinormalisasi terhadap gambar hasil orientasi yang sama. Ambang perpindahan dan kehilangan membatasi kandidat; ID tidak dipertahankan selamanya setelah objek hilang.

Hungarian meminimalkan jumlah cost yang disediakan backend, dengan kolom unmatched tersendiri. Edge yang gagal gate dilarang. Urutan input menentukan tie-break yang konsisten. Pemilihan global menghindari satu detection dipakai oleh dua track; nilai score atau kemenangan assignment tidak membuktikan bahwa identitas biologisnya benar.

Ambiguity diperiksa terpisah dari eligibility. Kandidat pesaing dengan score hampir sama menurunkan trust dan menandai batas tracklet. Crossing simetris dapat menghasilkan assignment deterministik sekaligus status ambigu. Prediksi missing tidak ditampilkan/dicatat sebagai pengukuran detektor yang benar-benar diamati, dan gap memutus trail gerakan.

## ID, data, dan batas cakupan

- `sessionID`/`trackingEpochID` memberi lingkup unik bagi nomor lokal. `backendTrackID` menunjuk track kinematik; `trackletID` menunjuk interval kontinuitas; `displayID` adalah nomor tampilan setelah konfirmasi, default tiga frame berurutan.
- Total ID terkonfirmasi dan total tracklet adalah jumlah lintasan/segmen, bukan ground truth jumlah benur. Satu live ID dapat memiliki beberapa tracklet.
- Confidence detector, score asosiasi, dan ambiguity adalah nilai berbeda. Appearance identity berstatus **unavailable** karena tidak tersedia classifier individu sesi ini.
- Mode foto menggunakan hitungan deteksi tanpa tracking. Pipeline detector/NMS tetap menjadi sumber deteksi untuk kedua backend.
- Pusat bbox bukan centroid tubuh dan luas bbox bukan luas blob. Tidak ada contour, posture, kepala–ekor, pemisahan blob, atau koreksi visual yang dibuat-buat.
- Adaptasi awal mengasumsikan kamera tetap. Pergeseran kamera dapat terlihat sebagai gerakan hewan; kompensasi kamera tervalidasi bukan bagian dari backend kinematik sederhana.

Koreksi identitas visual memerlukan jumlah individu yang diketahui dengan provenance, segmen saat semua individu terlihat terpisah, crop berkualitas, dan classifier yang dilatih/evaluasi untuk kelompok tersebut. Total ID tracker tidak digunakan untuk mengarang jumlah individu atau global segment. Hasil kinematik yang tersimpan tetap raw; status unavailable tidak menghasilkan corrected identity palsu.

Ekspor dataset crop, pencarian global segment, training/model appearance, import corrected mapping dan berversi ulang hasil koreksi ditunda dari scope sederhana ini. Metadata `appearance unavailable` menyatakan keterbatasan; bukan pengganti implementasi visual identification. Begitu pula tree search, fallback/budget tree, serta benchmark iPhone belum disediakan oleh adaptasi awal.

Tidak ada source C++ TRex yang disalin ke runtime iOS. Acuan repository memiliki [lisensi GPL v3](https://github.com/mooch443/trex/blob/37648566b448d80e12b130f95743b520fa23967f/LICENSE); dokumen ini mencatat referensi dan perbedaan implementasi mandiri.

## Verifikasi dan kalibrasi

Uji sintetis perlu mencakup diam, perpindahan tanpa overlap bbox, timestamp tidak seragam, gap pendek/panjang, crossing ambigu, assignment satu-ke-satu, unmatched/forbidden, reset, serta tracklet baru yang tetap memakai ID live. Objective Hungarian diperiksa dengan enumerasi graph kecil; tidak ada klaim validasi tree solver karena tree solver tidak termasuk scope sederhana ini.

Kalibrasi dari rekaman benur diperlukan untuk batas kecepatan/perpindahan, radius ketidakpastian, penghalusan kecepatan, lama kehilangan, score minimum, trust dan margin ambiguity. Synthetic tests memeriksa invariant algoritma; akurasi ID memerlukan anotasi manual. Benchmark Mac dan build simulator tidak mewakili FPS, memori, atau ketepatan ID pada iPhone. Hasil perintah yang benar-benar dijalankan dicatat pada laporan verifikasi implementasi.
