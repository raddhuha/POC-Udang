import AVFoundation
import CoreImage

/// One capture session per run. All mutable capture state lives on `queue`.
/// Only one latest frame is buffered while Core ML is busy; no unbounded task queue.
final class LiveCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Frame: Sendable { let jpeg: Data; let timestamp: Double; let sourceFrameIndex: Int }
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "benur.live-camera", qos: .userInitiated)
    private let context = CIContext()
    private var continuation: AsyncThrowingStream<Frame, Error>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var firstTimestamp: Double?
    private var lastTimestamp = -Double.infinity
    private var sourceFrameIndex = 0

    func start() -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.stop() }
            queue.async {
                self.continuation = continuation
                do {
                    try self.configure()
                    self.capture.startRunning()
                    if !self.capture.isRunning { throw MessageError("Kamera gagal dimulai.") }
                } catch { self.finish(error) }
            }
        }
    }

    func stop() { queue.async { self.finish() } }

    private func configure() throws {
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        capture.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw MessageError("Kamera belakang tidak tersedia. Gunakan iPhone fisik atau pilih video galeri.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddInput(input), capture.canAddOutput(output) else {
            throw MessageError("Konfigurasi kamera tidak didukung.")
        }
        capture.addInput(input)
        capture.addOutput(output)
        // App is portrait-only. Rotate the actual buffers, so both previews and boxes agree.
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
            throw MessageError("Orientasi kamera portrait tidak didukung.")
        }
        connection.videoRotationAngle = 90
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.finish(MessageError("Kamera terputus atau sedang digunakan. Tekan Mulai untuk mencoba lagi.")) }
            })
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard continuation != nil else { return }
        let inputIndex = sourceFrameIndex
        sourceFrameIndex += 1
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp - lastTimestamp >= 1 / max(1, AppConfig.cameraFPS) else { return }
        do {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { throw MessageError("Frame kamera rusak.") }
            let jpeg = try autoreleasepool { try MediaReader.encode(CIImage(cvPixelBuffer: buffer), context: context) }
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
            continuation?.yield(Frame(jpeg: jpeg, timestamp: timestamp - (firstTimestamp ?? timestamp), sourceFrameIndex: inputIndex))
        } catch { finish(error) }
    }

    private func finish(_ error: Error? = nil) {
        let stream = continuation
        continuation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if capture.isRunning { capture.stopRunning() }
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
    }
}
