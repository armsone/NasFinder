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
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        ScrollView {
            content
                .padding(.all, MacUIScale.defaultPadding)
                .frame(maxWidth: .infinity)
        }
        .background(SkyBreezeBackground())
        .navigationTitle("QR 표시해서 받기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Group {
                    Button("닫기") { requestDismiss() }
                }
                .uiBarFont()
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
                .padding(.top, ui(48))
        case .waitingForSender(let payload):
            VStack(spacing: ui(16)) {
                PhotoTransferPairingQRCodeView(urlString: payload.pairingURLString)
                    .frame(maxWidth: MacUIScale.isMac ? ui(360) : ui(280), maxHeight: MacUIScale.isMac ? ui(360) : ui(280))
                Text("보내는 기기에서 이 QR 코드를 스캔하세요.")
                    .font(.ui(.subheadline))
                    .multilineTextAlignment(.center)
                Text(verbatim: "\(payload.host):\(payload.port)")
                    .font(.ui(.caption, design: .monospaced))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .accessibilityLabel("수신 주소 \(payload.host) 포트 \(payload.port)")
                Button {
                    UIPasteboard.general.string = payload.pairingURLString
                    copiedPairingCode = payload.pairingURLString
                } label: {
                    Label(
                        copiedPairingCode == payload.pairingURLString
                            ? "연결 코드 복사됨"
                            : "연결 코드 복사",
                        interfaceSystemImage: copiedPairingCode == payload.pairingURLString
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .font(MacUIScale.isMac ? .ui(.subheadline) : nil)
                .controlSize(.small)
                .foregroundStyle(PorcelainMetrics.secondary)
                .accessibilityHint("QR 스캔을 사용할 수 없는 기기에 붙여넣을 일회용 연결 코드를 복사합니다.")
                ProgressView("연결 대기 중…")
                    .font(.ui(.caption))
                Button {
                    session.regeneratePairingQRCode()
                } label: {
                    Label("QR 다시 만들기", interfaceSystemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .font(MacUIScale.isMac ? .ui(.subheadline) : nil)
                .controlSize(.small)
                .foregroundStyle(PorcelainMetrics.secondary)
                .disabled(!session.canRegeneratePairingQRCode)
                .accessibilityLabel("페어링 QR 코드 다시 만들기")
                .accessibilityHint("현재 QR 코드를 무효화하고 새 연결 코드를 만듭니다.")
            }
        case .senderConnected(_, let peerPlatform):
            VStack(spacing: ui(12)) {
                Image(interfaceSystemName: "checkmark.circle.fill", pointSize: ui(48))
                    .font(.system(size: ui(48)))
                    .foregroundStyle(PorcelainMetrics.accent)
                    .accessibilityHidden(true)
                Text("\(peerPlatform.title) 기기와 연결되었습니다.")
                    .font(.ui(.headline))
                if session.transferFinished {
                    Text("\(session.receivedFileCount)개 받기 완료")
                        .font(.ui(.subheadline).weight(.semibold))
                        .foregroundStyle(PorcelainMetrics.accent)
                    if session.unverifiedSavedCount > 0 {
                        Text("그중 \(session.unverifiedSavedCount)개는 사진 보관함에 저장됐지만 저장본을 읽어 확인하지 못했습니다(사진 읽기 권한이 없는 경우 등). 저장은 정상이며, 보내는 기기에서는 이 항목의 원본 삭제를 사용할 수 없습니다. 이 앱은 읽기 권한을 몰래 요청하지 않습니다.")
                            .font(.ui(.footnote))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if !session.receivedResults.isEmpty {
                        receivedResultsGrid
                    }
                } else if let progress = session.transferProgress {
                    ProgressView(value: progress) {
                        Text(session.currentFileName ?? "파일 받는 중…")
                    }
                    .frame(maxWidth: MacUIScale.isMac ? .infinity : ui(280))
                    Text("\(session.receivedFileCount)개 받음")
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                } else {
                    ProgressView("파일 기다리는 중…")
                        .font(.ui(.caption))
                }
            }
            .padding(.top, ui(48))
        case .failed(let message):
            VStack(spacing: ui(12)) {
                Image(interfaceSystemName: "exclamationmark.triangle.fill", pointSize: ui(40))
                    .font(.system(size: ui(40)))
                    .foregroundStyle(PorcelainMetrics.warn)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.ui(.subheadline))
                    .multilineTextAlignment(.center)
                Button("다시 시도") { session.start() }
                    .buttonStyle(PorcelainProminentButtonStyle())
            }
            .padding(.top, ui(48))
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
            columns: [GridItem(.adaptive(minimum: ui(96), maximum: MacUIScale.isMac ? ui(220) : ui(132)), spacing: ui(10))],
            spacing: ui(10)
        ) {
            ForEach(session.receivedResults) { result in
                ZStack {
                    if let thumbnail = result.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: ui(12), style: .continuous)
                            .fill(.quaternary)
                        Image(interfaceSystemName: result.kind.systemImage, pointSize: 22)
                            .font(.ui(.title2))
                            .foregroundStyle(PorcelainMetrics.secondary)
                    }

                    if result.kind == .video {
                        Image(interfaceSystemName: "play.circle.fill", pointSize: 28)
                            .font(.ui(.title))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .frame(height: ui(104))
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ui(12), style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(result.kind.title)
                        .font(.ui(.caption2).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, ui(7))
                        .padding(.vertical, ui(4))
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(ui(6))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("저장 완료, \(result.kind.title)")
            }
        }
        .frame(maxWidth: MacUIScale.isMac ? .infinity : ui(560))
        .padding(.top, ui(4))
    }
}

/// 원본 삭제 선택 상태 규칙(순수). 세션 식별(epoch)이 바뀌면 이전 선택을 모두 버리고, 같은 세션이어도 삭제 후보가 아닌 항목은 뺀다.
enum PhotoTransferDeletionSelectionPolicy {
    static func reconciled(current: Set<String>, previousEpoch: UInt64, currentEpoch: UInt64, candidateIDs: Set<String>) -> Set<String> {
        guard previousEpoch == currentEpoch else { return [] }
        return current.intersection(candidateIDs)
    }
}

/// 보내기 역할 시트: QR을 스캔해 수신 기기와 핸드셰이크한다.
/// 스캐너를 못 쓰는 환경(iOS on Mac, 카메라 권한 거부)에서는 연결 코드 붙여넣기로 대체한다.
struct PhotoTransferSenderSheet: View {
    @ObservedObject var session: PhotoTransferSenderSession
    let sources: [PhotoTransferSendSource]
    @Environment(\.dismiss) private var dismiss
    @State private var scanErrorMessage: String?
    @State private var manualPayloadText = ""
    @State private var isDismissConfirmationPresented = false
    /// 삭제할 원본을 사용자가 직접 고른다. 기본은 아무것도 고르지 않은 상태(삭제 안 함)다.
    @State private var deletionSelection: Set<String> = []
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleting = false
    @State private var deletionMessage: String?
    private var themeRefresh = ThemeRefresh()

    /// '새로 보내기' 뒤에는 출력 실패로 막혔던 항목만(원래 순서) 새 전송으로 보낸다.
    private var scopedPositions: [Int]? {
        guard let positions = session.newCopyPositions, positions.allSatisfy({ sources.indices.contains($0) }) else { return nil }
        return positions
    }
    private var sendItems: [PhotoTransferSendSource] { scopedPositions.map { $0.map { sources[$0] } } ?? sources }

    var body: some View {
        let _ = themeRefresh.theme
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyBreezeBackground())
            .navigationTitle("QR 스캔해서 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        Button("닫기") { requestDismiss() }
                    }
                    .uiBarFont()
                }
            }
        .onChange(of: session.resultEpoch) { old, new in
            // 재연결·새 전송·새 결과 세션이 되면 이전에 체크한 삭제 선택을 이어받지 않는다(기본 OFF). OS 삭제 동의는 그대로 거친다.
            let reconciled = PhotoTransferDeletionSelectionPolicy.reconciled(
                current: deletionSelection, previousEpoch: old, currentEpoch: new,
                candidateIDs: Set(session.itemOutcomes.filter { $0.eligibility.isCandidate }.map(\.id)))
            if reconciled != deletionSelection { deletionSelection = reconciled }
            if old != new {
                deletionMessage = nil
                isDeleteConfirmationPresented = false
            }
        }
        .onDisappear {
            session.discardFullyVerifiedPlan()
            session.cancel()
            session.clearNewCopyScope()
        }
        .interactiveDismissDisabled(requiresDismissConfirmation)
        .alert("선택한 원본을 삭제할까요?", isPresented: $isDeleteConfirmationPresented) {
            Button("삭제", role: .destructive) { performDeletion() }
            Button("삭제 안 함", role: .cancel) {}
        } message: {
            Text("받는 기기 저장이 확인된 \(deletionSelection.count)개만 삭제합니다. 삭제 직전에 원본이 바뀌지 않았는지 다시 확인하고, iOS가 삭제를 한 번 더 확인합니다. 삭제한 항목은 '최근 삭제된 항목'으로 이동합니다.")
        }
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
            VStack(spacing: ui(14)) {
                ProgressView("연결 중…")
                Button("취소하고 다시 스캔") {
                    session.cancel()
                }
                .buttonStyle(.bordered)
                .font(MacUIScale.isMac ? .ui(.subheadline) : nil)
                .controlSize(.small)
                .foregroundStyle(PorcelainMetrics.secondary)
                .accessibilityHint("현재 연결 시도를 취소하고 QR 스캔 화면으로 돌아갑니다.")
            }
        case .connected(let payload, let peerPlatform):
            VStack(spacing: ui(12)) {
                Image(interfaceSystemName: "checkmark.circle.fill", pointSize: ui(48))
                    .font(.system(size: ui(48)))
                    .foregroundStyle(PorcelainMetrics.accent)
                    .accessibilityHidden(true)
                Text("\(peerPlatform.title) 기기와 연결되었습니다.")
                    .font(.ui(.headline))
                Text(verbatim: "\(payload.host):\(payload.port)")
                    .font(.ui(.caption, design: .monospaced))
                    .foregroundStyle(PorcelainMetrics.secondary)
                if session.transferFinished {
                    completionContent
                } else if session.isSending {
                    ProgressView(value: session.transferProgress ?? 0) {
                        Text("\(session.sentItemCount) / \(session.totalItemCount)")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: MacUIScale.isMac ? .infinity : ui(280))
                } else {
                    Button(scopedPositions == nil ? "4 보내기 · \(sources.count)개" : "새로 보내기 · \(sendItems.count)개") {
                        session.send(items: sendItems)
                    }
                    .buttonStyle(PorcelainProminentButtonStyle())
                    .disabled(sources.isEmpty)
                    if sources.isEmpty {
                        Text("먼저 이전 화면에서 보낼 항목을 담으세요.")
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.secondary)
                    }
                }
            }
        case .failed(let message):
            VStack(spacing: ui(12)) {
                Image(interfaceSystemName: "exclamationmark.triangle.fill", pointSize: ui(40))
                    .font(.system(size: ui(40)))
                    .foregroundStyle(PorcelainMetrics.warn)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.ui(.subheadline))
                    .multilineTextAlignment(.center)
                Button("다시 스캔") {
                    scanErrorMessage = nil
                    session.cancel()
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            }
            .padding(.all, MacUIScale.defaultPadding)
        }
    }

    // MARK: 송신 완료 화면과 원본 삭제(선택)

    private var verifiedCount: Int { session.itemOutcomes.filter { $0.status == .verified }.count }
    private var allVerified: Bool { !session.itemOutcomes.isEmpty && verifiedCount == session.itemOutcomes.count }

    @ViewBuilder
    private var completionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ui(12)) {
                if session.itemOutcomes.isEmpty {
                    Text("\(session.sentItemCount)개 보내기 완료")
                        .font(.ui(.headline)).foregroundStyle(PorcelainMetrics.accent)
                } else if allVerified {
                    Text("\(verifiedCount)개 보내기 완료 · 받는 기기 저장 확인됨")
                        .font(.ui(.headline)).foregroundStyle(PorcelainMetrics.accent)
                } else if session.receiptsNegotiated {
                    Text("\(verifiedCount)개 저장 확인 · \(session.itemOutcomes.count - verifiedCount)개는 확인하지 못했습니다")
                        .font(.ui(.headline)).foregroundStyle(PorcelainMetrics.warn)
                    Text("같은 사진을 다시 선택한 채 QR로 다시 연결하면, 이미 저장된 항목은 건너뛰고 남은 항목만 이어서 보냅니다.")
                        .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                    if session.retryableItemCount > 0 {
                        Button("다시 연결해서 이어 보내기") { session.cancel() }
                            .buttonStyle(PorcelainProminentButtonStyle())
                    }
                    outputBlockedContent
                } else {
                    Text("\(session.sentItemCount)개 보내기 완료")
                        .font(.ui(.headline)).foregroundStyle(PorcelainMetrics.accent)
                }
                deletionSection
            }
            .padding(.all, MacUIScale.defaultPadding)
            .frame(maxWidth: MacUIScale.isMac ? .infinity : ui(560), alignment: .leading)
        }
    }

    private var outputBlockedOutcomes: [PhotoTransferItemOutcome] { session.itemOutcomes.filter { $0.outputBlockedCode != nil } }

    /// 받는 기기에서 저장된 사본이 없어졌거나 바뀌었거나 확인되지 않은 항목. 이어 보내기에서 제외되고, 새 사본은 사용자가 직접 눌러야 보낸다.
    @ViewBuilder
    private var outputBlockedContent: some View {
        let blocked = outputBlockedOutcomes
        if !blocked.isEmpty {
            VStack(alignment: .leading, spacing: ui(6)) {
                Text("받는 기기 사본 문제 \(blocked.count)개").font(.ui(.subheadline).weight(.semibold)).foregroundStyle(PorcelainMetrics.warn)
                Text("이 항목은 같은 전송으로 다시 보내거나 받는 기기에서 되살리지 않습니다. 원본은 그대로입니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                ForEach(blocked) { outcome in
                    Text("항목 \(outcome.position + 1) · \(outcome.statusText)").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                }
                Text("원하면 새 전송으로 사본을 한 번 더 보낼 수 있습니다. 받는 기기에 같은 사진이 중복될 수 있습니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                Button("새로 보내기 (사본 \(blocked.count)개)") {
                    session.startNewTransferForBlockedItems(items: sendItems)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var deletionSection: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            Text("보낸 원본 삭제 (선택)").font(.ui(.headline))
            if session.tokenExposedToLegacy {
                Text(PhotoTransferSourceVerifier.tokenExposedReason + " 전송은 정상적으로 끝났고 원본은 그대로입니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
            } else if !session.receiptsNegotiated {
                Text("상대 앱이 항목별 저장 확인을 지원하지 않아 원본 삭제를 사용할 수 없습니다. 전송은 정상적으로 끝났고 원본은 그대로입니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
            } else {
                Text("기본값은 삭제 안 함입니다. 받는 기기가 저장을 확인했고 원본이 바뀌지 않은 항목만 직접 골라 지울 수 있습니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                ForEach(session.itemOutcomes) { outcome in
                    outcomeRow(outcome)
                }
                Button("선택한 원본 삭제…", role: .destructive) { isDeleteConfirmationPresented = true }
                    .disabled(deletionSelection.isEmpty || isDeleting)
                    .font(.ui(.subheadline))
                if isDeleting { ProgressView("원본을 확인하는 중…") }
            }
            if let deletionMessage {
                Text(deletionMessage).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.graphite)
            }
        }
    }

    private func outcomeRow(_ outcome: PhotoTransferItemOutcome) -> some View {
        let isCandidate = outcome.eligibility.isCandidate
        return HStack(alignment: .top, spacing: ui(10)) {
            Toggle(isOn: Binding(
                get: { deletionSelection.contains(outcome.id) },
                set: { isOn in
                    if isOn { deletionSelection.insert(outcome.id) } else { deletionSelection.remove(outcome.id) }
                })) { EmptyView() }
                .labelsHidden()
                .disabled(!isCandidate || isDeleting)
                .accessibilityLabel("항목 \(outcome.position + 1) 원본 삭제 선택")
            VStack(alignment: .leading, spacing: ui(2)) {
                Text("항목 \(outcome.position + 1) · \(outcome.kind.title)").font(.ui(.subheadline))
                Text(outcome.statusText).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                if case let .excluded(reason) = outcome.eligibility {
                    Text("삭제 제외: \(reason)").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.danger)
                }
            }
        }
    }

    private func performDeletion() {
        let selected = Array(deletionSelection)
        guard !selected.isEmpty else { return }
        isDeleting = true
        deletionMessage = nil
        Task {
            let result = await session.deleteSourceOriginals(itemIDs: selected)
            isDeleting = false
            session.markDeleted(itemIDs: result.deleted)
            deletionSelection.subtract(result.deleted)
            deletionSelection.subtract(result.excluded.keys)
            var lines: [String] = []
            if !result.deleted.isEmpty { lines.append("원본 \(result.deleted.count)개를 삭제했습니다.") }
            if let failure = result.failure { lines.append(failure) }
            if !result.excluded.isEmpty {
                lines.append("확인 결과 삭제하지 않은 \(result.excluded.count)개: " + Set(result.excluded.values).sorted().joined(separator: " / "))
            }
            deletionMessage = lines.isEmpty ? "삭제한 항목이 없습니다." : lines.joined(separator: "\n")
        }
    }

    @ViewBuilder
    private var scanningContent: some View {
        if PhotoTransferQRScannerView.isSupported {
            VStack(spacing: ui(12)) {
                PhotoTransferQRScannerView { handleScannedCode($0) }
                    .clipShape(RoundedRectangle(cornerRadius: ui(16)))
                    .frame(maxWidth: .infinity, minHeight: ui(280))
                    .accessibilityLabel("QR 코드 스캐너")
                Text("받는 기기 화면의 QR 코드를 비추세요.")
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
                if let scanErrorMessage {
                    Text(scanErrorMessage)
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.danger)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.all, MacUIScale.defaultPadding)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: ui(12)) {
                    Text("연결 코드 붙여넣기")
                        .font(.ui(.headline))
                    Text("받는 기기에서 QR 아래의 연결 코드를 복사한 뒤 여기에 붙여넣으세요.")
                        .font(.ui(.subheadline))
                    TextField("받는 기기에서 복사한 연결 코드", text: $manualPayloadText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable) // 영문·기호 코드라 한글 자모 배열이 뜨지 않게 한다.
                        .font(.ui(.caption, design: .monospaced))
                    Button("연결") {
                        handleScannedCode(
                            manualPayloadText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .buttonStyle(PorcelainProminentButtonStyle())
                    .disabled(manualPayloadText.isEmpty)
                    if let scanErrorMessage {
                        Text(scanErrorMessage)
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.danger)
                    }
                }
                .padding(.all, MacUIScale.defaultPadding)
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard case .idle = session.phase else { return }
        guard let payload = PhotoTransferPairingPayload(pairingURLString: code) else {
            scanErrorMessage = "NasFinder 미디어 전송 QR 코드가 아니거나 형식이 올바르지 않습니다."
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
        .accessibilityLabel("미디어 전송 페어링 QR 코드")
        .task(id: urlString) {
            image = PhotoTransferQRCodeGenerator.image(for: urlString)
        }
    }
}
