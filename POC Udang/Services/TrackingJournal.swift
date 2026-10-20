import Foundation

/// Append-only raw tracking output, owned by the processor's serial actor.
/// Only a small batch is retained in memory; no video or crops are copied here.
/// Call `finalize` explicitly so write failures can be reported to the UI.
final class TrackingJournal {
    let url: URL
    private(set) var writtenBytes = 0
    private(set) var archiveTruncated = false
    var pendingBytes: Int { pending.count }

    private let maximumBytes: Int
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var pending = Data()
    private var pendingRecords = 0
    private var acceptedRecords = 0
    private var discardedRecords = 0
    private var finalized = false
    private static let batchBytes = 64 * 1_024
    private static let batchRecords = 16

    enum JournalError: LocalizedError {
        case finalized
        case invalidByteLimit
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .finalized: return "Rekaman tracking sudah ditutup."
            case .invalidByteLimit: return "Batas ukuran rekaman tracking harus positif."
            case .applicationSupportUnavailable: return "Folder penyimpanan tracking tidak tersedia."
            }
        }
    }

    init(sessionID: UUID, epochID: UUID, settings: InferenceSettings,
         sourceReference: String? = nil, directory: URL? = nil,
         maxBytes: Int = 128 * 1_024 * 1_024) throws {
        guard maxBytes > 0 else { throw JournalError.invalidByteLimit }
        maximumBytes = maxBytes
        let folder: URL
        if let directory {
            folder = directory
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
                throw JournalError.applicationSupportUnavailable
            }
            folder = support.appendingPathComponent("TrackingSessions", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("\(sessionID.uuidString)_\(epochID.uuidString).jsonl")
        // Exclusive creation: retries must never replace an earlier raw result.
        try Data().write(to: url, options: .withoutOverwriting)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            handle = try FileHandle(forWritingTo: url)
            let header = Header(sessionID: sessionID, trackingEpochID: epochID,
                                settings: settings,
                                sourceReference: sourceReference.map {
                                    URL(fileURLWithPath: $0).lastPathComponent
                                },
                                conceptualReference: settings.backend == .kinematic
                                    ? "TRex tag 1.0, commit 37648566b448d80e12b130f95743b520fa23967f" : nil,
                                implementationVersion: settings.backend == .kinematic
                                    ? "bbox-kinematic-v1" : "native-botsort-8.4.177")
            try writeImmediately(encoded(header, type: "header"))
            try handle?.synchronize()
        } catch {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// The byte cap applies to raw records including the header. A small marker
    /// and footer may exceed it, so a capped archive is still valid and explicit.
    func append<T: Encodable>(_ value: T, type: String) throws {
        guard !finalized else { throw JournalError.finalized }
        guard !archiveTruncated else {
            discardedRecords += 1
            return
        }
        let record = try encoded(value, type: type)
        guard record.count <= maximumBytes - min(maximumBytes, writtenBytes + pending.count) else {
            try flush()
            try writeImmediately(encoded(Truncation(maxBytes: maximumBytes), type: "truncated"))
            archiveTruncated = true
            discardedRecords += 1
            return
        }
        if pending.count + record.count > Self.batchBytes { try flush() }
        if record.count >= Self.batchBytes {
            // A single frame can be larger than the batch; do not retain it.
            try writeImmediately(record)
        } else {
            pending.append(record)
            pendingRecords += 1
            if pendingRecords >= Self.batchRecords { try flush() }
        }
        acceptedRecords += 1
    }

    /// Idempotent, including after a failure; closed journals reject new writes.
    func finalize(reason: String) throws {
        guard !finalized else { return }
        finalized = true
        do {
            try flush()
            let footer = Footer(reason: reason, archiveTruncated: archiveTruncated,
                                acceptedRecords: acceptedRecords, discardedRecords: discardedRecords)
            try writeImmediately(encoded(footer, type: "footer"))
            try handle?.synchronize()
            try handle?.close()
            handle = nil
        } catch {
            try? handle?.close()
            handle = nil
            throw error
        }
    }

    deinit {
        // Explicit finalization is the supported error-reporting path. This only
        // salvages a batch when a processor is unexpectedly released.
        try? finalize(reason: "processorReleased")
    }

    private func encoded<T: Encodable>(_ value: T, type: String) throws -> Data {
        var data = try encoder.encode(Envelope(type: type, payload: value))
        data.append(0x0A)
        return data
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try writeImmediately(pending)
        pending.removeAll(keepingCapacity: true)
        pendingRecords = 0
    }

    private func writeImmediately(_ data: Data) throws {
        guard let handle else { throw JournalError.finalized }
        try handle.write(contentsOf: data)
        writtenBytes += data.count
    }

    private struct Envelope<Payload: Encodable>: Encodable {
        let type: String
        let payload: Payload
    }

    private struct Header: Encodable {
        let sessionID: UUID
        let trackingEpochID: UUID
        let settings: InferenceSettings
        let sourceReference: String?
        let createdAt = Date()
        let analysisVersion = 1
        let results = "raw"
        let geometry = "bbox and center in processed, oriented frame pixels; frame width/height accompany observations"
        let appearanceStatus = "unavailable"
        let appearanceUnavailableReason = "No per-session individual identity model is available."
        let sourceReferenceKind = "filename hint only; no retained video or crop"
        let conceptualReference: String?
        let implementationVersion: String
    }

    private struct Truncation: Encodable {
        let maxBytes: Int
        let reason = "rawArchiveByteLimit"
        let detail = "Tracking continues; subsequent raw records are omitted."
    }

    private struct Footer: Encodable {
        let reason: String
        let archiveTruncated: Bool
        let acceptedRecords: Int
        let discardedRecords: Int
        let finalizedAt = Date()
    }
}
