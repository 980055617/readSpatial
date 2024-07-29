/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Reads side-by-side video input and performs conversion to a multiview QuickTime video file.
*/

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox
import CoreImage

/// The left eye is video layer ID 0 (the hero eye) and the right eye is layer ID 1.
/// - Tag: VideoLayers
let MVHEVCVideoLayerIDs = [0, 1]

// For simplicity, choose view IDs that match the layer IDs.
let MVHEVCViewIDs = [0, 1]

// The first element in this array is the view ID of the left eye.
let MVHEVCLeftAndRightViewIDs = [0, 1]

/// Transcodes side-by-side HEVC to MV-HEVC.
final class SideBySideConverter: Sendable {
    
    let assetReader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let originalFrameDuration: CMTime
    /// Loads a video to read for conversion.
    /// - Parameter url: A URL to a side-by-side HEVC file.
    /// - Tag: ReadInputVideo
    init(from url: URL) async throws {
        let asset = AVURLAsset(url: url)
        self.assetReader = try AVAssetReader(asset: asset)
        
        
        // Get the side-by-side video track.
        guard let track = try await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo).first else {
            throw NSError(domain: "SideBySideConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error loading MV-HVEC video input"])
        }
        
        originalFrameDuration = track.minFrameDuration
        print(originalFrameDuration)
        let mediaCharacteristics = try await track.load(.mediaCharacteristics)
        print("Media Characteristics: \(mediaCharacteristics)")
        
        guard let videoLayerIds = try await loadVideoLayerIdsForTrack(track), videoLayerIds.count >= 2 else {
            throw NSError(domain: "SideBySideConverter", code: 2, userInfo: [NSLocalizedDescriptionKey: "ビデオレイヤーIDが見つかりませんでした。"])
        }
        
        // 両目用ビューのトラック出力を設定
        let outputSettings: [String: Any] = [
            AVVideoDecompressionPropertiesKey as String: [kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs as String: videoLayerIds]
        ]
        let tempTrackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        
        guard assetReader.canAdd(tempTrackOutput) else {
            throw NSError(domain: "SideBySideConverter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to add track output to asset reader"])
        }
        assetReader.add(tempTrackOutput)
        
        guard assetReader.startReading() else {
            throw NSError(domain: "SideBySideConverter", code: 4, userInfo: [NSLocalizedDescriptionKey: assetReader.error?.localizedDescription ?? "Unknown error during track read start"])
        }
        
        self.trackOutput = tempTrackOutput
        
        print("Initialize succeeded.")
    }
    
    /// Transcodes side-by-side HEVC media to MV-HEVC.
    /// - Parameter output: The output URL to write the MV-HEVC file to.
    /// - Parameter spatialMetadata: Optional spatial metadata to add to the output file.
    /// - Tag: TranscodeVideo
    func transcodeToTwoSight(output videoOutputURL: URL) async {
        
        var leftEyeImages: [CIImage] = []
        var rightEyeImages: [CIImage] = []
        
        while let nextSampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let taggedBuffers = nextSampleBuffer.taggedBuffers else {
                continue
            }
            
            taggedBuffers.forEach { taggedBuffer in
                switch taggedBuffer.buffer {
                case let .pixelBuffer(pixelBuffer):
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let tags = taggedBuffer.tags
                    
                    if tags.contains(.stereoView(.leftEye)) {
                        leftEyeImages.append(ciImage)
                    } else if tags.contains(.stereoView(.rightEye)) {
                        rightEyeImages.append(ciImage)
                    }
                    
                case .sampleBuffer(let samp):
                    fatalError("EXPECTED PIXEL BUFFER, GOT SAMPLE BUFFER \(samp)")
                @unknown default:
                    fatalError("EXPECTED PIXEL BUFFER TYPE, GOT \(taggedBuffer.buffer)")
                }
            }
        }
        
        let outputFileNameLeft = videoOutputURL.deletingPathExtension().lastPathComponent + "_left.mov"
        let outputFileNameRight = videoOutputURL.deletingPathExtension().lastPathComponent + "_right.mov"
        let outputURLLeft = videoOutputURL.deletingLastPathComponent().appendingPathComponent(outputFileNameLeft)
        let outputURLRight = videoOutputURL.deletingLastPathComponent().appendingPathComponent(outputFileNameRight)

        
        // Delete a previous output file with the same name if one exists.
        if FileManager.default.fileExists(atPath: outputURLLeft.path()) {
            do {
                try FileManager.default.removeItem(at: outputURLLeft)
            } catch {
                print("Failed to remove existing file: \(error)")
            }
        }
        // Delete a previous output file with the same name if one exists.
        if FileManager.default.fileExists(atPath: outputURLRight.path()) {
            do {
                try FileManager.default.removeItem(at: outputURLRight)
            } catch {
                print("Failed to remove existing file: \(error)")
            }
        }
        do {
            //try await createVideo(from: leftEyeImages, outputURL: outputURLLeft, frameDuration: originalFrameDuration)
            //try await createVideo(from: rightEyeImages, outputURL: outputURLRight, frameDuration: originalFrameDuration)
            try await createCombinedVideo(from: leftEyeImages, rightImages: rightEyeImages, outputURL: outputURLLeft, frameDuration: originalFrameDuration)
        } catch {
            print("Failed to create video: \(error)")
        }
        
    }
}

// Load the video layer ID's from an asset's stereo multiview track.
/// - Tag: LoadVideoLayers
func loadVideoLayerIdsForTrack(_ videoTrack: AVAssetTrack) async throws -> [Int64]? {
    let formatDescriptions = try await videoTrack.load(.formatDescriptions)
    var tags = [Int64]()
    if let tagCollections = formatDescriptions.first?.tagCollections {
        tags = tagCollections.flatMap({ $0 }).compactMap { tag in
            tag.value(onlyIfMatching: .videoLayerID)
        }
    }
    return tags
}

func createVideo(from images: [CIImage], outputURL: URL, frameDuration: CMTime) async throws {
    guard let firstImage = images.first else {
        print("No images to create video.")
        return
    }
    
    // 画像リストの長さを出力
    print("Number of images: \(images.count)")
    
    // Delete a previous output file with the same name if one exists.
    if FileManager.default.fileExists(atPath: outputURL.path) {
        do {
            try FileManager.default.removeItem(at: outputURL)
        } catch {
            print("Failed to remove existing file: \(error)")
        }
    }
    
    let size = firstImage.extent.size
    let videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height
    ]
    
    let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: nil)
    
    videoWriter.add(videoWriterInput)
    videoWriter.startWriting()
    videoWriter.startSession(atSourceTime: .zero)
    
    let ciContext = CIContext()
    var frameCount: Int64 = 0
    
    for ciImage in images {
        // ピクセルバッファを作成
        guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
            print("Pixel buffer pool is nil.")
            continue
        }
        
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
        
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            print("Failed to create pixel buffer.")
            continue
        }
        
        ciContext.render(ciImage, to: pixelBuffer)
        
        // ピクセルバッファを追加する前に readyForMoreMediaData をチェック
        while !videoWriterInput.isReadyForMoreMediaData {
            await Task.sleep(10_000_000) // 10ms 待機
        }
        
        let frameTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime)
        frameCount += 1
    }
    
    videoWriterInput.markAsFinished()
    await videoWriter.finishWriting()
}

func createCombinedVideo(from leftImages: [CIImage], rightImages: [CIImage], outputURL: URL, frameDuration: CMTime) async throws {
    guard let firstLeftImage = leftImages.first, let firstRightImage = rightImages.first else {
        print("No images to create video.")
        return
    }
    
    // 画像リストの長さを出力
    print("Number of left images: \(leftImages.count)")
    print("Number of right images: \(rightImages.count)")
    
    guard leftImages.count == rightImages.count else {
        print("Left and right image lists are not the same length.")
        return
    }
    
    // Delete a previous output file with the same name if one exists.
    if FileManager.default.fileExists(atPath: outputURL.path) {
        do {
            try FileManager.default.removeItem(at: outputURL)
        } catch {
            print("Failed to remove existing file: \(error)")
        }
    }
    
    let size = firstLeftImage.extent.size
    let videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height
    ]
    
    let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: nil)
    
    videoWriter.add(videoWriterInput)
    videoWriter.startWriting()
    videoWriter.startSession(atSourceTime: .zero)
    
    let ciContext = CIContext()
    var frameCount: Int64 = 0
    
    for (leftImage, rightImage) in zip(leftImages, rightImages) {
        // 左右の画像に透明度50%を適用
        let leftImageWithAlpha = leftImage.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
        ])
        
        let rightImageWithAlpha = rightImage.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
        ])
        
        // 左右の画像を重ね合わせる
        let combinedImage = leftImageWithAlpha.composited(over:rightImageWithAlpha)
        
        // ピクセルバッファを作成
        guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
            print("Pixel buffer pool is nil.")
            continue
        }
        
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
        
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            print("Failed to create pixel buffer.")
            continue
        }
        
        ciContext.render(combinedImage, to: pixelBuffer)
        
        // ピクセルバッファを追加する前に readyForMoreMediaData をチェック
        while !videoWriterInput.isReadyForMoreMediaData {
            await Task.sleep(10_000_000) // 10ms 待機
        }
        
        let frameTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: frameTime)
        frameCount += 1
    }
    
    videoWriterInput.markAsFinished()
    await videoWriter.finishWriting()
}
