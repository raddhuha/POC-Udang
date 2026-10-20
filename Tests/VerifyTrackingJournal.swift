import Foundation

@main
struct VerifyTrackingJournal {
    private struct Observation: Codable {
        let sourceFrameIndex: Int
        let timestamp: Double
        let bbox: [Double]
        let note: String
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifyTrackingJournal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID(), epoch = UUID()
        let journal = try TrackingJournal(sessionID: session, epochID: epoch, settings: InferenceSettings(),
                                          sourceReference: "/input/video/benur.mp4", directory: directory)
        let headerOnly = try lines(journal.url)
        precondition(headerOnly.count == 1 && headerOnly[0]["type"] as? String == "header")
        let header = headerOnly[0]["payload"] as! [String: Any]
        precondition(header["sessionID"] as? String == session.uuidString)
        precondition(header["trackingEpochID"] as? String == epoch.uuidString)
        precondition(header["analysisVersion"] as? Int == 1)
        precondition(header["sourceReference"] as? String == "benur.mp4")
        precondition(header["appearanceStatus"] as? String == "unavailable")
        precondition(header["implementationVersion"] as? String == "bbox-kinematic-v1")
        precondition(header["conceptualReference"] as? String ==
                     "TRex tag 1.0, commit 37648566b448d80e12b130f95743b520fa23967f")
        precondition(journal.pendingBytes == 0 && journal.writtenBytes > 0)

        for index in 0..<1_000 {
            let observation = Observation(sourceFrameIndex: index, timestamp: Double(index) * 0.1,
                                          bbox: [10, 20, 30, 40], note: String(repeating: "x", count: 100))
            try journal.append(observation, type: "frame")
            precondition(journal.pendingBytes <= 64 * 1_024)
            if (index + 1).isMultiple(of: 16) { precondition(journal.pendingBytes == 0) }
        }
        try journal.finalize(reason: "completed")
        precondition(journal.pendingBytes == 0)
        let bytes = try Data(contentsOf: journal.url)
        precondition(bytes.count == journal.writtenBytes)
        try journal.finalize(reason: "duplicateCall")
        let finalizedAgain = try Data(contentsOf: journal.url)
        precondition(finalizedAgain == bytes)
        let records = try lines(journal.url)
        precondition(records.count == 1_002)
        precondition(records.last?["type"] as? String == "footer")
        let payloadData = try JSONSerialization.data(withJSONObject: records[501]["payload"]!)
        let observation = try JSONDecoder().decode(Observation.self, from: payloadData)
        precondition(observation.sourceFrameIndex == 500 && observation.timestamp == 50)
        do {
            try journal.append(observation, type: "frame")
            preconditionFailure("Finalized journal accepted an append")
        } catch TrackingJournal.JournalError.finalized { }

        do {
            _ = try TrackingJournal(sessionID: session, epochID: epoch, settings: InferenceSettings(),
                                    directory: directory)
            preconditionFailure("An existing raw session was overwritten")
        } catch { }
        let preservedAfterCollision = try Data(contentsOf: journal.url)
        precondition(preservedAfterCollision == bytes)
        let rerun = try TrackingJournal(sessionID: UUID(), epochID: UUID(), settings: InferenceSettings(),
                                        directory: directory)
        precondition(rerun.url != journal.url)
        try rerun.finalize(reason: "cancelled")
        print("PASS journal JSONL roundtrip, ID provenance, exclusive creation, batching, finalize and rerun")

        let capped = try TrackingJournal(sessionID: UUID(), epochID: UUID(), settings: InferenceSettings(),
                                         directory: directory, maxBytes: 2_048)
        for index in 0..<100 {
            try capped.append(Observation(sourceFrameIndex: index, timestamp: Double(index),
                                          bbox: [1, 2, 3, 4], note: String(repeating: "x", count: 512)),
                              type: "frame")
            precondition(capped.pendingBytes <= 64 * 1_024)
        }
        precondition(capped.archiveTruncated)
        try capped.finalize(reason: "completed")
        let cappedRecords = try lines(capped.url)
        precondition(cappedRecords.filter { $0["type"] as? String == "truncated" }.count == 1)
        let cappedFooter = cappedRecords.last?["payload"] as! [String: Any]
        precondition(cappedFooter["archiveTruncated"] as? Bool == true)
        precondition(cappedFooter["discardedRecords"] as! Int > 0)
        precondition(capped.writtenBytes < 3_072)
        print("PASS byte cap is explicit, bounded and preserves a valid final footer")

        let large = try TrackingJournal(sessionID: UUID(), epochID: UUID(), settings: InferenceSettings(),
                                        directory: directory)
        try large.append(Observation(sourceFrameIndex: 0, timestamp: 0, bbox: [0, 0, 1, 1],
                                     note: String(repeating: "x", count: 80_000)), type: "frame")
        precondition(large.pendingBytes == 0)
        try large.finalize(reason: "completed")
        let largeRecords = try lines(large.url)
        precondition(largeRecords.count == 3)
        print("PASS a large single record is written directly without retaining an oversized batch")

        var baselineSettings = InferenceSettings()
        baselineSettings.backend = .botSort
        let tiny = try TrackingJournal(sessionID: UUID(), epochID: UUID(), settings: baselineSettings,
                                       directory: directory, maxBytes: 1)
        try tiny.append(["frameIndex": 0], type: "frame")
        try tiny.finalize(reason: "completed")
        let tinyRecords = try lines(tiny.url)
        precondition(tinyRecords.count == 3)
        precondition(tinyRecords.map { $0["type"] as! String } == ["header", "truncated", "footer"])
        let baselineHeader = tinyRecords[0]["payload"] as! [String: Any]
        precondition(baselineHeader["implementationVersion"] as? String == "native-botsort-8.4.177")
        precondition(baselineHeader["conceptualReference"] == nil)
        print("PASS cap smaller than header preserves metadata and marks truncation on first raw record")
        print("TRACKING JOURNAL REGRESSION PASSED")
    }

    private static func lines(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        precondition(data.last == 0x0A, "Journal must finish on a complete JSONL record")
        return try data.split(separator: 0x0A).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
    }
}
