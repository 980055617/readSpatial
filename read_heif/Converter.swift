import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox
import CoreImage

@available(macOS 14.0, *)
final class SideBySideConverter: Sendable {
    let inputURL: URL
    let assetReader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let originalFrameDuration: CMTime

    init(from url: URL) async throws {
        self.inputURL = url
        let asset = AVURLAsset(url: url)
        self.assetReader = try AVAssetReader(asset: asset)

        // Stereo multiview track
        guard let track = try await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo).first else {
            throw NSError(domain: "SideBySideConverter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Error loading MV-HEVC video input"])
        }
        originalFrameDuration = try await track.load(.minFrameDuration)

        // Configure reader for requested layers
        guard let layerIds = try await loadVideoLayerIdsForTrack(track), layerIds.count >= 2 else {
            throw NSError(domain: "SideBySideConverter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Video layer IDs not found"])
        }
        let outputSettings: [String: Any] = [
            AVVideoDecompressionPropertiesKey as String: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: layerIds
            ]
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        assetReader.add(readerOutput)
        guard assetReader.startReading() else {
            throw NSError(domain: "SideBySideConverter", code: 3, userInfo: nil)
        }
        self.trackOutput = readerOutput
    }

    /// Extract left/right frames and generate side-by-side MP4
    func transcodeToSideBySide(output videoOutputURL: URL) async throws {
        var leftFrames = [CIImage]()
        var rightFrames = [CIImage]()
        while let sample = trackOutput.copyNextSampleBuffer(), let tagged = sample.taggedBuffers {
            for tb in tagged {
                if case let .pixelBuffer(pb) = tb.buffer {
                    let ciImage = CIImage(cvPixelBuffer: pb)
                        .oriented(.down)  // Correct orientation for many HEVC outputs
                    if tb.tags.contains(.stereoView(.leftEye)) {
                        leftFrames.append(ciImage)
                    } else if tb.tags.contains(.stereoView(.rightEye)) {
                        rightFrames.append(ciImage)
                    }
                }
            }
        }
        try await createSideBySideVideo(from: leftFrames,
                                       rightImages: rightFrames,
                                       outputURL: videoOutputURL,
                                       frameDuration: originalFrameDuration)
    }

    /// Extract depth map frames and save as MP4
    func transcodeDepth(output depthOutputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        let reader = try AVAssetReader(asset: asset)
        let depthTracks = try await asset.loadTracks(withMediaType: .depthData)
        guard let depthTrack = depthTracks.first else {
            print("No depth track")
            return
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: depthTrack, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw NSError(domain: "SideBySideConverter", code: 4, userInfo: nil) }
        var depthFrames = [CIImage]()
        while let sample = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) {
            let ciImage = CIImage(cvPixelBuffer: pb)
                .oriented(.right)
            depthFrames.append(ciImage)
        }
        try await createVideo(from: depthFrames,
                              outputURL: depthOutputURL,
                              frameDuration: originalFrameDuration)
    }
}

// MARK: - Helpers

@available(macOS 14.0, *)
func loadVideoLayerIdsForTrack(_ track: AVAssetTrack) async throws -> [Int64]? {
    let descs = try await track.load(.formatDescriptions)
    return descs.first?.tagCollections?.flatMap { $0 }
        .compactMap { $0.value(onlyIfMatching: .videoLayerID) }
}

@available(macOS 14.0, *)
func createSideBySideVideo(
    from leftImages: [CIImage],
    rightImages: [CIImage],
    outputURL: URL,
    frameDuration: CMTime
) async throws {
    guard !leftImages.isEmpty, leftImages.count == rightImages.count else {
        print("Invalid frames")
        return
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let size = leftImages[0].extent.size
    let totalWidth = size.width * 2
    let height = size.height

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: totalWidth,
        AVVideoHeightKey: height
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: totalWidth,
        kCVPixelBufferHeightKey as String: height
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: attrs)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let context = CIContext()
    var index: Int64 = 0
    for (l, r) in zip(leftImages, rightImages) {
        let blank = CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: size))
        let leftComp = l.composited(over: blank)
        let rightTrans = r.transformed(by: .init(translationX: size.width, y: 0))
        let frame = rightTrans.composited(over: leftComp)

        // Render full frame bounds
        let bounds = CGRect(x: 0, y: 0, width: totalWidth, height: height)
        guard let pool = adaptor.pixelBufferPool else { continue }
        var buf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
        guard let pix = buf else { continue }
        context.render(frame, to: pix, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())

        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(pix, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
        index += 1
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@available(macOS 14.0, *)
func createVideo(
    from images: [CIImage],
    outputURL: URL,
    frameDuration: CMTime
) async throws {
    guard !images.isEmpty else { return }
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let size = images[0].extent.size
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: attrs)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let context = CIContext()
    var idx: Int64 = 0
    for img in images {
        guard let pool = adaptor.pixelBufferPool else { continue }
        var buf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
        guard let pix = buf else { continue }
        context.render(img, to: pix)
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        adaptor.append(pix, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(idx)))
        idx += 1
    }
    input.markAsFinished()
    await writer.finishWriting()
}
