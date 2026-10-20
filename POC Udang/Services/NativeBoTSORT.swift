import Foundation
import CoreGraphics

// Native port of the no-ReID BoT-SORT association/Kalman path in Ultralytics 8.4.177.
// Upstream: https://github.com/ultralytics/ultralytics (AGPL-3.0).
// GMC is supplied separately by Apple Vision translation registration, not OpenCV sparseOptFlow.
struct LocalDetection: Codable, Sendable {
    var bbox: [Double] // original-image pixel xyxy
    var confidence: Double
    var classID: Int = 0
    var measurement: [Double] {
        [(bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2, bbox[2] - bbox[0], bbox[3] - bbox[1]]
    }
}

/// XYWH Kalman has four independent position/velocity blocks. This representation is
/// algebraically equivalent to the upstream 8×8 covariance for translation-only GMC.
private struct KalmanAxis {
    var position: Double
    var velocity = 0.0
    var p00: Double
    var p01 = 0.0
    var p10 = 0.0
    var p11: Double

    init(position: Double, dimension: Double) {
        self.position = position
        p00 = pow(2 * dimension / 20, 2)
        p11 = pow(10 * dimension / 160, 2)
    }
    mutating func predict(dimension: Double) {
        position += velocity
        p00 += p01 + p10 + p11 + pow(dimension / 20, 2)
        p01 += p11
        p10 += p11
        p11 += pow(dimension / 160, 2)
    }
    mutating func update(_ measurement: Double, dimension: Double) {
        let innovationVariance = p00 + pow(dimension / 20, 2)
        let k0 = p00 / max(innovationVariance, 1e-12)
        let k1 = p10 / max(innovationVariance, 1e-12)
        let innovation = measurement - position
        position += k0 * innovation
        velocity += k1 * innovation
        let old00 = p00, old01 = p01
        p00 -= k0 * old00
        p01 -= k0 * old01
        p10 -= k1 * old00
        p11 -= k1 * old01
    }
}

private final class NativeTrack {
    enum State { case tracked, lost, removed }
    let id: Int
    let startFrame: Int
    var endFrame: Int
    var confirmed: Bool
    var state: State = .tracked
    var axes: [KalmanAxis]
    var detectionIndex: Int
    var score: Double
    var classID: Int
    private(set) var bbox: [Double]

    init(id: Int, detection: LocalDetection, index: Int, frame: Int) {
        self.id = id
        bbox = detection.bbox
        startFrame = frame
        endFrame = frame
        confirmed = frame == 1 // Same first-frame activation convention as Ultralytics.
        detectionIndex = index
        score = detection.confidence
        classID = detection.classID
        let m = detection.measurement
        axes = (0..<4).map { KalmanAxis(position: m[$0], dimension: m[$0 % 2 + 2]) }
    }
    private func refreshBox() {
        let x = axes[0].position, y = axes[1].position
        let halfWidth = axes[2].position / 2, halfHeight = axes[3].position / 2
        bbox = [x - halfWidth, y - halfHeight, x + halfWidth, y + halfHeight]
    }
    func predict() {
        if state != .tracked { axes[2].velocity = 0; axes[3].velocity = 0 }
        let width = max(axes[2].position, 1e-6), height = max(axes[3].position, 1e-6)
        for i in 0..<4 { axes[i].predict(dimension: i % 2 == 0 ? width : height) }
        refreshBox()
    }
    func translate(_ shift: CGPoint) {
        axes[0].position += shift.x
        axes[1].position += shift.y
        refreshBox()
    }
    func update(_ detection: LocalDetection, index: Int, frame: Int) {
        let m = detection.measurement
        let width = max(axes[2].position, 1e-6), height = max(axes[3].position, 1e-6)
        for i in 0..<4 { axes[i].update(m[i], dimension: i % 2 == 0 ? width : height) }
        refreshBox()
        detectionIndex = index
        score = detection.confidence
        classID = detection.classID
        endFrame = frame
        state = .tracked
        confirmed = true
    }
}

struct NativeTrackResult: Codable, Sendable {
    let id: Int
    let detectionIndex: Int
    let bbox: [Double]
    let confidence: Double
}

final class NativeBoTSORT {
    let trackBuffer: Int
    private let settings: InferenceSettings
    private(set) var frameID = 0
    private var nextID = 1
    private var tracked: [NativeTrack] = []
    private var lost: [NativeTrack] = []
    private var removedHistory: [Int] = []

    /// Read-only lifecycle snapshot for the backend adapter; does not alter native matching.
    var activeTrackIDs: [Int] {
        Array(Set((tracked + lost).filter { $0.state != .removed }.map(\.id))).sorted()
    }

    init(fps: Double = 30, settings: InferenceSettings = InferenceSettings()) {
        self.settings = settings
        trackBuffer = max(1, Int((fps * AppConfig.lostTrackSeconds).rounded()))
    }

    func update(_ detections: [LocalDetection], cameraTranslation: CGPoint = .zero) -> [NativeTrackResult] {
        frameID += 1
        let valid = detections.indices.filter {
            detections[$0].bbox.count == 4 && detections[$0].bbox.allSatisfy(\.isFinite)
                && detections[$0].confidence.isFinite
                && detections[$0].bbox[2] > detections[$0].bbox[0]
                && detections[$0].bbox[3] > detections[$0].bbox[1]
        }
        let high = valid.filter { detections[$0].confidence >= settings.confidence }
        let low = valid.filter { detections[$0].confidence > settings.lowConfidence && detections[$0].confidence < settings.confidence }
        let unconfirmed = tracked.filter { !$0.confirmed }
        let pool = tracked.filter(\.confirmed) + lost
        for track in pool { track.predict(); track.translate(cameraTranslation) }
        for track in unconfirmed { track.translate(cameraTranslation) }

        let first = associate(pool, high, detections, threshold: AppConfig.matchCost, fuseScore: AppConfig.fuseScore)
        for (t, d) in first.matches { pool[t].update(detections[high[d]], index: high[d], frame: frameID) }
        let remainingTracked = first.rows.map { pool[$0] }.filter { $0.state == .tracked }
        let second = associate(remainingTracked, low, detections, threshold: AppConfig.lowMatchCost, fuseScore: false)
        for (t, d) in second.matches {
            remainingTracked[t].update(detections[low[d]], index: low[d], frame: frameID)
        }
        for index in second.rows { remainingTracked[index].state = .lost }

        let remainingHigh = first.columns.map { high[$0] }
        let tentative = associate(unconfirmed, remainingHigh, detections, threshold: AppConfig.tentativeMatchCost, fuseScore: AppConfig.fuseScore)
        for (t, d) in tentative.matches {
            unconfirmed[t].update(detections[remainingHigh[d]], index: remainingHigh[d], frame: frameID)
        }
        for index in tentative.rows { unconfirmed[index].state = .removed }
        var added: [NativeTrack] = []
        for d in tentative.columns {
            let index = remainingHigh[d]
            if detections[index].confidence >= settings.confidence {
                added.append(NativeTrack(id: nextID, detection: detections[index], index: index, frame: frameID))
                nextID += 1
            }
        }
        // Upstream expires previously lost tracks after association; re-found tracks survive.
        var expiredThisFrame = Set<Int>()
        for track in lost where track.state == .lost && frameID - track.endFrame > trackBuffer {
            track.state = .removed
            expiredThisFrame.insert(track.id)
        }
        let all = pool + unconfirmed + added
        tracked = all.filter { $0.state == .tracked }
        // Ultralytics retains newly expired lost entries until next frame's merge.
        let previouslyRemoved = Set(removedHistory)
        lost = all.filter { ($0.state == .lost || expiredThisFrame.contains($0.id)) && !previouslyRemoved.contains($0.id) }
        removedHistory.append(contentsOf: all.filter { $0.state == .removed }.map(\.id))
        removedHistory = Array(removedHistory.suffix(1000))
        // Suppress tracked/lost duplicate identities using the upstream 0.15 distance rule.
        var duplicateTracked = Set<Int>(), duplicateLost = Set<Int>()
        for a in tracked {
            for b in lost where boxIoU(a.bbox, b.bbox) > AppConfig.duplicateTrackIoU {
                if a.endFrame - a.startFrame > b.endFrame - b.startFrame { duplicateLost.insert(b.id) }
                else { duplicateTracked.insert(a.id) }
            }
        }
        tracked.removeAll { duplicateTracked.contains($0.id) }
        lost.removeAll { duplicateLost.contains($0.id) }
        return tracked.filter { $0.confirmed && $0.endFrame == frameID }.map {
            NativeTrackResult(id: $0.id, detectionIndex: $0.detectionIndex, bbox: $0.bbox, confidence: $0.score)
        }
    }

    private func associate(_ tracks: [NativeTrack], _ indexes: [Int], _ detections: [LocalDetection],
                           threshold: Double, fuseScore: Bool) -> Assignment.Result {
        let costs = tracks.map { track in
            indexes.map { index -> Double in
                let iou = boxIoU(track.bbox, detections[index].bbox)
                return 1 - iou * (fuseScore ? detections[index].confidence : 1)
            }
        }
        return Assignment.solve(costs, rows: tracks.count, columns: indexes.count, threshold: threshold)
    }
}

func boxIoU(_ a: [Double], _ b: [Double]) -> Double {
    let intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    let areaA = max(0, a[2] - a[0]) * max(0, a[3] - a[1])
    let areaB = max(0, b[2] - b[0]) * max(0, b[3] - b[1])
    return intersection / max(areaA + areaB - intersection, 1e-12)
}

/// Hungarian assignment with explicit unmatched alternatives (LAPJV cost-limit semantics).
/// Rejecting expensive matches only AFTER ordinary Hungarian would produce incorrect assignments.
enum Assignment {
    struct Result { var matches: [(Int, Int)]; var rows: [Int]; var columns: [Int] }
    static func solve(_ costs: [[Double]], rows: Int, columns: Int, threshold: Double) -> Result {
        guard rows > 0 && columns > 0 else {
            return Result(matches: [], rows: Array(0..<rows), columns: Array(0..<columns))
        }
        // Disconnected candidate graphs are independent assignment problems. Most benur
        // boxes only overlap one nearby candidate, avoiding a cubic solve over the whole tray.
        var rowEdges = Array(repeating: [Int](), count: rows)
        var columnEdges = Array(repeating: [Int](), count: columns)
        for r in 0..<rows {
            for c in 0..<columns where costs[r][c] <= threshold {
                rowEdges[r].append(c); columnEdges[c].append(r)
            }
        }
        var visitedRows = Set<Int>(), visitedColumns = Set<Int>()
        var matchedRows = Set<Int>(), matchedColumns = Set<Int>(), matches: [(Int, Int)] = []
        for root in 0..<rows where !visitedRows.contains(root) && !rowEdges[root].isEmpty {
            var rs = [root], cs: [Int] = [], cursor = 0
            visitedRows.insert(root)
            while cursor < rs.count {
                for c in rowEdges[rs[cursor]] where !visitedColumns.contains(c) {
                    visitedColumns.insert(c); cs.append(c)
                    for r in columnEdges[c] where !visitedRows.contains(r) {
                        visitedRows.insert(r); rs.append(r)
                    }
                }
                cursor += 1
            }
            rs.sort(); cs.sort()
            let result = dense(rs.map { r in cs.map { costs[r][$0] } }, rows: rs.count, columns: cs.count, threshold: threshold)
            for (r,c) in result.matches {
                matches.append((rs[r],cs[c])); matchedRows.insert(rs[r]); matchedColumns.insert(cs[c])
            }
        }
        return Result(matches: matches, rows: (0..<rows).filter { !matchedRows.contains($0) },
                      columns: (0..<columns).filter { !matchedColumns.contains($0) })
    }
    private static func dense(_ costs: [[Double]], rows: Int, columns: Int, threshold: Double) -> Result {
        guard rows > 0 && columns > 0 else {
            return Result(matches: [], rows: Array(0..<rows), columns: Array(0..<columns))
        }
        // Rectangular formulation has the same cost-limit objective as LAPJV's
        // square padding, without adding artificial detection rows.
        let n = rows, m = columns + rows
        func cost(_ row: Int, _ col: Int) -> Double {
            if col < columns { return costs[row][col] <= threshold ? costs[row][col] : 1e6 }
            return threshold
        }
        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: m + 1)
        var p = Array(repeating: 0, count: m + 1), way = p
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = Array(repeating: Double.infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...m where !used[j] {
                    let current = cost(i0 - 1, j - 1) - u[i0] - v[j]
                    if current < minv[j] { minv[j] = current; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m {
                    if used[j] { u[p[j]] += delta; v[j] -= delta }
                    else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var matches: [(Int, Int)] = []
        var assignedRows = Set<Int>(), assignedColumns = Set<Int>()
        for j in 1...columns where p[j] > 0 && p[j] <= rows {
            let row = p[j] - 1, column = j - 1
            if costs[row][column] <= threshold {
                matches.append((row, column)); assignedRows.insert(row); assignedColumns.insert(column)
            }
        }
        return Result(matches: matches, rows: (0..<rows).filter { !assignedRows.contains($0) },
                      columns: (0..<columns).filter { !assignedColumns.contains($0) })
    }
}
