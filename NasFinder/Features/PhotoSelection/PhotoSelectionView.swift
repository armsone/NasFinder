import PhotosUI
import SwiftUI

/// 도구 → 사진 선별. 입력(사진 보관함·파일·공유) → 품질+다양성 분석 → 추천 개수와 이유 →
/// 직접 정한 N → 결과 미리보기와 확인 → 저장/공유/작업대에 담기.
struct PhotoSelectionView: View {
    @ObservedObject private var session = PhotoSelectionSession.shared
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isFileImporterPresented = false
    @State private var pendingFileImportResult: Result<[URL], Error>?
    @State private var countText = ""
    @State private var isPreviewPresented = false
    @State private var isClearConfirmationPresented = false
    @State private var isExcludedListPresented = false
    private var themeRefresh = ThemeRefresh()

    private let columns = [GridItem(.adaptive(minimum: ui(96), maximum: ui(130)), spacing: ui(8))]

    var body: some View {
        let _ = themeRefresh.theme
        ScrollView {
            VStack(alignment: .leading, spacing: ui(16)) {
                Text("비슷한 사진을 묶고 품질을 비교해 남길 만한 사진을 추천합니다. 원본은 옮기거나 지우지 않습니다.")
                    .font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.secondary)
                inputSection
                if !session.items.isEmpty || !session.excludedVideoNames.isEmpty { summarySection }
                if session.recommendation != nil { recommendationSection } else { noRecommendationNotice }
                if !session.items.isEmpty { itemsSection }
            }
            .padding(ui(16))
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(PorcelainMetrics.paper)
        .navigationTitle("사진 선별")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.loadSharedBatches()
            syncCountText()
        }
        .onChange(of: pickerSelection) { _, picked in
            guard !picked.isEmpty else { return }
            let snapshot = picked
            pickerSelection = []
            Task { await session.addPickerItems(snapshot) }
        }
        .onChange(of: session.recommendation) { _, _ in syncCountText() }
        #if targetEnvironment(macCatalyst)
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.image, .movie],
                      allowsMultipleSelection: true) { result in handleFileImport(result) }
        #else
        .fullScreenCover(isPresented: $isFileImporterPresented, onDismiss: {
            guard let result = pendingFileImportResult else { return }
            pendingFileImportResult = nil
            handleFileImport(result)
        }) {
            MediaDocumentPicker { result in
                pendingFileImportResult = result
                isFileImporterPresented = false
            }
            .ignoresSafeArea()
        }
        #endif
        .sheet(isPresented: $isPreviewPresented) { PhotoSelectionPreviewSheet(session: session) }
        .alert("입력을 모두 비울까요?", isPresented: $isClearConfirmationPresented) {
            Button("비우기", role: .destructive) { session.clearAll(); countText = "" }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 화면의 입력과 분석 결과만 비웁니다. 사진 보관함 원본은 그대로입니다.")
        }
        .alert("사진 선별 알림", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("확인", role: .cancel) { session.notice = nil }
        } message: { Text(session.notice ?? "") }
        .sheet(isPresented: $isExcludedListPresented) {
            NavigationStack {
                List(session.excludedVideoNames, id: \.self) { Text($0).font(.ui(.footnote)) }
                    .navigationTitle("제외된 동영상")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { isExcludedListPresented = false } } }
            }
        }
    }

    // MARK: 입력

    private var inputSection: some View {
        PorcelainGroupCard {
            PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
                PorcelainRow(title: "사진 보관함에서 고르기", subtitle: "여러 장을 한 번에 고를 수 있습니다", showsChevron: true) {
                    InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.rowIconSize)
                }
            }
            .buttonStyle(.plain)
            PorcelainDivider()
            Button { isFileImporterPresented = true } label: {
                PorcelainRow(title: "파일에서 고르기", subtitle: "기기 파일·iCloud Drive의 이미지", showsChevron: true) {
                    InterfaceIcon(systemName: "folder", size: PorcelainMetrics.rowIconSize)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 요약과 진행

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            let ready = session.readyItems.count
            let failed = session.failedItems.count
            Text("입력 \(session.items.count)장 · 분석 완료 \(ready)장" + (failed > 0 ? " · 실패 \(failed)장" : ""))
                .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(PorcelainMetrics.graphite)
            if !session.excludedVideoNames.isEmpty {
                Button { isExcludedListPresented = true } label: {
                    Text("동영상 \(session.excludedVideoNames.count)개는 선별에서 제외했습니다 · 목록 보기")
                        .font(.ui(.footnote))
                }
            }
            ForEach(session.skippedReasons, id: \.self) { reason in
                Text("공유에서 제외: \(reason)").font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
            }
            if session.isAnalyzing || session.isLoadingInputs {
                HStack(spacing: ui(8)) {
                    ProgressView()
                    Text("사진을 분석하는 중…").font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                    Spacer()
                    if session.isAnalyzing { Button("분석 중지") { session.cancelAnalysis() }.font(.ui(.footnote)) }
                }
            } else if session.items.contains(where: { $0.state == .queued }) {
                Button("분석 이어서 하기") { session.analyzePending() }.font(.ui(.footnote))
            }
            HStack(spacing: ui(12)) {
                if failed > 0 { Button("실패한 항목 모두 다시 시도") { session.retryAllFailed() }.font(.ui(.footnote)) }
                Spacer()
                Button("입력 모두 비우기", role: .destructive) { isClearConfirmationPresented = true }
                    .font(.ui(.footnote)).disabled(session.isAnalyzing)
            }
        }
    }

    // MARK: 추천과 개수

    @ViewBuilder private var recommendationSection: some View {
        if let recommendation = session.recommendation {
            PorcelainGroupCard {
                VStack(alignment: .leading, spacing: ui(10)) {
                    Text("추천 \(recommendation.recommendedCount)장")
                        .font(.ui(.title3).weight(.semibold)).foregroundStyle(PorcelainMetrics.graphite)
                    ForEach(Array(recommendation.reasonLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.graphite)
                    }
                    if !session.failedItems.isEmpty {
                        Text("분석하지 못한 사진 \(session.failedItems.count)장은 계산에서 빠졌습니다. 아래에서 다시 시도할 수 있습니다.")
                            .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
                    }
                    Text("사진은 이 기기 안에서만 분석하며 밖으로 보내지 않습니다.")
                        .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                    if !recommendation.rejectedByIndex.isEmpty {
                        Text("값이 올바르지 않아 제외된 사진 \(recommendation.rejectedByIndex.count)장")
                            .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
                    }
                    Divider()
                    countEditor(recommendation)
                    if case let .failure(error)? = session.outcome {
                        Text(error.message).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
                    }
                    if case let .success(result)? = session.outcome {
                        ForEach(result.warnings, id: \.self) { Text($0).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary) }
                    }
                    Button("결과 미리보기") { isPreviewPresented = true }
                        .buttonStyle(PorcelainProminentButtonStyle())
                        .disabled(!isOutcomeValid)
                }
                .padding(ui(14))
            }
        }
    }

    /// 분석에 성공한 사진이 하나도 없으면 추천이나 결과를 만들지 않고 이유와 다시 시도를 안내한다.
    @ViewBuilder private var noRecommendationNotice: some View {
        if !session.isAnalyzing, !session.isLoadingInputs {
            if session.items.isEmpty, !session.excludedVideoNames.isEmpty {
                Text("동영상만 있어 선별할 사진이 없습니다. 사진을 추가해 주세요.")
                    .font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.danger)
            } else if !session.items.isEmpty, session.readyItems.isEmpty {
                VStack(alignment: .leading, spacing: ui(6)) {
                    Text("분석에 성공한 사진이 없어 추천과 결과를 만들 수 없습니다.")
                        .font(.ui(.subheadline).weight(.semibold)).foregroundStyle(PorcelainMetrics.danger)
                    Text("아래 사진의 오류를 확인하고 다시 시도하거나, 다른 사진을 추가해 주세요.")
                        .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                }
            }
        }
    }

    private var isOutcomeValid: Bool {
        if case .success? = session.outcome { return true }
        return false
    }

    private func countEditor(_ recommendation: PhotoSelectionRecommendation) -> some View {
        HStack(spacing: ui(10)) {
            Text("선별 개수").font(.ui(.subheadline))
            TextField("\(recommendation.recommendedCount)", text: $countText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: ui(90))
                .multilineTextAlignment(.trailing)
                .onSubmit(commitCountText)
                .onChange(of: countText) { _, _ in commitCountText() }
                .accessibilityLabel("선별 개수")
            Text("장").font(.ui(.subheadline))
            Spacer()
            Button("추천값 사용") {
                session.setExplicitCount(nil)
                countText = ""
            }
            .font(.ui(.footnote))
            .disabled(session.explicitCount == nil)
        }
    }

    /// 숫자가 아니거나 비어 있으면 N을 정하지 않은 것으로 본다. 추천값으로 사용자의 입력을 덮어쓰지 않는다.
    private func commitCountText() {
        let digits = countText.filter(\.isNumber)
        if digits != countText { countText = digits }
        if let value = Int(digits), value >= 1 { session.setExplicitCount(value) }
        else if digits.isEmpty { session.setExplicitCount(nil) }
        else { session.setExplicitCount(0) }
    }

    private func syncCountText() {
        if let explicit = session.explicitCount, explicit >= 1, countText != String(explicit) { countText = String(explicit) }
    }

    // MARK: 항목

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: ui(8)) {
            Text("입력 사진").font(.ui(.headline)).foregroundStyle(PorcelainMetrics.graphite)
            LazyVGrid(columns: columns, spacing: ui(8)) {
                ForEach(session.items) { item in itemCell(item) }
            }
        }
    }

    private func itemCell(_ item: PhotoSelectionItem) -> some View {
        let selectedRole = session.role(of: item)
        return VStack(spacing: ui(4)) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: ui(10), style: .continuous).fill(.quaternary)
                    if let thumbnail = item.thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else if item.state == .analyzing || item.state == .queued {
                        ProgressView()
                    } else {
                        Image(interfaceSystemName: "exclamationmark.triangle").foregroundStyle(PorcelainMetrics.danger)
                    }
                }
                .frame(height: ui(96)).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ui(10), style: .continuous))
                .overlay {
                    if selectedRole != nil {
                        RoundedRectangle(cornerRadius: ui(10), style: .continuous).stroke(PorcelainMetrics.accent, lineWidth: 3)
                    }
                }
                Button { session.remove(id: item.id) } label: {
                    Image(interfaceSystemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65)).font(.ui(.title3))
                }
                .buttonStyle(.plain).padding(ui(4))
                .accessibilityLabel("\(item.name) 제거")
            }
            Text(item.name).font(.ui(.caption2)).lineLimit(1).foregroundStyle(PorcelainMetrics.secondary)
            switch item.state {
            case let .failed(message):
                Text(message).font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.danger).lineLimit(3)
                Button("다시 시도") { session.retry(id: item.id) }.font(.ui(.caption2))
            case .queued: Text("분석 대기").font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.secondary)
            case .analyzing: Text("분석 중").font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.secondary)
            case .ready:
                if let reason = session.reason(for: item) {
                    Text(reason).font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.graphite).lineLimit(3)
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            let cocoa = error as NSError
            guard !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.Code.userCancelled.rawValue) else { return }
            session.notice = "파일을 가져오지 못했습니다: \(error.localizedDescription)"
        case let .success(urls):
            guard !urls.isEmpty else { return }
            Task { await session.addFiles(urls) }
        }
    }
}

/// 결과 확인 시트: 고른 사진과 이유를 보고, 확인한 뒤에만 저장·공유·작업대 담기를 한다.
private struct PhotoSelectionPreviewSheet: View {
    @ObservedObject var session: PhotoSelectionSession
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: Action?
    @State private var isWorking = false
    @State private var message: String?
    @State private var shareFiles: PhotoSelectionActions.ShareFiles?
    @State private var workbenchRequest: WorkbenchAddRequest?

    private enum Action: Identifiable {
        case saveAlbum
        var id: Int { hashValue }
    }

    private let columns = [GridItem(.adaptive(minimum: ui(96), maximum: ui(130)), spacing: ui(8))]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ui(12)) {
                    let selected = session.selectedItems
                    Text("선별 결과 \(selected.count)장").font(.ui(.headline))
                    if case let .success(result)? = session.outcome {
                        ForEach(result.warnings, id: \.self) { Text($0).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary) }
                    }
                    LazyVGrid(columns: columns, spacing: ui(8)) {
                        ForEach(selected) { item in
                            VStack(spacing: ui(4)) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: ui(10), style: .continuous).fill(.quaternary)
                                    if let thumbnail = item.thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                                }
                                .frame(height: ui(96)).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: ui(10), style: .continuous))
                                Text(session.reason(for: item) ?? "").font(.ui(.caption2)).lineLimit(3)
                                    .foregroundStyle(PorcelainMetrics.secondary)
                            }
                        }
                    }
                    if let message { Text(message).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.graphite) }
                    actionButtons(count: selected.count)
                }
                .padding(ui(16))
            }
            .navigationTitle("결과 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .confirmationDialog(confirmationTitle, isPresented: Binding(get: { pendingAction != nil },
                                                                         set: { if !$0 { pendingAction = nil } }),
                                titleVisibility: .visible) {
                Button("확인") { if let action = pendingAction { run(action) } }
                Button("취소", role: .cancel) { pendingAction = nil }
            } message: { Text(confirmationMessage) }
            .workbenchAddSheet($workbenchRequest)
            .sheet(item: Binding(get: { shareFiles.map(ShareFilesToken.init) }, set: { if $0 == nil { finishSharing() } })) { token in
                PhotoSelectionShareSheet(urls: token.files.urls, onFinish: finishSharing)
            }
        }
    }

    private struct ShareFilesToken: Identifiable, Equatable {
        let files: PhotoSelectionActions.ShareFiles
        var id: String { files.directory.path }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    private func actionButtons(count: Int) -> some View {
        VStack(spacing: ui(8)) {
            Button { presentWorkbench() } label: { actionLabel("작업대에 담기", "tray.2") }
            Button { prepareShare() } label: { actionLabel("공유", "square.and.arrow.up") }
            Button { pendingAction = .saveAlbum } label: { actionLabel("Photos 앨범에 저장", "photo.badge.plus") }
        }
        .buttonStyle(PorcelainProminentButtonStyle())
        .disabled(isWorking || count == 0)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, interfaceSystemImage: symbol).frame(maxWidth: .infinity, minHeight: ui(30))
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .saveAlbum: "Photos 앨범에 저장할까요?"
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        let count = session.selectedItems.count
        return switch pendingAction {
        case .saveAlbum: "새 앨범을 만들어 \(count)장을 담습니다. 원본은 옮기거나 지우지 않습니다."
        case nil: ""
        }
    }

    private func run(_ action: Action) {
        pendingAction = nil
        let items = session.selectedItems
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            switch action {
            case .saveAlbum:
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm"
                let title = "사진 선별 " + formatter.string(from: Date())
                do { message = try await PhotoSelectionActions.saveToPhotos(items, albumTitle: title) }
                catch { message = "저장하지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }

    /// 선별 결과의 원본 위치만 사용자가 고른 포켓에 순서대로 참조로 담는다. 복사·편집본 생성 없음.
    private func presentWorkbench() {
        let result = PhotoSelectionActions.workbenchReferences(session.selectedItems)
        guard !result.entries.isEmpty else {
            message = result.notices.first ?? "담을 사진이 없습니다."
            return
        }
        workbenchRequest = WorkbenchAddRequest(title: "선별한 사진 \(result.entries.count)장", entries: result.entries, notices: result.notices)
    }

    private func prepareShare() {
        let items = session.selectedItems
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do { shareFiles = try await PhotoSelectionActions.prepareShareFiles(items) }
            catch { message = "공유할 파일을 준비하지 못했습니다: \(error.localizedDescription)" }
        }
    }

    private func finishSharing() {
        if let directory = shareFiles?.directory { try? FileManager.default.removeItem(at: directory) }
        shareFiles = nil
    }
}
