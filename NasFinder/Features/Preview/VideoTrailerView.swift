import AVFoundation
import HanAIApple
import ImageIO
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

// Adapter for the two analysis sources shared directly with HanClip.
enum MediaError: LocalizedError {
    case videoTrackUnavailable
    var errorDescription: String? { "분석할 수 있는 영상 트랙이 없습니다." }
}

private enum TrailerError: LocalizedError {
    case exportUnavailable, exportFailed, noUsableSources, outputMissing, intermediateInvalid
    var errorDescription: String? {
        switch self {
        case .intermediateInvalid: "만든 중간 영상을 읽지 못했습니다. 다시 시도해 주세요."
        case .exportUnavailable: "이 영상 형식으로 예고편을 만들 수 없습니다."
        case .exportFailed: "예고편을 만들지 못했습니다. 다시 시도해 주세요."
        case .noUsableSources: "예고편으로 만들 수 있는 사진이나 영상이 없습니다."
        case .outputMissing: "완성한 예고편 파일이 작업 폴더에서 사라졌습니다. 다시 시도해 주세요."
        }
    }
}

/// One finished intermediate clip and the scenes it really contains. `hasOriginalSound`
/// is false for a clip rebuilt from a still frame, which carries no original sound.
private struct TrailerRenderedClip {
    let url: URL
    let scenes: [VideoTrailerScene]
    let hasOriginalSound: Bool
}

/// Domain/code chain of an error for logs and the failure message. Never includes
/// file names or paths, only the NSError identifiers needed to diagnose a failure.
private func trailerErrorChain(_ error: Error) -> String {
    var parts: [String] = []
    var current: NSError? = error as NSError
    while let value = current, parts.count < 4 {
        parts.append("\(value.domain) \(value.code)")
        current = value.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return parts.joined(separator: " ← ")
}

/// Four printable characters of a media format code ("mp3 ", "aac "), otherwise its number.
private func trailerFourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? String(decoding: bytes, as: UTF8.self) : String(code)
}

/// The last failed attempt, kept as one small file in the app's own cache folder so the
/// stage can be read from the device when its unified log cannot be collected. Counts,
/// error codes and media format identifiers only: never a file name, path, URL or any
/// content. Each failure replaces the previous file.
private struct TrailerFailureDiagnostic: Encodable {
    struct Music: Encodable {
        var fileExtension = ""
        var formatID = ""
        var naturalTimeScale: Int32 = 0
        var rangeStartValue: Int64 = 0
        var rangeStartTimescale: Int32 = 0
        var rangeDurationValue: Int64 = 0
        var rangeDurationTimescale: Int32 = 0
        var policy = ""
        /// Pieces of the music actually inserted before the run stopped.
        var pieces = 0
        var ducked = 0
    }

    var date = Date()
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    var appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    var system = ProcessInfo.processInfo.operatingSystemVersionString
    var mode = ""
    var stage = ""
    var errorChain = ""
    /// The system error behind one of this app's own messages, when there was one.
    var wrappedErrorChain: String?
    var sources = 0
    var skipped = 0
    var recovered = 0
    var segments = 0
    var tracks = 0
    var renderWidth = 0
    var renderHeight = 0
    var outputSeconds = 0.0
    var music: Music?

    func persist() throws {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NasFinderTrailerDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent("lastFailure.json"), options: .atomic)
    }
}

/// What the editor currently shows. Owned by `VideoTrailerView`, not the sheet, so it is
/// still exactly as the user left it after a failed attempt, after the music browser and
/// when the editor is opened again.
/// The prepared plan the settings panel shows, computed once for both the panel and the
/// suspended-draft length so the two can never drift apart.
/// 저장본에서 작업 폴더로 복사한 결과. 상대 경로를 복사된 파일 주소로 이어 준다.
struct TrailerRestoredFiles: Sendable {
    let folder: URL
    let copies: [String: URL]
    let failed: [String]
}

enum TrailerPreparedPlan {
    /// 직접 편집한 장면 목록을 그대로 계획으로 바꾼다. 제외한 장면과 사라진 소스의 장면은 빠지고,
    /// 시간 값은 실제 소스 길이 안으로 맞춘다. 자동 추천 규칙은 쓰지 않는다.
    static func manual(_ edits: [TrailerEditScene], sources: [VideoTrailerSource]) -> [VideoTrailerScene] {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [VideoTrailerScene] = []
        for edit in edits where !edit.excluded {
            guard let source = byID[edit.sourceID] else { continue }
            var scene: VideoTrailerScene
            if source.isImage {
                let bounds = TrailerSceneEditor.sceneDurationBounds(scene: edit, source: source)
                scene = VideoTrailerScene(id: result.count, start: 0, length: min(bounds.maximum, max(bounds.minimum, edit.length)))
            } else {
                guard source.duration > 0 else { continue }
                let bounds = TrailerSceneEditor.sceneDurationBounds(scene: edit, source: source)
                let start = min(max(0, edit.start), max(0, source.duration - bounds.minimum))
                let length = min(bounds.maximum, max(bounds.minimum, edit.length))
                scene = VideoTrailerScene(id: result.count, start: start, length: length)
            }
            scene.sourceID = source.id
            scene.muted = edit.muted && !source.isImage
            scene.fitsFrame = edit.fitsFrame
            scene.volume = source.isImage ? 1 : min(1, max(0, edit.volume))
            scene.offsetX = min(1, max(-1, edit.offsetX))
            scene.offsetY = min(1, max(-1, edit.offsetY))
            result.append(scene)
        }
        return result
    }

    static func base(mode: VideoTrailerMode, sources: [VideoTrailerSource], total: Double?,
                     clipLength: Double, manual: [TrailerEditScene]? = nil) -> [VideoTrailerScene] {
        if let manual { return Self.manual(manual, sources: sources) }
        return mode == .mediaMusic ? VideoTrailerBatchPlan.wholeMedia(sources: sources)
            : VideoTrailerBatchPlan.selection(sources: sources, total: total, clipLength: clipLength)
    }

    /// Empty when the chosen music cannot be matched within the repeat limit.
    static func scenes(mode: VideoTrailerMode, sources: [VideoTrailerSource], total: Double,
                       clipLength: Double, music: TrailerMusicSelection?,
                       manual: [TrailerEditScene]? = nil) -> [VideoTrailerScene] {
        let base = base(mode: mode, sources: sources, total: total, clipLength: clipLength, manual: manual)
        guard let music else { return base }
        switch music.policy {
        case .fitMusic:
            return VideoTrailerBatchPlan.fitted(base, to: music.fittedDuration) ?? []
        case .loopMusic:
            guard music.duration > 0 else { return 0 <= TrailerMusic.maximumRepeats ? base : [] }
            let baseTotal = base.reduce(0) { $0 + $1.length }
            let repeats = max(1, Int((baseTotal / music.duration - 0.000001).rounded(.up)))
            return repeats <= TrailerMusic.maximumRepeats ? base : []
        case .single:
            return base
        }
    }

    /// 지금 자동 계획을 직접 편집용 장면 목록으로 옮긴다. 계획에 들지 못한 소스도 목록에 남긴다:
    /// 사진은 포함으로, 영상은 제외로 표시해 어느 것도 조용히 사라지지 않는다.
    static func seedEdits(mode: VideoTrailerMode, sources: [VideoTrailerSource], total: Double,
                          clipLength: Double) -> [TrailerEditScene] {
        let planned = base(mode: mode, sources: sources, total: total, clipLength: clipLength)
        var result: [TrailerEditScene] = []
        var next = 1
        func append(_ scene: VideoTrailerScene, excluded: Bool = false) {
            result.append(TrailerEditScene(id: next, sourceID: scene.sourceID, start: scene.start,
                                           length: scene.length, excluded: excluded))
            next += 1
        }
        for scene in planned { append(scene) }
        let covered = Set(planned.map(\.sourceID))
        for source in sources where !covered.contains(source.id) {
            if source.isImage {
                let ratio = source.imageDurationRatio.isFinite && source.imageDurationRatio > 0 ? source.imageDurationRatio : 0.55
                var scene = VideoTrailerScene(id: 0, start: 0, length: min(30.0, max(1.0 / 30.0, clipLength * ratio)))
                scene.sourceID = source.id
                append(scene)
            } else if source.duration > 0 {
                let length = VideoTrailerBatchPlan.sceneLength(source, clipLength: clipLength)
                var scene = source.plan.proposal(total: length, clipLength: length).first
                    ?? VideoTrailerScene(id: 0, start: 0, length: length)
                scene.sourceID = source.id
                append(scene, excluded: true)
            }
        }
        return result
    }
}

struct TrailerSettingsDraft {
    var sources: [VideoTrailerSource]
    var total: Double
    var clipLength: Double
    var aspectRatio: OutputAspectRatio?
    var music: TrailerMusicSelection?
    /// 장면 직접 편집 목록. nil이면 자동 추천 계획을 쓴다.
    var scenes: [TrailerEditScene]?
    var nextSceneID = 1
    /// 이 초안이 이미 알고 있는 소스. 여기 없는 새 소스만 목록 끝에 붙이므로 사용자가 뺀 것은 되살아나지 않는다.
    var knownIDs: Set<Int> = []
    /// Whether each "다른 길이" slider is open.
    var showingDuration = false
    var showingClipLength = false
}

/// What a suspended editor leaves in `TrailerDraftStore` and takes back when it is
/// reopened: the session itself, so nothing is fetched, analysed or shuffled again.
private final class TrailerSuspendedSession {
    let model: VideoTrailerModel
    let draft: TrailerSettingsDraft?
    let showedSettings: Bool

    init(model: VideoTrailerModel, draft: TrailerSettingsDraft?, showedSettings: Bool) {
        self.model = model
        self.draft = draft
        self.showedSettings = showedSettings
    }
}

/// One showing of the editor together with the draft it opens on, so the editor is never
/// on screen without the data it edits.
private struct TrailerSettingsPresentation: Identifiable {
    let id = UUID()
    let draft: TrailerSettingsDraft
}

/// A bounded-memory thumbnail decode off the main actor: never the full-resolution
/// original, which a plain `UIImage(contentsOfFile:)` on a large photo would block the
/// main actor decoding.
func trailerThumbnailImage(at url: URL, maxPixelSize: CGFloat) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }.value
}

/// Nominal duration assigned to still images so the batch planner's duration-weighted
/// math has a sensible value; a photo scene itself always lasts its own randomized
/// fraction (35%-75%) of the video clip length, and this value never limits which
/// clip lengths can be chosen.
private let trailerImageNominalDuration = 4.0

/// 디스크에 저장된 프로젝트를 편집기가 이어받을 때 `TrailerDraftEntry.session`에 들어가는 값.
final class TrailerPersistedSession {
    let record: TrailerProjectRecord
    init(record: TrailerProjectRecord) { self.record = record }
}

/// 저장 변경 감지용 서명. 이 값이 바뀌면 잠시 뒤 프로젝트를 자동 저장한다.
private struct TrailerProjectChangeKey: Equatable {
    var draft: TrailerDraftSignature?
    var mode: VideoTrailerMode
    var output: String?
    var sourceCount: Int
    var itemCount: Int
    var staged: Bool
    var selectedScene: Int?
}

struct VideoTrailerView: View {
    /// Grows when the user adds material from the Finder panel; a source's id is its index here.
    @State private var items: [RemoteFileItem]
    /// Routes each item to the service it came from (NAS, PhoneHard, Photos, system files).
    @State private var routed: TrailerRoutedService
    /// The mode this editor is in right now: it starts as the caller's (or the saved draft's)
    /// and the top selector of the editor changes it without leaving the editor.
    @State private var mode: VideoTrailerMode
    /// The mode the video currently shown was made in, for the name it is saved under.
    @State private var outputMode: VideoTrailerMode?
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.trailerEditorClose) private var hostedClose
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @StateObject private var model: VideoTrailerModel
    @StateObject private var history = TrailerEditHistory()
    @ObservedObject private var projects = TrailerProjectStore.shared
    @State private var presentedSettings: TrailerSettingsPresentation?
    @State private var draft: TrailerSettingsDraft?
    /// This editing session in `TrailerDraftStore`, the same before and after a suspension.
    /// It is also the id of the project saved on disk.
    @State private var sessionID: UUID
    @State private var didBegin = false
    /// The user already chose how this showing ends, so `onDisappear` leaves it alone.
    @State private var exitHandled = false
    @State private var showingStalePrompt = false
    @State private var resumeNotice: String?
    @State private var selectedSceneID: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var finderRequest = 0
    @State private var finderCloseRequest = 0
    @State private var showingAppSettings = false
    @State private var pendingStage = false
    @State private var addNotice: String?
    @State private var persistedRecord: TrailerProjectRecord?
    /// 이 편집의 비공개 오염 플래그. 프라이버시 모드에서 시작했거나 입력 중 하나라도 비공개 출처이면 켜지고,
    /// 편집본·출력(폰하드 파일)·컬렉션 영상으로 이어진다. 한 번 켜지면 자동으로 풀리지 않는다.
    @State private var originTaint: Bool
    private let keepsSelectionOrder: Bool
    private let isResumed: Bool
    private let reopensSettings: Bool
    private var showingSettings: Bool { presentedSettings != nil }
    private var service: any RemoteFileService { routed }

    /// With `resuming` the editor continues that suspended session instead of starting one.
    init(items: [RemoteFileItem], service: any RemoteFileService, mode: VideoTrailerMode = .trailer,
         keepsSelectionOrder: Bool = false, resuming entry: TrailerDraftEntry? = nil, originPrivate: Bool = false) {
        self.keepsSelectionOrder = keepsSelectionOrder
        _originTaint = State(initialValue: PrivacyMode.capturedOrigin(inputPrivate: originPrivate
            || entry?.isPrivate == true
            || items.contains { PrivacyMode.isPrivateOrigin(connectionID: $0.connectionID, path: $0.path) }))
        let suspended = entry?.session as? TrailerSuspendedSession
        let persisted = entry?.session as? TrailerPersistedSession
        isResumed = suspended != nil || persisted != nil
        reopensSettings = suspended?.showedSettings ?? persisted?.record.showedSettings ?? false
        _items = State(initialValue: items)
        _routed = State(initialValue: (service as? TrailerRoutedService) ?? TrailerRoutedService(fallback: service))
        _mode = State(initialValue: persisted.map { $0.record.mode == "mediaMusic" ? .mediaMusic : .trailer } ?? mode)
        _model = StateObject(wrappedValue: suspended?.model ?? VideoTrailerModel())
        _draft = State(initialValue: suspended?.draft)
        _sessionID = State(initialValue: entry?.id ?? UUID())
        _persistedRecord = State(initialValue: persisted?.record)
    }

    @AppStorage(AppThemePreference.storageKey) private var themeRawValue = AppThemePreference.light.rawValue

    var body: some View {
        let _ = themeRawValue
        workspace
            .modifier(PreserveMediaNavigation())
            .task { await begin() }
            // Autosave: a short pause after the last real change, with the result shown in the header.
            .onChange(of: changeKey) { _, _ in scheduleSave() }
            .onChange(of: draft?.signature) { _, _ in if let draft { history.observe(draft) } }
            .onChange(of: model.sources.map(\.id)) { _, _ in absorbStagedSources() }
            .onChange(of: model.isBusy) { _, busy in if !busy, pendingStage { stageAdded() } }
            .alert("영상 편집 알림", isPresented: Binding(get: { addNotice != nil }, set: { if !$0 { addNotice = nil } })) {
                Button("확인", role: .cancel) { addNotice = nil }
            } message: { Text(addNotice ?? "") }
            .sheet(isPresented: $showingAppSettings) {
                NavigationStack {
                    AppSettingsView(connectionCount: connectionStore.connections.count)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { showingAppSettings = false } } }
                }
            }
    }

    private var projectTitle: String {
        projects.records[sessionID]?.customTitle ?? persistedRecord?.customTitle
            ?? (items.first.map { items.count == 1 ? $0.name : "\($0.name) 외 \(items.count - 1)개" } ?? "새 편집")
    }

    private var changeKey: TrailerProjectChangeKey {
        TrailerProjectChangeKey(draft: draft?.signature, mode: mode, output: model.outputURL?.lastPathComponent,
                                sourceCount: model.sources.count, itemCount: items.count, staged: model.isStaged,
                                selectedScene: selectedSceneID)
    }

    private var sink: TrailerProjectSink {
        TrailerProjectSink(add: { added, origin in addItems(added, origin) })
    }

    private var draftBinding: Binding<TrailerSettingsDraft> {
        Binding(get: { draft ?? currentDraft() }, set: { draft = $0 })
    }

    private func chrome(for tier: TrailerWorkspaceTier) -> TrailerEditorChrome {
        let state = projects.state(sessionID)
        var chrome = TrailerEditorChrome()
        chrome.title = projectTitle
        chrome.showsAdd = !tier.dockedFinder
        chrome.onAdd = { finderRequest += 1 }
        chrome.canUndo = history.canUndo
        chrome.canRedo = history.canRedo
        chrome.onUndo = undo
        chrome.onRedo = redo
        chrome.saveLabel = state == .idle ? "" : state.label
        if case .failed = state { chrome.saveFailed = true }
        chrome.onRetrySave = { scheduleSave(immediately: true) }
        chrome.onCancelWork = { model.cancelCurrentWork() }
        chrome.onRetryRender = retry
        chrome.projectID = sessionID
        return chrome
    }

    private func undo() {
        let current = draft ?? currentDraft()
        guard let previous = history.undo(current: current) else { return }
        draft = previous
    }

    private func redo() {
        let current = draft ?? currentDraft()
        guard let next = history.redo(current: current) else { return }
        draft = next
    }

    /// 전체 화면 커버면 시스템 dismiss, Mac 셸 내용 영역에 올린 편집기면 그 편집기를 내리는 동작.
    private func dismiss() {
        if let hostedClose { hostedClose.run() } else { systemDismiss() }
    }

    private func leave(to tab: AppTab?) {
        requestExit()
        if let tab { AppShellRouter.shared.request = tab }
    }

    private var workspace: some View {
        TrailerWorkspace(
            finderOpenRequest: finderRequest,
            finderCloseRequest: finderCloseRequest,
            editor: { tier in mediaContent(tier: tier) },
            finder: { isOverlay, close in
                TrailerFinderPanel(sink: sink, projectName: projectTitle, isOverlay: isOverlay, close: close)
            },
            detail: { tier in inspector(tier: tier) },
            openSettings: { showingAppSettings = true },
            leave: leave(to:))
    }

    private func inspector(tier: TrailerWorkspaceTier) -> some View {
        let current = draftBinding
        return TrailerSceneInspector(
            mode: mode, sources: current.wrappedValue.sources, scenes: current.scenes,
            nextSceneID: current.nextSceneID, selectedID: $selectedSceneID,
            clipLength: current.wrappedValue.clipLength,
            beginEditing: { var next = current.wrappedValue; next.beginSceneEditing(mode: mode); draft = next
                selectedSceneID = next.scenes?.first?.id },
            chrome: chrome(for: tier), aspectRatio: current.wrappedValue.aspectRatio)
    }

    private func mediaContent(tier: TrailerWorkspaceTier) -> some View {
        NavigationStack {
            TrailerSettingsHost(
                mode: mode,
                draft: $draft,
                opening: currentDraft(),
                skippedCount: model.skippedCount,
                recoveredCount: model.recoveredCount,
                isBusy: model.isBusy,
                status: model.status,
                exportProgress: model.exportProgress,
                joinProgress: model.joinProgress,
                outputURL: model.outputURL,
                error: model.error,
                onModeChange: changeMode,
                onClose: requestExit,
                onDiscard: discardAndDismiss,
                onSave: {
                    model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상",
                               suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편", isPrivate: originTaint)
                },
                isSaved: model.isSaved,
                apply: apply,
                selectedSceneID: $selectedSceneID,
                inspectorInline: tier == .phone,
                chrome: chrome(for: tier)
            )
            .background(PorcelainMetrics.paper)
            .statusBarHidden(true)
            // Both modes go straight to the editor once the sources are in, before any
            // clip is joined, any photo scene is encoded or anything is exported.
            .onChange(of: model.isAwaitingSettings) { _, awaiting in
                if awaiting { openSettings() }
            }
            // SwiftUI reports this both when the app's return to the dashboard takes the
            // editor down without either close button and while a full-screen presentation
            // (the music browser) merely covers it. Either way the session is only kept:
            // nothing is cancelled or removed, and `begin` takes it back on reappearing.
            .onDisappear {
                guard !exitHandled, model.hasResumableWork else { return }
                suspendSession()
            }
            .alert("편집본 파일이 사라졌습니다", isPresented: $showingStalePrompt) {
                Button("다시 가져오기") {
                    resumeNotice = nil
                    model.restage(items: items, service: service, mode: mode)
                }
                Button("이 편집 버리기", role: .destructive) { discardAndDismiss() }
                Button("닫기", role: .cancel) { suspendAndDismiss() }
            } message: {
                Text(["이 편집을 위해 받아 둔 사진·영상이 기기에서 지워졌습니다. 순서와 설정은 그대로 두고 원본에서 다시 가져올 수 있습니다.",
                      resumeNotice].compactMap { $0 }.joined(separator: " "))
            }
            .alert("편집본을 다시 열었습니다", isPresented: Binding(
                get: { resumeNotice != nil && !showingStalePrompt },
                set: { if !$0 { resumeNotice = nil } })) {
                Button("확인", role: .cancel) { continueResume() }
            } message: {
                Text(resumeNotice ?? "")
            }
        }
    }

    // MARK: 소스 추가

    /// Material chosen in the Finder panel joins this project. Items already in it are skipped;
    /// nothing already staged is touched, and a render that is running finishes first.
    private func addItems(_ added: [RemoteFileItem], _ origin: any RemoteFileService) {
        let known = Set(items.map(\.id))
        let fresh = added.filter { $0.isTrailerEligible && !known.contains($0.id) }
        guard !fresh.isEmpty else {
            addNotice = "이미 이 프로젝트에 있거나 영상·사진이 아닌 항목이라 추가하지 않았습니다."
            return
        }
        routed.register(fresh, service: origin)
        if fresh.contains(where: { PrivacyMode.isPrivateOrigin(connectionID: $0.connectionID, path: $0.path) }) {
            originTaint = true
        }
        items.append(contentsOf: fresh)
        finderCloseRequest += 1
        addNotice = "\(fresh.count)개를 현재 프로젝트에 추가합니다." + (fresh.count < added.count ? " 중복·미지원 \(added.count - fresh.count)개는 건너뛰었습니다." : "")
        stageAdded()
    }

    private func stageAdded() {
        guard !model.isBusy else { pendingStage = true; return }
        pendingStage = false
        model.start(items: items, service: routed, mode: mode, keepsInputOrder: true)
    }

    /// Newly staged sources are appended to the end of the user's order; ones the user took out stay out.
    private func absorbStagedSources() {
        guard var current = draft, didBegin else { return }
        if current.absorbNewSources(model.sources) { draft = current }
    }

    /// A new editor stages its sources; a reopened one checks what is really still there
    /// and continues from it, saying so plainly when something is gone.
    private func begin() async {
        TrailerDraftStore.shared.reopen(sessionID)
        // A render cancelled on the way out may still be unwinding.
        while model.isSuspending, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard !Task.isCancelled, !didBegin else { return }
        didBegin = true
        // A project saved on disk is brought into this model's own working folder first; the
        // saved copies are only read, so nothing the editor does later can remove them.
        if let record = persistedRecord, model.sources.isEmpty {
            guard let files = await model.copyStoredFiles(record: record, store: projects) else {
                // 복사 중 닫혔다. 저장된 프로젝트는 건드리지 않았고 다음에 열 때 처음부터 다시 불러온다.
                didBegin = false
                return
            }
            let restored = model.adopt(record: record, restored: files)
            draft = restored
            selectedSceneID = record.selectedSceneID
            history.reset(to: restored)
            let unreadable = projects.missing(record)
            if !unreadable.isEmpty {
                resumeNotice = "저장된 파일 \(unreadable.count)개를 찾을 수 없습니다. 있는 것은 그대로 불러왔습니다."
            }
            if !files.failed.isEmpty {
                resumeNotice = (resumeNotice.map { $0 + " " } ?? "")
                    + "복사하지 못한 파일 \(files.failed.count)개: " + files.failed.joined(separator: ", ")
            }
        } else if draft != nil {
            history.reset(to: draft)
        }
        guard isResumed else {
            if model.sources.isEmpty { model.start(items: items, service: service, mode: mode, keepsInputOrder: keepsSelectionOrder) }
            return
        }
        // Work that was never cancelled is still running and shows its own progress.
        guard !model.isBusy else { return }
        let lost = model.reconcile()
        var notes: [String] = []
        if lost.output { notes.append("완성했던 영상 파일이 사라져 다시 만들어야 합니다.") }
        if let music = draft?.music, !model.holdsMusic(music) {
            draft?.music = nil
            notes.append("골라 둔 음악 파일을 찾을 수 없어 음악 선택을 비웠습니다.")
        }
        resumeNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
        if lost.sources {
            showingStalePrompt = true
        } else if notes.isEmpty {
            continueResume()
        }
    }

    private func continueResume() {
        if !model.isStaged {
            // Left while the sources were still coming in: only the missing ones are fetched.
            model.start(items: items, service: service, mode: mode, keepsInputOrder: keepsSelectionOrder)
        } else if reopensSettings || model.outputURL == nil {
            openSettings()
        }
    }

    /// Closing or cancelling suspends the editor; it never resets it. Only a showing with
    /// nothing staged yet ends the old way, and an earlier suspended editor of the same
    /// kind is never replaced without the user saying so.
    private func requestExit() {
        guard model.hasResumableWork else {
            exitHandled = true
            model.stop()
            dismiss()
            return
        }
        // Projects are independent and uncapped, so leaving never replaces another one.
        suspendAndDismiss()
    }

    private func suspendSession() {
        let session = model
        session.pinMusic(draft?.music)
        var entry = TrailerDraftEntry(id: sessionID, mode: mode, items: items, service: service,
            session: TrailerSuspendedSession(model: session, draft: draft, showedSettings: showingSettings),
            discard: { session.stop() })
        // This run's own staged copy only, so the management screen's thumbnail never
        // reaches the original remote file; a finished video's own first frame stands
        // in for it once no staged source is left to draw from.
        entry.thumbnailURL = model.sources.first?.url ?? model.outputURL
        entry.thumbnailIsImage = model.sources.first?.isImage ?? false
        // The length the settings panel itself shows for the current prepared settings
        // (same plan computation, music fit/repeat policy included), with or without an
        // output file; a computed zero is shown as zero. Only with no prepared sources
        // does the nominal source sum stand in as an estimate.
        let prepared = currentDraft()
        if prepared.sources.isEmpty {
            entry.totalDuration = model.sources.reduce(0) { $0 + $1.duration }
        } else {
            entry.totalDuration = TrailerPreparedPlan.scenes(
                mode: mode, sources: prepared.sources, total: prepared.total,
                clipLength: prepared.clipLength, music: prepared.music, manual: prepared.scenes).reduce(0) { $0 + $1.length }
        }
        entry.suspendedAt = Date()
        entry.customTitle = projects.records[sessionID]?.customTitle
        entry.isPrivate = originTaint ? true : nil
        TrailerDraftStore.shared.suspend(entry)
        // Leaving always saves what is on screen, without waiting for the autosave pause.
        scheduleSave(immediately: true)
    }

    // MARK: 자동 저장

    /// Saves the project a short moment after the last change. The staged copies are copied into
    /// the project's own folder and the metadata is replaced atomically; a failure keeps the earlier
    /// saved project untouched and is shown with a retry.
    private func scheduleSave(immediately: Bool = false) {
        guard model.isStaged, !model.sources.isEmpty || draft != nil, didBegin else { return }
        saveTask?.cancel()
        let snapshot = makeSnapshot()
        saveTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(for: .seconds(1.2)) }
            guard !Task.isCancelled else { return }
            await projects.save(snapshot)
        }
    }

    private func makeSnapshot() -> TrailerProjectSnapshot {
        model.projectSnapshot(id: sessionID, existing: projects.records[sessionID] ?? persistedRecord, mode: mode,
                              outputMode: outputMode, draft: currentDraft(), itemCount: items.count,
                              selectedSceneID: selectedSceneID, showedSettings: showingSettings,
                              isPrivate: originTaint)
    }

    private func suspendAndDismiss() {
        exitHandled = true
        // A render still running is cancelled; the staged sources and settings stay.
        model.suspend()
        suspendSession()
        dismiss()
    }

    private func discardAndDismiss() {
        exitHandled = true
        presentedSettings = nil
        saveTask?.cancel()
        TrailerDraftStore.shared.reopen(sessionID)
        model.stop()
        // The user confirmed discarding this edit: only this project's own folder goes.
        // Material basket items, collection videos and the originals are other files.
        projects.delete(sessionID)
        dismiss()
    }

    /// The draft brought in line with what is actually staged: the user's order and the
    /// current staged copies, minus sources that were excluded since (a decode failure).
    /// A thumbnail the user removed stays removed: this never appends a staged source the
    /// draft does not already hold. With no draft yet it is the automatic recommendation
    /// over every staged source, with no music.
    private func currentDraft() -> TrailerSettingsDraft {
        let staged = model.sources
        guard var draft else {
            let clipLength = model.recommendedClipLength
            // The length the recommendation really comes to, as the editor's starting total.
            let total = mode == .mediaMusic ? 0 : VideoTrailerBatchPlan.recommendedTotal(sources: staged, clipLength: clipLength)
            var fresh = TrailerSettingsDraft(sources: staged, total: total, clipLength: clipLength,
                                             aspectRatio: model.aspectRatio, music: model.music)
            fresh.knownIDs = Set(staged.map(\.id))
            return fresh
        }
        draft.sources = TrailerSceneEditor.reconcileSources(draftSources: draft.sources, stagedSources: staged)
        return draft
    }

    private func openSettings() {
        guard !model.sources.isEmpty else { return }
        let opening = currentDraft()
        draft = opening
        if presentedSettings == nil { presentedSettings = TrailerSettingsPresentation(draft: opening) }
    }

    /// Makes the video from the draft exactly as it stands. The draft is kept whatever
    /// the outcome, so a failure never costs the user their order, lengths or music.
    private func apply(_ draft: TrailerSettingsDraft) {
        guard !draft.sources.isEmpty else { return }
        presentedSettings = nil
        outputMode = mode
        // Sources the user took out leave the session for good, so earlier undo steps that
        // still point at them are dropped.
        let dropsSources = model.sources.contains { staged in !draft.sources.contains { $0.id == staged.id } }
        let reconciled = TrailerSceneEditor.reconcileSources(draftSources: draft.sources, stagedSources: model.sources)
        // Value copies of everything the render reads: later edits never change a running render.
        model.start(items: items, service: service, mode: mode, generate: true, sourceOrder: reconciled.map(\.id),
                    total: draft.total, clipLength: draft.clipLength, aspectRatio: draft.aspectRatio, music: draft.music,
                    manualScenes: draft.scenes, draftSources: reconciled)
        if dropsSources { history.reset(to: draft) }
    }

    /// After a failed attempt with the sources still staged this repeats that attempt;
    /// otherwise it stages again and then shows the editor, never a video on its own.
    private func retry() {
        if draft != nil, !model.sources.isEmpty, mode == .trailer || draft?.music != nil {
            let requested = currentDraft()
            draft = requested
            apply(requested)
        } else {
            model.start(items: items, service: service, mode: mode, keepsInputOrder: keepsSelectionOrder)
        }
    }

    /// Switches the editor between 예고편 and 뮤직비디오 in place. The sources, their order,
    /// the music and its options stay in the draft; only the plan rules change. Going to
    /// 예고편 first runs the real highlight analysis for sources that were never analysed
    /// (a session opened as 뮤직비디오); nothing is exported until the user applies.
    private func changeMode(_ next: VideoTrailerMode) {
        guard next != mode, !model.isBusy else { return }
        guard next == .trailer else {
            mode = next
            model.useMode(next)
            return
        }
        let baseline = model.sources
        model.analyzeHighlights { analyzed in
            guard !exitHandled, mode != .trailer else { return }
            mode = .trailer
            guard var current = draft else { return }
            current.sources = TrailerSceneEditor.reconcileSources(
                draftSources: current.sources,
                stagedSources: model.sources,
                timingBaseline: baseline
            )
            if analyzed || current.total <= 0 {
                current.clipLength = model.recommendedClipLength
                current.total = VideoTrailerBatchPlan.recommendedTotal(sources: current.sources, clipLength: current.clipLength)
                if let music = current.music, music.policy == .fitMusic { current.total = music.fittedDuration }
            }
            draft = current
        }
    }

    private func settingsContent(_ presentation: TrailerSettingsPresentation) -> some View {
        TrailerSettingsHost(
            mode: mode, draft: $draft, opening: presentation.draft,
            skippedCount: model.skippedCount, recoveredCount: model.recoveredCount,
            isBusy: model.isBusy, status: model.status,
            exportProgress: model.exportProgress, joinProgress: model.joinProgress,
            outputURL: model.outputURL, error: model.error,
            onModeChange: changeMode, onClose: { presentedSettings = nil },
            onDiscard: discardAndDismiss,
            onSave: {
                model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상",
                           suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편", isPrivate: originTaint)
            },
            isSaved: model.isSaved, apply: apply
        )
        .id(presentation.id)
    }

    private var trailerControls: some View {
        HStack(spacing: ui(8)) {
            Button {
                model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상",
                           suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편", isPrivate: originTaint)
            } label: {
                SharedPlayerCircleLabel(systemImage: model.isSaved ? "checkmark.circle" : "square.and.arrow.down")
            }
            .accessibilityLabel(model.isSaved ? "폰하드에 저장됨" : "폰하드에 저장")
            .disabled(model.isBusy || model.isSaved)
            Button { openSettings() } label: {
                SharedPlayerCircleLabel(systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("영상 편집").disabled(model.isBusy)
        }
    }
}

private struct TrailerOutputFileService: RemoteFileService {
    let url: URL
    let connection = RemoteConnection(id: UUID(uuidString: "8409962E-C55D-4B8E-92C9-876708AD3945")!,
        name: "예고편", kind: .synology, host: "localhost", username: "")
    var item: RemoteFileItem {
        RemoteFileItem(connectionID: connection.id, path: url.path, name: "예고편.mp4", kind: .file,
            size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
            modifiedAt: nil, contentTypeIdentifier: "public.mpeg-4")
    }
    func list(directory path: String?) async throws -> [RemoteFileItem] { [item] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        guard item.path == url.path, FileManager.default.fileExists(atPath: url.path) else { throw TrailerError.exportFailed }
        return url
    }
    func testConnection() async throws { _ = try await download(item) }
}

/// A video's real displayed size (natural size with its preferred transform applied), nil
/// without a video track. Loads only the track metadata, never frames.
func trailerOrientedVideoSize(url: URL) async throws -> CGSize? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
    return CGSize(width: abs(oriented.width), height: abs(oriented.height))
}

/// 대형 프리뷰: 완성 영상이 있으면 RemotePreviewView로 재생하고, 준비 중일 때는 첫 선택 미디어의 실제 커버를 화면 비율에 맞춰 크게 보여준다.
private struct TrailerWorkspacePreview: View {
    let outputURL: URL?
    let firstSource: VideoTrailerSource?
    /// The first video in the current order: 원본 follows its orientation-correct ratio.
    let firstVideo: VideoTrailerSource?
    let aspectRatio: OutputAspectRatio?
    let isBusy: Bool
    let status: String
    let error: String?
    let exportProgress: Double?
    let joinProgress: (completed: Int, total: Int)?
    let accessoryControls: AnyView?
    let onClose: () -> Void
    var isFullscreen = false
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    @State private var previewImage: UIImage?
    @State private var firstVideoSize: (id: Int, size: CGSize)?

    /// Same sizing rule as the export: a chosen ratio's real size, otherwise 원본 = the first
    /// video's own ratio (photos only: the first photo's), 16:9 only until that is known.
    private var aspectSize: CGSize {
        if let aspectRatio { return aspectRatio.renderSize }
        if let firstVideo {
            if let loaded = firstVideoSize, loaded.id == firstVideo.id { return OutputAspectRatio.renderSize(for: loaded.size) }
        } else if let firstSource, firstSource.isImage, let previewImage {
            return OutputAspectRatio.renderSize(for: previewImage.size)
        }
        return CGSize(width: 16, height: 9)
    }

    var body: some View {
        ZStack {
            if let outputURL {
                let previewService = TrailerOutputFileService(url: outputURL)
                // RemotePreviewView is a greedy GeometryReader with no ideal height, so inside the
                // editor's ScrollView it collapsed to a thin strip. Size it here with the same
                // aspect rule as the pre-output placeholder; fullscreen (nil ratio) fills the frame.
                Color.clear
                    .aspectRatio(isFullscreen ? nil : aspectSize.width / aspectSize.height, contentMode: .fit)
                    .overlay {
                        RemotePreviewView(
                            item: previewService.item,
                            sequentialItems: [previewService.item],
                            service: previewService,
                            accessoryControls: accessoryControls,
                            onClose: onClose,
                            playbackSuspended: isBusy
                        )
                        .id(outputURL)
                    }
            } else if let firstSource {
                Color.black
                    .aspectRatio(aspectSize.width / aspectSize.height, contentMode: .fit)
                    .overlay {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(interfaceSystemName: firstSource.isImage ? "photo" : "film", pointSize: ui(36))
                                .font(.system(size: ui(36)))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(firstSource.name)
                            .font(.ui(.caption2).weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, ui(6))
                            .padding(.vertical, ui(3))
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: ui(4)))
                            .padding(ui(8))
                    }
                    .task(id: "\(firstVideo?.id ?? -1)-\(aspectRatio == nil)") {
                        // Reads only the track's size and transform, once per first video; the
                        // task is cancelled with the view or when the first video changes.
                        guard aspectRatio == nil, let firstVideo else { return }
                        if let size = try? await trailerOrientedVideoSize(url: firstVideo.url), !Task.isCancelled {
                            firstVideoSize = (firstVideo.id, size)
                        }
                    }
                    .task(id: firstSource.id) {
                        guard previewImage == nil else { return }
                        if firstSource.isImage {
                            if let loaded = await trailerThumbnailImage(at: firstSource.url, maxPixelSize: 1024), !Task.isCancelled {
                                previewImage = loaded
                            }
                        } else {
                            let asset = AVURLAsset(url: firstSource.url)
                            let generator = AVAssetImageGenerator(asset: asset)
                            generator.appliesPreferredTrackTransform = true
                            generator.maximumSize = CGSize(width: 1024, height: 1024)
                            let time = CMTime(seconds: firstSource.plan.analysis.peakTime, preferredTimescale: 600)
                            if let frame = try? await generator.image(at: time), !Task.isCancelled {
                                previewImage = UIImage(cgImage: frame.image)
                            }
                        }
                    }
            } else {
                Color(uiColor: .tertiarySystemFill)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        VStack(spacing: ui(8)) {
                            ProgressView()
                            Text(status.isEmpty ? "미디어를 불러오는 중…" : status)
                                .font(.ui(.footnote))
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            if isBusy || error != nil {
                Color.black.opacity(0.65)
                VStack(spacing: ui(8)) {
                    if isBusy {
                        if let progress = exportProgress {
                            TrailerExportProgress(progress: progress).tint(.white)
                        } else if let joinProgress = joinProgress {
                            TrailerJoinProgressBar(completed: joinProgress.completed, total: joinProgress.total).tint(.white)
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    Text(error ?? status)
                        .font(.ui(.footnote))
                        .foregroundStyle(error != nil ? .red : .white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, ui(16))
                    if isBusy {
                        Button("취소", action: onCancel).buttonStyle(.bordered).tint(.white)
                    } else if error != nil {
                        Button("다시 시도", action: onRetry).buttonStyle(.bordered).tint(.white)
                    }
                }
                .padding(ui(12))
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: ui(12)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : ui(12), style: .continuous))
    }
}

/// The editor bound to the caller's draft. It arrives with the draft it opened on, so its
/// first frame already has content even before the caller's own state reaches this view.
private struct TrailerSettingsHost: View {
    let mode: VideoTrailerMode
    @Binding var draft: TrailerSettingsDraft?
    let opening: TrailerSettingsDraft
    let skippedCount: Int
    var recoveredCount: Int = 0
    let isBusy: Bool
    let status: String
    let exportProgress: Double?
    let joinProgress: (completed: Int, total: Int)?
    let outputURL: URL?
    let error: String?
    let onModeChange: (VideoTrailerMode) -> Void
    let onClose: () -> Void
    let onDiscard: () -> Void
    let onSave: (() -> Void)?
    let isSaved: Bool
    let apply: (TrailerSettingsDraft) -> Void
    var selectedSceneID: Binding<Int?> = .constant(nil)
    var inspectorInline = false
    var chrome = TrailerEditorChrome()
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        let binding = Binding(get: { draft ?? opening }, set: { draft = $0 })
        VideoTrailerSettings(
            mode: mode, sources: binding.sources, total: binding.total,
            clipLength: binding.clipLength, skippedCount: skippedCount,
            recoveredCount: recoveredCount,
            aspectRatio: binding.aspectRatio, music: binding.music,
            showingDuration: binding.showingDuration, showingClipLength: binding.showingClipLength,
            isBusy: isBusy, status: status,
            exportProgress: exportProgress, joinProgress: joinProgress,
            outputURL: outputURL, error: error,
            onModeChange: onModeChange, onClose: onClose, onDiscard: onDiscard,
            onSave: onSave, isSaved: isSaved,
            regenerate: { apply(draft ?? opening) },
            scenes: binding.scenes, nextSceneID: binding.nextSceneID, selectedSceneID: selectedSceneID,
            inspectorInline: inspectorInline, chrome: chrome
        )
        .scrollContentBackground(isPorcelain ? .hidden : .automatic)
        .background(isPorcelain ? PorcelainMetrics.paper : Color.clear)
    }

    @AppStorage(AppThemePreference.storageKey) private var themeRawValue = AppThemePreference.light.rawValue
    /// 6개 테마 공통 바탕.
    private var isPorcelain: Bool { true }
}

private enum TrailerOrderChoice {
    case added, chronological, name, random
}

private struct VideoTrailerSettings: View {
    let mode: VideoTrailerMode
    // Every binding is the caller's draft: nothing here is lost when this view goes away.
    @Binding var sources: [VideoTrailerSource]
    @Binding var total: Double
    @Binding var clipLength: Double
    let skippedCount: Int
    var recoveredCount: Int = 0
    @Binding var aspectRatio: OutputAspectRatio?
    /// Draft only: the session's music changes after a new video is actually made.
    @Binding var music: TrailerMusicSelection?
    @Binding var showingDuration: Bool
    @Binding var showingClipLength: Bool
    let isBusy: Bool
    let status: String
    let exportProgress: Double?
    let joinProgress: (completed: Int, total: Int)?
    let outputURL: URL?
    let error: String?
    let onModeChange: (VideoTrailerMode) -> Void
    let onClose: () -> Void
    let onDiscard: () -> Void
    let onSave: (() -> Void)?
    let isSaved: Bool
    let regenerate: () -> Void
    @Binding var scenes: [TrailerEditScene]?
    @Binding var nextSceneID: Int
    @Binding var selectedSceneID: Int?
    let inspectorInline: Bool
    let chrome: TrailerEditorChrome
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue = AppThemePreference.light.rawValue
    @State private var showingMusicPicker = false
    /// The finished video fills the whole window. The same preview view (and so the same
    /// player, position and play/pause state) stays in the tree; only its siblings go away.
    @State private var isPreviewFullscreen = false
    @State private var confirmingDiscard = false
    @State private var showingCollectionAdd = false
    /// Bottom edge of the window's usable area (window height minus its bottom safe area), in
    /// the window's own coordinates. Zero until the window has reported it.
    @State private var windowUsableBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedSourceID: Int?
    @State private var dragLocation = CGPoint.zero
    @State private var dragAnchor = CGSize.zero
    @State private var sourceFrames: [Int: CGRect] = [:]
    @State private var sourceImages: [Int: UIImage] = [:]
    @State private var revealedSourceID: Int?
    @State private var appliedOrder: (choice: TrailerOrderChoice, ids: [Int])?

    // Recomputed from the actual retained sources on every access, so removing the last
    // video, a decode-skip exclusion, retry or reopen all flip this immediately instead
    // of freezing whatever the initial items looked like.
    private var photoOnly: Bool { !sources.isEmpty && sources.allSatisfy(\.isImage) }
    private var originalTotal: Double { sources.reduce(0) { $0 + $1.duration } }
    /// The plan without music: unchanged trailer rules, or every source whole.
    private var baseProposal: [VideoTrailerScene] {
        TrailerPreparedPlan.base(mode: mode, sources: sources, total: total, clipLength: clipLength, manual: scenes)
    }
    private var baseTotal: Double { baseProposal.reduce(0) { $0 + $1.length } }
    /// Empty when the chosen music cannot be matched within the repeat limit.
    private var proposal: [VideoTrailerScene] {
        TrailerPreparedPlan.scenes(mode: mode, sources: sources, total: total, clipLength: clipLength, music: music, manual: scenes)
    }
    private var musicRepeatCount: Int {
        guard let music, music.duration > 0 else { return 0 }
        return max(1, Int((baseTotal / music.duration - 0.000001).rounded(.up)))
    }
    private func sourceFrameReporter(id: Int) -> some View {
        GeometryReader { geometry in
            let frame: CGRect = geometry.frame(in: .named("trailerOrder"))
            Color.clear.preference(key: TrailerSourceFramesKey.self, value: [id: frame])
        }
    }

    private var createBar: some View {
        let blocked: Bool = proposal.isEmpty || (mode == .mediaMusic && music == nil)
        return Button(action: regenerate) {
            Text(createTitle).frame(maxWidth: .infinity)
        }
        .buttonStyle(PorcelainProminentButtonStyle()).controlSize(.large)
        .disabled(blocked || isBusy)
        .padding(.horizontal, MacUIScale.defaultPadding).padding(.vertical, ui(8)).background(.bar)
    }

    private var autoDuckToggle: some View {
        Toggle("배경음악 자동 조절", isOn: Binding<Bool>(
            get: { self.music?.autoDuck ?? true },
            set: { self.music?.autoDuck = $0 }))
            .font(.ui(.subheadline))
    }

    private var musicLevelSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("배경음악 음량 \(Int(((music?.level ?? 1) * 100).rounded()))%")
                .font(.ui(.subheadline)).monospacedDigit()
            Slider(value: Binding<Double>(get: { self.music?.level ?? 1 }, set: { self.music?.level = $0 }), in: 0...1)
                .accessibilityLabel("배경음악 음량")
        }
    }

    private var autoDuckCaption: some View {
        let on: Bool = music?.autoDuck ?? true
        let text: String = on ? "원본 소리가 나는 곳에서는 음악이 작아지고, 조용한 곳과 사진에서는 커져요"
                              : "음악을 항상 같은 보통 크기로 틀어요"
        return Text(text).font(.ui(.caption)).foregroundStyle(.secondary)
    }

    private var musicHint: String? {
        guard let music else { return nil }
        guard !baseProposal.isEmpty else { return nil }
        guard !proposal.isEmpty else { return TrailerMusicError.tooManyRepeats.errorDescription }
        switch music.policy {
        case .fitMusic:
            let repeats = music.fitCount > 1 ? "음악을 \(music.fitCount)번 이어 틀어요 · " : ""
            if baseTotal < music.fittedDuration - 0.05 { return repeats + "영상이 음악보다 짧아 장면을 처음부터 다시 이어 붙여요" }
            if baseTotal > music.fittedDuration + 0.05 { return repeats + "음악이 끝나는 곳에서 영상도 끝나요 · 뒤쪽 장면은 잘려요" }
            return repeats + "영상과 음악 길이가 같아요"
        case .loopMusic:
            return musicRepeatCount > 1 ? "음악을 \(musicRepeatCount)번 이어 틀고 영상 끝에서 멈춰요" : "영상이 끝나면 음악도 멈춰요"
        case .single:
            return baseTotal > music.duration + 0.05 ? "음악은 한 번만 나오고, 끝난 뒤에는 원본 소리만 나와요"
                : "음악은 한 번만 나오고 영상이 끝나면 멈춰요"
        }
    }
    private var actualTotal: Double { proposal.reduce(0) { $0 + $1.length } }
    private var sceneSummary: String {
        if mode == .mediaMusic { return "\(proposal.count)장면 · 원본 그대로" }
        if photoOnly { return "\(proposal.count)장면" }
        return "\(proposal.count)장면 · \(clipLength.formatted(.number.precision(.fractionLength(0...1))))초씩"
    }
    private var originalSummary: String {
        if mode == .mediaMusic { return "선택한 순서대로 이어 붙여요" }
        return "원본 \(trailerDurationTitle(originalTotal)) 중 \(percent.formatted(.number.precision(.fractionLength(1))))%"
    }
    private var musicSummary: String {
        guard let music else { return "음악 없음" }
        guard music.policy == .fitMusic, music.fitCount > 1 else {
            return "\(music.name) · \(videoTrailerTime(music.duration))"
        }
        return "\(music.name) · \(videoTrailerTime(music.duration)) × \(music.fitCount) = \(videoTrailerTime(music.fittedDuration))"
    }
    private var createTitle: String {
        if isBusy { return "영상을 만드는 중…" }
        if outputURL != nil {
            return mode == .mediaMusic ? "새 설정으로 영상 만들기" : "\(trailerFullDurationTitle(actualTotal)) 예고편 다시 만들기"
        }
        guard mode == .mediaMusic else { return "\(trailerFullDurationTitle(actualTotal)) 예고편 만들기" }
        return music == nil ? "음악을 골라 주세요" : "\(trailerFullDurationTitle(actualTotal)) 영상 만들기"
    }
    private var percent: Double { originalTotal > 0 ? actualTotal / originalTotal * 100 : 0 }
    // Only real video durations bound the clip length; manual maximum is longest valid remaining span;
    // photos-only base ceiling 30.
    private var maximumClipLength: Double {
        if let editScenes = scenes {
            let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let videoSpans = editScenes.filter { !$0.excluded }.compactMap { scene -> Double? in
                guard let source = byID[scene.sourceID], !source.isImage, source.duration > 0 else { return nil }
                return max(0.0, source.duration - scene.start)
            }
            if let longest = videoSpans.max(), longest > 0 {
                return longest
            }
            return 30.0
        } else {
            let videoDurations = sources.filter { !$0.isImage && $0.duration > 0 }.map(\.duration)
            if let maxDuration = videoDurations.max(), maxDuration > 0 {
                return maxDuration
            }
            return 30.0
        }
    }
    private var excludedCount: Int { sources.filter { source in !baseProposal.contains { $0.sourceID == source.id } }.count }

    private var musicSection: some View {
    VStack(alignment: .leading, spacing: ui(4)) {
        HStack {
            Text("음악").font(.ui(.subheadline).weight(.semibold))
            Spacer()
            Text(musicSummary)
                .font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        HStack(spacing: ui(5)) {
            TrailerChoiceButton(title: music == nil ? "음악 고르기" : "음악 바꾸기", selected: false) {
                showingMusicPicker = true
            }
            if music != nil {
                TrailerChoiceButton(title: "음악 없음", selected: false) { music = nil }
            }
        }
        if let music {
            HStack(spacing: ui(5)) {
                ForEach(TrailerMusicPolicy.selectable) { policy in
                    TrailerChoiceButton(title: musicPolicyTitle(policy), selected: music.policy == policy) {
                        chooseMusicPolicy(policy)
                    }
                }
            }
            autoDuckToggle
            musicLevelSlider
            if let musicHint {
                Text(musicHint).font(.ui(.caption)).foregroundStyle(proposal.isEmpty ? Color.red : Color.secondary)
            }
            autoDuckCaption
        } else if mode == .mediaMusic {
            Text("음악을 골라야 영상을 만들 수 있어요").font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
    }

    @ViewBuilder
    private func sourceCell(index: Int, source: VideoTrailerSource) -> some View {
                    TrailerSourceThumbnail(source: source, number: index + 1, image: thumbnailImage(for: source.id),
                        isRevealed: revealedSourceID == source.id,
                        onTap: { revealedSourceID = revealedSourceID == source.id ? nil : source.id },
                        onRemove: {
                            revealedSourceID = nil
                            sources.removeAll { $0.id == source.id }
                        })
                        .background { sourceFrameReporter(id: source.id) }
                        .opacity(draggedSourceID == source.id ? 0.25 : 1)
                        // Mac Catalyst routes trackpad two-finger scroll through the same
                        // touch-emulation path as a click-drag; a zero-distance DragGesture
                        // here would claim that touch before the ScrollView's own pan
                        // recognizer sees it, leaving the whole sheet unscrollable. Mac
                        // instead gets the system pointer drag below, which only starts on
                        // an actual press-drag and never intercepts a hover/scroll.
                        // iPhone has no per-thumbnail SwiftUI gesture at all for the same
                        // reason: the grid's single `TrailerReorderHold` recognizer below
                        // owns the one second hold, so a short swipe stays the ScrollView's.
                        #if targetEnvironment(macCatalyst)
                        .onDrag {
                            draggedSourceID = source.id
                            return NSItemProvider(object: String(source.id) as NSString)
                        }
                        .onDrop(of: [.text], delegate: TrailerSourceDropDelegate(
                            target: source, sources: $sources,
                            draggedSourceID: $draggedSourceID, reduceMotion: reduceMotion))
                        #endif
                        .accessibilityAction(named: "앞으로 이동") { if index > 0 { sources.swapAt(index, index - 1) } }
                        .accessibilityAction(named: "뒤로 이동") { if index + 1 < sources.count { sources.swapAt(index, index + 1) } }
    }

    private var aspectSection: some View {
    VStack(alignment: .leading, spacing: ui(4)) {
        HStack {
            Text("화면 모양").font(.ui(.subheadline).weight(.semibold))
            Spacer()
            Text(aspectRatio?.title ?? "원본").font(.ui(.caption)).foregroundStyle(.secondary)
        }
        // Six equal 44pt square tiles in the order 원본/1:1/3:4/4:3/9:16/16:9 on a single row (never wraps);
        // the ratio text sits below each tile, and the row scrolls horizontally only when the width is too narrow.
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: ui(8)) {
            Button { aspectRatio = nil } label: {
                TrailerAspectRatioIcon(ratio: nil, isSelected: aspectRatio == nil, label: "원본")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("원본, 첫 영상 화면 비율")
            .accessibilityAddTraits(aspectRatio == nil ? .isSelected : [])
            ForEach(OutputAspectRatio.allCases) { ratio in
                Button { aspectRatio = ratio } label: {
                    TrailerAspectRatioIcon(ratio: ratio, isSelected: aspectRatio == ratio, label: ratio.rawValue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ratio.title)
                .accessibilityAddTraits(aspectRatio == ratio ? .isSelected : [])
            }
        }
        }
    }
    }

    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        GeometryReader { geometry in
            // On Mac Catalyst the hosting controller can be placed below the title/toolbar area
            // yet still be proposed the whole window height, so the bottom (the transport row
            // and the create bar) lands outside the window. The height actually available is
            // what remains of the window below this view's own origin.
            let originY = geometry.frame(in: .global).minY
            let available = windowUsableBottom > 0
                ? min(geometry.size.height, max(windowUsableBottom - originY, 0))
                : geometry.size.height
            editorLayout(size: CGSize(width: geometry.size.width, height: available))
                .frame(width: geometry.size.width, height: available, alignment: .top)
        }
        .background(TrailerWindowBottomReader { windowUsableBottom = $0 })
        .background { if isPreviewFullscreen { Color.black.ignoresSafeArea() } }
        // The hidden toolbar no longer owns Escape, so the presenting full-screen cover would
        // take it and dismiss the whole editor. While fullscreen, this responder consumes it.
        .background {
            if isPreviewFullscreen {
                TrailerFullscreenEscapeCatcher { isPreviewFullscreen = false }
            }
        }
        .toolbar(isPreviewFullscreen ? .hidden : .automatic, for: .navigationBar)
        .fullScreenCover(isPresented: $showingMusicPicker) {
            TrailerMusicPickerView(currentID: music?.recordID) { picked in
                var next = picked
                next?.autoDuck = music?.autoDuck ?? true
                next?.level = music?.level ?? 1
                music = next
            }
            .environmentObject(inboxStore)
        }
        .alert("이 편집을 버릴까요?", isPresented: $confirmingDiscard) {
            Button("버리기", role: .destructive, action: onDiscard)
            Button("취소", role: .cancel) { }
        } message: {
            Text("이 편집을 위해 받아 둔 사본과 폰하드에 저장하지 않은 완성 영상이 지워집니다. 원본과 폰하드에 저장한 파일은 그대로입니다.")
        }
        .navigationTitle(settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // Escape resolves to this button; in fullscreen it only leaves fullscreen.
                Button("닫기", action: isPreviewFullscreen ? { isPreviewFullscreen = false } : onClose).uiBarFont()
            }
            if chrome.showsAdd {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: chrome.onAdd) { Image(interfaceSystemName: "plus.circle") }
                        .accessibilityLabel("재료 추가")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue)
            }
            if let onSave {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onSave) {
                        Image(interfaceSystemName: isSaved ? "checkmark.circle" : "square.and.arrow.down")
                    }
                    .disabled(isBusy || isSaved || outputURL == nil)
                    .accessibilityLabel(isSaved ? "폰하드에 저장됨" : "폰하드에 저장")
                }
            }
            if let outputURL, !isBusy {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCollectionAdd = true } label: {
                        InterfaceToolbarIcon(systemName: "photo.stack")
                    }
                    .accessibilityLabel("컬렉션에 추가")
                    .sheet(isPresented: $showingCollectionAdd) {
                        CollectionAddSheet(videoURL: outputURL, suggestedTitle: "내 영상", sourceProjectID: chrome.projectID)
                    }
                }
            }
        }
    }

    /// One tree for both widths. `AnyLayout` swaps HStack/VStack without changing the identity of
    /// its children, so the preview (and its player, position and play/pause state) survives
    /// rotation, window resizing across 640pt and entering or leaving fullscreen.
    private func editorLayout(size: CGSize) -> some View {
        let isWide = size.width >= 640
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: ui(16)))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: ui(14)))
        return ScrollView(isWide ? [] : .vertical) {
            layout {
                VStack(alignment: .leading, spacing: ui(isWide ? 12 : 14)) {
                    if !isPreviewFullscreen { projectBar }
                    previewSection
                        // Fullscreen is exactly the viewport (safe area excluded), never taller.
                        .frame(minHeight: isPreviewFullscreen ? size.height : nil,
                               maxHeight: isPreviewFullscreen ? size.height : ui(isWide ? 380 : 260))
                    if !isPreviewFullscreen { orderSection }
                }
                .frame(width: isWide && !isPreviewFullscreen ? max(ui(320), (size.width - ui(48)) * 0.54) : nil)
                .frame(maxWidth: isPreviewFullscreen ? .infinity : nil)

                if !isPreviewFullscreen {
                    if isWide {
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: ui(12)) {
                                    optionsSection
                                }
                                .padding(.vertical, ui(8))
                            }
                            .scrollBounceBehavior(.always, axes: .vertical)

                            createBar
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Divider()
                        optionsSection
                    }
                }
            }
            .padding(isPreviewFullscreen ? 0 : ui(16))
            .frame(height: isWide ? size.height : nil)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDisabled(isPreviewFullscreen || isWide)
        .safeAreaInset(edge: .bottom) { if !isPreviewFullscreen && !isWide { createBar } }
    }

    private var previewSection: some View {
        TrailerWorkspacePreview(
            outputURL: outputURL,
            firstSource: sources.first,
            firstVideo: sources.first { !$0.isImage },
            aspectRatio: aspectRatio,
            isBusy: isBusy,
            status: status,
            error: error,
            exportProgress: exportProgress,
            joinProgress: joinProgress,
            accessoryControls: AnyView(trailerControlsView),
            // In fullscreen the close button and Escape return to the editor, not leave it.
            onClose: isPreviewFullscreen ? { isPreviewFullscreen = false } : onClose,
            isFullscreen: isPreviewFullscreen,
            onCancel: chrome.onCancelWork,
            onRetry: chrome.onRetryRender
        )
    }

    private var trailerControlsView: some View {
        HStack(spacing: ui(6)) {
            Button { isPreviewFullscreen.toggle() } label: {
                SharedPlayerCircleLabel(systemImage: isPreviewFullscreen
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(isPreviewFullscreen ? "전체화면 닫기" : "전체화면")
            if let onSave {
                Button(action: onSave) {
                    SharedPlayerCircleLabel(systemImage: isSaved ? "checkmark.circle" : "square.and.arrow.down")
                }
                .accessibilityLabel(isSaved ? "폰하드에 저장됨" : "폰하드에 저장")
                .disabled(isBusy || isSaved)
            }
        }
    }

    /// Highlighted only while the list still is exactly what that choice produced (or, for
    /// 추가순, still is the immutable input order), so a manual drag clears it.
    private func isOrderSelected(_ choice: TrailerOrderChoice) -> Bool {
        let ids = sources.map(\.id)
        if choice == .added, appliedOrder == nil { return ids == ids.sorted() }
        return appliedOrder?.choice == choice && appliedOrder?.ids == ids
    }

    private func orderButton(_ title: String, _ choice: TrailerOrderChoice,
                             _ arrange: @escaping ([VideoTrailerSource]) -> [VideoTrailerSource]) -> some View {
        TrailerChoiceButton(title: title, selected: isOrderSelected(choice), height: 28) {
            revealedSourceID = nil
            let next = arrange(sources)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { sources = next }
            appliedOrder = (choice, next.map(\.id))
        }
        .frame(maxWidth: .infinity, minHeight: ui(28))
    }

    @ViewBuilder
    private var orderSection: some View {
        if let editScenes = scenes {
            VStack(alignment: .leading, spacing: ui(6)) {
                HStack(spacing: ui(6)) {
                    Text("장면 (\(editScenes.count))").font(.ui(.subheadline).weight(.semibold))
                    Text("직접 편집 중").font(.ui(.caption)).foregroundStyle(.secondary)
                    Spacer()
                }
                TrailerSceneStrip(scenes: editScenes, sources: sources, selectedID: $selectedSceneID)
                if inspectorInline {
                    TrailerSceneInspector(
                        mode: mode, sources: sources, scenes: $scenes, nextSceneID: $nextSceneID,
                        selectedID: $selectedSceneID, clipLength: clipLength, beginEditing: beginSceneEditing, chrome: chrome,
                        aspectRatio: aspectRatio)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: ui(6)) {
                sourceOrderSection
                HStack {
                    Button("장면 직접 편집 시작", action: beginSceneEditing)
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(sources.isEmpty || isBusy)
                    Text("장면별로 자르고 순서를 바꿔요. 사진은 빠지지 않아요.")
                        .font(.ui(.caption2)).foregroundStyle(.secondary)
                }
                if inspectorInline {
                    TrailerSceneInspector(
                        mode: mode, sources: sources, scenes: $scenes, nextSceneID: $nextSceneID,
                        selectedID: $selectedSceneID, clipLength: clipLength, beginEditing: beginSceneEditing, chrome: chrome,
                        aspectRatio: aspectRatio)
                }
            }
        }
    }

    private func beginSceneEditing() {
        guard scenes == nil else { return }
        let seeded = TrailerPreparedPlan.seedEdits(mode: mode, sources: sources, total: total, clipLength: clipLength)
        scenes = seeded
        nextSceneID = (seeded.map(\.id).max() ?? 0) + 1
        selectedSceneID = seeded.first?.id
    }

    /// 이 프로젝트의 이름과 저장 상태, 되돌리기/다시 실행.
    private var projectBar: some View {
        HStack(spacing: ui(8)) {
            Text(chrome.title).font(.ui(.footnote).weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: ui(4))
            if !chrome.saveLabel.isEmpty {
                Text(chrome.saveLabel).font(.ui(.caption2)).lineLimit(1)
                    .foregroundStyle(chrome.saveFailed ? Color.red : Color.secondary)
                if chrome.saveFailed {
                    Button("다시 저장", action: chrome.onRetrySave).font(.ui(.caption2).weight(.semibold))
                }
            }
            Button(action: chrome.onUndo) { Image(interfaceSystemName: "arrow.uturn.backward") }
                .disabled(!chrome.canUndo).accessibilityLabel("되돌리기")
            Button(action: chrome.onRedo) { Image(interfaceSystemName: "arrow.uturn.forward") }
                .disabled(!chrome.canRedo).accessibilityLabel("다시 실행")
        }
        .buttonStyle(.plain)
        .frame(minHeight: ui(28))
    }

    private var sourceOrderSection: some View {
        VStack(alignment: .leading, spacing: ui(6)) {
            HStack(spacing: ui(6)) {
                Text("영상 순서 (\(sources.count))")
                    .font(.ui(.subheadline).weight(.semibold))
                Spacer()
            }

            if sources.count > 1 {
                HStack(spacing: ui(4)) {
                    orderButton("추가순", .added) { $0.sorted { $0.id < $1.id } }
                    orderButton("시간순", .chronological) { VideoTrailerSourceOrder.chronological($0) }
                    orderButton("가나다순", .name) { VideoTrailerSourceOrder.byName($0) }
                    // Shuffled once, here, on the explicit tap; never again on a redraw.
                    orderButton("랜덤", .random) { VideoTrailerSourceOrder.randomized($0) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ui(8)) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        sourceCell(index: index, source: source)
                            .frame(width: ui(64), height: ui(64))
                    }
                }
                .padding(.vertical, ui(2))
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            Picker("제작 방식", selection: Binding(get: { mode }, set: onModeChange)) {
                Text("예고편").tag(VideoTrailerMode.trailer)
                Text("뮤직비디오").tag(VideoTrailerMode.mediaMusic)
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)

            musicSection

            Divider()

            VStack(alignment: .leading, spacing: ui(3)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trailerFullDurationTitle(actualTotal)).font(.ui(.title2).weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(sceneSummary).font(.ui(.subheadline)).foregroundStyle(.secondary)
                }
                if !photoOnly && (mode == .mediaMusic || actualTotal <= originalTotal + 0.000001) {
                    Text(originalSummary).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }

            if mode == .trailer {
                Divider()
                durationControls
            }

            Divider()

            aspectSection

            if sources.isEmpty {
                Text("모든 영상이 제거되어 예고편을 만들 수 없습니다. 영상을 다시 추가해 주세요.")
                    .font(.ui(.caption)).foregroundStyle(.red)
            }
            if mode == .trailer, music?.policy != .fitMusic, abs(total - baseTotal) >= 0.5 {
                Text("선택한 \(trailerFullDurationTitle(total))에 가장 가까운 길이로 맞췄어요")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if recoveredCount > 0 {
                Text("복구됨 \(recoveredCount)개 · 멈춘 화면으로 대체된 영상").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if skippedCount > 0 {
                Text(trailerSkippedTitle(skippedCount)).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if excludedCount > 0 {
                Text("\(excludedCount)개 영상은 담기지 않아요. 총길이를 늘리거나 장면 길이를 줄여보세요.")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                if mode == .trailer || scenes != nil {
                    Button("자동 추천으로 되돌리기") {
                        scenes = nil
                        selectedSceneID = nil
                        clipLength = VideoTrailerModel.recommendedLength(sources)
                        total = VideoTrailerBatchPlan.recommendedTotal(sources: sources, clipLength: clipLength)
                        syncTotalToFit(music)
                        showingDuration = false
                        showingClipLength = false
                    }
                    .font(.ui(.caption)).frame(minHeight: ui(30))
                }
                Spacer()
                Button("이 편집 버리기", role: .destructive) { confirmingDiscard = true }
                    .font(.ui(.caption)).frame(minHeight: ui(30))
            }
        }
    }

    private var settingsTitle: String { "영상 편집" }

    private func musicPolicyTitle(_ policy: TrailerMusicPolicy) -> String {
        guard policy == .fitMusic, let music, music.policy == .fitMusic else { return policy.title }
        return TrailerMusicPolicy.fitTitle(count: music.fitCount)
    }

    /// Tapping "음악 길이에 맞추기" while it is already chosen fits one more run of the
    /// music; arriving from any other policy starts again at one.
    private func chooseMusicPolicy(_ policy: TrailerMusicPolicy) {
        guard var selection = music else { return }
        if policy == .fitMusic, selection.policy == .fitMusic {
            selection.fitCount = min(TrailerMusic.maximumRepeats, selection.fitCount + 1)
        } else {
            selection.fitCount = 1
        }
        selection.policy = policy
        music = selection
        syncTotalToFit(selection)
    }

    /// Under "음악 길이에 맞추기" the length shown in "얼마나 길게 볼까요?" is the music's
    /// own length times the count, the same as the header. It is set here and not through
    /// `setManualTotal`, so the chosen policy stays chosen.
    private func syncTotalToFit(_ selection: TrailerMusicSelection?) {
        guard mode == .trailer, let selection, selection.policy == .fitMusic else { return }
        total = selection.fittedDuration
    }

    private var durationControls: some View {
        let migratedSourcesForRecommendation: [VideoTrailerSource] = sources.map { src in
            guard src.isImage && src.imageDurationPolicyVersion < 2 else { return src }
            var copy = src
            copy.imageDurationRatio = VideoTrailerPhotoQuality.migrateV1ToV2Ratio(src.imageDurationRatio)
            copy.imageDurationPolicyVersion = 2
            return copy
        }
        let recommendedClip = VideoTrailerModel.recommendedLength(migratedSourcesForRecommendation)
        let recommendedTotal = VideoTrailerBatchPlan.recommendedTotal(sources: migratedSourcesForRecommendation, clipLength: recommendedClip)

        let computedMaxClip = maximumClipLength
        let maxClip = max(clipLength, computedMaxClip)
        let minClip = min(clipLength, min(0.5, maxClip))

        let totalValue: Double
        let minTotal: Double
        let maxTotal: Double
        if let editScenes = scenes {
            let actualSum = editScenes.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
            totalValue = actualSum
            let bounds = TrailerSceneEditor.manualTotalBounds(scenes: editScenes, sources: sources)
            minTotal = min(actualSum, bounds.minimum)
            maxTotal = max(actualSum, bounds.maximum)
        } else {
            totalValue = total
            minTotal = 1.0
            maxTotal = VideoTrailerBatchPlan.maximumRequestedDuration
        }

        return VStack(alignment: .leading, spacing: ui(12)) {
            TrailerAdaptiveDurationControl(
                title: "전체 길이",
                value: totalValue,
                recommended: recommendedTotal,
                minValue: minTotal,
                maxValue: maxTotal,
                isNonlinear: true,
                explanation: nil,
                formatValue: trailerFullDurationTitle,
                candidateFormatValue: trailerCompactDurationTitle,
                onCommit: { finalVal in
                    setManualTotal(finalVal)
                }
            )

            TrailerAdaptiveDurationControl(
                title: "영상 클립 길이",
                value: clipLength,
                recommended: recommendedClip,
                minValue: minClip,
                maxValue: maxClip,
                isNonlinear: true,
                explanation: "사진은 영상 클립 길이를 기준으로 중요도에 따라 조절돼요.",
                formatValue: trailerSceneLengthTitle,
                candidateFormatValue: trailerSceneLengthTitle,
                onCommit: { finalVal in
                    setExplicitClipLength(finalVal)
                }
            )
        }
    }

    /// The total length picked by hand (buttons or the slider).
    private func setManualTotal(_ value: Double) {
        if let editScenes = scenes {
            let bounds = TrailerSceneEditor.manualTotalBounds(scenes: editScenes, sources: sources)
            let valid = value.isFinite ? min(bounds.maximum, max(bounds.minimum, value)) : bounds.minimum
            TrailerSceneEditor.redistributeManualTotal(scenes: &scenes!, sources: sources, targetTotal: valid)
            let actual = (scenes ?? []).filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
            total = actual
        } else {
            let valid = value.isFinite ? min(VideoTrailerBatchPlan.maximumRequestedDuration, max(1, value)) : 1
            total = valid
        }
        guard var selection = music, selection.policy != .single else { return }
        selection.policy = .single
        selection.fitCount = 1
        music = selection
    }

    /// 공통 영상 클립 길이를 명시적으로 변경한다.
    private func setExplicitClipLength(_ value: Double) {
        let computedMaxClip = maximumClipLength
        let maxClip = max(clipLength, computedMaxClip)
        let minClip = min(clipLength, min(0.5, maxClip))
        let valid = value.isFinite ? max(minClip, min(maxClip, value)) : 4.0
        clipLength = valid
        // V1 사진 비율 1회 안전하게 마이그레이션
        for i in sources.indices where sources[i].isImage && sources[i].imageDurationPolicyVersion < 2 {
            sources[i].imageDurationRatio = VideoTrailerPhotoQuality.migrateV1ToV2Ratio(sources[i].imageDurationRatio)
            sources[i].imageDurationPolicyVersion = 2
        }
        if scenes != nil {
            TrailerSceneEditor.applyExplicitClipLength(clipLength: valid, scenes: &scenes!, sources: &sources)
            let actual = (scenes ?? []).filter { !$0.excluded }.reduce(0.0) { $0 + $1.length }
            total = actual
        } else {
            total = VideoTrailerBatchPlan.recommendedBudget(sources: sources, clipLength: valid)
        }
    }

    #if targetEnvironment(macCatalyst)
    private var macHeader: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(settingsTitle).font(.ui(.headline)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, ui(72))
                HStack {
                    Button("닫기", action: onClose).font(.ui(.body))
                        .frame(minHeight: ui(30)).contentShape(Rectangle())
                    Spacer()
                }
            }
            .padding(.horizontal, ui(16)).padding(.vertical, ui(8))
            Divider()
        }
        .background(.bar)
    }
    #endif

    private func thumbnailImage(for id: Int) -> Binding<UIImage?> {
        Binding(get: { sourceImages[id] }, set: { sourceImages[id] = $0 })
    }

    #if !targetEnvironment(macCatalyst)
    // `location` is in the grid's "trailerOrder" space for both of these.
    private func beginReorder(at location: CGPoint) {
        guard draggedSourceID == nil,
              let source = sources.first(where: { sourceFrames[$0.id]?.contains(location) == true }),
              let frame = sourceFrames[source.id] else { return }
        dragAnchor = CGSize(width: location.x - frame.midX, height: location.y - frame.midY)
        dragLocation = location
        draggedSourceID = source.id
    }

    // Runs on every finger move after the hold, so neighbors reorder live mid-gesture,
    // not only on release.
    private func moveReorder(to location: CGPoint) {
        guard let id = draggedSourceID else { return }
        dragLocation = location
        if let target = sources.first(where: { $0.id != id && sourceFrames[$0.id]?.contains(location) == true }),
           let from = sources.firstIndex(where: { $0.id == id }),
           let to = sources.firstIndex(where: { $0.id == target.id }) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                sources.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }
    #endif

    private func otherLengthButton(value: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("다른 길이")
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(interfaceSystemName: expanded ? "chevron.up" : "chevron.down", pointSize: 11).font(.ui(.caption2))
            }
            .font(.ui(.caption)).frame(minHeight: ui(30)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if targetEnvironment(macCatalyst)
/// Native pointer drag/drop reorder for Mac Catalyst. Only moves sources while this
/// view's own `onDrag` started the session (tracked via `draggedSourceID`), so an
/// unrelated external drag entering this grid can never reorder sources.
private struct TrailerSourceDropDelegate: DropDelegate {
    let target: VideoTrailerSource
    @Binding var sources: [VideoTrailerSource]
    @Binding var draggedSourceID: Int?
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard let draggedSourceID, draggedSourceID != target.id,
              let from = sources.firstIndex(where: { $0.id == draggedSourceID }),
              let to = sources.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
            sources.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggedSourceID = nil
        return true
    }
}

/// Catches drops that land in a gap between thumbnails (not on any `TrailerSourceThumbnail`
/// itself) and the pointer leaving the grid altogether, so a drag that ends without ever
/// hitting a thumbnail's own drop target still clears `draggedSourceID` instead of leaving
/// a thumbnail dimmed.
private struct TrailerSourceGridDropDelegate: DropDelegate {
    @Binding var draggedSourceID: Int?
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { draggedSourceID = nil; return true }
    func dropExited(info: DropInfo) { draggedSourceID = nil }
}
#else
/// iPhone reorder hold. One `UILongPressGestureRecognizer` for the whole grid, installed
/// on the enclosing `UIScrollView`: it fails by itself when the finger moves before the
/// one second hold completes, so the scroll view's own pan takes an ordinary swipe that
/// starts on a thumbnail, and once the hold completes it keeps reporting `.changed`
/// positions for live reordering. A SwiftUI `LongPressGesture` sequenced before a
/// zero-distance `DragGesture` on each thumbnail could not give both.
///
/// Reported points are in this view's own bounds. It is the grid's background, so that
/// is the grid's "trailerOrder" coordinate space.
private struct TrailerReorderHold: UIViewRepresentable {
    let canBegin: @MainActor (CGPoint) -> Bool
    let onBegan: @MainActor (CGPoint) -> Void
    let onChanged: @MainActor (CGPoint) -> Void
    let onEnded: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) { context.coordinator.parent = self }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) { coordinator.detach() }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { coordinator?.detach() } else { coordinator?.attach(anchor: self) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TrailerReorderHold
        private weak var anchor: UIView?
        private var recognizer: UILongPressGestureRecognizer?
        private var isReordering = false

        init(_ parent: TrailerReorderHold) { self.parent = parent }

        func attach(anchor: UIView) {
            detach()
            // The page's scroll view when there is one, otherwise the outermost ancestor;
            // either way `shouldReceive` below limits it to touches on a thumbnail.
            var host = anchor.superview
            while let current = host, !(current is UIScrollView), let next = current.superview { host = next }
            guard let host else { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumPressDuration = 1
            recognizer.delegate = self
            host.addGestureRecognizer(recognizer)
            self.anchor = anchor
            self.recognizer = recognizer
        }

        // Always removes the one recognizer this coordinator added, so re-attaching or
        // tearing the grid down never leaves a second one on the scroll view.
        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            anchor = nil
            guard isReordering else { return }
            isReordering = false
            // Deferred: this can run while SwiftUI is tearing the grid down.
            Task { @MainActor in self.parent.onEnded() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor else { return false }
            return parent.canBegin(touch.location(in: anchor))
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard let anchor else { return }
            let location = recognizer.location(in: anchor)
            switch recognizer.state {
            case .began:
                isReordering = true
                parent.onBegan(location)
            case .changed:
                if isReordering { parent.onChanged(location) }
            case .ended, .cancelled, .failed:
                if isReordering { parent.onEnded() }
                isReordering = false
            default:
                break
            }
        }
    }
}
#endif

private struct TrailerSourceFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Shows fractional scene lengths like "1.5초" or a randomized photo scene's "2.3초"
/// instead of the truncated "1초" that an `Int` conversion would produce.
private func trailerSceneLengthTitle(_ seconds: Double) -> String {
    "\(seconds.formatted(.number.precision(.fractionLength(0...2))))초"
}

private func trailerSkippedTitle(_ count: Int) -> String {
    "제외됨 \(count)개 · 이 기기에서 풀 수 없는 영상"
}

/// Horizontal bar for the composing step, driven only by the actual count of scene
/// clips already inserted into the composition; never a time-based estimate.
private struct TrailerJoinProgressBar: View {
    let completed: Int
    let total: Int
    var body: some View {
        ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
            .progressViewStyle(.linear).frame(width: ui(200))
            .accessibilityLabel("클립 연결 중")
            .accessibilityValue("\(completed) / \(total)")
    }
}

/// Horizontal bar and whole percentage for the final joining step. `progress` is the
/// exporter's own measured value, so nothing here advances on a timer.
private struct TrailerExportProgress: View {
    let progress: Double
    var body: some View {
        HStack(spacing: ui(10)) {
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: ui(200))
            Text("\(Int((progress * 100).rounded(.down)))%").font(.ui(.footnote).weight(.semibold)).monospacedDigit()
                .frame(minWidth: ui(40), alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("이어 붙이는 중")
        .accessibilityValue("\(Int((progress * 100).rounded(.down)))퍼센트")
    }
}

private func trailerDurationTitle(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3600
    let minutes = value / 60 % 60
    let seconds = value % 60
    return [hours > 0 ? "\(hours)시간" : nil, minutes > 0 ? "\(minutes)분" : nil,
            seconds > 0 || value == 0 ? "\(seconds)초" : nil].compactMap { $0 }.joined(separator: " ")
}

/// 0.5초 등 소수점 초를 정확히 표시하는 전체 표시용 포맷터.
private func trailerFullDurationTitle(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0초" }
    let roundedSec = (seconds * 10).rounded() / 10.0
    let totalSecInt = Int(roundedSec)
    let fraction = roundedSec - Double(totalSecInt)
    let hours = totalSecInt / 3600
    let minutes = totalSecInt / 60 % 60
    let remainingSec = totalSecInt % 60
    let hasFraction = abs(fraction) >= 0.05

    let secString: String?
    if hasFraction {
        let secValue = Double(remainingSec) + fraction
        secString = "\(secValue.formatted(.number.precision(.fractionLength(1))))초"
    } else if remainingSec > 0 || (hours == 0 && minutes == 0) {
        secString = "\(remainingSec)초"
    } else {
        secString = nil
    }

    return [hours > 0 ? "\(hours)시간" : nil,
            minutes > 0 ? "\(minutes)분" : nil,
            secString].compactMap { $0 }.joined(separator: " ")
}

/// 후보 버튼용 콤팩트 mm:ss.s 포맷터.
private func trailerCompactDurationTitle(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "00:00" }
    let roundedSec = (seconds * 10).rounded() / 10.0
    let totalSecInt = Int(roundedSec)
    let fraction = roundedSec - Double(totalSecInt)
    let hours = totalSecInt / 3600
    let minutes = totalSecInt / 60 % 60
    let remainingSec = totalSecInt % 60
    let hasFraction = abs(fraction) >= 0.05

    if hours > 0 {
        if hasFraction {
            let secVal = Double(remainingSec) + fraction
            return String(format: "%d:%02d:%04.1f", hours, minutes, secVal)
        } else {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSec)
        }
    } else {
        if hasFraction {
            let secVal = Double(remainingSec) + fraction
            return String(format: "%02d:%04.1f", minutes, secVal)
        } else {
            return String(format: "%02d:%02d", minutes, remainingSec)
        }
    }
}

private struct TrailerChoiceButton: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(3)) {
                Text(title)
                if selected { Image(interfaceSystemName: "checkmark", pointSize: 11).font(.ui(.caption2)) }
            }
            .font(.ui(.footnote).weight(.medium))
            .frame(maxWidth: .infinity, minHeight: ui(height))
            .background(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: ui(8)))
            .overlay { RoundedRectangle(cornerRadius: ui(8)).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum TrailerDurationMapping {
    static func position(value: Double, min minVal: Double, max maxVal: Double) -> Double {
        guard maxVal > minVal else { return 0 }
        let clamped = min(maxVal, max(minVal, value))
        return sqrt((clamped - minVal) / (maxVal - minVal))
    }

    static func value(position: Double, min minVal: Double, max maxVal: Double) -> Double {
        let clampedPos = min(1.0, max(0.0, position))
        let raw = minVal + (maxVal - minVal) * (clampedPos * clampedPos)
        let step = adaptiveStep(for: raw)
        let snapped = (raw / step).rounded() * step
        return min(maxVal, max(minVal, snapped))
    }

    static func adaptiveStep(for value: Double) -> Double {
        if value < 10 { return 0.5 }
        if value < 30 { return 1.0 }
        if value < 180 { return 5.0 }
        if value < 600 { return 30.0 }
        return 60.0
    }

    static func formatStep(_ step: Double) -> String {
        if step < 60 {
            if step == step.rounded() {
                return "\(Int(step))초"
            } else {
                return "\(step.formatted(.number.precision(.fractionLength(1))))초"
            }
        } else {
            let mins = Int(step / 60)
            return "\(mins)분"
        }
    }
}

private struct TrailerAdaptiveDurationControl: View {
    let title: String
    let value: Double
    let recommended: Double
    let minValue: Double
    let maxValue: Double
    let isNonlinear: Bool
    let explanation: String?
    let formatValue: (Double) -> String
    var candidateFormatValue: ((Double) -> String)? = nil
    let onCommit: (Double) -> Void

    @State private var draggingValue: Double? = nil

    private var displayValue: Double {
        draggingValue ?? value
    }

    var body: some View {
        let isControlEnabled = maxValue > minValue
        let clampedRec = min(maxValue, max(minValue, recommended))
        let lowerStep = TrailerDurationMapping.adaptiveStep(for: max(minValue, clampedRec - 0.001))
        let lowerCandidate = min(maxValue, max(minValue, ((clampedRec - lowerStep) / lowerStep).rounded() * lowerStep))
        let showLower = isControlEnabled && lowerCandidate < clampedRec && abs(lowerCandidate - clampedRec) >= 0.01

        let higherStep = TrailerDurationMapping.adaptiveStep(for: clampedRec)
        let higherCandidate = min(maxValue, max(minValue, ((clampedRec + higherStep) / higherStep).rounded() * higherStep))
        let showHigher = isControlEnabled && higherCandidate > clampedRec && abs(higherCandidate - clampedRec) >= 0.01

        let isRecSelected = isControlEnabled && abs(displayValue - clampedRec) < 0.01
        let isLowerSelected = showLower && abs(displayValue - lowerCandidate) < 0.01
        let isHigherSelected = showHigher && abs(displayValue - higherCandidate) < 0.01

        let stepDown = TrailerDurationMapping.adaptiveStep(for: max(minValue, displayValue - 0.001))
        let stepUp = TrailerDurationMapping.adaptiveStep(for: displayValue)
        let candidateFormatter = candidateFormatValue ?? formatValue

        let sliderMin = minValue
        let sliderMax = max(minValue + 0.001, maxValue)

        VStack(alignment: .leading, spacing: ui(6)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.ui(.subheadline).weight(.semibold))
                Spacer()
                Text(formatValue(displayValue))
                    .font(.ui(.title3).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: ui(4)) {
                // Minus button
                Button {
                    let nextVal = min(maxValue, max(minValue, displayValue - stepDown))
                    onCommit(nextVal)
                } label: {
                    Text("-\(TrailerDurationMapping.formatStep(stepDown))")
                        .font(.ui(.footnote).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: ui(44))
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: ui(8)))
                }
                .buttonStyle(.plain)
                .disabled(!isControlEnabled || displayValue <= minValue)
                .opacity((!isControlEnabled || displayValue <= minValue) ? 0.35 : 1.0)
                .accessibilityLabel("\(TrailerDurationMapping.formatStep(stepDown)) 줄이기")

                // Lower candidate
                if showLower {
                    Button {
                        onCommit(lowerCandidate)
                    } label: {
                        Text(candidateFormatter(lowerCandidate))
                            .font(.ui(.footnote).weight(.medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: ui(44))
                            .background(isLowerSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: ui(8)))
                            .overlay {
                                RoundedRectangle(cornerRadius: ui(8)).stroke(isLowerSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isControlEnabled)
                    .opacity(isControlEnabled ? 1.0 : 0.35)
                    .accessibilityLabel(formatValue(lowerCandidate))
                    .accessibilityAddTraits(isLowerSelected ? .isSelected : [])
                } else {
                    Button {} label: {
                        Text("-")
                            .font(.ui(.footnote))
                            .frame(maxWidth: .infinity, minHeight: ui(44))
                            .background(Color(uiColor: .tertiarySystemFill).opacity(0.35), in: RoundedRectangle(cornerRadius: ui(8)))
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .opacity(0.3)
                }

                // Recommended candidate (centered)
                Button {
                    onCommit(clampedRec)
                } label: {
                    VStack(spacing: ui(1)) {
                        Text(candidateFormatter(clampedRec))
                            .font(.ui(.footnote).weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("추천").font(.system(size: ui(9), weight: .bold))
                            .padding(.horizontal, ui(4)).padding(.vertical, ui(1))
                            .background(isRecSelected ? Color.accentColor : Color.secondary.opacity(0.2), in: Capsule())
                            .foregroundStyle(isRecSelected ? Color.white : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: ui(44))
                    .background(isRecSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: ui(8)))
                    .overlay {
                        RoundedRectangle(cornerRadius: ui(8)).stroke(isRecSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isControlEnabled)
                .opacity(isControlEnabled ? 1.0 : 0.35)
                .accessibilityLabel("\(formatValue(clampedRec)), 추천")
                .accessibilityAddTraits(isRecSelected ? .isSelected : [])

                // Higher candidate
                if showHigher {
                    Button {
                        onCommit(higherCandidate)
                    } label: {
                        Text(candidateFormatter(higherCandidate))
                            .font(.ui(.footnote).weight(.medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: ui(44))
                            .background(isHigherSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: ui(8)))
                            .overlay {
                                RoundedRectangle(cornerRadius: ui(8)).stroke(isHigherSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isControlEnabled)
                    .opacity(isControlEnabled ? 1.0 : 0.35)
                    .accessibilityLabel(formatValue(higherCandidate))
                    .accessibilityAddTraits(isHigherSelected ? .isSelected : [])
                } else {
                    Button {} label: {
                        Text("-")
                            .font(.ui(.footnote))
                            .frame(maxWidth: .infinity, minHeight: ui(44))
                            .background(Color(uiColor: .tertiarySystemFill).opacity(0.35), in: RoundedRectangle(cornerRadius: ui(8)))
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .opacity(0.3)
                }

                // Plus button
                Button {
                    let nextVal = min(maxValue, max(minValue, displayValue + stepUp))
                    onCommit(nextVal)
                } label: {
                    Text("+\(TrailerDurationMapping.formatStep(stepUp))")
                        .font(.ui(.footnote).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: ui(44))
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: ui(8)))
                }
                .buttonStyle(.plain)
                .disabled(!isControlEnabled || displayValue >= maxValue)
                .opacity((!isControlEnabled || displayValue >= maxValue) ? 0.35 : 1.0)
                .accessibilityLabel("\(TrailerDurationMapping.formatStep(stepUp)) 늘리기")
            }

            // Slider immediately below
            if isNonlinear {
                Slider(
                    value: Binding(
                        get: {
                            TrailerDurationMapping.position(value: displayValue, min: sliderMin, max: sliderMax)
                        },
                        set: { pos in
                            let val = TrailerDurationMapping.value(position: pos, min: sliderMin, max: sliderMax)
                            draggingValue = val
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            let finalVal = draggingValue ?? displayValue
                            draggingValue = nil
                            onCommit(finalVal)
                        }
                    }
                )
                .disabled(!isControlEnabled)
                .accessibilityLabel(title)
                .accessibilityValue(formatValue(displayValue))
                .accessibilityAdjustableAction { direction in
                    guard isControlEnabled else { return }
                    switch direction {
                    case .increment:
                        let step = TrailerDurationMapping.adaptiveStep(for: displayValue)
                        onCommit(min(maxValue, max(minValue, displayValue + step)))
                    case .decrement:
                        let step = TrailerDurationMapping.adaptiveStep(for: max(minValue, displayValue - 0.001))
                        onCommit(min(maxValue, max(minValue, displayValue - step)))
                    @unknown default:
                        break
                    }
                }
            } else {
                Slider(
                    value: Binding(
                        get: { displayValue },
                        set: { val in
                            let step = TrailerDurationMapping.adaptiveStep(for: val)
                            let snapped = min(sliderMax, max(sliderMin, (val / step).rounded() * step))
                            draggingValue = snapped
                        }
                    ),
                    in: sliderMin...sliderMax,
                    onEditingChanged: { editing in
                        if !editing {
                            let finalVal = draggingValue ?? displayValue
                            draggingValue = nil
                            onCommit(finalVal)
                        }
                    }
                )
                .disabled(!isControlEnabled)
                .accessibilityLabel(title)
                .accessibilityValue(formatValue(displayValue))
                .accessibilityAdjustableAction { direction in
                    guard isControlEnabled else { return }
                    switch direction {
                    case .increment:
                        let step = TrailerDurationMapping.adaptiveStep(for: displayValue)
                        onCommit(min(maxValue, max(minValue, displayValue + step)))
                    case .decrement:
                        let step = TrailerDurationMapping.adaptiveStep(for: max(minValue, displayValue - 0.001))
                        onCommit(min(maxValue, max(minValue, displayValue - step)))
                    @unknown default:
                        break
                    }
                }
            }

            if let explanation {
                Text(explanation)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Shape proportions, 32pt frame and selected outline imported from HanClip's AspectRatioIcon.
/// `ratio == nil` is 원본: a dashed 4:3 frame stands for "whatever the first video is".
private struct TrailerAspectRatioIcon: View {
    let ratio: OutputAspectRatio?
    let isSelected: Bool
    let label: String
    private var rectangleSize: CGSize {
        let size = ratio?.renderSize ?? CGSize(width: 4, height: 3)
        let aspect = size.width / size.height
        return aspect >= 1 ? CGSize(width: ui(30), height: ui(30) / aspect) : CGSize(width: ui(30) * aspect, height: ui(30))
    }
    var body: some View {
        VStack(spacing: ui(4)) {
            ZStack {
                RoundedRectangle(cornerRadius: ui(10)).fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                RoundedRectangle(cornerRadius: ui(3))
                    .stroke(isSelected ? Color.accentColor : Color.secondary, style: StrokeStyle(lineWidth: 2, dash: ratio == nil ? [ui(4), ui(3)] : []))
                    .frame(width: rectangleSize.width, height: rectangleSize.height)
            }
            .frame(width: ui(44), height: ui(44))
            .overlay {
                RoundedRectangle(cornerRadius: ui(10))
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.72), lineWidth: isSelected ? 2 : 1)
            }
            Text(label)
                .font(.ui(.caption).weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: ui(48), minHeight: ui(44))
        .contentShape(Rectangle())
    }
}

private struct TrailerSourceThumbnail: View {
    let source: VideoTrailerSource
    let number: Int
    @Binding var image: UIImage?
    var isRevealed: Bool
    var onTap: () -> Void
    var onRemove: () -> Void

    // The original filename's extension first, since the staged copy is just this run's
    // temporary working file; only when the name has none do we fall back to the
    // original content type's UTType, never the temp file's own path extension.
    private var imageExtensionLabel: String? {
        let nameExtension = (source.name as NSString).pathExtension
        if !nameExtension.isEmpty { return nameExtension.uppercased() }
        if let identifier = source.contentTypeIdentifier, let type = UTType(identifier),
           let typeExtension = type.preferredFilenameExtension {
            return typeExtension.uppercased()
        }
        return nil
    }

    var body: some View {
        // The square comes from this fill alone: a Color has no intrinsic size, so the
        // loaded image's own portrait/landscape shape can never stretch the cell. All
        // content is an overlay laid out in exactly those square bounds.
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                .allowsHitTesting(false)
                        } else {
                            Image(interfaceSystemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if isRevealed {
                            Color.black.opacity(0.35)
                            Button(action: onRemove) {
                                Image(interfaceSystemName: "trash.fill", pointSize: 16).font(.ui(.callout).weight(.semibold)).foregroundStyle(.white)
                                    .padding(ui(8)).background(.black.opacity(0.65), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("\(source.name) 이 예고편에서 제거")
                        }
                        if source.isImage, let label = imageExtensionLabel {
                            Text(label).font(.system(size: ui(9), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, ui(4)).padding(.vertical, ui(2))
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: ui(4)))
                                .padding(ui(5))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: ui(10)))
        .overlay(alignment: .topLeading) {
            // Drawn in its own overlay, above the clipped image/placeholder content,
            // so the source-order badge is never cropped by the thumbnail's own clipping.
            Text("\(number)").font(.ui(.caption).weight(.bold)).foregroundStyle(.white)
                .padding(ui(6)).background(.black.opacity(0.65), in: Circle()).padding(ui(5))
        }
        .contentShape(RoundedRectangle(cornerRadius: ui(10)))
        .onTapGesture(perform: onTap)
        .accessibilityLabel("\(number)번째 영상, \(source.name)")
        .accessibilityValue("원본 \(trailerDurationTitle(source.duration))")
        .accessibilityAction(named: "이 예고편에서 제거", onRemove)
        .task(id: source.id) {
            guard image == nil else { return }
            if source.isImage {
                if let loaded = await trailerThumbnailImage(at: source.url, maxPixelSize: 240), !Task.isCancelled { image = loaded }
                return
            }
            let asset = AVURLAsset(url: source.url)
            if #available(iOS 17, macOS 14, macCatalyst 17, *) {
                do {
                    let cgImage = try await RepresentativeVideoFrame.extract(
                        asset: asset, anchor: source.plan.analysis.peakTime,
                        appliesPreferredTrackTransform: true, maximumSize: CGSize(width: 240, height: 240))
                    if !Task.isCancelled { image = UIImage(cgImage: cgImage) }
                    return
                } catch is CancellationError {
                    // A cancelled helper request ends here; it never falls back to the
                    // plain generator below.
                    return
                } catch {
                    // Any other failure falls back to the existing single-frame path.
                }
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            do {
                let frame = try await generator.image(at: CMTime(seconds: source.plan.analysis.peakTime, preferredTimescale: 600))
                if !Task.isCancelled { image = UIImage(cgImage: frame.image) }
            } catch { }
        }
    }
}

@MainActor
final class VideoTrailerModel: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var sources: [VideoTrailerSource] = []
    @Published private(set) var scenes: [VideoTrailerScene] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var isSaved = false
    @Published private(set) var aspectRatio: OutputAspectRatio?
    /// Items whose image/video decode validation failed and were skipped without
    /// aborting the rest of the batch (e.g. a folder containing an undecodable clip).
    @Published private(set) var skippedCount = 0
    /// Offending items isolated via recursive bisect and recovered as still photo clips.
    @Published private(set) var recoveredCount = 0
    /// The exporter's own measured progress while the final joining runs, otherwise nil.
    /// Reaches 1 only after the export session reports completion.
    @Published private(set) var exportProgress: Double?
    /// Count of scene clips actually inserted into the composition so far, out of the
    /// actual count selected for this attempt. Never a fabricated/time-based estimate;
    /// reset to a fresh actual total on every start, retry, decode-exclusion pass and
    /// photo-render failure, and cleared on cancel/failure/cleanup.
    @Published private(set) var joinProgress: (completed: Int, total: Int)?
    /// The music mixed into the current output, nil for a plain one. Changes only
    /// together with `outputURL`, after a new export has been verified.
    @Published private(set) var music: TrailerMusicSelection?
    /// The current output's plan before any fitting to the music's length.
    @Published private(set) var baseScenes: [VideoTrailerScene] = []
    /// The sources are staged (and, for a trailer, analysed) and nothing has been joined,
    /// encoded or exported: that only starts when the user asks for it in the editor.
    @Published private(set) var isAwaitingSettings = false
    private var mode = VideoTrailerMode.trailer
    private var task: Task<Void, Never>?
    private var directory: URL?
    /// Measured loudness of each staged video's own sound, kept for the session.
    private var activityBySourceID: [Int: AudioActivityEnvelope] = [:]
    /// Session-owned copies of picked music, by PhoneHard record. The render only ever
    /// reads these, never the file in PhoneHard.
    private var musicSnapshots: [UUID: URL] = [:]
    /// Every item has been staged or skipped. False while they are still coming in, so a
    /// reopened editor fetches the rest instead of treating a part as the whole.
    private(set) var isStaged = false
    /// The running work was cancelled by `suspend`, not by `stop`: only what that one
    /// attempt made is removed.
    private(set) var isSuspending = false
    private var isSaving = false
    private var exporter: AVAssetExportSession?
    private var awakeActivityID: UUID?
    /// Ids removed from this trailer by the user; never re-downloaded or re-added,
    /// even though the originating item is still present in `items`.
    private var removedSourceIDs: Set<Int> = []
    /// Ids that failed decode validation in this workspace; a regeneration keeps the
    /// user's remaining selection sparse instead of staging and probing them again.
    private var skippedSourceIDs: Set<Int> = []
    /// Set once every staged photo's own quality/similarity scene duration has been
    /// measured, so a regenerate or reopen never re-decodes photos already scored.
    private var photoDurationsAnalyzed = false
    /// Staged videos whose highlight analysis really ran. A session opened as 뮤직비디오
    /// stages without it, so returning to 예고편 analyses the rest first.
    private var highlightAnalyzedIDs: Set<Int> = []
    /// Stable identity for this model in the log so cancel/cleanup/release lines can be
    /// matched with the run they belong to without naming any file.
    private let identity = String(UUID().uuidString.prefix(8))
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder",
        category: "video-trailer"
    )

    /// Measures every staged photo once (bounded-memory, on-device, no network) and sets
    /// each one's own `imageDurationRatio` from its quality rank among this batch's photos
    /// and how closely it resembles a better-ranked one. A photo that fails to decode here
    /// (already validated when staged, so this is never expected) keeps a neutral middle
    /// ratio rather than a fabricated score.
    private func applyPhotoDurationRatios() async throws {
        let imageSources = sources.filter(\.isImage)
        guard !imageSources.isEmpty else { return }
        let snapshot = imageSources.map { (id: $0.id, url: $0.url) }
        try Task.checkCancellation()
        // The measurement itself (quality/fingerprint decode plus the optional DINO
        // similarity AND-gate) never touches the main actor: only the finished ratio
        // dictionary comes back here, and only this one commit ever applies it.
        let handle = Task.detached(priority: .userInitiated) { () throws -> [Int: Double] in
            var measurements: [(id: Int, measurement: VideoTrailerPhotoQuality.Measurement?)] = []
            for item in snapshot {
                try Task.checkCancellation()
                measurements.append((item.id, await VideoTrailerPhotoQuality.measure(fileAt: item.url)))
            }
            try Task.checkCancellation()
            var dinoEmbeddings: [Int: [Float]]?
            if #available(iOS 17, macOS 14, macCatalyst 17, *) {
                dinoEmbeddings = try await VideoTrailerPhotoSimilarityGate.embeddings(for: snapshot)
            }
            try Task.checkCancellation()
            return VideoTrailerPhotoQuality.durationRatios(for: measurements, dinoEmbeddings: dinoEmbeddings)
        }
        let ratios = try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
        try Task.checkCancellation()
        // Commit only if the staged photo batch is still exactly what was measured; a
        // removal, retry restage or reorder-by-identity change in the meantime discards
        // this result rather than applying it to sources it no longer matches.
        let currentImageSources = sources.filter(\.isImage)
        let currentMap = Dictionary(uniqueKeysWithValues: currentImageSources.map { ($0.id, $0.url) })
        let snapshotMap = Dictionary(uniqueKeysWithValues: snapshot)
        guard currentMap == snapshotMap else { return }
        for index in sources.indices {
            if let ratio = ratios[sources[index].id] {
                sources[index].imageDurationRatio = ratio
                sources[index].imageDurationPolicyVersion = 2
            }
        }
    }

    static func imageCaptureDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let date = formatter.date(from: raw) {
            return date
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String, let date = formatter.date(from: raw) {
            return date
        }
        return nil
    }

    /// Counts and sizes only, so the failure log shows which of this run's own
    /// temporary files were still in place without naming any of them.
    static func workspaceState(directory: URL?, output: URL?, sources: [VideoTrailerSource]) -> String {
        let files = FileManager.default
        let missing = sources.filter { !files.fileExists(atPath: $0.url.path) }.count
        let bytes = output.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? -1
        return "workspace \(directory.map { files.fileExists(atPath: $0.path) ? 1 : 0 } ?? -1)"
            + " output \(output.map { files.fileExists(atPath: $0.path) ? 1 : 0 } ?? -1) bytes \(bytes)"
            + " staged \(sources.count) missing \(missing) app \(UIApplication.shared.applicationState.rawValue)"
    }

    var recommendedClipLength: Double { Self.recommendedLength(sources) }
    static func recommendedLength(_ sources: [VideoTrailerSource]) -> Double {
        // Photos never count, and a short video no longer shortens the common length.
        VideoTrailerBatchPlan.recommendedClipLength(sources)
    }

    private static let maximumItemsPerComposition = 15

    /// Only a failure that really points at one source's media may be bisected down to
    /// that source. Anything else (cancel, disk, permission, system/media services,
    /// encoder, or an error nobody classified) is rethrown so it is never mistaken for a
    /// bad item and silently dropped. A global cause anywhere in the chain wins over an
    /// outer media error.
    nonisolated private static func isBisectableSourceFailure(_ error: Error) -> Bool {
        var chain: [Error] = []
        var current: Error? = error
        while let link = current, chain.count < 8 {
            if link is CancellationError { return false }
            chain.append(link)
            current = (link as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        if chain.contains(where: isGlobalFailure) { return false }
        return chain.contains(where: isSourceMediaFailure)
    }

    nonisolated private static func isGlobalFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain:
            // Every filesystem or transport failure (missing/unreadable file, I/O error,
            // disk, permission, network) is infrastructure, never a bad source's media.
            return true
        case AVFoundationErrorDomain:
            return [-11878 /* AVErrorOperationCancelled */,
                    -11807 /* AVErrorDiskFull */,
                    -11819 /* AVErrorMediaServicesWereReset */,
                    -11847 /* AVErrorOperationInterrupted */,
                    -11835 /* AVErrorClientIsNotAuthorized */,
                    -11852 /* AVErrorClientIsNotAuthorizedToUseDevice */].contains(ns.code)
        default:
            return false
        }
    }

    nonisolated private static func isSourceMediaFailure(_ error: Error) -> Bool {
        if error is MediaError { return true }
        if let clipError = error as? VideoTrailerImageClip.ClipError { return clipError == .decodeFailed }
        let ns = error as NSError
        guard ns.domain == AVFoundationErrorDomain else { return false }
        return [-11821 /* AVErrorDecodeFailed */,
                -11822 /* AVErrorInvalidSourceMedia */,
                -11828 /* AVErrorFileFormatNotRecognized */,
                -11829 /* AVErrorFileFailedToParse */].contains(ns.code)
    }

    /// True when cancel, filesystem/transport, permission or system/media-services is
    /// anywhere in the chain.
    nonisolated private static func hasGlobalFailure(_ error: Error) -> Bool {
        errorChain(error).contains(where: isGlobalFailure)
    }

    nonisolated private static func errorChain(_ error: Error) -> [Error] {
        var chain: [Error] = []
        var current: Error? = error
        while let link = current, chain.count < 8 {
            chain.append(link)
            current = (link as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return chain
    }

    /// A frame request that only failed to produce an image for this media. Anything
    /// unknown, or with a global cause in its chain, is not ordinary and must be thrown.
    nonisolated private static func isOrdinaryFrameFailure(_ error: Error) -> Bool {
        let chain = errorChain(error)
        if chain.contains(where: isGlobalFailure) { return false }
        return chain.contains { link in
            if isSourceMediaFailure(link) { return true }
            let ns = link as NSError
            return ns.domain == AVFoundationErrorDomain
                && [-11832 /* AVErrorNoImageAtTime */,
                    -11833 /* AVErrorDecoderNotFound */].contains(ns.code)
        }
    }

    nonisolated private static func extractStillImage(
        source: VideoTrailerSource,
        at timeSeconds: Double,
        maxPixelSize: CGFloat = 1920
    ) async throws -> UIImage? {
        try Task.checkCancellation()
        if source.isImage {
            // A throwing read, so a missing or unreadable file propagates; only a readable
            // but undecodable image falls back to the thumbnail decode.
            let data = try Data(contentsOf: source.url, options: .mappedIfSafe)
            try Task.checkCancellation()
            if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
                return image
            }
            return await trailerThumbnailImage(at: source.url, maxPixelSize: maxPixelSize)
        }
        let asset = AVURLAsset(url: source.url)
        let anchorTime = (timeSeconds.isFinite && timeSeconds >= 0) ? timeSeconds : source.plan.analysis.peakTime
        if #available(iOS 17, macOS 14, macCatalyst 17, *) {
            do {
                let cgImage = try await RepresentativeVideoFrame.extract(
                    asset: asset,
                    anchor: anchorTime,
                    appliesPreferredTrackTransform: true,
                    maximumSize: CGSize(width: maxPixelSize, height: maxPixelSize)
                )
                return UIImage(cgImage: cgImage)
            } catch {
                // Only an ordinary frame/decode failure falls through to the generator.
                if hasGlobalFailure(error) { throw error }
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let requestedTime = CMTime(seconds: max(0, anchorTime), preferredTimescale: 600)
        do {
            let frame = try await generator.image(at: requestedTime)
            return UIImage(cgImage: frame.image)
        } catch {
            if !isOrdinaryFrameFailure(error) { throw error }
        }
        try Task.checkCancellation()
        do {
            let frame = try await generator.image(at: .zero)
            return UIImage(cgImage: frame.image)
        } catch {
            if !isOrdinaryFrameFailure(error) { throw error }
        }
        return nil
    }

    private func renderSceneGroup(
        scenes: [VideoTrailerScene],
        renderSize: CGSize,
        outputURL: URL,
        generationSeed: Int,
        sourceByID: [Int: VideoTrailerSource],
        directory: URL,
        attemptFiles: inout [URL],
        imageClipCache: inout [String: URL]
    ) async throws {
        try Task.checkCancellation()
        guard !scenes.isEmpty else { throw TrailerError.exportFailed }
        // Registered before anything is written, and removed again unless this attempt
        // finishes: a cancelled or failed group never leaves its output behind.
        attemptFiles.append(outputURL)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: outputURL) } }
        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TrailerError.exportUnavailable
        }
        let outputAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var originalVolumes: [(time: CMTime, volume: Float)] = []

        for segment in scenes {
            try Task.checkCancellation()
            guard let source = sourceByID[segment.sourceID] else { throw TrailerError.exportFailed }
            let naturalSize: CGSize
            let transform: CGAffineTransform
            let video: AVAssetTrack
            let asset: AVURLAsset
            if source.isImage {
                let photoRenderSize = Self.photoRenderSize(for: renderSize)
                let framing: VideoTrailerImageClip.Framing? = (segment.fitsFrame || segment.offsetX != 0 || segment.offsetY != 0)
                    ? .init(fitsFrame: segment.fitsFrame, offsetX: segment.offsetX, offsetY: segment.offsetY) : nil
                let framingKey = framing.map { "\($0.fitsFrame ? "fit" : "fill")\($0.offsetX),\($0.offsetY)" } ?? "auto"
                let cacheKey = "\(source.id):\(Int64((segment.length * 600).rounded())):\(Int(photoRenderSize.width))x\(Int(photoRenderSize.height)):\(framingKey)"
                let clipURL: URL
                if let cached = imageClipCache[cacheKey], FileManager.default.fileExists(atPath: cached.path) {
                    clipURL = cached
                } else {
                    clipURL = directory.appendingPathComponent("image-clip-\(segment.id)-\(UUID().uuidString).mov")
                    attemptFiles.append(clipURL)
                    let renderTask = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        try VideoTrailerImageClip.render(
                            imageURL: source.url,
                            duration: segment.length,
                            renderSize: photoRenderSize,
                            outputURL: clipURL,
                            seed: segment.id ^ generationSeed,
                            framing: framing
                        )
                    }
                    do {
                        try await withTaskCancellationHandler {
                            try await renderTask.value
                        } onCancel: {
                            renderTask.cancel()
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: clipURL)
                        throw error
                    }
                    imageClipCache[cacheKey] = clipURL
                }
                try Task.checkCancellation()
                asset = AVURLAsset(url: clipURL)
                guard let imageVideo = try await asset.loadTracks(withMediaType: .video).first else {
                    throw TrailerError.exportFailed
                }
                video = imageVideo
                naturalSize = photoRenderSize
                transform = CGAffineTransform(
                    scaleX: renderSize.width / photoRenderSize.width,
                    y: renderSize.height / photoRenderSize.height
                )
            } else {
                asset = AVURLAsset(url: source.url)
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MediaError.videoTrackUnavailable
                }
                video = videoTrack
                naturalSize = try await video.load(.naturalSize)
                transform = try await video.load(.preferredTransform)
            }
            guard naturalSize.width > 0, naturalSize.height > 0 else { throw TrailerError.exportUnavailable }
            let range = source.isImage
                ? CMTimeRange(start: .zero, duration: CMTime(seconds: segment.length, preferredTimescale: 600))
                : CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                              duration: CMTime(seconds: segment.length, preferredTimescale: 600))
            try outputVideo.insertTimeRange(range, of: video, at: cursor)
            if !source.isImage, !segment.muted, let audio = try await asset.loadTracks(withMediaType: .audio).first, let outputAudio,
               try await audio.load(.isDecodable) {
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if overlap.duration.seconds > 0 {
                    let audioStart = CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start))
                    try outputAudio.insertTimeRange(overlap, of: audio, at: audioStart)
                    originalVolumes.append((audioStart, Float(min(1, max(0, segment.volume)))))
                }
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
            layer.setTransform(source.isImage ? transform : (segment.fitsFrame
                ? TrailerOutputRenderer.aspectFitTransform(naturalSize: naturalSize, preferredTransform: transform, renderSize: renderSize)
                : TrailerOutputRenderer.aspectFillTransform(naturalSize: naturalSize, preferredTransform: transform, renderSize: renderSize,
                                                            offsetX: segment.offsetX, offsetY: segment.offsetY)), at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instruction.backgroundColor = UIColor.black.cgColor
            instructions.append(instruction)
            cursor = CMTimeAdd(cursor, range.duration)
        }

        if let outputAudio, outputAudio.segments.isEmpty { composition.removeTrack(outputAudio) }

        var audioMix: AVMutableAudioMix?
        let keepsOriginalTrack = outputAudio.map { !$0.segments.isEmpty } ?? false
        if keepsOriginalTrack, let outputAudio, originalVolumes.contains(where: { $0.volume != 1 }) {
            let originalParameters = AVMutableAudioMixInputParameters(track: outputAudio)
            for entry in originalVolumes { originalParameters.setVolume(entry.volume, at: entry.time) }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [originalParameters]
            audioMix = mix
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TrailerError.exportUnavailable
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false

        // Visible to `stop`/`suspend` while it runs; the cancellation handler also reaches
        // it when the task is cancelled by any other route.
        exporter = session
        defer { if exporter === session { exporter = nil } }
        nonisolated(unsafe) let cancelTarget = session
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            cancelTarget.cancelExport()
        }
        // A cancelled export reports its own error; it is always a cancellation here, never
        // a bad source.
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw session.error ?? TrailerError.exportFailed
        }
        finished = true
    }

    private func recoverFailedGroup(
        scenes: [VideoTrailerScene],
        renderSize: CGSize,
        generationSeed: Int,
        sourceByID: [Int: VideoTrailerSource],
        directory: URL,
        intermediateFiles: inout [URL],
        attemptFiles: inout [URL],
        imageClipCache: inout [String: URL]
    ) async throws -> [TrailerRenderedClip] {
        try Task.checkCancellation()
        guard !scenes.isEmpty else { return [] }

        if scenes.count > 1 {
            let mid = scenes.count / 2
            let leftScenes = Array(scenes[0..<mid])
            let rightScenes = Array(scenes[mid..<scenes.count])

            var leftClips: [TrailerRenderedClip] = []
            let leftURL = directory.appendingPathComponent("chunk-left-\(UUID().uuidString).mp4")
            do {
                try await renderSceneGroup(
                    scenes: leftScenes,
                    renderSize: renderSize,
                    outputURL: leftURL,
                    generationSeed: generationSeed,
                    sourceByID: sourceByID,
                    directory: directory,
                    attemptFiles: &attemptFiles,
                    imageClipCache: &imageClipCache
                )
                leftClips = [TrailerRenderedClip(url: leftURL, scenes: leftScenes, hasOriginalSound: true)]
                intermediateFiles.append(leftURL)
            } catch {
                guard Self.isBisectableSourceFailure(error) else { throw error }
                leftClips = try await recoverFailedGroup(
                    scenes: leftScenes,
                    renderSize: renderSize,
                    generationSeed: generationSeed,
                    sourceByID: sourceByID,
                    directory: directory,
                    intermediateFiles: &intermediateFiles,
                    attemptFiles: &attemptFiles,
                    imageClipCache: &imageClipCache
                )
            }

            var rightClips: [TrailerRenderedClip] = []
            let rightURL = directory.appendingPathComponent("chunk-right-\(UUID().uuidString).mp4")
            do {
                try await renderSceneGroup(
                    scenes: rightScenes,
                    renderSize: renderSize,
                    outputURL: rightURL,
                    generationSeed: generationSeed,
                    sourceByID: sourceByID,
                    directory: directory,
                    attemptFiles: &attemptFiles,
                    imageClipCache: &imageClipCache
                )
                rightClips = [TrailerRenderedClip(url: rightURL, scenes: rightScenes, hasOriginalSound: true)]
                intermediateFiles.append(rightURL)
            } catch {
                guard Self.isBisectableSourceFailure(error) else { throw error }
                rightClips = try await recoverFailedGroup(
                    scenes: rightScenes,
                    renderSize: renderSize,
                    generationSeed: generationSeed,
                    sourceByID: sourceByID,
                    directory: directory,
                    intermediateFiles: &intermediateFiles,
                    attemptFiles: &attemptFiles,
                    imageClipCache: &imageClipCache
                )
            }

            return leftClips + rightClips
        }

        // Singleton offending item isolation
        let singleton = scenes[0]
        guard let source = sourceByID[singleton.sourceID] else {
            if skippedSourceIDs.insert(singleton.sourceID).inserted { skippedCount += 1 }
            return []
        }

        Self.logger.notice("trailer isolating singleton source \(source.id, privacy: .public) scene \(singleton.id, privacy: .public)")

        if let stillImage = try await Self.extractStillImage(source: source, at: singleton.start),
           let jpegData = stillImage.jpegData(compressionQuality: 0.85) {
            let stillURL = directory.appendingPathComponent("recovered-still-\(singleton.id)-\(UUID().uuidString).jpg")
            let recoveredClipURL = directory.appendingPathComponent("recovered-chunk-\(singleton.id)-\(UUID().uuidString).mp4")
            // Registered before they are written, so a failure part-way still removes them.
            attemptFiles.append(stillURL)
            do {
                try Task.checkCancellation()
                try jpegData.write(to: stillURL)
                let recoveredSource = VideoTrailerSource(
                    id: source.id,
                    name: source.name,
                    url: stillURL,
                    plan: source.plan,
                    isImage: true,
                    contentTypeIdentifier: "public.jpeg",
                    captureDate: source.captureDate,
                    imageDurationRatio: source.imageDurationRatio,
                    imageDurationPolicyVersion: source.imageDurationPolicyVersion
                )
                // Only this one scene sees the still; the source keeps its own entry, so
                // other ranges of the same video are rendered from the video as before.
                var singletonSources = sourceByID
                singletonSources[source.id] = recoveredSource
                var singletonCache: [String: URL] = [:]
                try await renderSceneGroup(
                    scenes: [singleton],
                    renderSize: renderSize,
                    outputURL: recoveredClipURL,
                    generationSeed: generationSeed,
                    sourceByID: singletonSources,
                    directory: directory,
                    attemptFiles: &attemptFiles,
                    imageClipCache: &singletonCache
                )
                recoveredCount += 1
                intermediateFiles.append(recoveredClipURL)
                Self.logger.notice("trailer source \(source.id, privacy: .public) recovered as still clip")
                return [TrailerRenderedClip(url: recoveredClipURL, scenes: [singleton], hasOriginalSound: false)]
            } catch {
                try? FileManager.default.removeItem(at: stillURL)
                guard Self.isBisectableSourceFailure(error) else { throw error }
                Self.logger.error("trailer source \(source.id, privacy: .public) still render failed: \(trailerErrorChain(error), privacy: .public)")
            }
        }

        // A still that could not be extracted because the work was cancelled is not a skip.
        try Task.checkCancellation()
        Self.logger.error("trailer source \(source.id, privacy: .public) skipped: no safe still available")
        if skippedSourceIDs.insert(source.id).inserted { skippedCount += 1 }
        return []
    }

    /// 60% of the final render size for the temporary Ken Burns photo clip, kept even
    /// and at least 2px per side so the encoder and composition transform stay well-formed.
    static func photoRenderSize(for renderSize: CGSize) -> CGSize {
        func scaled(_ value: CGFloat) -> CGFloat {
            max(2, (value * 0.6 / 2).rounded() * 2)
        }
        return CGSize(width: scaled(renderSize.width), height: scaled(renderSize.height))
    }

    deinit {
        // Only this model's own workspace folder is ever removed here; originals and
        // the download cache are never touched. A running task retains the model, so
        // this cannot run while an export is in flight.
        let hadWorkspace = directory.map { FileManager.default.fileExists(atPath: $0.path) ? 1 : 0 } ?? -1
        let identity = self.identity
        Self.logger.notice("trailer model \(identity, privacy: .public) released: workspace \(hadWorkspace, privacy: .public)")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The plan rules the next generation uses; nothing staged or exported changes.
    func useMode(_ next: VideoTrailerMode) {
        guard !isBusy else { return }
        mode = next
    }

    /// Runs the real highlight analysis (video sound peaks, photo scene lengths) for staged
    /// sources that have none yet, then reports whether it had anything to do. Cancelled by
    /// `stop`/`suspend` like any other work, and `done` is not called then.
    func analyzeHighlights(done: @escaping (Bool) -> Void) {
        guard !isBusy else { return }
        let pending = sources.filter { !$0.isImage && !highlightAnalyzedIDs.contains($0.id) }
        let needsPhotos = !photoDurationsAnalyzed && sources.contains(where: \.isImage)
        guard !pending.isEmpty || needsPhotos else { mode = .trailer; done(false); return }
        isBusy = true
        error = nil
        task = Task {
            defer { isBusy = false; isSuspending = false; task = nil }
            do {
                for (position, source) in pending.enumerated() {
                    status = "\(position + 1)/\(pending.count) · 한양이 장면을 고르는 중…"
                    let buckets = max(192, min(2048, Int(min(1024, source.duration) * 2)))
                    let analysis = try await AudioAnalysisService.analyze(url: source.url, bucketCount: buckets)
                    try Task.checkCancellation()
                    if let index = sources.firstIndex(where: { $0.id == source.id }) {
                        sources[index] = VideoTrailerSource(id: source.id, name: source.name, url: source.url,
                            plan: VideoTrailerPlan(analysis: analysis, duration: source.duration),
                            isImage: false, contentTypeIdentifier: source.contentTypeIdentifier,
                            captureDate: source.captureDate, imageDurationRatio: source.imageDurationRatio,
                            imageDurationPolicyVersion: source.imageDurationPolicyVersion)
                    }
                    highlightAnalyzedIDs.insert(source.id)
                }
                if needsPhotos {
                    status = "사진을 준비하는 중…"
                    try await applyPhotoDurationRatios()
                    photoDurationsAnalyzed = true
                }
                try Task.checkCancellation()
                status = "영상 편집에서 만들기를 누르면 예고편을 만듭니다."
                mode = .trailer
                done(true)
            } catch is CancellationError {
                if !isSuspending { cleanup(reason: "cancelled during analysis") }
            } catch {
                Self.logger.error("trailer highlight analysis failed: \(trailerErrorChain(error), privacy: .public)")
                self.error = "한양이 장면을 고르지 못했습니다. 다시 시도해 주세요."
            }
        }
    }

    /// Without `generate` this only stages what is not staged yet and stops before any
    /// clip is joined; the video itself is made only on the user's explicit request.
    func start(items: [RemoteFileItem], service: any RemoteFileService, mode: VideoTrailerMode = .trailer,
               generate: Bool = false, sourceOrder: [Int]? = nil, total: Double? = nil,
               clipLength: Double? = nil, aspectRatio: OutputAspectRatio? = nil,
               music: TrailerMusicSelection? = nil, keepsInputOrder: Bool = false,
               manualScenes: [TrailerEditScene]? = nil, draftSources: [VideoTrailerSource]? = nil) {
        guard !isBusy, !items.isEmpty else { return }
        let total = total.map { $0.isFinite ? min(VideoTrailerBatchPlan.maximumRequestedDuration, max(1, $0)) : 1 }
        self.mode = mode
        isAwaitingSettings = false
        if let sourceOrder {
            // A thumbnail removed in the adjustment sheet leaves this trailer for good:
            // drop it from the active source list (and its staged copy, which is this
            // run's own file) so the retained subset is what gets ordered and planned.
            let kept = Set(sourceOrder)
            let dropped = sources.filter { !kept.contains($0.id) }
            removedSourceIDs.formUnion(dropped.map(\.id))
            sources.removeAll { !kept.contains($0.id) }
            for source in dropped { try? FileManager.default.removeItem(at: source.url) }
        }
        isBusy = true
        error = nil
        exportProgress = nil
        joinProgress = nil
        task = Task {
            // Fresh per generation so repeated regenerates of the same scenes don't
            // reproduce the exact same zoom direction/focal point every time; the
            // per-clip seed derived from it still stays fixed for the whole clip.
            let generationSeed = Int.random(in: Int.min...Int.max)
            let activityID = UUID()
            awakeActivityID = activityID
            ScreenAwakeController.shared.beginActivity(activityID)
            defer {
                ScreenAwakeController.shared.finishActivity(activityID)
                awakeActivityID = nil
                exportProgress = nil
                joinProgress = nil
                isBusy = false
                isSuspending = false
                task = nil
            }
            // Where the run stopped and what it was working on, for the failure log only.
            var stage = "download"
            var layout = ""
            var diagnostic = TrailerFailureDiagnostic(mode: mode == .mediaMusic ? "mediaMusic" : "trailer")
            var exportOutput: URL?
            // Photo clips rendered for the attempt in progress; never an input or an output.
            var attemptFiles: [URL] = []
            // Recoveries belong to one generation; they are counted afresh every time.
            recoveredCount = 0
            do {
                if directory == nil {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NasFinderTrailer-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    directory = folder
                    skippedCount = 0
                    recoveredCount = 0
                    skippedSourceIDs = []
                    Self.logger.notice("trailer model \(self.identity, privacy: .public) workspace created: items \(items.count, privacy: .public)")
                }
                guard let directory else { throw TrailerError.exportFailed }
                for (index, item) in items.enumerated()
                where !sources.contains(where: { $0.id == index }) && !removedSourceIDs.contains(index)
                    && !skippedSourceIDs.contains(index) {
                    status = "\(index + 1)/\(items.count) · \(item.isImage ? "사진을 받는 중…" : "영상을 받는 중…")"
                    await DownloadCache.shared.protect(item)
                    let staged: URL
                    do {
                        let downloaded = try await service.download(item)
                        try Task.checkCancellation()
                        staged = directory.appendingPathComponent("source-\(UUID().uuidString)")
                            .appendingPathExtension(downloaded.pathExtension)
                        try await Task.detached(priority: .userInitiated) {
                            try FileManager.default.copyItem(at: downloaded, to: staged)
                        }.value
                        try Task.checkCancellation()
                    } catch {
                        await DownloadCache.shared.release(item)
                        throw error
                    }
                    await DownloadCache.shared.release(item)
                    var step = item.isImage ? "photo-decode" : "probe"
                    do {
                        if item.isImage {
                            _ = try VideoTrailerImageClip.imageSize(at: staged)
                            let analysis = AudioAnalysisResult(waveform: [], peakTime: 0, highlightSource: .fallback)
                            let captureDate = Self.imageCaptureDate(at: staged) ?? item.modifiedAt
                            sources.append(VideoTrailerSource(id: index, name: item.name, url: staged,
                                plan: VideoTrailerPlan(analysis: analysis, duration: trailerImageNominalDuration),
                                isImage: true, contentTypeIdentifier: item.contentTypeIdentifier, captureDate: captureDate))
                            continue
                        }
                        let asset = AVURLAsset(url: staged)
                        let duration = try await asset.load(.duration).seconds
                        // The export validates every composition track before rendering, so a
                        // video this device cannot decode would fail the whole trailer there.
                        guard duration.isFinite, duration > 0,
                              let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
                              try await videoTrack.load(.isDecodable) else {
                            throw MediaError.videoTrackUnavailable
                        }
                        let analysis: AudioAnalysisResult
                        if mode == .mediaMusic {
                            // Whole videos are used as they are, so no scene is picked here.
                            analysis = AudioAnalysisResult(waveform: [], peakTime: 0, highlightSource: .fallback)
                        } else {
                            status = "\(index + 1)/\(items.count) · 한양이 장면을 고르는 중…"
                            step = "audio-analysis"
                            let buckets = max(192, min(2048, Int(min(1024, duration) * 2)))
                            analysis = try await AudioAnalysisService.analyze(url: staged, bucketCount: buckets)
                            try Task.checkCancellation()
                            highlightAnalyzedIDs.insert(index)
                        }
                        let captureDate = (try? await asset.load(.creationDate))?.dateValue ?? item.modifiedAt
                        sources.append(VideoTrailerSource(id: index, name: item.name, url: staged,
                            plan: VideoTrailerPlan(analysis: analysis, duration: duration), captureDate: captureDate))
                    } catch is CancellationError {
                        try? FileManager.default.removeItem(at: staged)
                        throw CancellationError()
                    } catch {
                        // Decode/track validation failed for this one item only; skip it and
                        // keep processing the rest of the batch instead of aborting everything.
                        try? FileManager.default.removeItem(at: staged)
                        skippedCount += 1
                        skippedSourceIDs.insert(index)
                        Self.logger.error("trailer source \(index, privacy: .public) skipped at \(step, privacy: .public): \(trailerErrorChain(error), privacy: .public) type \(staged.pathExtension.lowercased(), privacy: .public)")
                    }
                }
                guard !sources.isEmpty else { throw TrailerError.noUsableSources }
                if mode == .trailer, !photoDurationsAnalyzed, sources.contains(where: \.isImage) {
                    stage = "photo-quality"
                    status = "사진을 준비하는 중…"
                    try await applyPhotoDurationRatios()
                }
                if mode == .trailer { photoDurationsAnalyzed = true }
                isStaged = true
                stage = "plan"
                if let draftSources {
                    sources = TrailerSceneEditor.reconcileSources(draftSources: draftSources, stagedSources: sources)
                }
                if let sourceOrder {
                    // The requested order is the exact retained subset: ids are sparse after
                    // unsupported skips and removals, so only membership and uniqueness matter.
                    let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                    guard Set(sourceOrder).count == sourceOrder.count else { throw TrailerError.exportFailed }
                    let ordered = sourceOrder.compactMap { byID[$0] }
                    guard ordered.count == sourceOrder.count, !ordered.isEmpty else {
                        Self.logger.error("trailer model \(self.identity, privacy: .public) order mismatch: requested \(sourceOrder.count, privacy: .public) available \(ordered.count, privacy: .public) staged \(self.sources.count, privacy: .public)")
                        throw TrailerError.exportFailed
                    }
                    sources = ordered
                } else {
                    // Source ids are the caller's item indices: a new edit starts in the added
                    // (selection) order; 시간순/가나다순/랜덤 are explicit choices in the editor.
                    sources.sort { $0.id < $1.id }
                }
                if !generate || (mode == .mediaMusic && music == nil) {
                    status = mode == .mediaMusic ? "음악을 고르면 영상을 만듭니다."
                        : "예고편 조절에서 만들기를 누르면 예고편을 만듭니다."
                    isAwaitingSettings = true
                    return
                }
                // The asset is held here on purpose: a track only refers to its asset
                // weakly, and this one is used again long after it was loaded.
                var musicInput: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
                if let music {
                    stage = "music"
                    status = "음악을 확인하는 중…"
                    do {
                        let snapshot: URL
                        if let existing = musicSnapshots[music.recordID], FileManager.default.fileExists(atPath: existing.path) {
                            snapshot = existing
                        } else {
                            let original = music.url
                            let copy = directory.appendingPathComponent("music-\(UUID().uuidString)")
                                .appendingPathExtension(original.pathExtension)
                            try await Task.detached(priority: .userInitiated) {
                                try FileManager.default.copyItem(at: original, to: copy)
                            }.value
                            try Task.checkCancellation()
                            musicSnapshots[music.recordID] = copy
                            snapshot = copy
                        }
                        // Recognized as audio by name is not enough: the track must actually
                        // decode here and report a real length.
                        // Precise timing, as AVFoundation asks for an asset that goes into a
                        // composition: without it a format with no sample table (MP3) may
                        // report an estimated range, and that range is what gets inserted.
                        let musicAsset = AVURLAsset(url: snapshot, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        guard let track = try await musicAsset.loadTracks(withMediaType: .audio).first,
                              try await track.load(.isDecodable) else { throw TrailerMusicError.unreadable }
                        let range = try await track.load(.timeRange)
                        // Identifiers for the failure record only; not being able to read
                        // them does not make the music unusable.
                        let formatID = (try? await track.load(.formatDescriptions))?.first
                            .map { trailerFourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
                        let fileExtension = String(snapshot.pathExtension.lowercased()
                            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
                        diagnostic.music = TrailerFailureDiagnostic.Music(fileExtension: fileExtension, formatID: formatID,
                            naturalTimeScale: (try? await track.load(.naturalTimeScale)) ?? 0,
                            rangeStartValue: range.start.value, rangeStartTimescale: range.start.timescale,
                            rangeDurationValue: range.duration.value, rangeDurationTimescale: range.duration.timescale,
                            policy: music.policy == .fitMusic && music.fitCount > 1
                                ? "\(music.policy.rawValue) x\(music.fitCount)" : music.policy.rawValue)
                        try TrailerMusic.validate(duration: range.duration.seconds)
                        musicInput = (musicAsset, track, range)
                    } catch let error as TrailerMusicError {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Self.logger.error("trailer music unusable: \(trailerErrorChain(error), privacy: .public)")
                        diagnostic.wrappedErrorChain = trailerErrorChain(error)
                        throw TrailerMusicError.unreadable
                    }
                }
                var selected: [VideoTrailerScene] = []
                var baseSelected: [VideoTrailerScene] = []
                var cursor = CMTime.zero
                // Every pass either exports or excludes at least one source that failed an
                stage = "plan"
                // `manualScenes` is a value copy taken when this render began, so edits made
                // while it runs only affect the next one.
                baseSelected = TrailerPreparedPlan.base(mode: mode, sources: sources, total: total,
                    clipLength: clipLength ?? recommendedClipLength, manual: manualScenes)
                guard !baseSelected.isEmpty else { throw TrailerError.exportFailed }
                if let music, let musicInput, music.policy == .fitMusic {
                    // Same ordered scenes, repeated or cut at the end to the music's length
                    // laid end to end `fitCount` times; the music loop below fills the same.
                    guard let fitted = VideoTrailerBatchPlan.fitted(baseSelected,
                        to: musicInput.range.duration.seconds * Double(max(1, music.fitCount))) else {
                        throw TrailerMusicError.tooManyRepeats
                    }
                    selected = fitted
                } else {
                    selected = baseSelected
                }
                    if musicInput != nil {
                        // Reads each video's own decoded sound on this device, only to know
                        // where it is audible; this is not scene picking.
                        stage = "audio-activity"
                        let unmeasured = sources.filter { source in
                            !source.isImage && activityBySourceID[source.id] == nil
                                && selected.contains { $0.sourceID == source.id }
                        }
                        for (index, source) in unmeasured.enumerated() {
                            status = "원본 소리를 확인하는 중 · \(index + 1)/\(unmeasured.count)개"
                            do {
                                activityBySourceID[source.id] = try await AudioAnalysisService.activityEnvelope(url: source.url)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // Left unmeasured: its sound then counts as audible throughout.
                                Self.logger.error("trailer source \(source.id, privacy: .public) sound not measured: \(trailerErrorChain(error), privacy: .public)")
                            }
                            try Task.checkCancellation()
                        }
                    }
                let currentSourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                var renderSize = aspectRatio?.renderSize
                if renderSize == nil,
                   let firstVideo = selected.lazy.compactMap({ currentSourceByID[$0.sourceID] }).first(where: { !$0.isImage }) {
                    guard let size = try await trailerOrientedVideoSize(url: firstVideo.url) else { throw MediaError.videoTrackUnavailable }
                    renderSize = OutputAspectRatio.renderSize(for: size)
                }
                if renderSize == nil,
                   let firstImage = selected.lazy.compactMap({ currentSourceByID[$0.sourceID] }).first(where: { $0.isImage }) {
                    let imageSize = try VideoTrailerImageClip.imageSize(at: firstImage.url)
                    renderSize = OutputAspectRatio.renderSize(for: imageSize)
                }
                guard let renderSize else { throw TrailerError.exportUnavailable }

                stage = "chunk-render"
                layout = "sources \(sources.count) skipped \(skippedCount) segments \(selected.count)"
                diagnostic.segments = selected.count

                var sceneChunks: [[VideoTrailerScene]] = []
                var chunkStart = 0
                while chunkStart < selected.count {
                    let chunkEnd = min(chunkStart + Self.maximumItemsPerComposition, selected.count)
                    sceneChunks.append(Array(selected[chunkStart..<chunkEnd]))
                    chunkStart = chunkEnd
                }

                var intermediateClips: [TrailerRenderedClip] = []
                var intermediateFiles: [URL] = []
                var imageClipCache: [String: URL] = [:]
                var processedScenesCount = 0
                joinProgress = (0, selected.count)
                status = "클립 연결 중 · 0/\(selected.count)개"

                for (chunkIndex, chunkScenes) in sceneChunks.enumerated() {
                    try Task.checkCancellation()
                    let chunkURL = directory.appendingPathComponent("chunk-\(chunkIndex)-\(UUID().uuidString).mp4")
                    do {
                        try await renderSceneGroup(
                            scenes: chunkScenes,
                            renderSize: renderSize,
                            outputURL: chunkURL,
                            generationSeed: generationSeed,
                            sourceByID: currentSourceByID,
                            directory: directory,
                            attemptFiles: &attemptFiles,
                            imageClipCache: &imageClipCache
                        )
                        intermediateClips.append(TrailerRenderedClip(url: chunkURL, scenes: chunkScenes, hasOriginalSound: true))
                        intermediateFiles.append(chunkURL)
                        processedScenesCount += chunkScenes.count
                        joinProgress = (processedScenesCount, selected.count)
                        status = "클립 연결 중 · \(processedScenesCount)/\(selected.count)개"
                    } catch {
                        guard Self.isBisectableSourceFailure(error) else { throw error }
                        status = "풀 수 없는 장면을 찾는 중…"
                        let recovered = try await recoverFailedGroup(
                            scenes: chunkScenes,
                            renderSize: renderSize,
                            generationSeed: generationSeed,
                            sourceByID: currentSourceByID,
                            directory: directory,
                            intermediateFiles: &intermediateFiles,
                            attemptFiles: &attemptFiles,
                            imageClipCache: &imageClipCache
                        )
                        guard !recovered.isEmpty else {
                            processedScenesCount += chunkScenes.count
                            joinProgress = (processedScenesCount, selected.count)
                            continue
                        }
                        intermediateClips.append(contentsOf: recovered)
                        processedScenesCount += chunkScenes.count
                        joinProgress = (processedScenesCount, selected.count)
                        status = "클립 연결 중 · \(processedScenesCount)/\(selected.count)개"
                    }
                }

                guard !intermediateClips.isEmpty else { throw TrailerError.noUsableSources }

                stage = "compose-final"
                let finalComposition = AVMutableComposition()
                guard let finalVideoTrack = finalComposition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw TrailerError.exportUnavailable
                }
                let finalAudioTrack = finalComposition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                var finalCursor = CMTime.zero
                var intermediateAssets: [AVURLAsset] = []
                // Built from the scenes that really made it into the output, in order, so a
                // skipped scene never shifts the ducking and a still stand-in has no sound.
                var originalSound: [TrailerMusicDucking.Clip] = []

                for rendered in intermediateClips {
                    try Task.checkCancellation()
                    let asset = AVURLAsset(url: rendered.url)
                    intermediateAssets.append(asset)
                    // These are this attempt's own intermediates: one that cannot be read is a
                    // failure to report, never a clip to drop quietly.
                    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                        throw TrailerError.intermediateInvalid
                    }
                    let duration = try await asset.load(.duration)
                    guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                        throw TrailerError.intermediateInvalid
                    }
                    let timeRange = CMTimeRange(start: .zero, duration: duration)
                    try finalVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: finalCursor)
                    if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
                       try await audioTrack.load(.isDecodable),
                       let finalAudioTrack {
                        let audioRange = try await audioTrack.load(.timeRange)
                        let overlap = CMTimeRangeGetIntersection(timeRange, otherRange: audioRange)
                        if overlap.duration.seconds > 0 {
                            let audioStart = CMTimeAdd(finalCursor, CMTimeSubtract(overlap.start, timeRange.start))
                            try finalAudioTrack.insertTimeRange(overlap, of: audioTrack, at: audioStart)
                        }
                    }
                    if rendered.hasOriginalSound {
                        var sceneStart = finalCursor.seconds
                        for segment in rendered.scenes {
                            if let source = currentSourceByID[segment.sourceID], !source.isImage, !segment.muted {
                                originalSound.append(TrailerMusicDucking.Clip(
                                    outputStart: sceneStart,
                                    sourceStart: segment.start,
                                    length: segment.length,
                                    envelope: activityBySourceID[source.id]
                                ))
                            }
                            sceneStart += segment.length
                        }
                    }
                    finalCursor = CMTimeAdd(finalCursor, duration)
                }

                guard finalCursor.seconds > 0 else { throw TrailerError.noUsableSources }
                cursor = finalCursor

                if let finalAudioTrack, finalAudioTrack.segments.isEmpty {
                    finalComposition.removeTrack(finalAudioTrack)
                }

                var audioMix: AVMutableAudioMix?
                if let musicInput {
                    stage = "music"
                    guard let musicTrack = finalComposition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else {
                        throw TrailerError.exportUnavailable
                    }
                    var musicCursor = CMTime.zero
                    var pieces = 0
                    let playsOnce = music?.policy == .single
                    while CMTimeCompare(musicCursor, finalCursor) < 0, !(playsOnce && pieces == 1) {
                        pieces += 1
                        guard pieces <= TrailerMusic.maximumRepeats else { throw TrailerMusicError.tooManyRepeats }
                        let piece = CMTimeMinimum(musicInput.range.duration, CMTimeSubtract(finalCursor, musicCursor))
                        try musicTrack.insertTimeRange(
                            CMTimeRange(start: musicInput.range.start, duration: piece),
                            of: musicInput.track,
                            at: musicCursor
                        )
                        musicCursor = CMTimeAdd(musicCursor, piece)
                        diagnostic.music?.pieces = pieces
                    }
                    let parameters = AVMutableAudioMixInputParameters(track: musicTrack)
                    let ramps = TrailerMusicDucking.ramps(clips: originalSound, total: musicCursor.seconds, enabled: music?.autoDuck ?? true)
                    for ramp in ramps {
                        let rampStart = CMTime(seconds: ramp.start, preferredTimescale: 600)
                        let rampEnd = CMTime(seconds: ramp.end, preferredTimescale: 600)
                        guard CMTimeCompare(rampStart, rampEnd) < 0 else { continue }
                        parameters.setVolumeRamp(
                            fromStartVolume: ramp.from * Float(min(1, max(0, music?.level ?? 1))),
                            toEndVolume: ramp.to * Float(min(1, max(0, music?.level ?? 1))),
                            timeRange: CMTimeRange(start: rampStart, end: rampEnd)
                        )
                    }
                    let musicLevel = Float(min(1, max(0, music?.level ?? 1)))
                    if music?.autoDuck == false {
                        parameters.setVolume(TrailerMusicDucking.loudVolume * musicLevel, at: .zero)
                    } else if ramps.isEmpty, musicLevel != 1 {
                        parameters.setVolume(musicLevel, at: .zero)
                    }
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [parameters]
                    audioMix = mix
                    layout += " music \(pieces) ducked \(ramps.count)"
                    diagnostic.music?.ducked = ramps.count
                }

                let finalVideoComposition = AVMutableVideoComposition()
                finalVideoComposition.renderSize = renderSize
                finalVideoComposition.frameDuration = CMTime(value: 1, timescale: 30)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: finalCursor)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: finalVideoTrack)
                instruction.layerInstructions = [layerInstruction]
                instruction.backgroundColor = UIColor.black.cgColor
                finalVideoComposition.instructions = [instruction]

                let output = directory.appendingPathComponent("trailer-\(UUID().uuidString).mp4")
                stage = "export"
                layout += " tracks \(finalComposition.tracks.count) render \(Int(renderSize.width))x\(Int(renderSize.height)) seconds \(Int(finalCursor.seconds))"
                diagnostic.tracks = finalComposition.tracks.count
                diagnostic.renderWidth = Int(renderSize.width)
                diagnostic.renderHeight = Int(renderSize.height)
                diagnostic.outputSeconds = finalCursor.seconds
                exportOutput = output

                guard FileManager.default.fileExists(atPath: directory.path) else { throw TrailerError.outputMissing }
                Self.logger.notice("trailer model \(self.identity, privacy: .public) export start: \(layout, privacy: .public) app \(UIApplication.shared.applicationState.rawValue, privacy: .public)")

                guard let session = AVAssetExportSession(
                    asset: finalComposition,
                    presetName: AVAssetExportPresetHighestQuality
                ) else {
                    throw TrailerError.exportUnavailable
                }
                session.videoComposition = finalVideoComposition
                session.audioMix = audioMix
                session.outputURL = output
                session.outputFileType = .mp4
                session.shouldOptimizeForNetworkUse = true
                status = "클립 연결 \(selected.count)/\(selected.count)개 · 영상으로 저장 중"
                exporter = session
                exportProgress = 0

                let progressTask = Task {
                    while !Task.isCancelled {
                        exportProgress = min(0.99, Double(session.progress))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                nonisolated(unsafe) let cancelTarget = session
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        session.exportAsynchronously { continuation.resume() }
                    }
                } onCancel: {
                    cancelTarget.cancelExport()
                }
                progressTask.cancel()
                withExtendedLifetime(musicInput?.asset) { }
                withExtendedLifetime(intermediateAssets) { }
                try Task.checkCancellation()
                guard session.status == .completed else {
                    exporter = nil
                    exportProgress = nil
                    let failure = session.error ?? TrailerError.exportFailed
                    Self.logger.error("trailer final export failed: \(trailerErrorChain(failure), privacy: .public)")
                    try? FileManager.default.removeItem(at: output)
                    exportOutput = nil
                    throw failure
                }
                exporter = nil
                exportProgress = 1
                for file in intermediateFiles { try? FileManager.default.removeItem(at: file) }
                guard let output = exportOutput else { throw TrailerError.exportFailed }
                Self.logger.notice("trailer model \(self.identity, privacy: .public) export completed: \(Self.workspaceState(directory: directory, output: output, sources: self.sources), privacy: .public)")
                stage = "verify"
                // A finished export whose file is no longer at its path cannot be opened at all
                // (AVFoundationErrorDomain -11800 / -17913); report that instead of a bare code.
                guard FileManager.default.fileExists(atPath: output.path) else { throw TrailerError.outputMissing }
                let outputAsset = AVURLAsset(url: output)
                guard try await outputAsset.load(.isPlayable) else { throw TrailerError.exportFailed }
                // Cancelled while verifying: nothing is published.
                try Task.checkCancellation()
                let workspace = Self.workspaceState(directory: directory, output: output, sources: sources)
                Self.logger.notice("trailer exported: \(layout, privacy: .public) \(workspace, privacy: .public)")
                guard SharedMediaAudioSession.activatePlayback() else { throw TrailerError.exportFailed }
                // The only place the session's output changes: the previous file keeps
                // playing until this verified one has replaced it, and is removed after.
                let previousOutput = outputURL
                outputURL = output
                isSaved = false
                self.aspectRatio = aspectRatio
                self.music = music
                scenes = selected
                baseScenes = baseSelected
                if let previousOutput { try? FileManager.default.removeItem(at: previousOutput) }
                for file in attemptFiles { try? FileManager.default.removeItem(at: file) }
                // A copy of music that is no longer the one in use is not needed again.
                for (recordID, snapshot) in musicSnapshots where recordID != music?.recordID {
                    try? FileManager.default.removeItem(at: snapshot)
                    musicSnapshots[recordID] = nil
                }
                let originalTotal = sources.reduce(0) { $0 + $1.duration }
                var countParts: [String] = []
                if recoveredCount > 0 { countParts.append("복구 \(recoveredCount)개") }
                if skippedCount > 0 { countParts.append("제외 \(skippedCount)개") }
                let countSuffix = countParts.isEmpty ? "" : " (\(countParts.joined(separator: ", ")))"
                status = mode == .mediaMusic
                    ? "영상 \(videoTrailerTime(cursor.seconds)) · \(selected.count)개 장면\(countSuffix)" + (music == nil ? "" : " · 음악 포함")
                    : "원본 \(videoTrailerTime(originalTotal)) → 예고편 \(videoTrailerTime(cursor.seconds)) · \(selected.count)개 클립\(countSuffix)"
                        + (music == nil ? "" : " · 음악 포함")
            } catch let error where isSuspending && (error is CancellationError || Task.isCancelled) {
                // Left mid-run without discarding: only this attempt's unfinished output and
                // photo clips go. The staged sources, the picked music's copy and an
                // earlier finished video all stay for when the editor is reopened.
                Self.logger.notice("trailer model \(self.identity, privacy: .public) suspended at \(stage, privacy: .public)")
                exporter = nil
                recoveredCount = 0
                if let exportOutput, exportOutput != outputURL { try? FileManager.default.removeItem(at: exportOutput) }
                for file in attemptFiles { try? FileManager.default.removeItem(at: file) }
                status = mode == .mediaMusic ? "음악을 고르면 영상을 만듭니다."
                    : "예고편 조절에서 만들기를 누르면 예고편을 만듭니다."
            } catch is CancellationError {
                cleanup(reason: "cancelled at \(stage)")
            } catch {
                let workspace = Self.workspaceState(directory: directory, output: exportOutput, sources: sources)
                Self.logger.error("trailer failed at \(stage, privacy: .public): \(trailerErrorChain(error), privacy: .public) \(layout, privacy: .public) \(workspace, privacy: .public)")
                diagnostic.stage = stage
                diagnostic.errorChain = trailerErrorChain(error)
                diagnostic.sources = sources.count
                diagnostic.skipped = skippedCount
                diagnostic.recovered = recoveredCount
                do {
                    try diagnostic.persist()
                } catch {
                    Self.logger.error("trailer failure record not written: \(trailerErrorChain(error), privacy: .public)")
                }
                // Only what this failed attempt made is removed. The output still on screen,
                // the staged sources and the music in PhoneHard are left as they are.
                if let exportOutput, exportOutput != outputURL { try? FileManager.default.removeItem(at: exportOutput) }
                for file in attemptFiles { try? FileManager.default.removeItem(at: file) }
                let keepsOutput = outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                // Staged copies that are gone make every retry fail the same way; drop this
                // workspace so the next attempt stages again from the untouched originals.
                // Never while an earlier output is still there to watch.
                if !keepsOutput, sources.contains(where: { !FileManager.default.fileExists(atPath: $0.url.path) }) {
                    let removed = removedSourceIDs
                    cleanup(reason: "staged copies missing")
                    removedSourceIDs = removed
                }
                // Own errors already say what happened; system errors are only identifiable by code.
                self.error = error is TrailerError || error is MediaError || error is TrailerMusicError
                    ? error.localizedDescription
                    : "\(error.localizedDescription) (\(trailerErrorChain(error)))"
            }
        }
    }

    // MARK: 프로젝트 저장·복원

    /// 렌더링이나 준비를 취소한다. 편집기는 열린 채 남고, 이번 시도가 만든 미완성 파일만 지워진다.
    func cancelCurrentWork() {
        guard task != nil, !isSaving else { return }
        suspend()
    }

    func stagedMusicFile(_ music: TrailerMusicSelection) -> URL? {
        musicSnapshots[music.recordID].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// 편집기 상태를 저장 가능한 값으로 만든다. 파일 복사는 저장소가 백그라운드에서 한다.
    func projectSnapshot(id: UUID, existing: TrailerProjectRecord?, mode: VideoTrailerMode,
                         outputMode: VideoTrailerMode?, draft: TrailerSettingsDraft, itemCount: Int,
                         selectedSceneID: Int?, showedSettings: Bool, isPrivate: Bool = false) -> TrailerProjectSnapshot {
        let kept = Set(draft.sources.map(\.id))
        let removedByDraft = Set(sources.map(\.id)).subtracting(kept)
        var staged: [Int: URL] = [:]
        let rows: [TrailerProjectRecord.Source] = draft.sources.map { source in
            staged[source.id] = source.url
            let analysis = source.plan.analysis
            return TrailerProjectRecord.Source(
                id: source.id, name: source.name, file: "", isImage: source.isImage, duration: source.duration,
                contentTypeIdentifier: source.contentTypeIdentifier, captureDate: source.captureDate,
                imageDurationRatio: source.imageDurationRatio, waveform: analysis.waveform,
                peakTime: analysis.peakTime, peakTimes: analysis.peakTimes,
                highlightSource: analysis.highlightSource.rawValue,
                audioAvailability: analysis.audioAvailability.rawValue,
                highlightAnalyzed: highlightAnalyzedIDs.contains(source.id),
                imageDurationPolicyVersion: source.imageDurationPolicyVersion)
        }
        var musicRow: TrailerProjectRecord.Music?
        var musicFile: URL?
        if let music = draft.music {
            musicFile = stagedMusicFile(music) ?? (FileManager.default.fileExists(atPath: music.url.path) ? music.url : nil)
            musicRow = TrailerProjectRecord.Music(recordID: music.recordID, name: music.name, file: "",
                duration: music.duration, policy: music.policy.rawValue, fitCount: music.fitCount, autoDuck: music.autoDuck, level: music.level)
        }
        let record = TrailerProjectRecord(
            id: id, customTitle: existing?.customTitle, mode: mode == .mediaMusic ? "mediaMusic" : "trailer",
            createdAt: existing?.createdAt ?? Date(), updatedAt: Date(), revision: existing?.revision ?? 0,
            sources: rows, nextSourceID: itemCount, removedSourceIDs: Array(removedSourceIDs.union(removedByDraft)).sorted(),
            skippedSourceIDs: Array(skippedSourceIDs).sorted(), knownSourceIDs: Array(draft.knownIDs).sorted(),
            photosAnalyzed: photoDurationsAnalyzed, total: draft.total, clipLength: draft.clipLength,
            aspectRatio: draft.aspectRatio?.rawValue, music: musicRow, scenes: draft.scenes,
            nextSceneID: draft.nextSceneID, selectedSceneID: selectedSceneID,
            outputFile: nil, outputMode: outputURL == nil ? nil : (outputMode ?? mode) == .mediaMusic ? "mediaMusic" : "trailer",
            showedSettings: showedSettings, linkedCollectionVideoIDs: existing?.linkedCollectionVideoIDs ?? [],
            isPrivate: (isPrivate || existing?.isPrivate == true) ? true : nil)
        return TrailerProjectSnapshot(record: record, stagedFiles: staged, musicFile: musicFile,
                                      outputFile: outputURL)
    }

    /// 저장된 프로젝트를 이 모델의 새 작업 폴더로 되살린다. 프로젝트 폴더의 파일은 읽기만 하고
    /// 모델은 자기 사본만 지우므로, 편집기에서 소스를 빼거나 다시 가져와도 저장된 사본은 그대로다.
    /// 저장본의 파일을 이 모델의 새 작업 폴더로 복사한다. 복사는 파일마다 메인 스레드 밖에서 하고
    /// 진행 상황을 `status`에 보여 준다. 저장된 프로젝트 폴더는 읽기만 하며, 취소되면 이번에 만든 작업 폴더만 지운다.
    /// 복사에 실패한 파일은 `failed`에 담겨 돌아오고, 상태 변경은 호출한 쪽(메인)에서 한다.
    func copyStoredFiles(record: TrailerProjectRecord, store: TrailerProjectStore) async -> TrailerRestoredFiles? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NasFinderTrailer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var relatives = record.sources.map(\.file)
        if let music = record.music { relatives.append(music.file) }
        if let output = record.outputFile { relatives.append(output) }
        var jobs: [(relative: String, origin: URL, destination: URL)] = []
        for relative in relatives where !relative.isEmpty {
            let destination = folder.appendingPathComponent((relative as NSString).lastPathComponent)
            if let origin = store.fileURL(relative, id: record.id), FileManager.default.fileExists(atPath: origin.path) {
                jobs.append((relative, origin, destination))
            }
        }
        var copies: [String: URL] = [:]
        var failed: [String] = []
        for (index, job) in jobs.enumerated() {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            status = "저장된 파일을 불러오는 중 · \(index + 1)/\(jobs.count)"
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try? FileManager.default.removeItem(at: job.destination)
                    try FileManager.default.copyItem(at: job.origin, to: job.destination)
                    return true
                } catch {
                    try? FileManager.default.removeItem(at: job.destination)
                    return false
                }
            }.value
            if ok { copies[job.relative] = job.destination } else { failed.append((job.relative as NSString).lastPathComponent) }
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return TrailerRestoredFiles(folder: folder, copies: copies, failed: failed)
    }

    func adopt(record: TrailerProjectRecord, restored: TrailerRestoredFiles) -> TrailerSettingsDraft {
        let files = FileManager.default
        let folder = restored.folder
        directory = folder
        mode = record.mode == "mediaMusic" ? .mediaMusic : .trailer
        func bring(_ relative: String) -> URL {
            restored.copies[relative] ?? folder.appendingPathComponent((relative as NSString).lastPathComponent)
        }
        sources = record.sources.map { row in
            let analysis = AudioAnalysisResult(
                waveform: row.waveform, peakTime: row.peakTime, peakTimes: row.peakTimes,
                audioAvailability: ClipAudioAvailability(rawValue: row.audioAvailability) ?? .unknown,
                highlightSource: ClipHighlightSource(rawValue: row.highlightSource) ?? .fallback)
            return VideoTrailerSource(id: row.id, name: row.name, url: bring(row.file),
                plan: VideoTrailerPlan(analysis: analysis, duration: row.duration), isImage: row.isImage,
                contentTypeIdentifier: row.contentTypeIdentifier, captureDate: row.captureDate,
                imageDurationRatio: row.imageDurationRatio,
                imageDurationPolicyVersion: row.imageDurationPolicyVersion ?? 1)
        }
        highlightAnalyzedIDs = Set(record.sources.filter(\.highlightAnalyzed).map(\.id))
        photoDurationsAnalyzed = record.photosAnalyzed
        removedSourceIDs = Set(record.removedSourceIDs)
        skippedSourceIDs = Set(record.skippedSourceIDs)
        skippedCount = skippedSourceIDs.count
        recoveredCount = 0
        isStaged = true
        var restoredMusic: TrailerMusicSelection?
        if let row = record.music {
            let copy = bring(row.file)
            musicSnapshots[row.recordID] = copy
            restoredMusic = TrailerMusicSelection(recordID: row.recordID, name: row.name, url: copy,
                duration: row.duration, policy: TrailerMusicPolicy(rawValue: row.policy) ?? .single,
                fitCount: row.fitCount, autoDuck: row.autoDuck, level: min(1, max(0, row.level ?? 1)))
        }
        let ratio = record.aspectRatio.flatMap(OutputAspectRatio.init(rawValue:))
        aspectRatio = ratio
        if let output = record.outputFile {
            let copy = bring(output)
            if files.fileExists(atPath: copy.path) {
                outputURL = copy
                music = restoredMusic
                status = "저장된 완성 영상을 불러왔습니다."
            }
        }
        var draft = TrailerSettingsDraft(sources: sources, total: record.total, clipLength: record.clipLength,
                                         aspectRatio: ratio, music: restoredMusic)
        draft.scenes = record.scenes
        draft.nextSceneID = record.nextSceneID
        draft.knownIDs = Set(record.knownSourceIDs).union(sources.map(\.id))
        return draft
    }

    func save(to store: SharedInboxStore, filename: String, suffix: String = "예고편", isPrivate: Bool = false) {
        guard let outputURL, !isBusy, !isSaved else { return }
        isBusy = true
        isSaving = true
        error = nil
        task = Task {
            defer { isSaving = false }
            do {
                let base = (filename as NSString).deletingPathExtension
                _ = try await store.importDownloadedFile(at: outputURL,
                    originalFilename: "\(base)-\(suffix).mp4", contentTypeIdentifier: "public.mpeg-4",
                    isPrivate: isPrivate)
                isSaved = true
                status = "폰하드에 저장했습니다."
            } catch {
                self.error = "폰하드에 저장하지 못했습니다: \(error.localizedDescription)"
            }
            if Task.isCancelled { cleanup(reason: "cancelled during save") }
            isBusy = false
            task = nil
        }
    }

    /// Called only by the user closing or cancelling this trailer. An export is cancelled
    /// only while it is still running; a finished session is left alone so its output is
    /// never discarded underneath the verification step.
    func stop() {
        isSuspending = false
        if let awakeActivityID { ScreenAwakeController.shared.finishActivity(awakeActivityID) }
        let session = exporter
        Self.logger.notice("trailer model \(self.identity, privacy: .public) stop: task \(self.task != nil ? 1 : 0, privacy: .public) export status \(session?.status.rawValue ?? -1, privacy: .public) output \(self.outputURL != nil ? 1 : 0, privacy: .public)")
        task?.cancel()
        if let session, session.status == .exporting || session.status == .waiting { session.cancelExport() }
        if task == nil { cleanup(reason: "stop") }
    }

    /// Something of this session is worth coming back to.
    var hasResumableWork: Bool { !sources.isEmpty || outputURL != nil }

    /// Called when the user leaves the editor without discarding it. A staging, render or
    /// export still running is cancelled and only its own unfinished files are removed; a
    /// save to PhoneHard is left to finish. Nothing else of the session changes.
    func suspend() {
        guard task != nil, !isSaving else { return }
        Self.logger.notice("trailer model \(self.identity, privacy: .public) suspend: export status \(self.exporter?.status.rawValue ?? -1, privacy: .public) output \(self.outputURL != nil ? 1 : 0, privacy: .public)")
        isSuspending = true
        task?.cancel()
        if let session = exporter, session.status == .exporting || session.status == .waiting { session.cancelExport() }
    }

    /// Copies the picked music into this session's own folder while the editor is away,
    /// as a render does, so the pick does not depend on the PhoneHard file staying put.
    func pinMusic(_ music: TrailerMusicSelection?) {
        guard let music, let directory, musicSnapshots[music.recordID] == nil else { return }
        let original = music.url
        let copy = directory.appendingPathComponent("music-\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension)
        Task {
            let copied = await Task.detached(priority: .utility) {
                (try? FileManager.default.copyItem(at: original, to: copy)) != nil
            }.value
            guard copied else { return }
            if self.directory == directory, musicSnapshots[music.recordID] == nil {
                musicSnapshots[music.recordID] = copy
            } else {
                try? FileManager.default.removeItem(at: copy)
            }
        }
    }

    /// The picked music can still be read, from this session's copy or from PhoneHard.
    func holdsMusic(_ music: TrailerMusicSelection) -> Bool {
        let files = FileManager.default
        if let snapshot = musicSnapshots[music.recordID], files.fileExists(atPath: snapshot.path) { return true }
        return files.fileExists(atPath: music.url.path)
    }

    /// Checks a reopened session against what is really on disk. A finished video that is
    /// gone is no longer offered; staged copies that are gone are only reported, so the
    /// user decides whether to fetch them again.
    func reconcile() -> (sources: Bool, output: Bool) {
        let files = FileManager.default
        var outputLost = false
        if let outputURL, !files.fileExists(atPath: outputURL.path) {
            self.outputURL = nil
            scenes = []
            baseScenes = []
            music = nil
            isSaved = false
            outputLost = true
        }
        let sourcesLost = sources.contains { !files.fileExists(atPath: $0.url.path) }
        if sourcesLost || outputLost {
            Self.logger.notice("trailer model \(self.identity, privacy: .public) reopened stale: \(Self.workspaceState(directory: self.directory, output: self.outputURL, sources: self.sources), privacy: .public)")
        }
        return (sourcesLost, outputLost)
    }

    /// Stages every source again from the untouched originals after this session's own
    /// copies were lost. A finished video that is still there, and which sources the user
    /// took out, are kept.
    func restage(items: [RemoteFileItem], service: any RemoteFileService, mode: VideoTrailerMode) {
        guard !isBusy else { return }
        for source in sources { try? FileManager.default.removeItem(at: source.url) }
        sources = []
        activityBySourceID = [:]
        highlightAnalyzedIDs = []
        photoDurationsAnalyzed = false
        skippedSourceIDs = []
        skippedCount = 0
        recoveredCount = 0
        isStaged = false
        if let directory, !FileManager.default.fileExists(atPath: directory.path) {
            self.directory = nil
            musicSnapshots = [:]
        }
        start(items: items, service: service, mode: mode)
    }

    private func cleanup(reason: String) {
        let hadWorkspace = directory.map { FileManager.default.fileExists(atPath: $0.path) ? 1 : 0 } ?? -1
        Self.logger.notice("trailer model \(self.identity, privacy: .public) cleanup (\(reason, privacy: .public)): workspace \(hadWorkspace, privacy: .public) staged \(self.sources.count, privacy: .public) output \(self.outputURL != nil ? 1 : 0, privacy: .public)")
        exporter = nil
        sources = []
        scenes = []
        baseScenes = []
        music = nil
        isAwaitingSettings = false
        isStaged = false
        activityBySourceID = [:]
        musicSnapshots = [:]
        outputURL = nil
        exportProgress = nil
        joinProgress = nil
        removedSourceIDs = []
        skippedSourceIDs = []
        skippedCount = 0
        recoveredCount = 0
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

/// Reports the bottom edge of the hosting window's usable area, so the editor can size itself to
/// what is really visible instead of the height it was proposed.
private struct TrailerWindowBottomReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.setNeedsLayout()
    }

    final class ReaderView: UIView {
        var onChange: (CGFloat) -> Void = { _ in }
        private var last: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let bottom = window.bounds.height - window.safeAreaInsets.bottom
            guard abs(bottom - last) > 0.5 else { return }
            last = bottom
            DispatchQueue.main.async { [onChange] in onChange(bottom) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }
}

/// Present only while the trailer preview is fullscreen. It takes Escape ahead of the system's
/// modal-dismiss behaviour so the key leaves fullscreen instead of closing the editor. It
/// answers only when it lives in the topmost presented controller, so a share sheet, alert
/// or picker above it still gets its own Escape.
private struct TrailerFullscreenEscapeCatcher: UIViewControllerRepresentable {
    let onEscape: () -> Void

    func makeUIViewController(context: Context) -> EscapeController {
        let controller = EscapeController()
        controller.onEscape = onEscape
        return controller
    }

    func updateUIViewController(_ controller: EscapeController, context: Context) {
        controller.onEscape = onEscape
        controller.claimFirstResponder()
    }

    final class EscapeController: UIViewController {
        var onEscape: () -> Void = {}

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            guard ownsTopmostPresentation else { return [] }
            let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
            command.wantsPriorityOverSystemBehavior = true
            return [command]
        }

        private var ownsTopmostPresentation: Bool {
            guard var top = view.window?.rootViewController else { return false }
            while let presented = top.presentedViewController { top = presented }
            var current: UIViewController? = self
            while let controller = current {
                if controller === top { return true }
                current = controller.parent
            }
            return false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            claimFirstResponder()
        }

        func claimFirstResponder() {
            guard view.window != nil, !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view.window != nil, self.ownsTopmostPresentation else { return }
                self.becomeFirstResponder()
            }
        }

        @objc private func escapePressed() { onEscape() }
    }
}

/// 하나의 표준 슬라이더에서 드래그 속도만 연속적으로 반영한다. 별도 미세조절 모드는 없다.
private struct TrailerTotalDurationSlider: UIViewRepresentable {
    @Binding var value: Double
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeUIView(context: Context) -> TrailerVelocityDurationSlider {
        let slider = TrailerVelocityDurationSlider()
        // 속도 추적과 tintColor를 쓰므로 Mac idiom에서도 iPad 슬라이더 동작을 유지한다.
        slider.preferredBehavioralStyle = .pad
        slider.minimumValue = 1
        slider.maximumValue = Float(VideoTrailerBatchPlan.maximumRequestedDuration)
        slider.isContinuous = true
        slider.accessibilityLabel = "예고편 총길이"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return slider
    }
    func updateUIView(_ slider: TrailerVelocityDurationSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = isEnabled
        slider.tintColor = UIColor(SkyBreezeTheme.accent)
        if !slider.isUserAdjusting { slider.setValue(Float(value.rounded()), animated: false) }
        slider.accessibilityValue = trailerDurationTitle(value)
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: TrailerVelocityDurationSlider) {
            let seconds = Double(slider.value.rounded())
            slider.accessibilityValue = trailerDurationTitle(seconds)
            value.wrappedValue = seconds
        }
    }
}

private final class TrailerVelocityDurationSlider: UISlider {
    private(set) var isUserAdjusting = false
    private var accumulatedValue = 1.0
    private var lastX: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0
    private var smoothedSpeed: Double?

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(decreaseOneSecond)),
         UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(decreaseOneSecond)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(increaseOneSecond)),
         UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(increaseOneSecond))]
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        let point = touch.location(in: self)
        let track = trackRect(forBounds: bounds)
        let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
        let initial = Double(value)
        let hitThumb = thumb.insetBy(dx: -8, dy: -8).contains(point)
        _ = super.beginTracking(touch, with: event)
        isUserAdjusting = true
        becomeFirstResponder()
        if hitThumb {
            accumulatedValue = initial
        } else {
            let limits = travelLimits()
            let fraction = min(1, max(0, Double((point.x - limits.lower) / limits.width)))
            let ordered = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction
            accumulatedValue = Double(minimumValue) + ordered * Double(maximumValue - minimumValue)
        }
        lastX = point.x
        lastTimestamp = touch.timestamp
        smoothedSpeed = nil
        isHighlighted = true
        publishAccumulatedValue(force: !hitThumb)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isUserAdjusting else { return false }
        let x = touch.location(in: self).x
        let delta = Double(x - lastX)
        let elapsed = max(1.0 / 240, touch.timestamp - lastTimestamp)
        let speed = abs(delta) / elapsed
        let filtered = smoothedSpeed.map { $0 * 0.7 + speed * 0.3 } ?? speed
        smoothedSpeed = filtered
        let normalized = min(1, max(0, (filtered - 80) / 520))
        let smoothstep = normalized * normalized * (3 - 2 * normalized)
        let gain = 0.05 + 0.95 * smoothstep
        let direction = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1.0 : 1.0
        accumulatedValue += direction * delta / Double(travelLimits().width)
            * Double(maximumValue - minimumValue) * gain
        accumulatedValue = min(Double(maximumValue), max(Double(minimumValue), accumulatedValue))
        lastX = x
        lastTimestamp = touch.timestamp
        publishAccumulatedValue()
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let finalValue = value
        super.endTracking(touch, with: event)
        setValue(finalValue, animated: false)
        sendActions(for: .valueChanged)
        finishTracking()
    }
    override func cancelTracking(with event: UIEvent?) {
        let finalValue = value
        super.cancelTracking(with: event)
        setValue(finalValue, animated: false)
        sendActions(for: .valueChanged)
        finishTracking()
    }
    override func accessibilityIncrement() { adjustByOneSecond(1) }
    override func accessibilityDecrement() { adjustByOneSecond(-1) }
    @objc private func increaseOneSecond() { adjustByOneSecond(1) }
    @objc private func decreaseOneSecond() { adjustByOneSecond(-1) }
    private func adjustByOneSecond(_ delta: Float) {
        guard isEnabled else { return }
        setValue(min(maximumValue, max(minimumValue, value.rounded() + delta)), animated: false)
        accumulatedValue = Double(value)
        accessibilityValue = trailerDurationTitle(Double(value))
        sendActions(for: .valueChanged)
    }
    private func publishAccumulatedValue(force: Bool = false) {
        let seconds = Float(accumulatedValue.rounded())
        if force || abs(value - seconds) >= 0.5 {
            setValue(seconds, animated: false)
            sendActions(for: .valueChanged)
        } else { setValue(seconds, animated: false) }
    }
    private func finishTracking() {
        isUserAdjusting = false
        isHighlighted = false
        smoothedSpeed = nil
    }
    private func travelLimits() -> (lower: CGFloat, width: CGFloat) {
        let track = trackRect(forBounds: bounds)
        let minimum = thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX
        let maximum = thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX
        return (min(minimum, maximum), max(1, abs(maximum - minimum)))
    }
}
