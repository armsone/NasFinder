@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// Android Motion Photo의 이미지/영상 컴포넌트를 Photos가 받는 Live Photo 리소스로 정규화한다.
/// 공개 ImageIO/AVFoundation API만 사용하며, 두 출력 중 하나라도 실패하면 결과를 반환하지 않는다.
enum PhotoTransferLivePhotoConverter {
    struct ConvertedPair: Sendable {
        let imageURL: URL
        let pairedVideoURL: URL

        func removeTemporaryFiles() {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: pairedVideoURL)
        }
    }

    enum ConversionError: LocalizedError {
        case invalidImage
        case imageMetadataWriteFailed
        case videoTrackUnavailable
        case videoMetadataDescriptionFailed
        case readerCouldNotStart
        case writerCouldNotStart
        case sampleWriteFailed
        case outputValidationFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "Motion Photo의 대표 이미지를 읽을 수 없습니다."
            case .imageMetadataWriteFailed: "Live Photo 이미지 메타데이터를 만들지 못했습니다."
            case .videoTrackUnavailable: "Motion Photo의 움직임 영상을 읽을 수 없습니다."
            case .videoMetadataDescriptionFailed: "Live Photo 영상 메타데이터 형식을 만들지 못했습니다."
            case .readerCouldNotStart: "움직임 영상 변환을 시작하지 못했습니다."
            case .writerCouldNotStart: "Live Photo 영상 생성을 시작하지 못했습니다."
            case .sampleWriteFailed: "Live Photo 영상 샘플을 기록하지 못했습니다."
            case .outputValidationFailed: "변환된 Live Photo 메타데이터를 확인하지 못했습니다."
            }
        }
    }

    static func convert(
        imageURL: URL,
        videoURL: URL,
        stillImageTimeUs: Int64
    ) async throws -> ConvertedPair {
        let assetIdentifier = UUID().uuidString
        let imageExtension = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
        let convertedImage = PhotoTransferSelectionLoader.temporaryURL(fileExtension: imageExtension)
        let convertedVideo = PhotoTransferSelectionLoader.temporaryURL(fileExtension: "mov")
        do {
            try writeImage(
                from: imageURL,
                to: convertedImage,
                assetIdentifier: assetIdentifier
            )
            try await writePairedVideo(
                from: videoURL,
                to: convertedVideo,
                assetIdentifier: assetIdentifier,
                stillImageTimeUs: stillImageTimeUs
            )
            guard try imageAssetIdentifier(at: convertedImage) == assetIdentifier,
                  try await videoAssetIdentifier(at: convertedVideo) == assetIdentifier,
                  try await videoContainsStillImageTime(at: convertedVideo)
            else {
                throw ConversionError.outputValidationFailed
            }
            return ConvertedPair(imageURL: convertedImage, pairedVideoURL: convertedVideo)
        } catch {
            try? FileManager.default.removeItem(at: convertedImage)
            try? FileManager.default.removeItem(at: convertedVideo)
            throw error
        }
    }

    static func resolvedStillImageTime(
        durationSeconds: TimeInterval,
        requestedMicroseconds: Int64
    ) -> TimeInterval {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        let requested = requestedMicroseconds >= 0
            ? TimeInterval(requestedMicroseconds) / 1_000_000
            : durationSeconds / 2
        return min(max(0, requested), durationSeconds)
    }

    private static func writeImage(from sourceURL: URL, to destinationURL: URL, assetIdentifier: String) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil)
        else {
            throw ConversionError.invalidImage
        }
        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let properties = imagePropertiesByAddingAssetIdentifier(
            sourceProperties,
            assetIdentifier: assetIdentifier
        )
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.imageMetadataWriteFailed
        }
    }

    static func imagePropertiesByAddingAssetIdentifier(
        _ source: [CFString: Any],
        assetIdentifier: String
    ) -> [CFString: Any] {
        var properties = source
        var makerApple = (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        makerApple["17"] = assetIdentifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerApple
        return properties
    }

    private static func writePairedVideo(
        from sourceURL: URL,
        to destinationURL: URL,
        assetIdentifier: String,
        stillImageTimeUs: Int64
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw ConversionError.videoTrackUnavailable }
        let duration = try await asset.load(.duration)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        let reader = try AVAssetReader(asset: asset)

        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.keySpace = .quickTimeMetadata
        contentIdentifier.key = "com.apple.quicktime.content.identifier" as NSString
        contentIdentifier.value = assetIdentifier as NSString
        let sourceMetadata = try await asset.load(.metadata)
        writer.metadata = sourceMetadata.filter {
            !isContentIdentifierMetadata($0)
        } + [contentIdentifier]

        var copyPairs: [(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput)] = []
        for track in videoTracks + audioTracks {
            let formatDescription = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
            }
            guard writer.canAdd(input), reader.canAdd(output) else {
                throw ConversionError.sampleWriteFailed
            }
            writer.add(input)
            reader.add(output)
            copyPairs.append((input, output))
        }

        var metadataDescription: CMFormatDescription?
        let specification: [CFString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                kCMMetadataBaseDataType_SInt8,
        ]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMediaType_Metadata,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &metadataDescription
        )
        guard status == noErr, let metadataDescription else {
            throw ConversionError.videoMetadataDescriptionFailed
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: metadataDescription
        )
        guard writer.canAdd(metadataInput) else { throw ConversionError.videoMetadataDescriptionFailed }
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.startWriting() else { throw writer.error ?? ConversionError.writerCouldNotStart }
        guard reader.startReading() else { throw reader.error ?? ConversionError.readerCouldNotStart }
        writer.startSession(atSourceTime: .zero)

        let seconds = resolvedStillImageTime(
            durationSeconds: duration.seconds,
            requestedMicroseconds: stillImageTimeUs
        )
        let stillTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.value = NSNumber(value: Int8(0))
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 600))
        )
        guard metadataAdaptor.append(group) else { throw ConversionError.sampleWriteFailed }
        metadataInput.markAsFinished()

        var finished = Array(repeating: false, count: copyPairs.count)
        while finished.contains(false) {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw CancellationError()
            }
            if copyLoopHasTerminalFailure(
                readerStatus: reader.status,
                writerStatus: writer.status
            ) {
                reader.cancelReading()
                writer.cancelWriting()
                throw reader.error ?? writer.error ?? ConversionError.sampleWriteFailed
            }
            var madeProgress = false
            for index in copyPairs.indices where !finished[index] {
                let pair = copyPairs[index]
                guard pair.input.isReadyForMoreMediaData else { continue }
                if let sample = pair.output.copyNextSampleBuffer() {
                    guard pair.input.append(sample) else {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw writer.error ?? ConversionError.sampleWriteFailed
                    }
                    madeProgress = true
                } else {
                    pair.input.markAsFinished()
                    finished[index] = true
                    madeProgress = true
                }
            }
            if !madeProgress { try await Task.sleep(for: .milliseconds(2)) }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? ConversionError.sampleWriteFailed
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ConversionError.sampleWriteFailed
        }
    }

    static func copyLoopHasTerminalFailure(
        readerStatus: AVAssetReader.Status,
        writerStatus: AVAssetWriter.Status
    ) -> Bool {
        readerStatus == .failed || readerStatus == .cancelled
            || writerStatus == .failed || writerStatus == .cancelled
    }

    private static func isContentIdentifierMetadata(_ item: AVMetadataItem) -> Bool {
        item.keySpace == .quickTimeMetadata
            && (item.key as? String) == "com.apple.quicktime.content.identifier"
    }

    static func imageAssetIdentifier(at url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return makerApple["17"] as? String
    }

    static func videoAssetIdentifier(at url: URL) async throws -> String? {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        for item in metadata {
            guard item.keySpace == .quickTimeMetadata,
                  (item.key as? String) == "com.apple.quicktime.content.identifier"
            else { continue }
            return try await item.load(.stringValue)
        }
        return nil
    }

    static func videoContainsStillImageTime(at url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }
            while let sample = output.copyNextSampleBuffer() {
                guard let group = AVTimedMetadataGroup(sampleBuffer: sample) else { continue }
                if group.items.contains(where: {
                    ($0.key as? String) == "com.apple.quicktime.still-image-time"
                }) {
                    reader.cancelReading()
                    return true
                }
            }
        }
        return false
    }
}
