import CoreImage.CIFilterBuiltins
import UIKit

/// CoreImage 내장 필터만으로 페어링 QR 이미지를 만든다. 외부 의존성 없음.
enum PhotoTransferQRCodeGenerator {
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        guard scale > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
