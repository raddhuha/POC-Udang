# Hitung benur — iOS lokal

Satu screen SwiftUI untuk **Foto** dan **Video**, iOS 17+, portrait. Core ML dan port Swift BoT-SORT berjalan di perangkat tanpa backend atau Python.

## Menjalankan dan menggunakan

Buka `POC Udang.xcodeproj` → scheme **POC Udang** → iPhone → **Run**. Model `yolo26_best.mlpackage` dan `yolo11_best.mlpackage` dikompilasi dan dibundel otomatis.

- **Foto:** ambil/pilih foto → deteksi otomatis. Hasil di atas, foto asli di bawah.
- **Video galeri:** Video → Galeri → Pilih video → Mulai.
- **Video langsung:** Video → Kamera langsung → Mulai → izinkan kamera belakang.
- **Video layar penuh:** satu preview memenuhi layar, dengan **ID dan bounding box** langsung di atas frame; confidence berukuran kecil di samping ID, tanpa preview kedua atau garis lintasan. Tombol di atas dan hitungan/kontrol di bawah menumpang pada video. Ketuk gambar atau tombol sembunyikan kontrol untuk tampilan bersih; ketuk gambar/tombol kontrol untuk memunculkannya kembali. Aspect-fit mempertahankan seluruh gambar tanpa memotongnya; video landscape dapat memiliki area hitam di layar portrait.
- **Hentikan:** hasil terakhir tetap terlihat. **Mulai** lagi selalu memulai sesi baru.

Kamera tidak menyimpan rekaman/audio. Frame kamera yang diproses mengikuti kemampuan perangkat; hanya satu frame terbaru menunggu inferensi. Kamera berhenti saat background atau interupsi. Media iCloud mungkin harus diunduh oleh Photos sebelum diterima aplikasi.

## Tombol Pengaturan

Ikon slider membuka sheet pada screen yang sama. Pemrosesan dihentikan ketika pengaturan dibuka.

- **Tampilkan ID**, **Tampilkan bounding box**, dan **Tampilkan confidence score** dapat diaktifkan terpisah pada preview foto/video, tanpa mengubah hitungan/log.
- **Model lokal:** pilih `yolo26_best` atau `yolo11_best`.
- **Confidence**, **NMS IoU**, dan **Konfirmasi ID (frame)** dapat diubah tanpa build ulang.
- **Terapkan:** model baru divalidasi sebelum mengganti model aktif. Jika gagal, model/pengaturan sebelumnya dipertahankan dan error ditampilkan.
- Mengubah model/threshold/konfirmasi mengosongkan hasil dan ID sesi. Foto diproses ulang; video tetap dipilih dan dimulai ulang dengan **Mulai**. Menutup tanpa menerapkan membatalkan perubahan inferensi; sakelar tampilan tetap berlaku.

Pengaturan saat ini berada di RAM. `AppConfig.swift` menentukan default saat aplikasi dibuka: confidence 0,50, NMS IoU 0,70, konfirmasi 3 frame, model YOLO26. Parameter teknis lain tetap terpusat di file ini (biaya asosiasi, lost buffer, GMC, resolusi preview, FPS kamera, dan log lintasan). `InferenceSettings` adalah snapshot immutable yang digunakan bersama oleh detector, tracker, dan presentasi pada satu sesi. Ambang deteksi lemah dihitung `min(AppConfig.lowConfidence, confidence / 2)`; ambang kandidat ID mengikuti confidence.

## ID per sesi

Tracker internal memberi nomor pada kandidat sebelum lolos konfirmasi, sehingga angka mentah bisa meloncat (misalnya 99 atau 800). Itu bukan data sesi sebelumnya. `TrackPresentation` sekarang memetakan kandidat yang benar-benar terkonfirmasi menjadi **ID tampilan 1, 2, 3, …** sesuai urutan konfirmasi. ID yang kembali terlihat mempertahankan nomor tersebut. Mapping baru dibuat tiap sesi, termasuk setelah perubahan model/threshold, dan tidak disimpan permanen.

- **Terdeteksi sekarang:** jumlah deteksi valid pada frame terbaru, termasuk box yang masih menunggu konfirmasi ID.
- **Total ID tercatat:** jumlah ID tampilan unik yang pernah terkonfirmasi dalam sesi. Total tetap ada saat frame kosong; ID baru hanya dicatat setelah jumlah frame konfirmasi terpenuhi.
- Label menggunakan box deteksi terbaru; prediksi Kalman dan deteksi lemah hanya digunakan internal tracker.
- `CountingSession.observations` menyimpan ID tampilan, timestamp, bbox, dan center di RAM. Data titik tengah/lintasan masih dicatat, tetapi garisnya tidak digambar di video.
- Sakelar tampilan tidak memengaruhi inferensi, konfirmasi, ataupun total ID.

## Model dan struktur

Kedua model memiliki input RGB640×640 dan kelas `0: shrimp`. Parser menangani **YOLO26 `[1,N,6]`** (xyxy, confidence, class) dan **YOLO11 `[1,4+kelas,N]`** (xywh dan class scores). Keduanya memakai class filter, confidence, letterbox, dan NMS di aplikasi. Format model lainnya membutuhkan parser yang sesuai; tidak ada training ulang.

- `ContentView` / `SettingsView`: UI foto, video penuh, dan pengaturan.
- `CountingSession`: start/stop/reset, pemilihan pengaturan/model, state UI dan observasi; token generasi mencegah hasil task lama masuk sesi baru.
- `MediaReader` / `LiveCamera`: decoding, koreksi orientasi dan capture di luar main actor.
- `OnDeviceInference` / `LocalVideoProcessor` / `TrackPresentation`: Core ML, koordinat, pemrosesan sesi dan ID tampilan.
- `NativeBoTSORT`: Kalman XYWH, asosiasi high/low, tentative confirmation, lost buffer dan deduplikasi.

BoT-SORT ini adalah **port native** jalur tanpa ReID dari Ultralytics 8.4.177, bukan Python yang dijalankan dalam Swift. GMC menggunakan translasi Apple Vision, berbeda dari affine sparseOptFlow OpenCV. Lihat `THIRD_PARTY_NOTICES.md` dan [sumber upstream](https://github.com/ultralytics/ultralytics/blob/v8.4.177/ultralytics/trackers/bot_sort.py).

## Verifikasi dan keterbatasan

`Tests/README.md` memuat uji yang dapat dijalankan ulang. Regresi mencakup ID internal 99/800 → tampilan 1/2, reset kembali 1, track lemah/frame kosong/box invalid, pengaturan runtime, kedua format model, foto dan sampel 60 frame dari masing-masing dua video untuk setiap model. Parity tracker menggunakan snapshot parameter oracle lama secara eksplisit.

Model masih dapat salah mengenali latar seperti keyboard. Confidence/konfirmasi yang lebih ketat mengurangi sebagian false positive tetapi dapat melewatkan benur samar. ID switch juga masih bisa membuat total lebih besar dari jumlah individu sebenarnya. Penomoran berurutan tidak memperbaiki akurasi model atau identitas biologis. YOLO26 memiliki maksimum 300 kandidat; YOLO11 tidak menggunakan batas output tersebut. Belum ada validasi ground truth.

Aplikasi hanya target iOS; harness core berjalan di Mac. Kamera fisik, gestur fullscreen, dan interaksi sheet/PhotosPicker masih memerlukan uji di iPhone. Tidak ada klaim performa real-time pada perangkat. Log RAM bertambah selama sesi. Lost buffer kamera menggunakan FPS nominal sehingga durasi sebenarnya dapat lebih panjang pada perangkat lambat.
