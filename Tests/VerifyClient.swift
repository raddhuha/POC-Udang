// Native inference/tracking regression on Mac. No app UI or camera hardware coverage.
import Foundation
import CoreImage
import Darwin

@main
struct VerifyClient {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let media = root.deletingLastPathComponent()
        let videos = try FileManager.default.contentsOfDirectory(at: media.appendingPathComponent("video"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" }.sorted { $0.path < $1.path }
        precondition(videos.count >= 2)
        let modelName = CommandLine.arguments.first(where: { $0.hasPrefix("--model=") })?.replacingOccurrences(of: "--model=", with: "") ?? AppConfig.modelName
        let modelURL = root.appendingPathComponent("POC Udang/Models/\(modelName).mlpackage")
        let inference = OnDeviceInference(modelURL: modelURL)
        let full = CommandLine.arguments.contains("--full")
        var reports: [[String: Any]] = []
        let reader = MediaReader()
        _ = try await reader.open(videos[0])
        let still = try await reader.next()!
        await reader.cancel()
        let photo = try await inference.photo(still.jpeg)
        precondition(photo.currentCount > 0 && photo.totalIDs == 0)
        check(photo)
        precondition(photo.objects.allSatisfy { $0.confidence >= AppConfig.confidence })
        for (index, object) in photo.objects.enumerated() {
            for other in photo.objects.dropFirst(index + 1) {
                precondition(boxIoU(object.bbox, other.bbox) <= AppConfig.nmsIoU + 1e-8)
            }
        }
        print("PASS photo: \(photo.currentCount) benur; confidence=\(AppConfig.confidence), IoU=\(AppConfig.nmsIoU)")
        if CommandLine.arguments.contains("--photo-only") { return }
        for url in videos {
            let reader = MediaReader()
            let info = try await reader.open(url)
            let processor = LocalVideoProcessor(inference: inference, fps: info.fps)
            var ids = Set<Int>(), frames = 0, last: FrameResult?
            while let frame = try await reader.next() {
                let result = try await processor.frame(frame.jpeg, timestamp: frame.timestamp)
                check(result)
                ids.formUnion(result.objects.compactMap(\.trackID))
                precondition(result.totalIDs == ids.count)
                last = result
                frames += 1
                if frames % 200 == 0 { print("PROGRESS: \(frames) frames") }
                if !full && frames == 60 { break }
            }
            await reader.cancel()
            precondition(frames > 0 && !ids.isEmpty)
            reports.append(["video": url.lastPathComponent, "frames": frames, "total_ids": last!.totalIDs])
            print("PASS video: \(frames) frames; \(ids.count) confirmed IDs")
        }
        // Fresh processors reset IDs/trails; camera path accepts portrait JPEG with relative timestamps.
        let ci = CIImage(data: still.jpeg)!.oriented(.right)
        let portrait = try MediaReader.encode(ci, context: CIContext())
        for _ in 0..<2 {
            let processor = LocalVideoProcessor(inference: inference, fps: AppConfig.cameraFPS)
            var first: FrameResult!
            for index in 0..<AppConfig.confirmIDFrames {
                first = try await processor.frame(portrait, timestamp: Double(index) * 0.01)
                check(first)
                if index < AppConfig.confirmIDFrames - 1 { precondition(first.totalIDs == 0) }
            }
            precondition(first.totalIDs > 0 && first.objects.compactMap(\.trackID).min() == 1)
            precondition(first.objects.filter { $0.trackID != nil }.allSatisfy { $0.trail.count == 1 })
            let next = try await processor.frame(portrait, timestamp: 1)
            check(next)
            precondition(next.totalIDs == first.totalIDs)
            do {
                _ = try await processor.frame(portrait, timestamp: 1)
                preconditionFailure("Duplicate timestamp must fail")
            } catch is MessageError {}
        }
        print("PASS portrait frames, sequential camera timestamps, fresh session IDs/trails")
        do { _ = try await inference.photo(Data("invalid".utf8)); preconditionFailure("Corrupt image must fail") }
        catch is MessageError {}
        let missing = OnDeviceInference(modelURL: URL(fileURLWithPath: "/tmp/missing-benur.mlmodelc"))
        do { _ = try await missing.photo(still.jpeg); preconditionFailure("Missing model must fail") }
        catch is MessageError {}
        print("PASS corrupt media / missing model errors")
        let report: [String: Any] = ["runtime": "native Core ML + Swift", "scope": full ? "full videos" : "60-frame samples",
                                   "photo_count": photo.currentCount, "videos": reports,
                                   "portrait_reset_errors": "passed", "physical_camera": "not tested"]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("verification"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("verification/ios-core-\(modelName)-report.json"))
        print("NATIVE CORE REGRESSION PASSED")
    }
    static func check(_ result: FrameResult) {
        precondition(result.currentCount == result.objects.count)
        for object in result.objects {
            precondition(object.bbox.count == 4 && object.bbox.allSatisfy { $0.isFinite && (0...1).contains($0) })
            precondition(object.center.count == 2 && object.trail.count <= AppConfig.trailLength)
            precondition(abs(object.center[0] - (object.bbox[0] + object.bbox[2]) / 2) < 1e-8)
            precondition(abs(object.center[1] - (object.bbox[1] + object.bbox[3]) / 2) < 1e-8)
        }
    }
}
