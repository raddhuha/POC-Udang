import Foundation

/// Default aplikasi. Confidence, IoU, konfirmasi ID, dan model juga dapat diubah dari tombol Pengaturan.
enum AppConfig {
    static let modelName = "yolo11_best"
    static let classIDs: Set<Int> = [0] // 0 = shrimp pada model ini.

    static let confidence = 0.15       // Foto + deteksi kuat video.
    static let nmsIoU = 0.30           // Lebih rendah: lebih banyak box tumpang tindih dibuang.
    static let lowConfidence = 0.10    // Harus < confidence; hanya untuk memulihkan track.
    static let confirmIDFrames = 3      // Deteksi kuat berturut-turut sebelum ID ditampilkan/dicatat.

    // Ambang COST asosiasi, bukan NMS IoU: lebih tinggi = pencocokan lebih longgar.
    static let matchCost = 0.80
    static let lowMatchCost = 0.50
    static let tentativeMatchCost = 0.70
    static let fuseScore = true
    static let lostTrackSeconds = 1.0
    static let duplicateTrackIoU = 0.85
    static let cameraMotionCompensation = true

    static let trailLength = 30
    static let trailGapSeconds = 1.0
    static let previewMaxDimension = 1280.0
    static let jpegQuality = 0.90
    static let cameraFPS = 10.0        // Batas frame masuk inferensi; FPS aktual mengikuti perangkat.
}

/// Snapshot per sesi. Pengaturan UI tidak mengubah tracker yang sedang berjalan.
enum TrackingBackendKind: String, CaseIterable, Codable, Sendable {
    case kinematic
    case botSort

    var title: String {
        switch self {
        case .kinematic: return "Kinematik (adaptasi TRex)"
        case .botSort: return "BoT-SORT (baseline)"
        }
    }
}

/// Bbox-only application heuristics, not the numeric defaults/probabilities of TRex.
/// Distances use processed oriented frame pixels (preview max 1280), so tune maxSpeed
/// on representative recordings at the same input scale.
struct KinematicTrackingConfiguration: Codable, Equatable, Sendable {
    var maxSpeed = 450.0 // processed oriented frame pixels / second
    var lostTrackSeconds = AppConfig.lostTrackSeconds
    var minimumMatchScore = 0.12
    var trustedScore = 0.55
    var ambiguityMargin = 0.12
    var velocitySmoothingSeconds = 0.15
    var trackletGapSeconds = 0.35 // also split when input skips an unusually long interval
    var bodyUncertaintyScale = 0.75 // bbox diagonal surrogate, not measured body length
}

struct InferenceSettings: Codable, Equatable, Sendable {
    var modelName = AppConfig.modelName
    var confidence = AppConfig.confidence
    var nmsIoU = AppConfig.nmsIoU
    var confirmIDFrames = AppConfig.confirmIDFrames
    var backend = TrackingBackendKind.kinematic
    var kinematic = KinematicTrackingConfiguration()
    var lowConfidence: Double { min(AppConfig.lowConfidence, confidence / 2) }
}
