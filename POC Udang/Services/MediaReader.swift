import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Decoding, orientation correction and JPEG encoding stay off the main actor.
actor MediaReader {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var transform = CGAffineTransform.identity
    private let context = CIContext()
    private var sourceFrameIndex = 0

    func photo(_ data: Data) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw MessageError("Foto tidak dapat dibaca.")
        }
        return try Self.encode(image, context: context)
    }
    func open(_ url: URL) async throws -> (fps: Double, duration: Double) {
        cancel()
        sourceFrameIndex = 0
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MessageError("Video tidak memiliki frame yang dapat dibaca.")
        }
        transform = try await track.load(.preferredTransform)
        let fps = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MessageError("Durasi video tidak valid.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MessageError("Format video tidak didukung.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MessageError("Video gagal dimuat.") }
        self.reader = reader
        self.output = output
        return (fps.isFinite && fps > 0 ? fps : 30, duration)
    }
    func next() throws -> (jpeg: Data, timestamp: Double, sourceFrameIndex: Int)? {
        try Task.checkCancellation()
        guard let sample = output?.copyNextSampleBuffer() else {
            if reader?.status == .failed { throw reader?.error ?? MessageError("Video gagal dibaca.") }
            return nil
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw MessageError("Frame video rusak.") }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard timestamp.isFinite else { throw MessageError("Timestamp video tidak valid.") }
        let jpeg = try Self.encode(CIImage(cvPixelBuffer: buffer).transformed(by: transform), context: context)
        defer { sourceFrameIndex += 1 }
        return (jpeg, timestamp, sourceFrameIndex)
    }
    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }
    static func encode(_ image: CIImage, context: CIContext) throws -> Data {
        let scale = min(1, AppConfig.previewMaxDimension / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            throw MessageError("Gambar gagal diproses.")
        }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MessageError("JPEG gagal dibuat.")
        }
        CGImageDestinationAddImage(encoder, cg, [kCGImageDestinationLossyCompressionQuality: AppConfig.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw MessageError("JPEG gagal dibuat.") }
        return data as Data
    }
}
