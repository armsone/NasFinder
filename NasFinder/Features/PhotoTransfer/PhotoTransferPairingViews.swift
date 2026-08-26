import PhotosUI
import SwiftUI
import UIKit

enum PhotoTransferDismissalPolicy {
    static func receiverRequiresConfirmation(
        phase: PhotoTransferReceiverSession.Phase,
        transferFinished: Bool
    ) -> Bool {
        if case .senderConnected = phase { return !transferFinished }
        return false
    }

    static func senderRequiresConfirmation(
        phase: PhotoTransferSenderSession.Phase,
        isSending: Bool,
        transferFinished: Bool
    ) -> Bool {
        if case .connecting = phase { return true }
        if case .connected = phase { return isSending && !transferFinished }
        return false
    }
}

/// 받기 역할 시트: 페어링 QR을 표시하고 발신 기기의 접속을 기다린다.
struct PhotoTransferReceiverSheet: View {
    @ObservedObject var session: PhotoTransferReceiverSession
    @Environment(\.dismiss) private var dismiss
    @State private var isDismissConfirmationPresented = false
    @State private var copiedPairingCode: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .background(SkyBreezeBackground())
            .navigationTitle("QR 표시해서 받기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { requestDismiss() }
                }
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .interactiveDismissDisabled(requiresDismissConfirmation)
        .confirmationDialog(
            "받기를 중단할까요?",
            isPresented: $isDismissConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("중단하고 닫기", role: .destructive) { dismiss() }
            Button("계속 받기", role: .cancel) {}
        } message: {
            Text("연결된 기기에서 받고 있는 항목은 완료되지 않습니다.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .starting:
            ProgressView("수신 준비 중…")
                .padding(.top, 48)
        case .waitingForSender(let payload):
            VStack(spacing: 16) {
                PhotoTransferPairingQRCodeView(urlString: payload.pairingURLString)
                    .frame(maxWidth: 280, maxHeight: 280)
                Text("보내는 기기에서 이 QR 코드를 스캔하세요.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Text(verbatim: "\(payload.host):\(payload.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("수신 주소 \(payload.host) 포트 \(payload.port)")
                Button {
                    UIPasteboard.general.string = payload.pairingURLString
                    copiedPairingCode = payload.pairingURLString
                } label: {
                    Label(
                        copiedPairingCode == payload.pairingURLString
                            ? "연결 코드 복사됨"
                            : "연결 코드 복사",
                        systemImage: copiedPairingCode == payload.pairingURLString
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .accessibilityHint("QR 스캔을 사용할 수 없는 기기에 붙여넣을 일회용 연결 코드를 복사합니다.")
                ProgressView("연결 대기 중…")
                    .font(.caption)
                Button {
                    session.regeneratePairingQRCode()
                } label: {
                    Label("QR 다시 만들기", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .disabled(!session.canRegeneratePairingQRCode)
                .accessibilityLabel("페어링 QR 코드 다시 만들기")
                .accessibilityHint("현재 QR 코드를 무효화하고 새 연결 코드를 만듭니다.")
            }
        case .senderConnected(_, let peerPlatform):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("\(peerPlatform.title) 기기와 연결되었습니다.")
                    .font(.headline)
                if session.transferFinished {
                    Text("\(session.receivedFileCount)개 받기 완료")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    if !session.receivedResults.isEmpty {
                        receivedResultsGrid
                    }
                } else if let progress = session.transferProgress {
                    ProgressView(value: progress) {
                        Text(session.currentFileName ?? "파일 받는 중…")
                    }
                    .frame(maxWidth: 280)
                    Text("\(session.receivedFileCount)개 받음")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("파일 기다리는 중…")
                        .font(.caption)
                }
            }
            .padding(.top, 48)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("다시 시도") { session.start() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 48)
        }
    }

    private var requiresDismissConfirmation: Bool {
        PhotoTransferDismissalPolicy.receiverRequiresConfirmation(
            phase: session.phase,
            transferFinished: session.transferFinished
        )
    }

    private func requestDismiss() {
        if requiresDismissConfirmation {
            isDismissConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private var receivedResultsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 10)],
            spacing: 10
        ) {
            ForEach(session.receivedResults) { result in
                ZStack {
                    if let thumbnail = result.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.quaternary)
                        Image(systemName: result.kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    if result.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .frame(height: 104)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(result.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("저장 완료, \(result.kind.title)")
            }
        }
        .frame(maxWidth: 560)
        .padding(.top, 4)
    }
}

/// 보내기 역할 시트: QR을 스캔해 수신 기기와 핸드셰이크한다.
/// 스캐너를 못 쓰는 환경(iOS on Mac, 카메라 권한 거부)에서는 연결 코드 붙여넣기로 대체한다.
struct PhotoTransferSenderSheet: View {
    @ObservedObject var session: PhotoTransferSenderSession
    let selectedItems: [PhotosPickerItem]
    let mediaKinds: [PhotoTransferMediaKind]
    @Environment(\.dismiss) private var dismiss
    @State private var scanErrorMessage: String?
    @State private var manualPayloadText = ""
    @State private var isDismissConfirmationPresented = false

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SkyBreezeBackground())
                .navigationTitle("QR 스캔해서 보내기")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("닫기") { requestDismiss() }
                    }
                }
        }
        .onDisappear { session.cancel() }
        .interactiveDismissDisabled(requiresDismissConfirmation)
        .confirmationDialog(
            "보내기를 중단할까요?",
            isPresented: $isDismissConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("중단하고 닫기", role: .destructive) { dismiss() }
            Button("계속 보내기", role: .cancel) {}
        } message: {
            Text("현재 연결 또는 파일 전송이 완료되지 않습니다.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            scanningContent
        case .connecting:
            VStack(spacing: 14) {
                ProgressView("연결 중…")
                Button("취소하고 다시 스캔") {
                    session.cancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .accessibilityHint("현재 연결 시도를 취소하고 QR 스캔 화면으로 돌아갑니다.")
            }
        case .connected(let payload, let peerPlatform):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("\(peerPlatform.title) 기기와 연결되었습니다.")
                    .font(.headline)
                Text(verbatim: "\(payload.host):\(payload.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if session.transferFinished {
                    Text("\(session.sentItemCount)개 보내기 완료")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                } else if session.isSending {
                    ProgressView(value: session.transferProgress ?? 0) {
                        Text("\(session.sentItemCount) / \(session.totalItemCount)")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 280)
                } else {
                    Button("4 보내기 · \(selectedItems.count)개") {
                        session.send(items: selectedItems, kinds: mediaKinds)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedItems.isEmpty)
                    if selectedItems.isEmpty {
                        Text("먼저 이전 화면에서 사진이나 영상을 선택하세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("다시 스캔") {
                    scanErrorMessage = nil
                    session.cancel()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var scanningContent: some View {
        if PhotoTransferQRScannerView.isSupported {
            VStack(spacing: 12) {
                PhotoTransferQRScannerView { handleScannedCode($0) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .accessibilityLabel("QR 코드 스캐너")
                Text("받는 기기 화면의 QR 코드를 비추세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let scanErrorMessage {
                    Text(scanErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("연결 코드 붙여넣기")
                        .font(.headline)
                    Text("받는 기기에서 QR 아래의 연결 코드를 복사한 뒤 여기에 붙여넣으세요.")
                        .font(.subheadline)
                    TextField("받는 기기에서 복사한 연결 코드", text: $manualPayloadText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption.monospaced())
                    Button("연결") {
                        handleScannedCode(
                            manualPayloadText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualPayloadText.isEmpty)
                    if let scanErrorMessage {
                        Text(scanErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard case .idle = session.phase else { return }
        guard let payload = PhotoTransferPairingPayload(pairingURLString: code) else {
            scanErrorMessage = "NasFinder 사진 전송 QR 코드가 아니거나 형식이 올바르지 않습니다."
            return
        }
        scanErrorMessage = nil
        session.connect(using: payload)
    }

    private var requiresDismissConfirmation: Bool {
        PhotoTransferDismissalPolicy.senderRequiresConfirmation(
            phase: session.phase,
            isSending: session.isSending,
            transferFinished: session.transferFinished
        )
    }

    private func requestDismiss() {
        if requiresDismissConfirmation {
            isDismissConfirmationPresented = true
        } else {
            dismiss()
        }
    }
}

/// 페이로드 문자열을 QR 이미지로 렌더링한다. 픽셀 보간 없이 또렷하게 표시.
private struct PhotoTransferPairingQRCodeView: View {
    let urlString: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .accessibilityLabel("사진 전송 페어링 QR 코드")
        .task(id: urlString) {
            image = PhotoTransferQRCodeGenerator.image(for: urlString)
        }
    }
}
