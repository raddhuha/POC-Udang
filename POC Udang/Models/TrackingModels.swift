import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct TrackedObject: Codable, Identifiable, Sendable {
    let trackID: Int?
    let confidence: Double
    /// Normalized top-left x1, y1, x2, y2 matching the displayed JPEG.
    let bbox: [Double]
    let center: [Double]
    let trail: [[Double]]
    var ambiguous: Bool = false
    var hasValidBox: Bool {
        bbox.count == 4 && bbox.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && bbox[2] > bbox[0] && bbox[3] > bbox[1]
    }
    var id: String { trackID.map(String.init) ?? "\(bbox)" }
    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case confidence, bbox, center, trail, ambiguous
    }
}

struct FrameResult: Codable, Sendable {
    let timestamp: Double
    let currentCount: Int
    let totalIDs: Int
    let objects: [TrackedObject]
    var tracking: TrackingDiagnostics? = nil
    enum CodingKeys: String, CodingKey {
        case timestamp, objects, tracking
        case currentCount = "current_count"
        case totalIDs = "total_ids"
    }
}

/// Snapshot only; missing predictions never become visible measured objects.
struct TrackingDiagnostics: Codable, Sendable {
    let sessionID: UUID
    let trackingEpochID: UUID
    let backend: TrackingBackendKind
    let confirmedVisible: Int
    let missingConfirmed: Int
    let totalTracklets: Int
    let ambiguousMatches: Int
    let candidateEdges: Int
    let associationMilliseconds: Double
    let processingMilliseconds: Double
    let skippedInputFrames: Int
    let archiveTruncated: Bool
}

struct RecordedAssociation: Codable, Sendable {
    let association: TrackAssociation
    let displayID: Int?
    // Associations always refer to real measurements at detectionIndex, never predictions.
    var observed = true
}

struct TrackingFrameRecord: Codable, Sendable {
    let timestamp: Double
    let sourceFrameIndex: Int
    let processedFrameIndex: Int
    let width: Int
    let height: Int
    let detections: [LocalDetection]
    let associations: [RecordedAssociation]
    let missingTrackIDs: [Int]
    let events: [TrackingEvent]
    let diagnostics: TrackingDiagnostics
    let cameraTranslation: [Double]
    let cameraCompensation: String
}

struct TrackObservation: Sendable {
    let trackID: Int
    let timestamp: Double
    let bbox: [Double]
    let center: [Double]
}

struct PickedVideo: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}
