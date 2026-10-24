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
    @State private var workbenchRequest: WorkbenchAddRequest?
    @State private var isReferencePagePresented = false
    @AppStorage("googlePhotosDisclosureAccepted.v1") private var disclosureAccepted = false
    /// 영상만들기 선택기에서만 지정한다. 이번에 가져온 항목만 돌려주며 기본 동작은 바뀌지 않는다.
    private let onImportedMedia: (([SharedInboxRecord]) -> Void)?
    /// 지정하면 부모 화면 안의 페이지로 동작한다: 자체 제목·dismiss 없이 끝난 기록을 바구니로 바로 넘긴다.
    private let lifecycle: EmbeddedGooglePhotosLifecycle?
    /// 임베디드 사전 고지에서 사용자가 명시적으로 취소했을 때 부모가 다른 소스 페이지로 돌아가게 한다.
    private let onExit: (() -> Void)?
    private var isEmbedded: Bool { lifecycle != nil }

    init(inboxStore: SharedInboxStore, forceAuthorization: Bool = false,
         lifecycle: EmbeddedGooglePhotosLifecycle? = nil,
         onImportedMedia: (([SharedInboxRecord]) -> Void)? = nil,
         onExit: (() -> Void)? = nil) {
        self.lifecycle = lifecycle
        self.onExit = onExit
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
        self.onExit = nil
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
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("작업대에 참조로 담기 (내려받지 않음)", interfaceSystemImage: "tray.2") {
                            // 진행 중인 가져오기는 멈추고, 선택 결과를 내려받지 않는 참조 전용 선택으로 넘어간다.
                            if controller.isRunning { controller.cancel() }
                            isReferencePagePresented = true
                        }
                    } label: {
                        Image(interfaceSystemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Google 포토 담기 방식")
                }
            }
        }
        .workbenchAddSheet($workbenchRequest)
        .navigationDestination(isPresented: $isReferencePagePresented) { WorkbenchGooglePhotosPage(pocketID: nil) }
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
        .trailerEditorCover(item: trailerCoverBinding($trailerSelection, sink: projectSink)) { selection in
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
                    if isEmbedded {
                        onExit?()
                    } else {
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
            Image(interfaceSystemName: systemImage, pointSize: 34)
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
            iconStyle: failed == 0 ? PorcelainMetrics.accent : PorcelainMetrics.warn,
            title: "가져오기 완료",
            detail: "가져옴 \(imported)개 · 건너뜀 \(skipped)개 · 실패 \(failed)개"
        )
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: ui(14)) {
            Image(interfaceSystemName: "exclamationmark.triangle", pointSize: 34)
                .font(.ui(.largeTitle))
                .foregroundStyle(PorcelainMetrics.warn)
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
            Image(interfaceSystemName: systemImage, pointSize: 34)
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
                Button("영상 만들기에 담기", interfaceSystemImage: "film") {
                    onImportedMedia(importedMedia.records)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            } else if onImportedMedia == nil, case .finished = controller.phase, !importedMedia.records.isEmpty {
                Button("영상 편집", interfaceSystemImage: "film") {
                    let items = importedMedia.records.map { LocalInboxFileService.remoteItem(for: $0) }
                        .filter(\.isTrailerEligible)
                    guard !items.isEmpty else { return }
                    trailerSelection = VideoTrailerSelection(items: items)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            }
            if case .finished = controller.phase, !controller.itemReports.isEmpty {
                workbenchSection
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
        controller.itemReports.filter { $0.status != .imported }
    }

    /// 가져오기 결과를 숨기지 않고 보여 주고, 폰하드로 가져온 파일의 위치만 작업대 포켓에 참조로 담게 한다.
    /// 처리하지 못한 항목은 조용히 빠지지 않고 사유와 함께 남는다. 내려받지 않고 담으려면 상단 메뉴의 참조 전용 선택을 쓴다.
    @ViewBuilder
    var workbenchSection: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            ForEach(unresolvedReports) { report in
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.name).font(.ui(.subheadline)).lineLimit(1)
                    Text(report.failureText ?? "").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.warn)
                }
            }
            if !unresolvedReports.isEmpty {
                Text("처리하지 못한 항목은 \"가져오기\"를 다시 열어 Google 포토에서 다시 선택하거나, 상단 메뉴의 \"작업대에 참조로 담기\"로 내려받지 않고 담을 수 있습니다.")
                    .font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
            }
            if !importedMedia.records.isEmpty {
                Button("작업대에 담기 (폰하드로 가져온 \(importedMedia.records.count)개)", interfaceSystemImage: "tray.2") {
                    let entries = importedMedia.records.map {
                        WorkbenchEntryFactory.entry(remote: LocalInboxFileService.browserItem(for: $0),
                                                    sourceLabel: WorkbenchSourceLabel.phoneHard)
                    }
                    workbenchRequest = WorkbenchAddRequest(title: "Google 포토에서 폰하드로 가져온 \(entries.count)개", entries: entries)
                }
                .buttonStyle(PorcelainProminentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
