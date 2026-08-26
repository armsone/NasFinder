import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import NasFinder

final class AnimatedImagePlaybackTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        super.tearDown()
    }

    func testTinyOrMissingGIFDelaysPlayAtBrowserFallbackSpeed() {
        XCTAssertEqual(AnimatedImagePlaybackPolicy.normalizedDelay(nil), 0.1)
        XCTAssertEqual(AnimatedImagePlaybackPolicy.normalizedDelay(0), 0.1)
        XCTAssertEqual(AnimatedImagePlaybackPolicy.normalizedDelay(0.01), 0.1)
        XCTAssertEqual(AnimatedImagePlaybackPolicy.normalizedDelay(0.04), 0.04)
        XCTAssertEqual(AnimatedImagePlaybackPolicy.normalizedDelay(.nan), 0.1)
    }

    func testTimelineExpandsVariableDelaysIntoUniformSlots() {
        let timeline = AnimatedImagePlaybackPolicy.timeline(frameDelays: [0.1, 0.2, 0.1])
        XCTAssertEqual(timeline.frameIndices, [0, 1, 1, 2])
        XCTAssertEqual(timeline.totalDuration, 0.4, accuracy: 0.000_1)

        let uniform = AnimatedImagePlaybackPolicy.timeline(frameDelays: [0.05, 0.05])
        XCTAssertEqual(uniform.frameIndices, [0, 1])
        XCTAssertEqual(uniform.totalDuration, 0.1, accuracy: 0.000_1)
    }

    func testIrregularTimelineFallsBackToOneSlotPerFrame() {
        let delays = (0..<600).map { $0.isMultiple(of: 2) ? 0.097 : 0.101 }
        let timeline = AnimatedImagePlaybackPolicy.timeline(frameDelays: delays)
        XCTAssertEqual(timeline.frameIndices, Array(0..<600))
        XCTAssertEqual(timeline.totalDuration, 59.4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            timeline.frameIndices.count,
            AnimatedImagePlaybackPolicy.maximumExpandedFrameCount
        )
    }

    func testFramePixelSizeShrinksWithFrameCountButKeepsStillImagesLarge() {
        XCTAssertEqual(
            AnimatedImagePlaybackPolicy.maximumPixelSize(frameCount: 1, preferred: 4_096),
            4_096
        )
        let hundredFrames = AnimatedImagePlaybackPolicy.maximumPixelSize(
            frameCount: 100,
            preferred: 4_096
        )
        XCTAssertGreaterThanOrEqual(hundredFrames, AnimatedImagePlaybackPolicy.minimumPixelSize)
        XCTAssertLessThan(hundredFrames, 4_096)
        XCTAssertLessThanOrEqual(
            hundredFrames * hundredFrames * 4 * 100,
            AnimatedImagePlaybackPolicy.maximumDecodedByteCount
        )
        XCTAssertEqual(
            AnimatedImagePlaybackPolicy.maximumPixelSize(frameCount: 100_000, preferred: 4_096),
            AnimatedImagePlaybackPolicy.minimumPixelSize
        )
    }

    func testAnimatedGIFDecodesEveryFrameWithItsDelay() async throws {
        let gifURL = try makeGIF(frameDelays: [0.1, 0.2, 0.1])

        let decoded = try await AnimatedImageDecoder.decodeGIF(
            fileURL: gifURL,
            maximumPixelSize: 4_096
        )

        let frames = try XCTUnwrap(decoded)
        XCTAssertEqual(frames.frames.count, 3)
        XCTAssertEqual(frames.timeline.frameIndices, [0, 1, 1, 2])
        XCTAssertEqual(frames.timeline.totalDuration, 0.4, accuracy: 0.000_1)

        let image = try XCTUnwrap(frames.makeUIImage())
        XCTAssertEqual(image.images?.count, 4)
        XCTAssertEqual(image.duration, 0.4, accuracy: 0.000_1)
        XCTAssertEqual(image.size, CGSize(width: 8, height: 8))
    }

    func testStillImagesKeepTheExistingStillPath() async throws {
        let stillGIF = try makeGIF(frameDelays: [0.1])
        let stillPNG = try makePNG()

        let gifResult = try await AnimatedImageDecoder.decodeGIF(
            fileURL: stillGIF,
            maximumPixelSize: 4_096
        )
        let pngResult = try await AnimatedImageDecoder.decodeGIF(
            fileURL: stillPNG,
            maximumPixelSize: 4_096
        )

        XCTAssertNil(gifResult)
        XCTAssertNil(pngResult)
    }

    func testDownsampledAnimatedFramesStayWithinPixelBound() async throws {
        let gifURL = try makeGIF(frameDelays: [0.1, 0.1], side: 64)

        let decoded = try await AnimatedImageDecoder.decodeGIF(
            fileURL: gifURL,
            maximumPixelSize: 16
        )

        let frames = try XCTUnwrap(decoded)
        XCTAssertEqual(frames.frames.count, 2)
        for frame in frames.frames {
            XCTAssertLessThanOrEqual(max(frame.width, frame.height), 16)
        }
    }

    private func makeGIF(frameDelays: [Double], side: Int = 8) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("gif")
        temporaryFiles.append(url)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.gif.identifier as CFString,
                frameDelays.count,
                nil
            )
        )
        CGImageDestinationSetProperties(
            destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        for (index, delay) in frameDelays.enumerated() {
            let image = try solidImage(
                side: side,
                gray: CGFloat(index + 1) / CGFloat(frameDelays.count + 1)
            )
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makePNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension("png")
        temporaryFiles.append(url)
        let data = try XCTUnwrap(UIImage(cgImage: try solidImage(side: 8, gray: 0.5)).pngData())
        try data.write(to: url)
        return url
    }

    private func solidImage(side: Int, gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }
}
