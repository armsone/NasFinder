import SwiftUI
#if targetEnvironment(macCatalyst)
struct PhotoTransferQRScannerView: View {
    let onCodeScanned: (String) -> Void
    static var isSupported: Bool { false }

    var body: some View {
        ContentUnavailableView(
            "Mac에서는 QR 스캔을 지원하지 않습니다",
            systemImage: "qrcode.viewfinder",
            description: Text("전송 주소를 직접 입력해 주세요.")
        )
    }
}
#else
import VisionKit

/// QR 심볼로지만 인식하는 VisionKit DataScanner 래퍼.
struct PhotoTransferQRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    /// 기기 미지원(iOS on Mac 등)이나 카메라 권한 거부 시 false.
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        context.coordinator.onCodeScanned = onCodeScanned
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCodeScanned: (String) -> Void

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payloadString = barcode.observation.payloadStringValue {
                    onCodeScanned(payloadString)
                    return
                }
            }
        }
    }
}
#endif
