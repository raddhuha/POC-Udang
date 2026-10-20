# Model lokal

Dua model hasil training benur sudah tersedia, kelas `0: shrimp`, input RGB640×640:

- `yolo26_best.mlpackage`: output `[1,300,6]` (pixel xyxy, confidence, class).
- `yolo11_best.mlpackage`: output `[1,5,8400]` (pixel center-x, center-y, width, height, score shrimp).

Xcode mengompilasi keduanya ke `.mlmodelc`. Tombol Pengaturan memilih model bundel; tidak membutuhkan server, ekspor ulang atau training ulang. Inferensi menerapkan filtering/NMS sesuai pengaturan UI. Model gagal/format tak kompatibel menampilkan error dan tidak mengganti model aktif.

Default ada di `AppConfig.swift`. Dukungan model tambahan membutuhkan input `image` dan output salah satu format yang didukung. Aplikasi saat ini memakai kelas `AppConfig.classIDs = [0]`.
