import Foundation

@main
struct VerifySettings {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let videos = try FileManager.default.contentsOfDirectory(at: root.deletingLastPathComponent().appendingPathComponent("video"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }
        let reader = MediaReader()
        _ = try await reader.open(videos[0])
        let frame = try await reader.next()!
        await reader.cancel()
        for model in ["yolo26_best", "yolo11_best"] {
            let url = root.appendingPathComponent("POC Udang/Models/\(model).mlpackage")
            var settings = InferenceSettings()
            settings.modelName = model
            let normal = OnDeviceInference(modelURL: url, settings: settings)
            try await normal.prepare()
            let result = try await normal.photo(frame.jpeg)
            precondition(result.currentCount > 0)
            settings.confidence = 0.9
            let strict = try await OnDeviceInference(modelURL: url, settings: settings).photo(frame.jpeg)
            precondition(strict.currentCount <= result.currentCount)
            precondition(strict.objects.allSatisfy { $0.confidence >= 0.9 })
            settings.confidence = 0.5
            settings.nmsIoU = 0.2
            let suppressed = try await OnDeviceInference(modelURL: url, settings: settings).photo(frame.jpeg)
            for (index, object) in suppressed.objects.enumerated() {
                precondition(object.hasValidBox)
                for other in suppressed.objects.dropFirst(index + 1) {
                    precondition(boxIoU(object.bbox, other.bbox) <= 0.2 + 1e-8)
                }
            }
            print("PASS \(model): baseline \(result.currentCount), confidence .90 → \(strict.currentCount), IoU .20 → \(suppressed.currentCount)")
        }
        var settings = InferenceSettings()
        settings.confidence = 0.8
        settings.confirmIDFrames = 2
        let tracker = NativeBoTSORT(settings: settings)
        var presentation = TrackPresentation(settings: settings)
        let weak = LocalDetection(bbox: [10, 10, 30, 30], confidence: 0.6)
        let rejected = presentation.result(detections: [weak], tracks: tracker.update([weak]), width: 100, height: 100, timestamp: 0)
        precondition(rejected.currentCount == 0 && rejected.totalIDs == 0)
        let strong = LocalDetection(bbox: weak.bbox, confidence: 0.95)
        var result: FrameResult!
        for index in 1...3 { // native tentative confirmation, then 2 visible strong frames
            result = presentation.result(detections: [strong], tracks: tracker.update([strong]), width: 100, height: 100, timestamp: Double(index))
            if index < 3 { precondition(result.totalIDs == 0) }
        }
        precondition(result.totalIDs == 1 && result.objects[0].trackID == 1)
        print("PASS runtime confidence and confirmation settings propagate to tracker/presentation")
    }
}
