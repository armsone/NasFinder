import SwiftUI

/// 미디어 전송: 작업대의 포켓을 보낼 목록으로 골라 QR로 연결한 기기로 보낸다.
/// 세 소스(미디어 / Google 포토 / 파일)는 모두 원본을 복사하지 않고 선택한 포켓에 참조만 담으며,
/// 원본은 보내는 순간에 항목마다 가져온다. 소스를 바꾸거나 취소해도 포켓의 참조는 그대로다.
@MainActor
struct PhotoTransferView: View {
    private enum PairingRole: String, Identifiable {
        case receiver
        case sender

        var id: String { rawValue }
    }

    @EnvironmentObject private var connectionStore: ConnectionStore
    @ObservedObject private var store = WorkbenchStore.shared
    /// 사용자가 직접 고른 포켓. 고르지 않았으면 비어 있고, 어떤 포켓에도 조용히 담지 않는다.
    @AppStorage(WorkbenchSelectionKey.transferPocket) private var selectedPocketRaw = ""
    /// nil은 포켓 전체, 빈 집합은 보낼 선택이 없다는 뜻이다. 사라진 선택을 전체로 넓히지 않는다.
    @State private var selectedEntryIDs: Set<UUID>?
    @State private var pairingRole: PairingRole?
    @State private var isGooglePresented = false
    @State private var isSendingFlowSelected = false
    @State private var isCreatingPocket = false
    @State private var newPocketName = ""
    @State private var notice: String?
    @State private var relinkGuidance: WorkbenchEntry?
    @State private var senderSources: [PhotoTransferSendSource] = []
    @StateObject private var receiverSession = PhotoTransferReceiverSession()
    @StateObject private var senderSession = PhotoTransferSenderSession()
    @StateObject private var run = WorkbenchRun(purpose: .transfer)

    private var selectedPocket: WorkbenchPocket? {
        UUID(uuidString: selectedPocketRaw).flatMap { store.pocket($0) }
    }

    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let palette = themeRefresh.theme.palette
        return List {
            roleSection
                .listRowBackground(palette.surface)
            if isSendingFlowSelected {
                pocketSection
                    .listRowBackground(palette.surface)
                sourceSection
                    .listRowBackground(palette.surface)
                if let pocket = selectedPocket, !pocket.entries.isEmpty {
                    reviewSection(pocket)
                        .listRowBackground(palette.surface)
                }
                pairingSection
                    .listRowBackground(palette.surface)
            }
        }
        .environment(\.defaultMinListRowHeight, MacUIScale.minListRowHeight)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("미디어 전송")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { WorkbenchRunPanel(run: run, title: "미디어 전송") }
        .navigationDestination(isPresented: $isGooglePresented) {
            WorkbenchGooglePhotosPage(pocketID: selectedPocket?.id)
        }
        .navigationDestination(item: $pairingRole) { role in
            switch role {
            case .receiver:
                PhotoTransferReceiverSheet(session: receiverSession)
            case .sender:
                PhotoTransferSenderSheet(session: senderSession, sources: senderSources)
            }
        }
        .onChange(of: run.phase) { _, phase in
            guard phase == .ready else { return }
            senderSources = run.sendSources()
            pairingRole = .sender
        }
        .onChange(of: pairingRole) { _, role in
            // 보내기·받기 화면에서 돌아오면 이번 실행의 임시 파일을 정리한다. 포켓의 참조는 그대로다.
            if role == nil { run.finish() }
        }
        .alert("새 포켓", isPresented: $isCreatingPocket) {
            TextField("포켓 이름", text: $newPocketName)
            Button("취소", role: .cancel) {}
            Button("만들기") { createPocket() }
        }
        .alert("다시 연결", isPresented: Binding(get: { relinkGuidance != nil }, set: { if !$0 { relinkGuidance = nil } })) {
            if relinkGuidance?.kind == .googlePhoto {
                Button("Google 포토에서 다시 선택") { relinkGuidance = nil; isGooglePresented = true }
            }
            Button("확인", role: .cancel) { relinkGuidance = nil }
        } message: { Text(relinkGuidance.map(WorkbenchPocketView.guidance(for:)) ?? "") }
        .alert("미디어 전송 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .onAppear {
            PhotoTransferSenderJournal.shared.expireOldPlans()
            if let selection = AppShellRouter.shared.currentWorkbenchTransferSelection() {
                if selection.pocketID == selectedPocket?.id, selection.privacyActive == PrivacyMode.currentlyActive {
                    selectedEntryIDs = selection.entryIDs
                } else {
                    selectedEntryIDs = []
                    notice = "보낼 선택을 복원하지 못했습니다. 포켓과 항목을 다시 골라 주세요."
                }
            }
            // 작업대에서 포켓을 골라 넘어왔거나 이전에 고른 포켓에 항목이 있으면 보내기 목록을 바로 보여 준다.
            if let pocket = selectedPocket, !pocket.entries.isEmpty { isSendingFlowSelected = true }
        }
        .onChange(of: selectedPocketRaw) { _, _ in
            if let pocket = selectedPocket, !pocket.entries.isEmpty { isSendingFlowSelected = true }
        }
        .onDisappear {
            // 받기·보내기·Google 화면을 push하면 이 화면도 onDisappear를 받는다. 그때 멈추면 방금 시작한 수신이 곧바로
            // 꺼져 QR이 떴다가 사라진다. 각 화면은 자기 onDisappear에서 스스로 정리하므로, 여기서는 하위 화면으로
            // 넘어가지 않고 이 화면을 떠날 때만 정리한다. 포켓의 참조는 정리 대상이 아니다.
            guard pairingRole == nil, !isGooglePresented else { return }
            receiverSession.stop()
            senderSession.cancel()
            selectedEntryIDs = nil
        }
    }

    private var roleSection: some View {
        Section {
            Button {
                isSendingFlowSelected = true
            } label: {
                Label("보내기", interfaceSystemImage: "nf.send")
                    .font(.ui(.subheadline))
            }
            Button {
                pairingRole = .receiver
            } label: {
                Label("받기", interfaceSystemImage: "nf.receive")
                    .font(.ui(.subheadline))
            }
            .accessibilityHint("수신을 시작하고 QR 코드를 표시합니다.")
        }
    }

    private var pocketSection: some View {
        Section {
            Menu {
                ForEach(store.pockets) { pocket in
                    Button {
                        useAllPocketEntries()
                        selectedPocketRaw = pocket.id.uuidString
                    } label: {
                        Label("\(pocket.name) · \(pocket.entries.count)개",
                              interfaceSystemImage: pocket.id == selectedPocket?.id ? "checkmark" : "nf.pocket")
                    }
                }
                if !store.pockets.isEmpty { Divider() }
                Button("새 포켓 만들기", interfaceSystemImage: "plus") { newPocketName = ""; isCreatingPocket = true }
            } label: {
                HStack {
                    Label(selectedPocket?.name ?? "포켓을 고르세요", interfaceSystemImage: "nf.pocket")
                        .font(.ui(.subheadline))
                    Spacer(minLength: 0)
                    Image(interfaceSystemName: "chevron.up.chevron.down", pointSize: 12).font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("보낼 포켓 선택")
            .accessibilityValue(selectedPocket?.name ?? "선택 안 됨")
            if selectedEntryIDs != nil {
                Button("포켓 전체 사용") { useAllPocketEntries() }
                    .accessibilityHint("작업대에서 고른 일부 항목 대신 이 포켓의 전체 항목을 보낼 목록으로 사용합니다.")
            }
        } header: {
            sectionHeader("1 보낼 포켓", systemImage: "nf.pocket")
        } footer: {
            Text("보낼 항목은 작업대의 포켓에 모읍니다. 어떤 포켓에도 자동으로 담지 않습니다.")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
    }

    /// 세 소스 모두 선택한 포켓에 위치(참조)만 담는다. 원본은 보내는 순간에만 가져온다.
    private var sourceSection: some View {
        Section {
            WorkbenchAddSourceControls(pocketID: selectedPocket?.id, layout: .rows) { isGooglePresented = true }
        } header: {
            sectionHeader("2 담을 곳 선택", systemImage: "plus.circle")
        } footer: {
            Text(selectedPocket == nil
                 ? "먼저 위에서 포켓을 고르세요."
                 : "고른 항목은 앱에 복사되지 않고 위치만 포켓에 기록됩니다. 여러 곳에서 이어서 담을 수 있습니다.")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
    }

    private func reviewSection(_ pocket: WorkbenchPocket) -> some View {
        let entries = transferEntries(in: pocket)
        let photos = entries.filter { $0.mediaKind == .photo }.count
        let videos = entries.filter { $0.mediaKind == .video }.count
        let folders = entries.filter(\.isFolder).count
        let others = entries.filter { $0.mediaKind == .other }.count
        var title = "3 보내기 목록 · \(entries.count)개 (사진 \(photos) · 영상 \(videos)"
        if folders > 0 { title += " · 폴더 \(folders)" }
        if others > 0 { title += " · 지원 안 함 \(others)" }
        title += ")"
        return Section {
            ForEach(entries) { entry in
                WorkbenchEntryRow(entry: entry, remove: {
                    if case .failure(let error) = store.removeEntries([entry.id], from: pocket.id) {
                        notice = error.localizedDescription
                    }
                }, relink: { relinkGuidance = entry })
            }
        } header: {
            sectionHeader(title, systemImage: "photo.on.rectangle")
        } footer: {
            Text("폴더는 보내기를 시작할 때의 현재 사진·영상으로 펼칩니다. 보낸 뒤에도 포켓의 참조는 남아 실패 시 다시 보낼 수 있고, 빼도 원본은 지워지지 않습니다.")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                startSend()
            } label: {
                Label("QR 스캔해서 연결", interfaceSystemImage: "qrcode.viewfinder")
                    .font(.ui(.subheadline))
            }
            .accessibilityHint("보낼 항목을 확인한 뒤 받는 기기에 표시된 QR 코드를 스캔해 연결합니다.")
            .disabled((selectedPocket.map { transferEntries(in: $0).isEmpty } ?? true) || run.isBusy)
        } header: {
            sectionHeader("4 다른 폰 연결", systemImage: "wifi")
        } footer: {
            Text("두 기기가 같은 Wi-Fi에 있어야 합니다.")
                .font(.ui(.caption2))
                .foregroundStyle(PorcelainMetrics.secondary)
        }
    }

    private func useAllPocketEntries() {
        selectedEntryIDs = nil
        AppShellRouter.shared.clearWorkbenchTransferSelection()
    }

    private func transferEntries(in pocket: WorkbenchPocket) -> [WorkbenchEntry] {
        guard let selectedEntryIDs else { return pocket.entries }
        return pocket.entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private func startSend() {
        guard let pocket = selectedPocket else { return }
        let entries = transferEntries(in: pocket)
        guard !entries.isEmpty else { return }
        run.start(entries: entries, connectionStore: connectionStore, inputPrivate: pocket.isPrivate == true)
    }

    private func createPocket() {
        switch store.createPocket(named: newPocketName) {
        case .success(let id):
            useAllPocketEntries()
            selectedPocketRaw = id.uuidString
        case .failure(let error): notice = error.localizedDescription
        }
    }

    nonisolated fileprivate static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    nonisolated static func selectionAccessibilityLabel(
        index: Int,
        kindTitle: String,
        duration: TimeInterval?
    ) -> String {
        guard let duration else { return "항목 \(index), \(kindTitle)" }
        return "항목 \(index), \(kindTitle), 재생 시간 \(durationText(duration))"
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: ui(3)) {
            Image(interfaceSystemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.ui(.footnote).weight(.medium))
        .foregroundStyle(PorcelainMetrics.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
