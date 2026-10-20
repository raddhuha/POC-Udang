import Foundation

@main
struct VerifyTrackPresentation {
    static func main() {
        let strong = LocalDetection(bbox: [10, 20, 30, 40], confidence: 0.95)
        let weak = LocalDetection(bbox: strong.bbox, confidence: (AppConfig.lowConfidence + AppConfig.confidence) / 2)
        let tracker = NativeBoTSORT()
        var presentation = TrackPresentation()
        var first: FrameResult!
        for frame in 0..<AppConfig.confirmIDFrames {
            first = presentation.result(detections: [strong], tracks: tracker.update([strong]), width: 100, height: 100,
                                        timestamp: Double(frame) * 0.01)
            if frame < AppConfig.confirmIDFrames - 1 {
                precondition(first.totalIDs == 0 && first.objects[0].trackID == nil)
            }
        }
        precondition(first.currentCount == 1 && first.totalIDs == 1 && first.objects[0].trackID == 1)
        let recovered = tracker.update([weak])
        precondition(recovered.first?.id == 1, "Low-score association must still preserve the tracker internally")
        let low = presentation.result(detections: [weak], tracks: recovered, width: 100, height: 100, timestamp: 0.1)
        precondition(low.currentCount == 0 && low.objects.isEmpty && low.totalIDs == 1)
        let emptyTracks = tracker.update([])
        precondition(emptyTracks.isEmpty, "Lost track must not be returned as visible")
        let empty = presentation.result(detections: [], tracks: emptyTracks, width: 100, height: 100, timestamp: 0.2)
        precondition(empty.objects.isEmpty && empty.currentCount == 0 && empty.totalIDs == 1)
        print("PASS low-score/empty frames: no boxes, no labels, no count growth; session total retained")

        // A shifted/collapsed Kalman box must never become the display box.
        let prediction = NativeTrackResult(id: 1, detectionIndex: 0, bbox: [200, 200, 210, 210], confidence: 0.95)
        let visible = presentation.result(detections: [strong], tracks: [prediction], width: 100, height: 100, timestamp: 0.3)
        precondition(visible.objects[0].bbox == [0.1, 0.2, 0.3, 0.4])
        precondition(visible.objects[0].center == [0.2, (0.2 + 0.4) / 2])
        precondition(visible.objects[0].trail.last == visible.objects[0].center)
        print("PASS ID/box/trail use the current measured detection, not a Kalman prediction")

        var clean = TrackPresentation()
        let invalid = [
            LocalDetection(bbox: [200, 200, 210, 210], confidence: 0.95),
            LocalDetection(bbox: [10, 10, 10, 20], confidence: 0.95),
            LocalDetection(bbox: [.nan, 10, 20, 20], confidence: 0.95),
            LocalDetection(bbox: [1, 2], confidence: 0.95),
            LocalDetection(bbox: [30, 40, 10, 20], confidence: 0.95),
            LocalDetection(bbox: strong.bbox, confidence: 0.95, classID: 999)
        ]
        let invalidTracks = invalid.indices.map { NativeTrackResult(id: $0 + 1, detectionIndex: $0, bbox: strong.bbox, confidence: 0.95) }
        let rejected = clean.result(detections: invalid, tracks: invalidTracks, width: 100, height: 100, timestamp: 0)
        precondition(rejected.objects.isEmpty && rejected.totalIDs == 0)
        let orphan = clean.result(detections: [], tracks: [prediction], width: 100, height: 100, timestamp: 0.1)
        precondition(orphan.currentCount == 0 && orphan.totalIDs == 0)
        let untracked = clean.result(detections: [strong], tracks: [], width: 100, height: 100, timestamp: 0.2)
        precondition(untracked.currentCount == 1 && untracked.totalIDs == 0 && untracked.objects[0].trackID == nil)
        print("PASS invalid boxes/classes and orphan track IDs cannot produce visible IDs or totals")
        // A one-frame false alarm and interrupted confirmations must never enter the total.
        var transient = TrackPresentation()
        let candidate = NativeTrackResult(id: 99, detectionIndex: 0, bbox: strong.bbox, confidence: 0.95)
        if AppConfig.confirmIDFrames > 1 {
            for index in 0..<6 {
                let result = transient.result(detections: index % 2 == 0 ? [strong] : [], tracks: [candidate],
                                              width: 100, height: 100, timestamp: Double(index))
                precondition(result.totalIDs == 0 && result.objects.allSatisfy { $0.trackID == nil })
            }
        }
        print("PASS transient detections cannot create IDs; new IDs require consecutive strong detections")
        var numbered = TrackPresentation()
        let raw99 = NativeTrackResult(id: 99, detectionIndex: 0, bbox: strong.bbox, confidence: 0.95)
        let raw800 = NativeTrackResult(id: 800, detectionIndex: 1, bbox: strong.bbox, confidence: 0.95)
        var last: FrameResult!
        for frame in 0..<AppConfig.confirmIDFrames {
            last = numbered.result(detections: [strong], tracks: [raw99], width: 100, height: 100, timestamp: Double(frame))
        }
        precondition(last.objects[0].trackID == 1 && last.totalIDs == 1)
        for frame in 0..<AppConfig.confirmIDFrames {
            last = numbered.result(detections: [strong, strong], tracks: [raw99, raw800], width: 100, height: 100,
                                   timestamp: Double(frame + 10))
        }
        precondition(last.objects.compactMap(\.trackID) == [1, 2] && last.totalIDs == 2)
        numbered = TrackPresentation()
        for frame in 0..<AppConfig.confirmIDFrames {
            last = numbered.result(detections: [strong], tracks: [raw99], width: 100, height: 100, timestamp: Double(frame))
        }
        precondition(last.objects[0].trackID == 1 && last.totalIDs == 1)
        print("PASS raw IDs 99/800 display as 1/2; a fresh session starts at 1 again")
        print("TRACK PRESENTATION REGRESSION PASSED")
    }
}
