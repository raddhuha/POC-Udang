import Foundation
import CoreGraphics

protocol TrackingBackend: AnyObject {
    func update(_ detections: [LocalDetection], timestamp: Double, cameraTranslation: CGPoint) throws -> TrackingUpdate
    func reset()
    func finalize() -> [TrackingEvent]
}

struct TrackAssociation: Codable, Sendable {
    let track: NativeTrackResult
    let trackletID: Int
    let associationScore: Double?
    let ambiguous: Bool
}

struct TrackingUpdate: Codable, Sendable {
    /// Actual measurements only. A missing prediction must never inflate the observed count.
    let associations: [TrackAssociation]
    let missingTrackIDs: [Int]
    /// All retained live IDs, including temporarily missing tracks.
    let activeTrackIDs: [Int]
    let totalTracklets: Int
    let candidateEdges: Int
    let events: [TrackingEvent]
}

struct TrackingEvent: Codable, Sendable {
    let kind: String
    let trackID: Int?
    let trackletID: Int?
    let detail: String?
}

enum TrackingBackendError: LocalizedError {
    case invalidTimestamp
    case invalidCameraTranslation

    var errorDescription: String? {
        switch self {
        case .invalidTimestamp: return "Timestamp tracking harus valid dan meningkat."
        case .invalidCameraTranslation: return "Translasi kamera tracking tidak valid."
        }
    }
}

/// A deliberately small bbox adaptation of TRex's kinematic/tracklet flow.
/// Uses smoothed constant velocity and global Hungarian assignment, not the TRex
/// orientation predictor, original probability formula, tree solver, or visual ID.
final class TRexKinematicBackend: TrackingBackend {
    private struct Track {
        let id: Int
        let classID: Int
        var center: CGPoint
        var width: Double
        var height: Double
        var velocity: CGPoint = .zero // pixels / second, after translation compensation
        var hasVelocity = false
        var lastObserved: Double
        var missing = false
        var lowTrust = false
        var trackletID: Int
        var trackletOpen = true
    }

    private let settings: InferenceSettings
    private let config: KinematicTrackingConfiguration
    private var tracks: [Track] = []
    private var nextID = 1
    private var nextTrackletID = 1
    private var lastTimestamp: Double?

    init(settings: InferenceSettings = InferenceSettings()) {
        self.settings = settings
        // A session snapshot owns these values. Defend against edited/imported configs.
        var config = settings.kinematic
        func finite(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
        }
        config.maxSpeed = finite(config.maxSpeed, 450, 1...100_000)
        config.lostTrackSeconds = finite(config.lostTrackSeconds, 1, 0.001...60)
        config.minimumMatchScore = finite(config.minimumMatchScore, 0.12, 0.001...0.99)
        config.trustedScore = finite(config.trustedScore, 0.55, config.minimumMatchScore...1)
        config.ambiguityMargin = finite(config.ambiguityMargin, 0.12, 0...1)
        config.velocitySmoothingSeconds = finite(config.velocitySmoothingSeconds, 0.15, 0.001...10)
        config.trackletGapSeconds = finite(config.trackletGapSeconds, 0.35, 0.001...60)
        config.bodyUncertaintyScale = finite(config.bodyUncertaintyScale, 0.75, 0.01...10)
        self.config = config
    }

    func update(_ detections: [LocalDetection], timestamp: Double,
                cameraTranslation: CGPoint = .zero) throws -> TrackingUpdate {
        // Validate before changing ANY state, including counters and stored centers.
        guard timestamp.isFinite, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            throw TrackingBackendError.invalidTimestamp
        }
        guard cameraTranslation.x.isFinite, cameraTranslation.y.isFinite else {
            throw TrackingBackendError.invalidCameraTranslation
        }
        lastTimestamp = timestamp
        var events: [TrackingEvent] = []

        // Expiry must run before matching: a late detection cannot resurrect an old ID.
        tracks.removeAll { track in
            guard timestamp - track.lastObserved > config.lostTrackSeconds else { return false }
            if track.trackletOpen { events.append(event("tracklet_ended", track, "expired")) }
            events.append(event("removed", track, "lost_timeout"))
            return true
        }
        // Shift every stored last-observed center, including missing tracks. Successive
        // frame-to-frame GMC translations accumulate without becoming animal velocity.
        for index in tracks.indices {
            tracks[index].center.x += cameraTranslation.x
            tracks[index].center.y += cameraTranslation.y
        }

        let valid = detections.indices.filter { index in
            let detection = detections[index]
            return detection.bbox.count == 4 && detection.bbox.allSatisfy(\.isFinite)
                && detection.bbox[2] > detection.bbox[0] && detection.bbox[3] > detection.bbox[1]
                && detection.confidence.isFinite && detection.confidence <= 1
                && detection.confidence >= settings.lowConfidence
                && AppConfig.classIDs.contains(detection.classID)
        }
        let forbidden = 1e6
        var scores = Array(repeating: Array(repeating: 0.0, count: valid.count), count: tracks.count)
        var costs = Array(repeating: Array(repeating: forbidden, count: valid.count), count: tracks.count)
        var edgeCount = 0
        for row in tracks.indices {
            for column in valid.indices {
                if let score = score(tracks[row], detections[valid[column]], timestamp: timestamp),
                   score >= config.minimumMatchScore {
                    scores[row][column] = score
                    costs[row][column] = 1 - score
                    edgeCount += 1
                }
            }
        }
        // Maximize the sum of eligible scores; null/unmatched has weight zero.
        // The minimum score is only an eligibility gate, not a penalty per match.
        // Connected components retain every eligible edge; ties are input-order stable.
        let assignment = Assignment.solve(costs, rows: tracks.count, columns: valid.count,
                                          threshold: 1)
        var associations: [TrackAssociation] = []
        for (row, column) in assignment.matches.sorted(by: { $0.0 < $1.0 }) {
            let index = valid[column], detection = detections[index], matchScore = scores[row][column]
            var track = tracks[row]
            let dt = timestamp - track.lastObserved
            let measurement = detection.measurement
            let center = CGPoint(x: measurement[0], y: measurement[1])
            let dx = center.x - track.center.x, dy = center.y - track.center.y
            let observedSpeed = hypot(dx, dy) / dt
            // Both row and column competition matter: two tracks may equally claim a
            // single measurement even when each track has no second candidate.
            let competingRow = scores[row].indices.contains {
                $0 != column && scores[row][$0] >= config.minimumMatchScore
                    && matchScore - scores[row][$0] <= config.ambiguityMargin
            }
            let competingColumn = scores.indices.contains {
                $0 != row && scores[$0][column] >= config.minimumMatchScore
                    && matchScore - scores[$0][column] <= config.ambiguityMargin
            }
            let competing = competingRow || competingColumn
            let speedRisk = observedSpeed > config.maxSpeed
            let lowTrust = matchScore < config.trustedScore || competing || speedRisk
            let wasMissing = track.missing
            let previousLowTrust = track.lowTrust
            let boundary: String?
            if !track.trackletOpen { boundary = "reacquired" }
            else if dt > config.trackletGapSeconds { boundary = "input_time_gap" }
            else if lowTrust != previousLowTrust { boundary = lowTrust ? "low_trust" : "trust_restored" }
            else { boundary = nil }
            if let boundary {
                if track.trackletOpen { events.append(event("tracklet_ended", track, boundary)) }
                track.trackletID = allocateTracklet()
                track.trackletOpen = true
                events.append(event("tracklet_started", track, boundary))
            }
            if wasMissing { events.append(event("reacquired", track, nil)) }
            if lowTrust && (!previousLowTrust || wasMissing) {
                let reason = competing ? "competing_matches" : (speedRisk ? "speed_limit" : "association_score")
                events.append(event("low_trust", track, reason))
                if competing { events.append(event("ambiguity", track, "competing_matches")) }
            }

            // Velocity is calculated with the actual observation interval. Tiny motion
            // has no heading; stationary animals remain eligible for ordinary matching.
            let stationaryDistance = max(0.5, 0.02 * hypot(track.width, track.height))
            if hypot(dx, dy) <= stationaryDistance {
                track.velocity = .zero
            } else {
                let clamp = min(1, config.maxSpeed / max(observedSpeed, 1e-12))
                let vx = dx / dt * clamp, vy = dy / dt * clamp
                let alpha = track.hasVelocity ? 1 - exp(-dt / config.velocitySmoothingSeconds) : 1
                track.velocity.x += alpha * (vx - track.velocity.x)
                track.velocity.y += alpha * (vy - track.velocity.y)
            }
            track.hasVelocity = true
            track.center = center
            track.width = measurement[2]
            track.height = measurement[3]
            track.lastObserved = timestamp
            track.missing = false
            track.lowTrust = lowTrust
            tracks[row] = track
            associations.append(association(track, detection, index: index, score: matchScore))
        }
        for row in assignment.rows {
            if !tracks[row].missing {
                if tracks[row].trackletOpen {
                    events.append(event("tracklet_ended", tracks[row], "missing"))
                    tracks[row].trackletOpen = false
                }
                events.append(event("missing", tracks[row], nil))
            }
            tracks[row].missing = true
        }
        for column in assignment.columns {
            let index = valid[column], detection = detections[index]
            // Weak detections may recover a live track, never create a candidate.
            guard detection.confidence >= settings.confidence else { continue }
            let m = detection.measurement
            let track = Track(id: nextID, classID: detection.classID,
                              center: CGPoint(x: m[0], y: m[1]), width: m[2], height: m[3],
                              lastObserved: timestamp, trackletID: allocateTracklet())
            nextID += 1
            tracks.append(track)
            events.append(event("candidate", track, nil))
            events.append(event("tracklet_started", track, "candidate"))
            associations.append(association(track, detection, index: index, score: nil))
        }
        return TrackingUpdate(associations: associations.sorted { $0.track.detectionIndex < $1.track.detectionIndex },
                              missingTrackIDs: tracks.filter(\.missing).map(\.id),
                              activeTrackIDs: tracks.map(\.id), totalTracklets: nextTrackletID - 1,
                              candidateEdges: edgeCount, events: events)
    }

    private func score(_ track: Track, _ detection: LocalDetection, timestamp: Double) -> Double? {
        guard detection.classID == track.classID else { return nil }
        let dt = timestamp - track.lastObserved, m = detection.measurement
        let uncertainty = max(4, config.bodyUncertaintyScale * hypot(track.width, track.height))
        let envelope = config.maxSpeed * dt + uncertainty
        let displacement = hypot(m[0] - track.center.x, m[1] - track.center.y)
        guard displacement <= envelope else { return nil }
        let predictedX = track.center.x + track.velocity.x * dt
        let predictedY = track.center.y + track.velocity.y * dt
        let residual = hypot(m[0] - predictedX, m[1] - predictedY)
        guard residual <= envelope else { return nil }
        let widthRatio = m[2] / track.width, heightRatio = m[3] / track.height
        guard (0.25...4).contains(widthRatio), (0.25...4).contains(heightRatio) else { return nil }
        // These are explicit heuristic scores, not probabilities or copied TRex defaults.
        // With no velocity history, allow a wider residual. Later, size uncertainty and
        // acceleration allowance set sigma. At the geometric gate score can fall BELOW
        // minimumMatchScore, so unmatched and trust thresholds remain meaningful.
        let sigma = track.hasVelocity ? max(uncertainty, 0.20 * config.maxSpeed * dt) : 0.45 * envelope
        let distanceScore = exp(-0.5 * pow(residual / max(sigma, 1e-6), 2))
        let sizeScore = exp(-0.5 * (abs(log(widthRatio)) + abs(log(heightRatio))))
        let timeScore = exp(-0.5 * dt / config.lostTrackSeconds)
        return distanceScore * sizeScore * timeScore
    }

    private func association(_ track: Track, _ detection: LocalDetection, index: Int, score: Double?) -> TrackAssociation {
        TrackAssociation(track: NativeTrackResult(id: track.id, detectionIndex: index, bbox: detection.bbox,
                                                  confidence: detection.confidence),
                         trackletID: track.trackletID, associationScore: score, ambiguous: track.lowTrust)
    }

    private func event(_ kind: String, _ track: Track, _ detail: String?) -> TrackingEvent {
        TrackingEvent(kind: kind, trackID: track.id, trackletID: track.trackletID, detail: detail)
    }

    private func allocateTracklet() -> Int {
        defer { nextTrackletID += 1 }
        return nextTrackletID
    }

    func reset() {
        tracks = []
        nextID = 1
        nextTrackletID = 1
        lastTimestamp = nil
    }

    func finalize() -> [TrackingEvent] {
        let events = tracks.filter(\.trackletOpen).map { event("tracklet_ended", $0, "session_finalized") }
        tracks = []
        lastTimestamp = nil
        return events
    }
}

/// Baseline adapter only: its Kalman/IoU matching remains unchanged and runs instead
/// of the kinematic backend. Native BoT-SORT does not provide association scores.
final class ExistingBoTSORTBackend: TrackingBackend {
    private let fps: Double
    private let settings: InferenceSettings
    private var tracker: NativeBoTSORT
    private var lastTimestamp: Double?
    private var seen: [Int: (lastObserved: Double, trackletID: Int, missing: Bool)] = [:]
    private var nextTrackletID = 1

    init(fps: Double = 30, settings: InferenceSettings = InferenceSettings()) {
        self.fps = fps
        self.settings = settings
        tracker = NativeBoTSORT(fps: fps, settings: settings)
    }

    func update(_ detections: [LocalDetection], timestamp: Double,
                cameraTranslation: CGPoint = .zero) throws -> TrackingUpdate {
        guard timestamp.isFinite, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            throw TrackingBackendError.invalidTimestamp
        }
        guard cameraTranslation.x.isFinite, cameraTranslation.y.isFinite else {
            throw TrackingBackendError.invalidCameraTranslation
        }
        lastTimestamp = timestamp
        let results = tracker.update(detections, cameraTranslation: cameraTranslation)
        let observed = Set(results.map(\.id))
        let retained = Set(tracker.activeTrackIDs)
        var events: [TrackingEvent] = []
        for id in seen.keys.sorted() where !observed.contains(id) {
            guard var state = seen[id] else { continue }
            if !retained.contains(id) {
                if !state.missing {
                    events.append(TrackingEvent(kind: "tracklet_ended", trackID: id,
                                                trackletID: state.trackletID, detail: "baseline_not_observed"))
                }
                events.append(TrackingEvent(kind: "removed", trackID: id, trackletID: state.trackletID,
                                            detail: "baseline_removed"))
                seen.removeValue(forKey: id)
            } else if !state.missing {
                events.append(TrackingEvent(kind: "missing", trackID: id, trackletID: state.trackletID, detail: nil))
                events.append(TrackingEvent(kind: "tracklet_ended", trackID: id, trackletID: state.trackletID, detail: "missing"))
                state.missing = true
                seen[id] = state
            }
        }
        let associations = results.map { result -> TrackAssociation in
            let previous = seen[result.id]
            let tracklet: Int
            if let previous, !previous.missing { tracklet = previous.trackletID }
            else {
                tracklet = nextTrackletID
                nextTrackletID += 1
                events.append(TrackingEvent(kind: previous == nil ? "candidate" : "reacquired", trackID: result.id,
                                            trackletID: tracklet, detail: "baseline_confirmed_output"))
                events.append(TrackingEvent(kind: "tracklet_started", trackID: result.id, trackletID: tracklet,
                                            detail: previous == nil ? "candidate" : "reacquired"))
            }
            seen[result.id] = (timestamp, tracklet, false)
            return TrackAssociation(track: result, trackletID: tracklet, associationScore: nil, ambiguous: false)
        }
        return TrackingUpdate(associations: associations, missingTrackIDs: seen.keys.sorted().filter { seen[$0]!.missing },
                              activeTrackIDs: seen.keys.sorted(), totalTracklets: nextTrackletID - 1,
                              candidateEdges: 0, events: events)
    }

    func reset() {
        tracker = NativeBoTSORT(fps: fps, settings: settings)
        seen = [:]
        lastTimestamp = nil
        nextTrackletID = 1
    }

    func finalize() -> [TrackingEvent] {
        let events = seen.keys.sorted().compactMap { id -> TrackingEvent? in
            guard let state = seen[id], !state.missing else { return nil }
            return TrackingEvent(kind: "tracklet_ended", trackID: id, trackletID: state.trackletID, detail: "session_finalized")
        }
        seen = [:]
        lastTimestamp = nil
        return events
    }
}
