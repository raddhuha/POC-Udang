import Foundation
import CoreGraphics

@main
struct VerifyKinematic {
    static func detection(_ x: Double, _ y: Double = 0, confidence: Double = 0.9) -> LocalDetection {
        LocalDetection(bbox: [x - 5, y - 5, x + 5, y + 5], confidence: confidence)
    }

    static func main() throws {
        try stationaryAndMotion()
        try gapsAndCompensation()
        try crossingAndUnmatched()
        try validationAndLifecycle()
        try baseline()
        exhaustiveAssignment()
        print("PASS kinematic backend: stationary, no-overlap motion, actual dt, gap/expiry, GMC, ambiguity/recovery, unmatched, validation, reset/finalize and baseline lifecycle")
    }

    static func stationaryAndMotion() throws {
        let stationary = TRexKinematicBackend()
        for frame in 0..<60 {
            let update = try stationary.update([detection(100)], timestamp: Double(frame) / 30)
            precondition(update.associations.count == 1 && update.associations[0].track.id == 1)
            precondition(update.associations[0].trackletID == 1 && !update.associations[0].ambiguous)
        }
        let moving = TRexKinematicBackend()
        for (time, x) in [(0.0, 0.0), (0.1, 20.0), (0.2, 40.0), (0.4, 80.0), (0.7, 140.0)] {
            let result = try moving.update([detection(x)], timestamp: time)
            precondition(result.associations.count == 1 && result.associations[0].track.id == 1,
                         "Actual dt and nonoverlapping boxes must preserve identity")
            precondition(result.associations[0].track.bbox == detection(x).bbox, "Output must be observed bbox")
        }
    }

    static func gapsAndCompensation() throws {
        let tracker = TRexKinematicBackend()
        _ = try tracker.update([detection(0)], timestamp: 0)
        let missing = try tracker.update([], timestamp: 0.1, cameraTranslation: CGPoint(x: 10, y: 0))
        precondition(missing.associations.isEmpty && missing.missingTrackIDs == [1] && missing.activeTrackIDs == [1])
        precondition(missing.events.contains { $0.kind == "tracklet_ended" && $0.detail == "missing" })
        let back = try tracker.update([detection(20)], timestamp: 0.2, cameraTranslation: CGPoint(x: 10, y: 0))
        precondition(back.associations.first?.track.id == 1 && back.associations.first?.trackletID == 2)
        precondition(back.events.contains { $0.kind == "reacquired" })
        let next = try tracker.update([detection(20)], timestamp: 0.3)
        precondition(next.associations.first?.track.id == 1 && next.associations.first?.trackletID == 2,
                     "Accumulated GMC must not become animal velocity")
        let expired = try tracker.update([detection(20)], timestamp: 1.31)
        precondition(expired.associations.first?.track.id == 2, "Expire BEFORE association")
        precondition(expired.activeTrackIDs == [2] && expired.events.contains { $0.kind == "removed" && $0.trackID == 1 })

        let skipped = TRexKinematicBackend()
        _ = try skipped.update([detection(0)], timestamp: 0)
        let skippedResult = try skipped.update([detection(0)], timestamp: 0.4)
        precondition(skippedResult.associations.first?.track.id == 1 && skippedResult.associations.first?.trackletID == 2)
        precondition(skippedResult.events.contains { $0.detail == "input_time_gap" })
    }

    static func crossingAndUnmatched() throws {
        let crossing = TRexKinematicBackend()
        _ = try crossing.update([detection(0), detection(40)], timestamp: 0)
        _ = try crossing.update([detection(10), detection(30)], timestamp: 0.1)
        let ambiguous = try crossing.update([detection(20), detection(20)], timestamp: 0.2)
        precondition(ambiguous.associations.count == 2 && ambiguous.associations.allSatisfy(\.ambiguous))
        precondition(Set(ambiguous.associations.map { $0.track.id }) == [1, 2])
        let recovered = try crossing.update([detection(30), detection(10)], timestamp: 0.3)
        precondition(recovered.associations.allSatisfy { !$0.ambiguous })
        precondition(recovered.events.filter { $0.kind == "tracklet_started" && $0.detail == "trust_restored" }.count == 2)
        precondition(Set(recovered.associations.map { $0.trackletID }).isDisjoint(with: ambiguous.associations.map { $0.trackletID }))

        let crowded = TRexKinematicBackend()
        _ = try crowded.update([detection(0), detection(20)], timestamp: 0)
        let merged = try crowded.update([detection(10)], timestamp: 0.1)
        precondition(merged.associations.count == 1 && merged.associations[0].ambiguous)
        precondition(merged.missingTrackIDs.count == 1, "Never give one measured detection to two IDs")

        let tracker = TRexKinematicBackend()
        _ = try tracker.update([detection(0)], timestamp: 0)
        let unmatched = try tracker.update([detection(54)], timestamp: 0.1)
        precondition(unmatched.associations.first?.track.id == 2 && unmatched.missingTrackIDs == [1],
                     "Low score INSIDE distance gate must permit unmatched")
        let far = try tracker.update([detection(1000)], timestamp: 0.2)
        precondition(far.associations.first?.track.id == 3 && far.candidateEdges == 0)
    }

    static func validationAndLifecycle() throws {
        let tracker = TRexKinematicBackend()
        let invalid = [LocalDetection(bbox: [0, 0, 1], confidence: 0.9),
                       LocalDetection(bbox: [0, 0, 0, 1], confidence: 0.9),
                       LocalDetection(bbox: [.nan, 0, 1, 1], confidence: 0.9),
                       LocalDetection(bbox: [0, 0, 1, 1], confidence: .nan),
                       LocalDetection(bbox: [0, 0, 1, 1], confidence: 0.9, classID: 1),
                       detection(0, confidence: 1.1), detection(0, confidence: 0.01)]
        let empty = try tracker.update(invalid, timestamp: -1)
        precondition(empty.associations.isEmpty && empty.activeTrackIDs.isEmpty)
        let weakNew = try tracker.update([detection(0, confidence: 0.1)], timestamp: -0.5)
        precondition(weakNew.associations.isEmpty, "Weak detection cannot create track")
        _ = try tracker.update([detection(0)], timestamp: 0)
        for badTime in [0.0, -1, Double.nan, Double.infinity] {
            do {
                _ = try tracker.update([], timestamp: badTime, cameraTranslation: CGPoint(x: 1000, y: 0))
                preconditionFailure("Timestamp must be rejected")
            } catch TrackingBackendError.invalidTimestamp { }
        }
        do {
            _ = try tracker.update([], timestamp: 0.1, cameraTranslation: CGPoint(x: Double.infinity, y: 0))
            preconditionFailure("Invalid camera shift must be rejected")
        } catch TrackingBackendError.invalidCameraTranslation { }
        let weakRecovery = try tracker.update([detection(0, confidence: 0.1)], timestamp: 0.1)
        precondition(weakRecovery.associations.first?.track.id == 1, "Invalid updates must not mutate timestamp/position")
        precondition(weakRecovery.associations.first?.track.confidence == 0.1)
        let ended = tracker.finalize()
        precondition(ended.count == 1 && ended[0].kind == "tracklet_ended")
        precondition(tracker.finalize().isEmpty)
        tracker.reset()
        let restarted = try tracker.update([detection(0)], timestamp: 0)
        precondition(restarted.associations.first?.track.id == 1 && restarted.associations.first?.trackletID == 1)
        let serialized = try JSONEncoder().encode(InferenceSettings())
        let decoded = try JSONDecoder().decode(InferenceSettings.self, from: serialized)
        precondition(decoded == InferenceSettings())
    }

    static func baseline() throws {
        let baseline = ExistingBoTSORTBackend(fps: 2)
        _ = try baseline.update([detection(0)], timestamp: 0)
        let firstMissing = try baseline.update([], timestamp: 0.1)
        precondition(firstMissing.associations.isEmpty && firstMissing.missingTrackIDs == [1])
        let secondMissing = try baseline.update([], timestamp: 0.2)
        precondition(secondMissing.activeTrackIDs == [1], "Baseline should follow its original frame buffer")
        let removed = try baseline.update([], timestamp: 0.3)
        precondition(removed.activeTrackIDs.isEmpty && removed.events.contains { $0.kind == "removed" })
        baseline.reset()
        let restarted = try baseline.update([detection(0)], timestamp: 0)
        precondition(restarted.associations.first?.track.id == 1)
    }

    static func exhaustiveAssignment() {
        let threshold = 0.8, values = [0.0, 0.3, 0.8, 1e6]
        var checked = 0
        func enumerate(_ costs: [[Double]], rows: Int, columns: Int) -> Double {
            func best(_ row: Int, _ used: Set<Int>) -> Double {
                if row == rows { return 0 }
                var result = threshold + best(row + 1, used)
                for column in 0..<columns where !used.contains(column) && costs[row][column] <= threshold {
                    result = min(result, costs[row][column] + best(row + 1, used.union([column])))
                }
                return result
            }
            return best(0, [])
        }
        for (rows, columns) in [(1, 1), (1, 3), (2, 2), (2, 3), (3, 2)] {
            let combinations = Int(pow(Double(values.count), Double(rows * columns)))
            for combination in 0..<combinations {
                var encoded = combination
                var costs = Array(repeating: Array(repeating: 0.0, count: columns), count: rows)
                for row in 0..<rows {
                    for column in 0..<columns {
                        costs[row][column] = values[encoded % values.count]
                        encoded /= values.count
                    }
                }
                let result = Assignment.solve(costs, rows: rows, columns: columns, threshold: threshold)
                let actual = result.matches.reduce(Double(result.rows.count) * threshold) { $0 + costs[$1.0][$1.1] }
                precondition(abs(actual - enumerate(costs, rows: rows, columns: columns)) < 1e-9)
                precondition(Set(result.matches.map { $0.0 }).count == result.matches.count)
                precondition(Set(result.matches.map { $0.1 }).count == result.matches.count)
                precondition(result.matches.allSatisfy { costs[$0.0][$0.1] <= threshold })
                let repeated = Assignment.solve(costs, rows: rows, columns: columns, threshold: threshold)
                precondition(result.matches.map { [$0.0, $0.1] } == repeated.matches.map { [$0.0, $0.1] })
                checked += 1
            }
        }
        precondition(Assignment.solve([], rows: 0, columns: 2, threshold: threshold).columns == [0, 1])
        precondition(Assignment.solve([[]], rows: 1, columns: 0, threshold: threshold).rows == [0])
        print("PASS global assignment vs exhaustive enumeration: \(checked) matrices, forbidden edges, unmatched and deterministic ties")
    }
}
