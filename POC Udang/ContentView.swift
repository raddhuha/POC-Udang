import SwiftUI
import PhotosUI
import AVFoundation

struct ContentView: View {
    @StateObject private var session = CountingSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PhotosPickerItem?
    @State private var video: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var showIDs = true
    @State private var showBoxes = true
    @State private var showConfidence = true
    @State private var videoControlsVisible = true

    var body: some View {
        Group {
            if session.mode == .video { videoScreen }
            else { photoScreen }
        }
        .onChange(of: session.mode) { _, _ in resetSelection() }
        .onChange(of: session.videoSource) { _, _ in resetSelection() }
        .onChange(of: photo) { _, item in if let item { session.loadPhoto(item) } }
        .onChange(of: video) { _, item in if let item { session.loadVideo(item) } }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                showCamera = false
                if let data { session.loadPhotoData(data) }
            }.ignoresSafeArea()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(session: session, showIDs: $showIDs, showBoxes: $showBoxes, showConfidence: $showConfidence)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && session.isRunning { session.stop() }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        HStack {
            Picker("Mode", selection: $session.mode) {
                Text("Foto").tag(CountingSession.Mode.photo)
                Text("Video").tag(CountingSession.Mode.video)
            }.pickerStyle(.segmented)
            Button {
                session.stop()
                showSettings = true
            } label: { Image(systemName: "slider.horizontal.3").font(.title3).padding(8) }
                .accessibilityLabel("Pengaturan")
        }
    }

    private var videoScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MediaPreview(image: session.image, objects: session.objects, showIDs: showIDs,
                         showBoxes: showBoxes, showConfidence: showConfidence, cornerRadius: 0)
                .ignoresSafeArea()
                .onTapGesture { videoControlsVisible.toggle() }
            if videoControlsVisible {
                VStack {
                    VStack(spacing: 10) {
                        HStack {
                            header
                            Button { videoControlsVisible = false } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8)
                            }.accessibilityLabel("Sembunyikan kontrol video")
                        }
                        Picker("Sumber video", selection: $session.videoSource) {
                            Text("Galeri").tag(CountingSession.VideoSource.gallery)
                            Text("Kamera langsung").tag(CountingSession.VideoSource.camera)
                        }.pickerStyle(.segmented)
                    }.padding(16).background(.ultraThinMaterial)
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Terdeteksi sekarang: \(session.currentCount)").font(.headline)
                        Text("Total ID tercatat: \(session.totalIDs)").font(.headline)
                        Text("ID sementara per sesi; total ID bukan jumlah pasti benur. Tanda ? berarti pasangan ambigu.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let tracking = session.tracking {
                            Text("\(tracking.backend.title) · terlihat ber-ID \(tracking.confirmedVisible) · hilang \(tracking.missingConfirmed)")
                                .font(.caption)
                            Text("Tracklet \(tracking.totalTracklets) · ambigu \(tracking.ambiguousMatches) · ReID belum tersedia")
                                .font(.caption).foregroundStyle(.secondary)
                            if tracking.archiveTruncated {
                                Text("Batas ukuran log tercapai; tracking tetap berjalan.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let url = session.trackingLogURL {
                            ShareLink(item: url) { Label("Ekspor log tracking", systemImage: "square.and.arrow.up") }.font(.caption)
                        }
                        status
                        if session.isRunning && session.videoSource == .gallery { ProgressView(value: session.progress) }
                        HStack {
                            if session.videoSource == .gallery {
                                PhotosPicker(selection: $video, matching: .videos) {
                                    Label("Pilih video", systemImage: "video")
                                }.disabled(session.isBusy)
                            }
                            Spacer()
                            if session.isRunning {
                                Button("Hentikan", role: .destructive) { session.stop() }
                            } else {
                                Button("Mulai") {
                                    if session.videoSource == .camera { session.startCamera() }
                                    else { session.startVideo() }
                                }.disabled(session.isBusy || (session.videoSource == .gallery && session.videoURL == nil))
                            }
                        }.buttonStyle(.borderedProminent)
                    }.padding(16).background(.ultraThinMaterial)
                }
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button { videoControlsVisible = true } label: {
                            Image(systemName: "slider.horizontal.3").padding(12).background(.ultraThinMaterial, in: Circle())
                        }.accessibilityLabel("Tampilkan kontrol video")
                    }
                    Spacer()
                }.padding()
            }
            if session.isBusy && session.image == nil { ProgressView().tint(.white) }
        }.environment(\.colorScheme, .dark)
            .onChange(of: session.isRunning) { _, running in if !running { videoControlsVisible = true } }
    }

    private var photoScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hitung benur").font(.largeTitle.bold())
                header
                Text("Jumlah benur: \(session.currentCount)").font(.title2.bold())
                HStack {
                    Button {
                        Task {
                            if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true }
                            else { session.error = "Akses kamera ditolak. Izinkan kamera melalui Pengaturan iPhone." }
                        }
                    } label: { Label("Ambil foto", systemImage: "camera") }
                        .disabled(!CameraPicker.isAvailable || session.isBusy)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Pilih foto", systemImage: "photo")
                    }.disabled(session.isBusy)
                }.buttonStyle(.borderedProminent)
                if session.image != nil { Button("Foto ulang") { session.reset(); photo = nil } }
                status
                if session.isBusy { ProgressView() }
                Text("Hasil deteksi").font(.headline)
                MediaPreview(image: session.image, objects: session.objects, showIDs: showIDs, showBoxes: showBoxes, showConfidence: showConfidence)
                    .frame(height: 250)
                Text("Gambar asli").font(.headline)
                MediaPreview(image: session.image, objects: []).frame(height: 250)
            }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.status).font(.caption).foregroundStyle(.secondary)
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func resetSelection() {
        session.reset()
        videoControlsVisible = true
        photo = nil
        video = nil
    }
}
