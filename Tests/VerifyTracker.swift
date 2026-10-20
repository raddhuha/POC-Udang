import Foundation

@main
struct VerifyTracker {
    struct Fixture: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let name: String
        let fps: Double
        let frames: [[LocalDetection]]
        let expected: [[NativeTrackResult]]
    }
    static func main() throws {
        let url = URL(fileURLWithPath: "Tests/tracker-reference.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var reference = InferenceSettings()
        reference.confidence = 0.25
        var frames = 0, maxError = 0.0
        for test in fixture.cases {
            let tracker = NativeBoTSORT(fps: test.fps, settings: reference)
            for (index, detections) in test.frames.enumerated() {
                let actual = tracker.update(detections).sorted { $0.id < $1.id }
                let expected = test.expected[index].sorted { $0.id < $1.id }
                precondition(actual.count == expected.count, "\(test.name) frame \(index): \(actual) != \(expected)")
                for (a,b) in zip(actual,expected) {
                    precondition(a.id == b.id && a.detectionIndex == b.detectionIndex,
                                 "\(test.name) frame \(index): ID/index mismatch \(a) vs \(b)")
                    for (x,y) in zip(a.bbox,b.bbox) {
                        let error = abs(x-y)
                        maxError = max(maxError, error)
                        precondition(error < 0.002, "\(test.name) frame \(index): Kalman box mismatch \(error)")
                    }
                }
                frames += 1
            }
        }
        let first = NativeBoTSORT(), second = NativeBoTSORT()
        let detection = LocalDetection(bbox:[10,10,40,40], confidence:0.9)
        precondition(first.update([detection]).first?.id == 1)
        precondition(second.update([detection]).first?.id == 1)
        precondition(first.update([detection]).first?.id == 1)
        let moved = first.update([LocalDetection(bbox:[30,15,60,45],confidence:0.9)],
                                 cameraTranslation: CGPoint(x:20,y:5))
        precondition(moved.first?.id == 1)
        print("PASS native BoT-SORT association/Kalman parity: \(fixture.cases.count) cases, \(frames) frames, max bbox error \(maxError) px")
        print("PASS independent session IDs, reset by fresh instance, and translation GMC application")
    }
}
