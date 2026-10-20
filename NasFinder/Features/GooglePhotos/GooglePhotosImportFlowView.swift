import SwiftUI

@MainActor
final class GooglePhotosImportedMedia: ObservableObject {
    @Published var records: [SharedInboxRecord] = []
    @Published var pickerURL: URL?
    @Published var isPickerPresented = false
}

/// Standalone Google Photos import session that survives view disappearance (e.g. sidebar navigation).
/// Only explicit user cancellation or reset cancels the flow and deletes the session.
@MainActor
final class GooglePhotosImportSession: ObservableObject {
    static let shared = GooglePhotosImportSession()

    @Published var controller: GooglePhotosImportFlowController?
    @Published var importedMedia = GooglePhotosImportedMedia()
    @Published var skippedReports: Set<String> = []
    @Published var basketMessage: String?
    @Published var isFilingBasket = false
    @Published var filedReportIDs: Set<String> = []
    var deliveredCount = 0

    func resolveController(
        inboxStore: SharedInboxStore,
        forceAuthorization: Bool
    ) -> GooglePhotosImportFlowController {
        if let existing = controller {
            return existing
        }
        let media = GooglePhotosImportedMedia()
        self.importedMedia = media
        self.skippedReports.removeAll()
        self.basketMessage = nil
        self.isFilingBasket = false
        self.filedReportIDs.removeAll()
        self.deliveredCount = 0
        let newController = GooglePhotosImportFlowController(
            dependencies: .live(
                inboxStore: inboxStore,
                onImported: { [weak media] record in
                    media?.records.append(record)
                },
                openPicker: { [weak media] url in
                    guard let media, !media.isPickerPresented else { return false }
                    media.pickerURL = url
                    media.isPickerPresented = true
                    return true
                },
                closePicker: { [weak media] in
                    media?.isPickerPresented = false
                }
            ),
            forceAuthorization: forceAuthorization
        )
        self.controller = newController
        return newController
    }

    func cancel() {
        controller?.cancel()
        reset()
    }

    func reset() {
        controller = nil
        importedMedia = GooglePhotosImportedMedia()
        skippedReports.removeAll()
        basketMessage = nil
        isFilingBasket = false
        filedReportIDs.removeAll()
        deliveredCount = 0
    }
}

/// 영상 만들기 부모 화면이 임베드한 Google 포토 흐름을 부모를 떠날 때만 취소하기 위한 연결 고리.
/// 페이지 전환(스와이프)으로는 세션·웹 피커를 취소하지 않는다.
@MainActor
final class EmbeddedGooglePhotosLifecycle {
    var session: GooglePhotosImportSession?
    fileprivate var cancelHandler: (() -> Void)?

    func cancel() {
        cancelHandler?()
        session?.cancel()
        session = nil
    }
}

/// Google 포토 가져오기와 선택을 앱 탐색 경로의 페이지로 표시한다.
/// 사전 고지 → 인증/세션 준비 → 선택 대기 → 가져오기 진행 → 결과 순으로 단계를 보여준다.
struct GooglePhotosImportFlowView: View {
    @Environment(\.trailerProjectSink) private var projectSink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var controller: GooglePhotosImportFlowController
    @ObservedObject private var importedMedia: GooglePhotosImportedMedia
    @ObservedObject private var session: GooglePhotosImportSession
    @State private var trailerSelection: VideoTrailerSelection?
    @AppStorage("googlePhotosDisclosureAccepted.v1") private var disclosureAccepted = false
    /// 영상만들기 선택기에서만 지정한다. 이번에 가져온 항목만 돌려주며 기본 동작은 바뀌지 않는다.
    private let onImportedMedia: (([SharedInboxRecord]) -> Void)?
    /// 지정하면 부모 화면 안의 페이지로 동작한다: 자체 제목·dismiss 없이 끝난 기록을 바구니로 바로 넘긴다.
    private let lifecycle: EmbeddedGooglePhotosLifecycle?
    private var isEmbedded: Bool { lifecycle != nil }

    init(inboxStore: SharedInboxStore, forceAuthorization: Bool = false,
         lifecycle: EmbeddedGooglePhotosLifecycle? = nil,
         onImportedMedia: (([SharedInboxRecord]) -> Void)? = nil) {
        self.lifecycle = lifecycle
        self.onImportedMedia = onImportedMedia
        let session: GooglePhotosImportSession
        if let lifecycle {
            if let existing = lifecycle.session {
                session = existing
            } else {
                let fresh = GooglePhotosImportSession()
                lifecycle.session = fresh
                session = fresh
            }
        } else {
            session = GooglePhotosImportSession.shared
        }
        let controller = session.resolveController(inboxStore: inboxStore, forceAuthorization: forceAuthorization)
        self.session = session
        self.controller = controller
        self.importedMedia = session.importedMedia
    }

    /// 테스트·프리뷰용 주입 생성자.
    init(controller: @autoclosure @escaping () -> GooglePhotosImportFlowController) {
        let resolved = controller()
        let session = GooglePhotosImportSession()
        session.controller = resolved
        self.session = session
        self.controller = resolved
        self.importedMedia = session.importedMedia
        self.onImportedMedia = nil
        self.lifecycle = nil
    }

    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        mediaContent.modifier(PreserveMediaNavigation())
    }

    private var mediaContent: some View {
        ZStack {
            if importedMedia.isPickerPresented, let url = importedMedia.pickerURL {
                GooglePhotosPickerPage(url: url)
            } else {
                content
            }
        }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SkyBreezeBackground())
                .modifier(GooglePhotosStandaloneTitle(isEmbedded: isEmbedded))
        .onAppear {
            lifecycle?.cancelHandler = { [controller] in controller.cancel() }
            controller.setScenePollingAllowed(scenePhase == .active)
            if controller.phase == .idle { beginImport() }
        }
        .onDisappear {
            // Menu switch is not explicit user cancellation. Do not cancel the controller here.
        }
        .onChange(of: controller.phase) { _, phase in
            guard isEmbedded, let onImportedMedia else { return }
            switch phase {
            case .finished, .cancelled, .failed:
                let fresh = Array(importedMedia.records.dropFirst(session.deliveredCount))
                guard !fresh.isEmpty else { return }
                session.deliveredCount = importedMedia.records.count
                onImportedMedia(fresh)
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setScenePollingAllowed(phase == .active)
        }
        .routesTrailerSelection($trailerSelection, service: { LocalInboxFileService(records: importedMedia.records) }, sink: projectSink)
        .fullScreenCover(item: trailerCoverBinding($trailerSelection, sink: projectSink)) { selection in
            VideoTrailerView(items: selection.items, service: LocalInboxFileService(records: importedMedia.records), mode: selection.mode)
        }
    }

    private func beginImport() {
        controller.presentDisclosure()
        if disclosureAccepted || (try? GooglePhotosKeychainCredentialStore().load()) != nil {
            disclosureAccepted = true
            controller.confirmDisclosure()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .disclosure:
            GooglePhotosDisclosureView(
                onContinue: {
                    disclosureAccepted = true
                    controller.confirmDisclosure()
                },
                onCancel: {
                    controller.declineDisclosure()
                    if !isEmbedded {
                        session.reset()
                        dismiss()
                    }
                }
            )

        case .preparing:
            statusView(
                systemImage: "person.badge.key",
                title: "Google 계정을 확인하는 중",
                detail: "잠시만 기다려 주세요."
            )

        case .waitingForSelection:
            statusView(
                systemImage: "photo.on.rectangle.angled",
                title: "Google 포토에서 선택해 주세요",
                detail: "앱 안의 선택 화면에서 항목(최대 \(GooglePhotosImportFlowController.maxSelectionCount)개)을 고르고 완료하면 자동으로 가져옵니다."
            )

        case let .importing(completed, total):
            statusView(
                systemImage: "arrow.down.circle",
                title: "가져오는 중",
                detail: total > 0
                    ? "\(completed)/\(total)개 완료"
                    : "선택한 항목을 확인하는 중입니다."
            )

        case let .finished(imported, skipped, failed):
            resultView(imported: imported, skipped: skipped, failed: failed)

        case let .cancelled(imported):
            endView(
                systemImage: "xmark.circle",
                iconStyle: Color.secondary,
                title: "가져오기를 취소했습니다",
                detail: imported > 0
                    ? "이미 가져온 \(imported)개 파일은 폰하드에 그대로 유지됩니다."
                    : "가져온 파일이 없습니다."
            )

        case let .failed(message):
            failureView(message: message)
        }
    }

    private func statusView(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: ui(14)) {
            Image(systemName: systemImage)
                .font(.ui(.largeTitle))
                .foregroundStyle(SkyBreezeTheme.accent)
                .accessibilityHidden(true)

            Text(title)
                .font(.ui(.headline))
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.ui(.subheadline))
                .foregroundStyle(PorcelainMetrics.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            ProgressView()
                .padding(.top, ui(2))

            if case .waitingForSelection = controller.phase {
                Button("선택 화면 다시 열기") { controller.reopenPicker() }
                    .buttonStyle(PorcelainProminentButtonStyle())
            }
            Button("취소") {
                controller.cancel()
                if !isEmbedded {
                    session.cancel()
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, ui(10))
            .accessibilityLabel("Google 포토 가져오기 취소")
        }
        .padding(ui(24))
        .frame(maxWidth: ui(480))
        .accessibilityElement(children: .contain)
        .modifier(ScrollsWhenTooTall())
    }

    private func resultView(imported: Int, skipped: Int, failed: Int) -> some View {
        endView(
            systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle",
            iconStyle: failed == 0 ? Color.green : Color.orange,
            title: "가져오기 완료",
            detail: "가져옴 \(imported)개 · 건너뜀 \(skipped)개 · 실패 \(failed)개"
        )
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: ui(14)) {
            Image(systemName: "exclamationmark.triangle")
                .font(.ui(.largeTitle))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("가져오지 못했습니다")
                .font(.ui(.headline))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.ui(.subheadline))
                .foregroundStyle(PorcelainMetrics.secondary)
                .multilineTextAlignment(.center)

            Button("다시 시도") {
                beginImport()
            }
            .buttonStyle(PorcelainProminentButtonStyle())
            .controlSize(.large)
            .padding(.top, ui(10))

            Button("닫기") {
                if !isEmbedded { dismiss() }
            }
            .font(.ui(.subheadline))
            .foregroundStyle(PorcelainMetrics.secondary)
        }
        .padding(ui(24))
        .frame(maxWidth: ui(480))
        .modifier(ScrollsWhenTooTall())
    }

    private func endView(systemImage: String, iconStyle: Color, title: String, detail: String) -> some View {
        VStack(spacing: ui(14)) {
            Image(systemName: systemImage)
                .font(.ui(.largeTitle))
                .foregroundStyle(iconStyle)
                .accessibilityHidden(true)

            Text(title)
                .font(.ui(.headline))
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.ui(.subheadline))
                .foregroundStyle(PorcelainMetrics.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            if let onImportedMedia, !isEmbedded, !importedMedia.records.isEmpty,
               { if case .finished = controller.phase { return true }
                 if case .cancelled = controller.phase { return true }
                 return false }() {
                Button("영상 만들기에 담기", systemImage: "film") {
                    onImportedMedia(importedMedia.records)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            } else if onImportedMedia == nil, case .finished = controller.phase, !importedMedia.records.isEmpty {
                Button("영상 편집", systemImage: "film") {
                    let items = importedMedia.records.map { LocalInboxFileService.remoteItem(for: $0) }
                        .filter(\.isTrailerEligible)
                    guard !items.isEmpty else { return }
                    trailerSelection = VideoTrailerSelection(items: items)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            }
            if case .finished = controller.phase, !controller.itemReports.isEmpty {
                basketSection
            }
            Button(isEmbedded ? "더 선택하기" : "완료") {
                if isEmbedded {
                    beginImport()
                } else {
                    session.reset()
                    dismiss()
                }
            }
            .buttonStyle(PorcelainProminentButtonStyle())
            .controlSize(.large)
            .padding(.top, ui(10))
        }
        .padding(ui(24))
        .frame(maxWidth: ui(480))
        .modifier(ScrollsWhenTooTall())
    }
}

extension GooglePhotosImportFlowView {
    private var unresolvedReports: [GooglePhotosItemReport] {
        controller.itemReports.filter { $0.status != .imported && !session.filedReportIDs.contains($0.itemID) }
    }

    private var pendingImportedReports: [GooglePhotosItemReport] {
        controller.itemReports.filter { $0.status == .imported && !session.filedReportIDs.contains($0.itemID) }
    }

    /// 선택한 항목별 결과를 모두 보여 주고, 사용자가 확인한 뒤에만 재료함에 담는다.
    /// 처리하지 못한 항목은 조용히 빠지지 않고 "사용 불가"로 남거나 사용자가 직접 건너뛴다.
    /// 선택 세션은 가져오기가 끝나면 닫히므로 항목 하나만 다시 받을 수는 없고, 다시 선택해야 한다.
    @ViewBuilder
    var basketSection: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            ForEach(unresolvedReports) { report in
                HStack(spacing: ui(8)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.name).font(.ui(.subheadline)).lineLimit(1)
                        Text((report.failureText ?? "") + (session.skippedReports.contains(report.itemID) ? " · 건너뜀" : ""))
                            .font(.ui(.caption)).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button(session.skippedReports.contains(report.itemID) ? "되돌리기" : "건너뛰기") {
                        if session.skippedReports.contains(report.itemID) { session.skippedReports.remove(report.itemID) }
                        else { session.skippedReports.insert(report.itemID) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !unresolvedReports.isEmpty {
                Text("처리하지 못한 항목은 \"가져오기\"를 다시 열어 Google 포토에서 다시 선택하면 받을 수 있습니다. 담으면 재료함에 사용 불가 상태로 남습니다.")
                    .font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
            }
            if !pendingImportedReports.isEmpty || unresolvedReports.contains(where: { !session.skippedReports.contains($0.itemID) }) {
                Button(session.isFilingBasket ? "담는 중…" : "재료함에 담기 (\(pendingImportedReports.count)개 준비됨)", systemImage: "tray.and.arrow.down") {
                    fileToBasket()
                }
                .buttonStyle(PorcelainProminentButtonStyle())
                .disabled(session.isFilingBasket)
            }
            if let basketMessage = session.basketMessage {
                Text(basketMessage).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 가져온 파일을 열 수 있는지 확인한 뒤 담는다. 이번 선택의 파일은 가져온 순서대로 최근 기록과 짝지어진다.
    func fileToBasket() {
        let reports = controller.itemReports
        let imported = pendingImportedReports
        let recordSlice = Array(importedMedia.records.suffix(reports.filter { $0.status == .imported }.count))
        let allImported = reports.filter { $0.status == .imported }
        let skippedNow = session.skippedReports
        let unresolved = unresolvedReports.filter { !skippedNow.contains($0.itemID) }
        session.isFilingBasket = true
        Task {
            let basket = MaterialBasketStore.shared
            var failures: [String] = []
            var done: Set<String> = []
            for report in imported {
                guard let index = allImported.firstIndex(of: report), recordSlice.indices.contains(index),
                      let url = try? SharedInbox.fileURL(for: recordSlice[index]) else {
                    failures.append("\(report.name): 파일을 찾을 수 없습니다.")
                    continue
                }
                switch await basket.addValidated(url: url, name: report.name, isVideo: report.isVideo,
                                                 sourceKey: "google:\(report.itemID)", kind: .googlePhotos) {
                case .added, .duplicate: done.insert(report.itemID)
                case .failed(let reason):
                    failures.append("\(report.name): \(reason)")
                    // 사용 불가 항목이 인덱스에 기록된 경우에만 반영한 것으로 센다.
                    if basket.addUnresolved(name: report.name, isVideo: report.isVideo,
                                            sourceKey: "google:\(report.itemID)", kind: .googlePhotos, reason: reason) {
                        done.insert(report.itemID)
                    }
                }
            }
            for report in unresolved {
                if basket.addUnresolved(name: report.name, isVideo: report.isVideo,
                                        sourceKey: "google:\(report.itemID)", kind: .googlePhotos,
                                        reason: report.failureText ?? "받지 못했습니다.") {
                    done.insert(report.itemID)
                } else {
                    failures.append("\(report.name): \(basket.persistenceError ?? "재료함에 기록하지 못했습니다.")")
                }
            }
            session.filedReportIDs.formUnion(done)
            session.isFilingBasket = false
            session.basketMessage = failures.isEmpty
                ? "재료함에 \(done.count)개를 반영했습니다."
                : "일부는 담지 못했습니다. 재료함에서 사유를 확인하고 제외하거나 다시 선택하세요.\n" + failures.joined(separator: "\n")
        }
    }
}

/// Keeps a centered status reachable in a window too short for it by letting it scroll.
private struct ScrollsWhenTooTall: ViewModifier {
    func body(content: Content) -> some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }
}

private struct GooglePhotosStandaloneTitle: ViewModifier {
    let isEmbedded: Bool
    func body(content: Content) -> some View {
        if isEmbedded { content } else {
            content.navigationTitle("Google 포토").navigationBarTitleDisplayMode(.inline)
        }
    }
}
