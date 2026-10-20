import SwiftUI
import PhotosUI
import Combine
import AVFoundation

@MainActor
final class CountingSession: ObservableObject {
    enum Mode { case photo, video }
    enum VideoSource { case gallery, camera }
    @Published var videoSource: VideoSource = .gallery
    @Published var mode: Mode = .photo
    @Published var image: UIImage?
    @Published var objects: [TrackedObject] = []
    @Published var currentCount = 0
    @Published var totalIDs = 0
    @Published private(set) var tracking: TrackingDiagnostics?
    @Published private(set) var trackingLogURL: URL?
    @Published var isBusy = false
    @Published var isRunning = false
    @Published var error: String?
    @Published var status = "Pilih foto atau ambil foto untuk memulai."
    @Published var progress = 0.0
    @Published private(set) var videoURL: URL?
    private(set) var observations: [TrackObservation] = []
    private var task: Task<Void, Never>?
    private var camera: LiveCamera?
    private var generation = UUID()
    private var activeRunID: UUID?
    @Published private(set) var settings = InferenceSettings()
    private var inference: OnDeviceInference
    private var photoJPEG: Data?
    var availableModels: [String] {
        let names = (Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
        return Array(Set(names + [settings.modelName])).sorted()
    }
    @Published private(set) var processedFrames = 0

    init(modelURL: URL? = nil) { inference = OnDeviceInference(modelURL: modelURL) }

    func reset() {
        stop()
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        videoURL = nil
        photoJPEG = nil
        clearResults()
        image = nil
        error = nil
        status = mode == .photo ? "Pilih foto atau ambil foto untuk memulai." : "Pilih video dari galeri atau gunakan kamera langsung."
    }

    func stop() {
        generation = UUID()
        camera?.stop()
        camera = nil
        task?.cancel()
        task = nil
        if isRunning { status = "Dihentikan. Hasil terakhir tetap ditampilkan." }
        isBusy = false
        isRunning = false
    }

    private func clearResults() {
        objects = []
        observations = []
        currentCount = 0
        totalIDs = 0
        tracking = nil
        trackingLogURL = nil
        activeRunID = nil
        progress = 0
        processedFrames = 0
    }

    func loadPhoto(_ item: PhotosPickerItem) {
        reset()
        isBusy = true
        status = "Memuat foto…"
        let token = generation
        task = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw MessageError("Foto tidak dapat dimuat dari galeri.")
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                try await processPhoto(data, token: token)
            } catch { fail(error, token: token) }
        }
    }

    func loadPhotoData(_ data: Data) {
        reset()
        isBusy = true
        let token = generation
        task = Task {
            do { try await processPhoto(data, token: token) }
            catch { fail(error, token: token) }
        }
    }

    private func processPhoto(_ data: Data, token: UUID) async throws {
        let jpeg = try await MediaReader().photo(data)
        try Task.checkCancellation()
        guard token == generation else { return }
        photoJPEG = jpeg
        image = UIImage(data: jpeg)
        status = "Mendeteksi benur…"
        let result = try await inference.photo(jpeg)
        try Task.checkCancellation()
        guard token == generation else { return }
        apply(result)
        isBusy = false
        status = String(format: "Selesai · confidence ≥ %.0f%% · NMS IoU %.2f", settings.confidence * 100, settings.nmsIoU)
    }

    func loadVideo(_ item: PhotosPickerItem) {
        reset()
        isBusy = true
        status = "Memuat video…"
        let token = generation
        task = Task {
            var imported: URL?
            let reader = MediaReader()
            do {
                guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                    throw MessageError("Video tidak dapat dimuat dari galeri.")
                }
                imported = video.url
                try Task.checkCancellation()
                _ = try await reader.open(video.url)
                guard let frame = try await reader.next() else { throw MessageError("Video kosong.") }
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                videoURL = video.url
                image = UIImage(data: frame.jpeg)
                isBusy = false
                status = "Video siap. Tekan Mulai."
            } catch {
                if let imported { try? FileManager.default.removeItem(at: imported) }
                fail(error, token: token)
            }
            await reader.cancel()
        }
    }

    func startVideo() {
        guard let videoURL, !isBusy else { return }
        stop()
        clearResults()
        image = nil
        error = nil
        isBusy = true
        isRunning = true
        status = "Menyiapkan model dan \(settings.backend.title)…"
        let token = generation
        let runID = UUID()
        activeRunID = runID
        task = Task {
            let reader = MediaReader()
            var processor: LocalVideoProcessor?
            var finishReason = "completed"
            do {
                let info = try await reader.open(videoURL)
                try Task.checkCancellation()
                let runningProcessor = LocalVideoProcessor(inference: inference, fps: info.fps, sourceReference: videoURL.lastPathComponent)
                processor = runningProcessor
                var frames = 0
                while let frame = try await reader.next() {
                    try Task.checkCancellation()
                    let result = try await runningProcessor.frame(frame.jpeg, timestamp: frame.timestamp, sourceFrameIndex: frame.sourceFrameIndex)
                    try Task.checkCancellation()
                    guard token == generation else { throw CancellationError() }
                    // Publish the exact frame and its annotations together: no playback drift.
                    image = UIImage(data: frame.jpeg)
                    apply(result)
                    frames += 1
                    processedFrames = frames
                    progress = min(1, frame.timestamp / info.duration)
                    status = String(format: "Memproses %.2f / %.2f detik · %d frame", frame.timestamp, info.duration, frames)
                }
                guard frames > 0 else { throw MessageError("Video kosong.") }
                if token == generation {
                    progress = 1
                    status = "Selesai. \(frames) frame diproses. Hasil terakhir tetap ditampilkan."
                    isBusy = false
                    isRunning = false
                }
            } catch {
                finishReason = Task.isCancelled ? "cancelled" : "failed"
                fail(error, token: token)
            }
            await reader.cancel()
            await finishTracking(processor, runID: runID, reason: finishReason)
        }
    }

    func startCamera() {
        guard !isBusy else { return }
        reset()
        isBusy = true
        isRunning = true
        status = "Menyiapkan kamera dan model…"
        let token = generation
        let runID = UUID()
        activeRunID = runID
        task = Task {
            var processor: LocalVideoProcessor?
            var finishReason = "completed"
            do {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw MessageError("Akses kamera ditolak. Izinkan kamera melalui Pengaturan iPhone.")
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                let liveCamera = LiveCamera()
                camera = liveCamera
                defer { liveCamera.stop() }
                let runningProcessor = LocalVideoProcessor(inference: inference, fps: AppConfig.cameraFPS, sourceReference: "live-camera")
                processor = runningProcessor
                for try await frame in liveCamera.start() {
                    try Task.checkCancellation()
                    let result = try await runningProcessor.frame(frame.jpeg, timestamp: frame.timestamp, sourceFrameIndex: frame.sourceFrameIndex)
                    try Task.checkCancellation()
                    guard token == generation else { throw CancellationError() }
                    // Both previews use exactly this processed frame, including its orientation.
                    image = UIImage(data: frame.jpeg)
                    apply(result)
                    processedFrames += 1
                    status = String(format: "Kamera langsung · %.1f detik · %d frame", frame.timestamp, processedFrames)
                }
                if token == generation { stop() }
            } catch {
                finishReason = Task.isCancelled ? "cancelled" : "failed"
                fail(error, token: token)
            }
            await finishTracking(processor, runID: runID, reason: finishReason)
        }
    }

    /// Validate the replacement before committing it. Threshold/model changes start a fresh session.
    func applySettings(_ updated: InferenceSettings) async -> Bool {
        guard updated != settings else { return true }
        stop()
        let token = generation
        isBusy = true
        error = nil
        status = "Memuat model…"
        do {
            let replacement = OnDeviceInference(settings: updated)
            try await replacement.prepare()
            guard token == generation else { return false }
            let savedPhoto = photoJPEG
            inference = replacement
            settings = updated
            clearResults()
            isBusy = false
            status = "Pengaturan diterapkan. Tekan Mulai untuk sesi baru dari ID 1."
            if mode == .photo, let savedPhoto { loadPhotoData(savedPhoto) }
            return true
        } catch {
            guard token == generation else { return false }
            isBusy = false
            self.error = error.localizedDescription
            status = "Model/pengaturan sebelumnya tetap digunakan."
            return false
        }
    }

    private func apply(_ result: FrameResult) {
        objects = result.objects
        currentCount = result.currentCount
        totalIDs = result.totalIDs
        tracking = result.tracking
        for object in result.objects {
            if let id = object.trackID {
                observations.append(TrackObservation(trackID: id, timestamp: result.timestamp,
                                                     bbox: object.bbox, center: object.center))
            }
        }
        // Full measurements are streamed to disk; UI retains only a small recent window.
        if observations.count > 2_048 { observations.removeFirst(observations.count - 2_048) }
    }

    private func finishTracking(_ processor: LocalVideoProcessor?, runID: UUID, reason: String) async {
        do {
            let url = try await processor?.finalize(reason: reason)
            if activeRunID == runID { trackingLogURL = url }
        } catch {
            if activeRunID == runID { self.error = "Log tracking gagal disimpan: \(error.localizedDescription)" }
        }
    }

    private func fail(_ failure: Error, token: UUID) {
        guard token == generation, !Task.isCancelled else { return }
        camera?.stop()
        camera = nil
        error = failure.localizedDescription
        status = "Pemrosesan gagal. Silakan coba lagi."
        isBusy = false
        isRunning = false
    }
}
