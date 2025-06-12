import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox
import CoreImage

@available(macOS 14.0, *)
final class SideBySideConverter: Sendable {
    let assetReader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let originalFrameDuration: CMTime

    init(from url: URL) async throws {
        let asset = AVURLAsset(url: url)
        self.assetReader = try AVAssetReader(asset: asset)

        guard let track = try await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo).first else {
            throw NSError(domain: "SideBySideConverter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Error loading MV-HEVC video input"])
        }

        // Use load(.minFrameDuration) instead of deprecated property
        originalFrameDuration = try await track.load(.minFrameDuration)

        guard let layerIds = try await loadVideoLayerIdsForTrack(track), layerIds.count >= 2 else {
            throw NSError(domain: "SideBySideConverter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ビデオレイヤーIDが見つかりませんでした。"])
        }

        let settings: [String: Any] = [
            AVVideoDecompressionPropertiesKey as String: [
                kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: layerIds
            ]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard assetReader.canAdd(output) else {
            throw NSError(domain: "SideBySideConverter", code: 3, userInfo: nil)
        }
        assetReader.add(output)
        guard assetReader.startReading() else {
            throw NSError(domain: "SideBySideConverter", code: 4, userInfo: nil)
        }
        self.trackOutput = output
    }

    func transcodeToSideBySide(output videoOutputURL: URL) async throws {
        var leftFrames: [CIImage] = []
        var rightFrames: [CIImage] = []
        while let buffer = trackOutput.copyNextSampleBuffer() {
            guard let tagged = buffer.taggedBuffers else { continue }
            for tb in tagged {
                if case let .pixelBuffer(pb) = tb.buffer {
                    let img = CIImage(cvPixelBuffer: pb)
                    if tb.tags.contains(.stereoView(.leftEye)) {
                        leftFrames.append(img)
                    } else if tb.tags.contains(.stereoView(.rightEye)) {
                        rightFrames.append(img)
                    }
                }
            }
        }

        try await createSideBySideVideo(
            from: leftFrames,
            rightImages: rightFrames,
            outputURL: videoOutputURL,
            frameDuration: originalFrameDuration
        )
    }
}

// MARK: - Utilities

@available(macOS 14.0, *)
func loadVideoLayerIdsForTrack(_ videoTrack: AVAssetTrack) async throws -> [Int64]? {
    let descs = try await videoTrack.load(.formatDescriptions)
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
    // Remove existing output file if present
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    guard let firstLeft = leftImages.first,
          leftImages.count == rightImages.count else {
        print("Invalid frame lists")
        return
    }

    let leftSize = firstLeft.extent.size
    let totalWidth = leftSize.width * 2
    let height = leftSize.height

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let outputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: totalWidth,
        AVVideoHeightKey: height
    ]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    let pixelAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: totalWidth,
        kCVPixelBufferHeightKey as String: height
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerInput,
        sourcePixelBufferAttributes: pixelAttributes
    )

    writer.add(writerInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let ciContext = CIContext()
    var index: Int64 = 0

    for (left, right) in zip(leftImages, rightImages) {
        let blank = CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: totalWidth, height: height))
        let leftComp = left.composited(over: blank)
        let rightTrans = right.transformed(by: CGAffineTransform(translationX: leftSize.width, y: 0))
        let frameImage = rightTrans.composited(over: leftComp)

        guard let pool = adaptor.pixelBufferPool else { continue }
        var pxBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pxBuf)
        guard let pixelBuffer = pxBuf else { continue }

        ciContext.render(frameImage, to: pixelBuffer)

        // Append when writerInput is ready
        while !writerInput.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let pts = CMTimeMultiply(frameDuration, multiplier: Int32(index))
        adaptor.append(pixelBuffer, withPresentationTime: pts)
        index += 1
    }

    writerInput.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error {
            print("AVAssetWriter error: \(err.localizedDescription)")
        }
        if let err = writer.error {
            print("AVAssetWriter error: \(err.localizedDescription)")
        }
}
