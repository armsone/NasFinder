import SwiftUI

@MainActor
private final class GooglePhotosImportedMedia: ObservableObject {
    @Published var records: [SharedInboxRecord] = []
    @Published var pickerURL: URL?
    @Published var isPickerPresented = false
}

/// 영상 만들기 부모 화면이 임베드한 Google 포토 흐름을 부모를 떠날 때만 취소하기 위한 연결 고리.
/// 페이지 전환(스와이프)으로는 세션·웹 피커를 취소하지 않는다.
@MainActor
final class EmbeddedGooglePhotosLifecycle {
    fileprivate var cancelHandler: (() -> Void)?
    func cancel() { cancelHandler?() }
}

/// Google 포토 가져오기와 선택을 앱 탐색 경로의 페이지로 표시한다.
/// 사전 고지 → 인증/세션 준비 → 선택 대기 → 가져오기 진행 → 결과 순으로 단계를 보여준다.
struct GooglePhotosImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: GooglePhotosImportFlowController
    @StateObject private var importedMedia: GooglePhotosImportedMedia
    @State private var trailerSelection: VideoTrailerSelection?
    @AppStorage("googlePhotosDisclosureAccepted.v1") private var disclosureAccepted = false
    /// 영상만들기 선택기에서만 지정한다. 이번에 가져온 항목만 돌려주며 기본 동작은 바뀌지 않는다.
    private let onImportedMedia: (([SharedInboxRecord]) -> Void)?
    /// 지정하면 부모 화면 안의 페이지로 동작한다: 자체 제목·dismiss 없이 끝난 기록을 바구니로 바로 넘긴다.
    private let lifecycle: EmbeddedGooglePhotosLifecycle?
    private var isEmbedded: Bool { lifecycle != nil }
    @State private var deliveredCount = 0

    init(inboxStore: SharedInboxStore, forceAuthorization: Bool = false,
         lifecycle: EmbeddedGooglePhotosLifecycle? = nil,
         onImportedMedia: (([SharedInboxRecord]) -> Void)? = nil) {
        self.lifecycle = lifecycle
        self.onImportedMedia = onImportedMedia
        let importedMedia = GooglePhotosImportedMedia()
        _importedMedia = StateObject(wrappedValue: importedMedia)
        _controller = StateObject(
            wrappedValue: GooglePhotosImportFlowController(
                dependencies: .live(
                    inboxStore: inboxStore,
                    onImported: { importedMedia.records.append($0) },
                    openPicker: { url in
                        guard !importedMedia.isPickerPresented else { return false }
                        importedMedia.pickerURL = url
                        importedMedia.isPickerPresented = true
                        return true
                    },
                    closePicker: {
                        importedMedia.isPickerPresented = false
                    }
                ),
                forceAuthorization: forceAuthorization
            )
        )
    }

    /// 테스트·프리뷰용 주입 생성자.
    init(controller: @autoclosure @escaping () -> GooglePhotosImportFlowController) {
        _controller = StateObject(wrappedValue: controller())
        _importedMedia = StateObject(wrappedValue: GooglePhotosImportedMedia())
        onImportedMedia = nil
        lifecycle = nil
    }

    var body: some View {
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
            if !isEmbedded, trailerSelection == nil {
                controller.cancel()
            }
        }
        .onChange(of: controller.phase) { _, phase in
            guard isEmbedded, let onImportedMedia else { return }
            switch phase {
            case .finished, .cancelled, .failed:
                let fresh = Array(importedMedia.records.dropFirst(deliveredCount))
                guard !fresh.isEmpty else { return }
                deliveredCount = importedMedia.records.count
                onImportedMedia(fresh)
            default: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setScenePollingAllowed(phase == .active)
        }
        .fullScreenCover(item: $trailerSelection) { selection in
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
                    if !isEmbedded { dismiss() }
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            ProgressView()
                .padding(.top, ui(2))

            if case .waitingForSelection = controller.phase {
                Button("선택 화면 다시 열기") { controller.reopenPicker() }
                    .buttonStyle(.borderedProminent)
            }
            Button("취소") {
                controller.cancel()
                if !isEmbedded { dismiss() }
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("다시 시도") {
                beginImport()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, ui(10))

            Button("닫기") {
                if !isEmbedded { dismiss() }
            }
            .font(.ui(.subheadline))
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            if let onImportedMedia, !isEmbedded, !importedMedia.records.isEmpty,
               { if case .finished = controller.phase { return true }
                 if case .cancelled = controller.phase { return true }
                 return false }() {
                Button("영상 만들기에 담기", systemImage: "film") {
                    onImportedMedia(importedMedia.records)
                }
                .buttonStyle(.borderedProminent)
            } else if onImportedMedia == nil, case .finished = controller.phase, !importedMedia.records.isEmpty {
                Button("영상 편집", systemImage: "film") {
                    let items = importedMedia.records.map { LocalInboxFileService.remoteItem(for: $0) }
                        .filter(\.isTrailerEligible)
                    guard !items.isEmpty else { return }
                    trailerSelection = VideoTrailerSelection(items: items)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(isEmbedded ? "더 선택하기" : "완료") {
                if isEmbedded { beginImport() } else { dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, ui(10))
        }
        .padding(ui(24))
        .frame(maxWidth: ui(480))
        .modifier(ScrollsWhenTooTall())
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
