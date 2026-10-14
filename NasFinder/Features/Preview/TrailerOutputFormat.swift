import CoreGraphics
import Foundation

// HanClip ClipItem.OutputAspectRatio and VideoComposer.aspectFillTransform,
// imported for the same output sizes and centered aspect-fill behavior.
enum OutputAspectRatio: String, CaseIterable, Identifiable {
    case square = "1:1"
    case portrait3x4 = "3:4"
    case landscape4x3 = "4:3"
    case portrait9x16 = "9:16"
    case landscape16x9 = "16:9"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square:
            "정방형"
        case .portrait3x4:
            "세로 3:4"
        case .landscape4x3:
            "가로 4:3"
        case .portrait9x16:
            "세로 9:16"
        case .landscape16x9:
            "가로 16:9"
        }
    }

    var renderSize: CGSize {
        switch self {
        case .square:
            CGSize(width: 1080, height: 1080)
        case .portrait3x4:
            CGSize(width: 1080, height: 1440)
        case .landscape4x3:
            CGSize(width: 1440, height: 1080)
        case .portrait9x16:
            CGSize(width: 1080, height: 1920)
        case .landscape16x9:
            CGSize(width: 1920, height: 1080)
        }
    }

    static func renderSize(for sourceSize: CGSize) -> CGSize {
        let safeWidth = max(1, sourceSize.width)
        let safeHeight = max(1, sourceSize.height)
        let ratio = safeWidth / safeHeight
        let size: CGSize

        if ratio >= 1 {
            if ratio <= 16.0 / 9.0 {
                size = CGSize(width: 1080 * ratio, height: 1080)
            } else {
                size = CGSize(width: 1920, height: 1920 / ratio)
            }
        } else if ratio >= 9.0 / 16.0 {
            size = CGSize(width: 1080, height: 1080 / ratio)
        } else {
            size = CGSize(width: 1920 * ratio, height: 1920)
        }

        return CGSize(
            width: evenPixelValue(size.width),
            height: evenPixelValue(size.height)
        )
    }

    private static func evenPixelValue(_ value: CGFloat) -> CGFloat {
        let rounded = max(4, Int(value.rounded()))
        return CGFloat(max(4, rounded - rounded % 4))
    }
}

enum TrailerOutputRenderer {
    static func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let originalRect = CGRect(origin: .zero, size: naturalSize)
        let orientedRect = originalRect.applying(preferredTransform)
        let orientedSize = CGSize(
            width: abs(orientedRect.width),
            height: abs(orientedRect.height)
        )
        let scale = max(
            renderSize.width / orientedSize.width,
            renderSize.height / orientedSize.height
        )
        let scaled = preferredTransform.concatenating(
            CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledRect = originalRect.applying(scaled)
        let translation = CGAffineTransform(
            translationX:
                (renderSize.width - scaledRect.width) / 2 - scaledRect.minX,
            y:
                (renderSize.height - scaledRect.height) / 2 - scaledRect.minY
        )
        return scaled.concatenating(translation)
    }

}
