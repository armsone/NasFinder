import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinder

final class RemoteThumbnailImageDecoderTests: XCTestCase {
    func testDownsampleBoundsDecodedPixelDimensions() async throws {
        let data = try makePNGData(width: 1_200, height: 600)

        let result = try await RemoteThumbnailImageDecoder.downsample(
            data: data,
            maximumPixelSize: 120
        )

        XCTAssertLessThanOrEqual(result.image.width, 120)
        XCTAssertLessThanOrEqual(result.image.height, 120)
        XCTAssertEqual(result.image.width, 120)
        XCTAssertEqual(result.image.height, 60)
    }

    func testDownsampleRejectsInvalidImageBytes() async {
        do {
            _ = try await RemoteThumbnailImageDecoder.downsample(
                data: Data("not an image".utf8),
                maximumPixelSize: 120
            )
            XCTFail("Invalid image data should not produce a thumbnail")
        } catch let error as RemoteThumbnailGenerationError {
            guard case .invalidImageData = error else {
                XCTFail("Unexpected generation error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.cannotCreateContext
        }

        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestImageError.cannotCreateImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.cannotCreateDestination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.cannotEncodeImage
        }
        return output as Data
    }
}

private enum TestImageError: Error {
    case cannotCreateContext
    case cannotCreateImage
    case cannotCreateDestination
    case cannotEncodeImage
}
