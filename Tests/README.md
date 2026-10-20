# Verifikasi iOS lokal

Aplikasi hanya target iOS. Harness command line Mac menguji kode inti Core ML/BoT-SORT yang sama tanpa menambahkan target macOS ke aplikasi.

## Regresi inti

Dari root project:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  -parse-as-library -module-cache-path /tmp/benur-swift-cache \
  'POC Udang/AppConfig.swift' \
  'POC Udang/Models/TrackingModels.swift' \
  'POC Udang/Services/NativeBoTSORT.swift' \
  'POC Udang/Services/OnDeviceInference.swift' \
  'POC Udang/Services/MediaReader.swift' \
  Tests/VerifyClient.swift -o /tmp/benur-verify-core
/tmp/benur-verify-core
/tmp/benur-verify-core --model=yolo11_best
```

Menggunakan model bundel dan kedua MP4 asli di `../video`: foto benur positif, 60 frame per video, count/set ID, normalisasi box dan center, frame portrait, reset ID/lintasan, timestamp duplikat, model hilang dan media rusak. Gunakan `--full` untuk seluruh frame, atau `--photo-only` untuk foto. Laporan per model: `verification/ios-core-yolo26_best-report.json` dan `verification/ios-core-yolo11_best-report.json`.

## Parity tracker

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -module-cache-path /tmp/benur-swift-cache \
  'POC Udang/AppConfig.swift' \
  'POC Udang/Services/NativeBoTSORT.swift' Tests/VerifyTracker.swift \
  -o /tmp/benur-verify-tracker
/tmp/benur-verify-tracker
```

16 kasus / 1.231 frame dengan snapshot parameter oracle (confidence 0,25 / lowConfidence 0,10) yang dibuat eksplisit dalam test. Konfigurasi aplikasi tidak diubah. Fixture dari Ultralytics 8.4.177, GMC/ReID nonaktif, toleransi bbox 0,002 px. `GenerateTrackerReference.py` hanya alat development.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'POC Udang.xcodeproj' -scheme 'POC Udang' \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/benur-build CODE_SIGNING_ALLOWED=NO build
```

## Uji manual iPhone (masih perlu dilakukan)

1. Foto kamera/galeri: hasil di atas, asli di bawah, posisi dan orientasi cocok.
2. Video galeri fullscreen: Mulai → ID/box → Hentikan; hasil tetap tampil. Mulai lagi harus dimulai dari sesi kosong.
3. Video → Kamera langsung → Mulai. Izin pertama tidak boleh membatalkan startup. Box dan frame asli tetap sinkron; UI/tombol Hentikan responsif.
4. Hentikan lalu Mulai: ID/log sesi lama dibersihkan dan ID tampilan pertama harus 1. Ganti mode/sumber saat proses berjalan; tidak ada hasil lama yang masuk.
5. Background/foreground dan interupsi kamera: capture berhenti, hasil tetap tampil, Mulai dapat digunakan lagi.
6. Tolak izin kamera: pesan error jelas dan foto/video galeri masih bisa digunakan.
7. Sembunyikan kontrol video, lalu ketuk gambar/tombol kontrol: hanya satu preview, confidence berukuran kecil di samping ID, tanpa lintasan/preview asli kedua.
8. Buka Pengaturan: sakelar ID/box berlaku independen dan tidak mengubah jumlah. Terapkan threshold/model baru: hasil direset; foto diproses ulang, video siap Mulai dari sesi baru.
9. Coba YOLO26 dan YOLO11, lalu model gagal jika menambahkan model tidak kompatibel: error muncul dan model sebelumnya tetap digunakan. Tutup tanpa Terapkan: pengaturan inferensi tidak berubah.

Harness ini tidak menguji UIKit, PhotosPicker, izin kamera, frame capture fisik, maupun FPS/performa di iPhone. Laporan `local-report.json`/`local-integration.txt` lama adalah verifikasi versi sebelum UI khusus iOS/kamera langsung.

## Regresi ID tanpa kotak

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  -parse-as-library -module-cache-path /tmp/benur-swift-cache \
  'POC Udang/AppConfig.swift' 'POC Udang/Models/TrackingModels.swift' \
  'POC Udang/Services/NativeBoTSORT.swift' 'POC Udang/Services/OnDeviceInference.swift' \
  Tests/VerifyTrackPresentation.swift -o /tmp/benur-verify-presentation
/tmp/benur-verify-presentation
```

Memeriksa track low-confidence tetap dipulihkan secara internal tetapi tanpa label/count, frame kosong tidak mengeluarkan track hilang, total sesi tetap kumulatif, bbox/center mengikuti deteksi terbaru, prediksi Kalman keluar gambar tidak menghasilkan label yatim, serta penolakan box degenerat/kelas salah/ID tanpa deteksi. Tidak membuktikan model bebas false positive pada keyboard; itu memerlukan foto/video keyboard yang sama.

## Pengaturan dan kedua model

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O \
  -parse-as-library -module-cache-path /tmp/benur-swift-cache \
  'POC Udang/AppConfig.swift' 'POC Udang/Models/TrackingModels.swift' \
  'POC Udang/Services/NativeBoTSORT.swift' 'POC Udang/Services/OnDeviceInference.swift' \
  'POC Udang/Services/MediaReader.swift' Tests/VerifySettings.swift -o /tmp/benur-verify-settings
/tmp/benur-verify-settings
```

Memeriksa parser kedua model pada foto benur nyata, efek confidence 0,90, NMS IoU 0,20, dan penerusan snapshot pengaturan ke tracker/konfirmasi. Uji presentasi juga mencakup raw ID 99/800 menjadi 1/2 dan reset kembali 1. Build/harness belum mencakup interaksi sheet UIKit pada iPhone.
