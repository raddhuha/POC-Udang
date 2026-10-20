import Foundation
import CoreML
import CoreImage
import Vision
import ImageIO

struct MessageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LocalDetectionFrame: Sendable {
    let detections: [LocalDetection]
    let image: CGImage
}

/// All model loading, preprocessing and inference execute on this actor, never the UI actor.
actor OnDeviceInference {
    let settings: InferenceSettings
    private let sourceURL: URL?
    private var model: MLModel?
    private let context = CIContext()
    private var inputSize = CGSize(width: 640, height: 640)
    private var targetClasses = Set<Int>()
    private var outputName: String?
    private var endToEnd = true

    init(modelURL: URL? = nil, settings: InferenceSettings = InferenceSettings()) {
        sourceURL = modelURL
        self.settings = settings
    }

    func prepare() throws { _ = try loadModel() }

    private func loadModel() throws -> MLModel {
        if let model { return model }
        let bundled = Bundle.main.url(forResource: settings.modelName, withExtension: "mlmodelc")
        let url = sourceURL ?? bundled
        guard let url else { throw MessageError("Model YOLO tidak ditemukan dalam aplikasi.") }
        do {
            let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let loaded = try MLModel(contentsOf: compiled, configuration: configuration)
            guard let constraint = loaded.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
                throw MessageError("Model harus menerima input image Core ML.")
            }
            let outputs = loaded.modelDescription.outputDescriptionsByName
            let output = outputs.first { _, feature in
                guard let shape = feature.multiArrayConstraint?.shape else { return false }
                return shape.count == 3 && shape[0].intValue == 1 &&
                    (shape[2].intValue == 6 || (shape[1].intValue >= 5 && shape[1].intValue < shape[2].intValue))
            }
            guard let output, let shape = output.value.multiArrayConstraint?.shape else {
                throw MessageError("Output model harus YOLO26 [1,N,6] atau YOLO11 [1,4+kelas,N].")
            }
            outputName = output.key
            endToEnd = shape[2].intValue == 6
            inputSize = CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
            targetClasses = AppConfig.classIDs
            guard !targetClasses.isEmpty, settings.lowConfidence >= 0,
                  settings.lowConfidence < settings.confidence, settings.confidence <= 1,
                  (0...1).contains(settings.nmsIoU),
                  [AppConfig.matchCost, AppConfig.lowMatchCost, AppConfig.tentativeMatchCost,
                   AppConfig.duplicateTrackIoU].allSatisfy({ (0...1).contains($0) }),
                  AppConfig.lostTrackSeconds > 0, AppConfig.trailLength > 0, settings.confirmIDFrames > 0,
                  AppConfig.cameraFPS > 0, AppConfig.previewMaxDimension > 0,
                  (0...1).contains(AppConfig.jpegQuality) else {
                throw MessageError("Pengaturan tidak valid. Periksa confidence, IoU, dan parameter tracker.")
            }
            model = loaded
            return loaded
        } catch { throw MessageError("Model gagal dimuat: \(error.localizedDescription)") }
    }

    func detect(_ jpeg: Data) throws -> LocalDetectionFrame {
        try Task.checkCancellation()
        let model = try loadModel()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw MessageError("Foto/frame tidak dapat dibaca.")
            }
            let width = Double(image.width), height = Double(image.height)
            let mw = Int(inputSize.width), mh = Int(inputSize.height)
            let ratio = min(Double(mw) / width, Double(mh) / height)
            let rw = (width * ratio).rounded(), rh = (height * ratio).rounded()
            let left = floor((Double(mw) - rw) / 2), top = floor((Double(mh) - rh) / 2)
            let bottom = Double(mh) - rh - top
            let input = CIImage(cgImage: image)
                .transformed(by: CGAffineTransform(scaleX: rw / width, y: rh / height))
                .transformed(by: CGAffineTransform(translationX: left, y: bottom))
            let background = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
                .cropped(to: CGRect(origin: .zero, size: inputSize))
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, mw, mh, kCVPixelFormatType_32BGRA,
                                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw MessageError("Buffer inferensi gagal dibuat.") }
            context.render(input.composited(over: background), to: buffer,
                           bounds: CGRect(origin: .zero, size: inputSize), colorSpace: CGColorSpaceCreateDeviceRGB())
            let inputFeatures = ["image": MLFeatureValue(pixelBuffer: buffer)]
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputFeatures))
            guard let name = outputName, let tensor = output.featureValue(for: name)?.multiArrayValue,
                  tensor.shape.count == 3 else { throw MessageError("Tensor model tidak kompatibel.") }
            var candidates: [(box: [Double], score: Double, label: Int)] = []
            if endToEnd {
                for i in 0..<tensor.shape[1].intValue {
                    let row = (0..<6).map { tensor[[0, NSNumber(value: i), NSNumber(value: $0)]].doubleValue }
                    guard row.allSatisfy(\.isFinite), row[5] >= 0, row[5] < 10000 else { continue }
                    candidates.append((Array(row.prefix(4)), row[4], Int(row[5])))
                }
            } else {
                // YOLO11 raw head: pixel center-x, center-y, width, height, then class scores.
                let classCount = tensor.shape[1].intValue - 4
                for i in 0..<tensor.shape[2].intValue {
                    func value(_ channel: Int) -> Double {
                        tensor[[0, NSNumber(value: channel), NSNumber(value: i)]].doubleValue
                    }
                    var label = 0, score = -Double.infinity
                    for c in 0..<classCount where value(c + 4) > score { label = c; score = value(c + 4) }
                    guard score > settings.lowConfidence, targetClasses.contains(label) else { continue }
                    let x = value(0), y = value(1), w = value(2), h = value(3)
                    candidates.append(([x-w/2, y-h/2, x+w/2, y+h/2], score, label))
                }
            }
            var detections: [LocalDetection] = []
            for (b, score, label) in candidates {
                guard b.allSatisfy(\.isFinite), score.isFinite, score > settings.lowConfidence, targetClasses.contains(label) else { continue }
                let box = [(b[0]-left)*width/rw, (b[1]-top)*height/rh,
                           (b[2]-left)*width/rw, (b[3]-top)*height/rh]
                    .enumerated().map { min(max(0, $0.element), $0.offset % 2 == 0 ? width : height) }
                if box[2] > box[0] && box[3] > box[1] {
                    detections.append(LocalDetection(bbox: box, confidence: score, classID: label))
                }
            }
            // Explicit class-aware NMS also enforces the app's final IoU threshold.
            var selected: [LocalDetection] = []
            for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
                if !selected.contains(where: { $0.classID == detection.classID && boxIoU($0.bbox, detection.bbox) > settings.nmsIoU }) {
                    selected.append(detection)
                }
            }
            return LocalDetectionFrame(detections: selected, image: image)
        }
    }

    func photo(_ jpeg: Data) throws -> FrameResult {
        let result = try detect(jpeg)
        let objects = result.detections.filter { $0.confidence >= settings.confidence }.map {
            trackedObject(box: $0.bbox, confidence: $0.confidence, width: result.image.width, height: result.image.height)
        }
        return FrameResult(timestamp: 0, currentCount: objects.count, totalIDs: 0, objects: objects)
    }
}

func trackedObject(box: [Double], confidence: Double, width: Int, height: Int,
                   id: Int? = nil, trail: [[Double]] = []) -> TrackedObject {
    let divisor = [Double(width), Double(height), Double(width), Double(height)]
    let normalized = zip(box, divisor).map { min(1, max(0, $0 / $1)) }
    return TrackedObject(trackID: id, confidence: confidence, bbox: normalized,
                         center: [(normalized[0] + normalized[2]) / 2, (normalized[1] + normalized[3]) / 2], trail: trail)
}

/// Visible IDs always belong to a valid, above-threshold detection in THIS frame.
/// Kalman boxes and low-score recovery remain internal to the tracker.
struct TrackPresentation {
    private var trails: [Int: [[Double]]] = [:]
    private var lastSeen: [Int: Double] = [:]
    // Raw BoT-SORT candidate IDs can skip numbers. Allocate display IDs only on confirmation.
    // Only live mappings stay in RAM; the journal retains retired IDs.
    private var displayIDs: [Int: Int] = [:]
    private var totalConfirmed = 0
    private let settings: InferenceSettings

    init(settings: InferenceSettings = InferenceSettings()) { self.settings = settings }
    private var consecutiveHits: [Int: Int] = [:]

    func displayID(for backendID: Int) -> Int? { displayIDs[backendID] }

    mutating func retain(activeIDs: [Int]) {
        let active = Set(activeIDs)
        displayIDs = displayIDs.filter { active.contains($0.key) }
        trails = trails.filter { active.contains($0.key) }
        lastSeen = lastSeen.filter { active.contains($0.key) }
        consecutiveHits = consecutiveHits.filter { active.contains($0.key) }
    }

    mutating func result(detections: [LocalDetection], tracks: [NativeTrackResult],
                         width: Int, height: Int, timestamp: Double) -> FrameResult {
        var objects: [TrackedObject] = []
        var frameHits: [Int: Int] = [:]
        defer { consecutiveHits = frameHits }
        guard width > 0, height > 0 else {
            return FrameResult(timestamp: timestamp, currentCount: 0, totalIDs: totalConfirmed, objects: [])
        }
        for (index, detection) in detections.enumerated() {
            guard detection.confidence.isFinite, detection.confidence >= settings.confidence,
                  AppConfig.classIDs.contains(detection.classID),
                  detection.bbox.count == 4, detection.bbox.allSatisfy(\.isFinite) else { continue }
            // Draw the measured detection box, not the predicted/smoothed Kalman position.
            let object = trackedObject(box: detection.bbox, confidence: detection.confidence, width: width, height: height)
            guard object.hasValidBox else { continue }
            guard let track = tracks.first(where: { $0.detectionIndex == index && $0.id > 0 }) else {
                objects.append(object)
                continue
            }
            let hits = (consecutiveHits[track.id] ?? 0) + 1
            frameHits[track.id] = min(hits, settings.confirmIDFrames)
            guard displayIDs[track.id] != nil || hits >= settings.confirmIDFrames else {
                objects.append(object) // Detection exists, but its ID is not yet trusted for the session total.
                continue
            }
            var points = trails[track.id] ?? []
            // Never draw an observed path across a missing/weak frame.
            if consecutiveHits[track.id] == nil || timestamp - (lastSeen[track.id] ?? timestamp) > AppConfig.trailGapSeconds { points = [] }
            points.append(object.center)
            points = Array(points.suffix(AppConfig.trailLength))
            trails[track.id] = points
            lastSeen[track.id] = timestamp
            if displayIDs[track.id] == nil {
                totalConfirmed += 1
                displayIDs[track.id] = totalConfirmed
            }
            objects.append(TrackedObject(trackID: displayIDs[track.id], confidence: object.confidence, bbox: object.bbox,
                                         center: object.center, trail: points))
        }
        return FrameResult(timestamp: timestamp, currentCount: objects.count, totalIDs: totalConfirmed, objects: objects)
    }
}

/// Per-session state: releasing this actor discards tracker, previous image and all ID trails.
actor LocalVideoProcessor {
    private let inference: OnDeviceInference
    private let tracker: any TrackingBackend
    private var previous: CGImage?
    private let context = CIContext()
    private var presentation: TrackPresentation
    private var lastTimestamp = -Double.infinity
    private var dimensions: CGSize?
    private let sessionID = UUID()
    private let epochID = UUID()
    private let sourceReference: String?
    private let journalDirectory: URL?
    private var journal: TrackingJournal?
    private var processedFrames = 0
    private var lastSourceFrameIndex: Int?
    private var finalized = false
    private var processingFrame = false

    init(inference: OnDeviceInference, fps: Double, sourceReference: String? = nil, journalDirectory: URL? = nil) {
        self.inference = inference
        self.sourceReference = sourceReference
        self.journalDirectory = journalDirectory
        switch inference.settings.backend {
        case .kinematic: tracker = TRexKinematicBackend(settings: inference.settings)
        case .botSort: tracker = ExistingBoTSORTBackend(fps: fps, settings: inference.settings)
        }
        presentation = TrackPresentation(settings: inference.settings)
    }

    func frame(_ jpeg: Data, timestamp: Double, sourceFrameIndex: Int? = nil) async throws -> FrameResult {
        try Task.checkCancellation()
        guard !finalized, !processingFrame else { throw MessageError("Sesi selesai atau frame masih diproses.") }
        processingFrame = true
        defer { processingFrame = false }
        let started = ProcessInfo.processInfo.systemUptime
        let inputIndex = sourceFrameIndex ?? processedFrames
        guard timestamp.isFinite, timestamp >= 0, timestamp > lastTimestamp else {
            throw MessageError("Timestamp video tidak valid atau tidak berurutan.")
        }
        guard inputIndex >= 0, lastSourceFrameIndex == nil || inputIndex > lastSourceFrameIndex! else {
            throw MessageError("Urutan frame video tidak valid.")
        }
        let frame = try await inference.detect(jpeg)
        try Task.checkCancellation()
        guard !finalized else { throw MessageError("Sesi tracking sudah selesai.") }
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        guard dimensions == nil || dimensions == size else { throw MessageError("Ukuran frame berubah. Mulai sesi baru.") }
        dimensions = size
        if journal == nil {
            journal = try TrackingJournal(sessionID: sessionID, epochID: epochID, settings: inference.settings,
                                          sourceReference: sourceReference, directory: journalDirectory)
        }
        let shift = AppConfig.cameraMotionCompensation ? cameraTranslation(frame.image) : .zero
        let matchingStarted = ProcessInfo.processInfo.systemUptime
        let update = try tracker.update(frame.detections, timestamp: timestamp, cameraTranslation: shift)
        let associationMS = (ProcessInfo.processInfo.systemUptime - matchingStarted) * 1000
        let previouslyConfirmed = Set(update.associations.compactMap { association in
            presentation.displayID(for: association.track.id).map { _ in association.track.id }
        })
        let visible = presentation.result(detections: frame.detections, tracks: update.associations.map(\.track),
                                          width: frame.image.width, height: frame.image.height, timestamp: timestamp)
        let ambiguousDisplayIDs = Set(update.associations.filter(\.ambiguous).compactMap { presentation.displayID(for: $0.track.id) })
        let objects = visible.objects.map { object in
            var object = object
            object.ambiguous = object.trackID.map { ambiguousDisplayIDs.contains($0) } ?? false
            return object
        }
        let skipped = lastSourceFrameIndex.map { max(0, inputIndex - $0 - 1) } ?? 0
        let diagnostics = TrackingDiagnostics(sessionID: sessionID, trackingEpochID: epochID, backend: inference.settings.backend,
            confirmedVisible: objects.filter { $0.trackID != nil }.count,
            missingConfirmed: update.missingTrackIDs.filter { presentation.displayID(for: $0) != nil }.count,
            totalTracklets: update.totalTracklets, ambiguousMatches: update.associations.filter(\.ambiguous).count,
            candidateEdges: update.candidateEdges, associationMilliseconds: associationMS,
            processingMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
            skippedInputFrames: skipped, archiveTruncated: journal?.archiveTruncated ?? false)
        let confirmedEvents = update.associations.compactMap { association -> TrackingEvent? in
            guard !previouslyConfirmed.contains(association.track.id), presentation.displayID(for: association.track.id) != nil else { return nil }
            return TrackingEvent(kind: "confirmed", trackID: association.track.id, trackletID: association.trackletID, detail: nil)
        }
        let record = TrackingFrameRecord(timestamp: timestamp, sourceFrameIndex: inputIndex, processedFrameIndex: processedFrames,
            width: frame.image.width, height: frame.image.height, detections: frame.detections,
            associations: update.associations.map { RecordedAssociation(association: $0, displayID: presentation.displayID(for: $0.track.id)) },
            missingTrackIDs: update.missingTrackIDs, events: update.events + confirmedEvents, diagnostics: diagnostics,
            cameraTranslation: [shift.x, shift.y], cameraCompensation: AppConfig.cameraMotionCompensation ? "vision-translation-estimate-unvalidated" : "disabled")
        try journal?.append(record, type: "frame")
        presentation.retain(activeIDs: update.activeTrackIDs)
        lastTimestamp = timestamp
        lastSourceFrameIndex = inputIndex
        processedFrames += 1
        return FrameResult(timestamp: timestamp, currentCount: objects.count, totalIDs: visible.totalIDs, objects: objects, tracking: diagnostics)
    }

    /// Called after the frame loop, including cancellation. A new run uses new scoped IDs/files.
    func finalize(reason: String = "completed") throws -> URL? {
        if !finalized {
            finalized = true
            try journal?.append(tracker.finalize(), type: "final_events")
            try journal?.finalize(reason: reason)
        }
        return journal?.url
    }

    private func cameraTranslation(_ image: CGImage) -> CGPoint {
        let scale = min(1, 320.0 / Double(max(image.width, image.height)))
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let current = context.createCGImage(small, from: small.extent) else { return .zero }
        defer { previous = current }
        guard let previous else { return .zero }
        let shift = nativeCameraTranslation(previous: previous, current: current)
        return CGPoint(x: shift.x / scale, y: shift.y / scale)
    }
}

/// Returns previous → current displacement in top-left image pixels.
func nativeCameraTranslation(previous: CGImage, current: CGImage) -> CGPoint {
    autoreleasepool {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        do {
            try VNImageRequestHandler(cgImage: current).perform([request])
            guard let transform = request.results?.first?.alignmentTransform,
                  transform.tx.isFinite, transform.ty.isFinite,
                  abs(transform.tx) < Double(current.width) / 4,
                  abs(transform.ty) < Double(current.height) / 4 else { return .zero }
            return CGPoint(x: transform.tx, y: -transform.ty)
        } catch { return .zero }
    }
}
