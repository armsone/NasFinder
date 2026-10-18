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
    case exportUnavailable, exportFailed, noUsableSources, outputMissing
    var errorDescription: String? {
        switch self {
        case .exportUnavailable: "이 영상 형식으로 예고편을 만들 수 없습니다."
        case .exportFailed: "예고편을 만들지 못했습니다. 다시 시도해 주세요."
        case .noUsableSources: "예고편으로 만들 수 있는 사진이나 영상이 없습니다."
        case .outputMissing: "완성한 예고편 파일이 작업 폴더에서 사라졌습니다. 다시 시도해 주세요."
        }
    }
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
private enum TrailerPreparedPlan {
    static func base(mode: VideoTrailerMode, sources: [VideoTrailerSource], total: Double,
                     clipLength: Double) -> [VideoTrailerScene] {
        mode == .mediaMusic ? VideoTrailerBatchPlan.wholeMedia(sources: sources)
            : VideoTrailerBatchPlan.selection(sources: sources, total: total, clipLength: clipLength)
    }

    /// Empty when the chosen music cannot be matched within the repeat limit.
    static func scenes(mode: VideoTrailerMode, sources: [VideoTrailerSource], total: Double,
                       clipLength: Double, music: TrailerMusicSelection?) -> [VideoTrailerScene] {
        let base = base(mode: mode, sources: sources, total: total, clipLength: clipLength)
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
}

private struct TrailerSettingsDraft {
    var sources: [VideoTrailerSource]
    var total: Double
    var clipLength: Double
    var aspectRatio: OutputAspectRatio?
    var music: TrailerMusicSelection?
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

struct VideoTrailerView: View {
    let items: [RemoteFileItem]
    let service: any RemoteFileService
    /// The mode this editor is in right now: it starts as the caller's (or the saved draft's)
    /// and the top selector of the editor changes it without leaving the editor.
    @State private var mode: VideoTrailerMode
    /// The mode the video currently shown was made in, for the name it is saved under.
    @State private var outputMode: VideoTrailerMode?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @StateObject private var model: VideoTrailerModel
    @State private var presentedSettings: TrailerSettingsPresentation?
    @State private var draft: TrailerSettingsDraft?
    /// This editing session in `TrailerDraftStore`, the same before and after a suspension.
    @State private var sessionID: UUID
    @State private var didBegin = false
    /// The user already chose how this showing ends, so `onDisappear` leaves it alone.
    @State private var exitHandled = false
    @State private var showingReplacePrompt = false
    @State private var showingStalePrompt = false
    @State private var resumeNotice: String?
    private let keepsSelectionOrder: Bool
    private let isResumed: Bool
    private let reopensSettings: Bool
    private var showingSettings: Bool { presentedSettings != nil }

    /// With `resuming` the editor continues that suspended session instead of starting one.
    init(items: [RemoteFileItem], service: any RemoteFileService, mode: VideoTrailerMode = .trailer,
         keepsSelectionOrder: Bool = false, resuming entry: TrailerDraftEntry? = nil) {
        self.items = items
        self.keepsSelectionOrder = keepsSelectionOrder
        self.service = service
        _mode = State(initialValue: mode)
        let suspended = entry?.session as? TrailerSuspendedSession
        isResumed = suspended != nil
        reopensSettings = suspended?.showedSettings ?? false
        _model = StateObject(wrappedValue: suspended?.model ?? VideoTrailerModel())
        _draft = State(initialValue: suspended?.draft)
        _sessionID = State(initialValue: entry?.id ?? UUID())
    }

    @AppStorage(AppThemePreference.storageKey) private var themeRawValue = AppThemePreference.light.rawValue

    var body: some View {
        let _ = themeRawValue
        mediaContent.modifier(PreserveMediaNavigation())
    }

    private var mediaContent: some View {
        NavigationStack {
            TrailerSettingsHost(
                mode: mode,
                draft: $draft,
                opening: currentDraft(),
                skippedCount: model.skippedCount,
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
                               suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편")
                },
                isSaved: model.isSaved,
                apply: apply
            )
            .background(PorcelainMetrics.paper)
            .task { await begin() }
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
            .alert("보관 중인 다른 편집이 있습니다", isPresented: $showingReplacePrompt) {
                Button("둘 다 보관") { suspendAndDismiss() }
                Button("이전 편집을 버리고 이 편집 보관", role: .destructive) {
                    let store = TrailerDraftStore.shared
                    for other in store.others(mode: mode, than: sessionID) { store.discard(other.id) }
                    suspendAndDismiss()
                }
                Button("이 편집 버리기", role: .destructive) { discardAndDismiss() }
                Button("계속 편집", role: .cancel) { }
            } message: {
                Text("같은 종류의 편집이 이미 보관되어 있습니다. 고르지 않은 편집은 지워지지 않습니다.")
            }
            .alert("보관한 편집 파일이 사라졌습니다", isPresented: $showingStalePrompt) {
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
            .alert("보관한 편집을 다시 열었습니다", isPresented: Binding(
                get: { resumeNotice != nil && !showingStalePrompt },
                set: { if !$0 { resumeNotice = nil } })) {
                Button("확인", role: .cancel) { continueResume() }
            } message: {
                Text(resumeNotice ?? "")
            }
        }
    }

    /// A new editor stages its sources; a reopened one checks what is really still there
    /// and continues from it, saying so plainly when something is gone.
    private func begin() async {
        TrailerDraftStore.shared.reopen(sessionID)
        // A render cancelled on the way out may still be unwinding.
        while model.isSuspending, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard !Task.isCancelled, !didBegin else { return }
        didBegin = true
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
        if TrailerDraftStore.shared.others(mode: mode, than: sessionID).isEmpty {
            suspendAndDismiss()
        } else {
            showingReplacePrompt = true
        }
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
                clipLength: prepared.clipLength, music: prepared.music).reduce(0) { $0 + $1.length }
        }
        entry.suspendedAt = Date()
        TrailerDraftStore.shared.suspend(entry)
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
        TrailerDraftStore.shared.reopen(sessionID)
        model.stop()
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
            return TrailerSettingsDraft(sources: staged, total: total, clipLength: clipLength,
                                        aspectRatio: model.aspectRatio, music: model.music)
        }
        let byID = Dictionary(uniqueKeysWithValues: staged.map { ($0.id, $0) })
        draft.sources = draft.sources.compactMap { byID[$0.id] }
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
        model.start(items: items, service: service, mode: mode, generate: true, sourceOrder: draft.sources.map(\.id),
                    total: draft.total, clipLength: draft.clipLength, aspectRatio: draft.aspectRatio, music: draft.music)
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
        model.analyzeHighlights { analyzed in
            guard !exitHandled, mode != .trailer else { return }
            mode = .trailer
            guard var current = draft else { return }
            if analyzed || current.total <= 0 {
                current.clipLength = model.recommendedClipLength
                current.total = VideoTrailerBatchPlan.recommendedTotal(sources: current.sources, clipLength: current.clipLength)
                if let music = current.music, music.policy == .fitMusic { current.total = music.fittedDuration }
            }
            let byID = Dictionary(uniqueKeysWithValues: model.sources.map { ($0.id, $0) })
            current.sources = current.sources.compactMap { byID[$0.id] }
            draft = current
        }
    }

    private func settingsContent(_ presentation: TrailerSettingsPresentation) -> some View {
        TrailerSettingsHost(
            mode: mode, draft: $draft, opening: presentation.draft,
            skippedCount: model.skippedCount, isBusy: model.isBusy, status: model.status,
            exportProgress: model.exportProgress, joinProgress: model.joinProgress,
            outputURL: model.outputURL, error: model.error,
            onModeChange: changeMode, onClose: { presentedSettings = nil },
            onDiscard: discardAndDismiss,
            onSave: {
                model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상",
                           suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편")
            },
            isSaved: model.isSaved, apply: apply
        )
        .id(presentation.id)
    }

    private var trailerControls: some View {
        HStack(spacing: ui(8)) {
            Button {
                model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상",
                           suffix: (outputMode ?? mode) == .mediaMusic ? "음악" : "예고편")
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
private func trailerOrientedVideoSize(url: URL) async throws -> CGSize? {
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
                RemotePreviewView(
                    item: previewService.item,
                    sequentialItems: [previewService.item],
                    service: previewService,
                    accessoryControls: accessoryControls,
                    onClose: onClose,
                    playbackSuspended: isBusy
                )
                .id(outputURL)
            } else if let firstSource {
                Color.black
                    .aspectRatio(aspectSize.width / aspectSize.height, contentMode: .fit)
                    .overlay {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: firstSource.isImage ? "photo" : "film")
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
                }
                .padding(ui(12))
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: ui(12)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ui(12), style: .continuous))
    }
}

/// The editor bound to the caller's draft. It arrives with the draft it opened on, so its
/// first frame already has content even before the caller's own state reaches this view.
private struct TrailerSettingsHost: View {
    let mode: VideoTrailerMode
    @Binding var draft: TrailerSettingsDraft?
    let opening: TrailerSettingsDraft
    let skippedCount: Int
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
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        let binding = Binding(get: { draft ?? opening }, set: { draft = $0 })
        VideoTrailerSettings(
            mode: mode, sources: binding.sources, total: binding.total,
            clipLength: binding.clipLength, skippedCount: skippedCount,
            aspectRatio: binding.aspectRatio, music: binding.music,
            showingDuration: binding.showingDuration, showingClipLength: binding.showingClipLength,
            isBusy: isBusy, status: status,
            exportProgress: exportProgress, joinProgress: joinProgress,
            outputURL: outputURL, error: error,
            onModeChange: onModeChange, onClose: onClose, onDiscard: onDiscard,
            onSave: onSave, isSaved: isSaved,
            regenerate: { apply(draft ?? opening) }
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
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @State private var showingMusicPicker = false
    @State private var confirmingDiscard = false
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
        TrailerPreparedPlan.base(mode: mode, sources: sources, total: total, clipLength: clipLength)
    }
    private var baseTotal: Double { baseProposal.reduce(0) { $0 + $1.length } }
    /// Empty when the chosen music cannot be matched within the repeat limit.
    private var proposal: [VideoTrailerScene] {
        TrailerPreparedPlan.scenes(mode: mode, sources: sources, total: total, clipLength: clipLength, music: music)
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
            return mode == .mediaMusic ? "새 설정으로 영상 만들기" : "\(trailerDurationTitle(actualTotal)) 예고편 다시 만들기"
        }
        guard mode == .mediaMusic else { return "\(trailerDurationTitle(actualTotal)) 예고편 만들기" }
        return music == nil ? "음악을 골라 주세요" : "\(trailerDurationTitle(actualTotal)) 영상 만들기"
    }
    private var percent: Double { originalTotal > 0 ? actualTotal / originalTotal * 100 : 0 }
    // Only real video durations bound the clip length; a still image has no duration of
    // its own, so a photo-only trailer keeps every preset.
    private var maximumClipLength: Double { min(30, sources.filter { !$0.isImage }.map(\.duration).max() ?? 30) }
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
            let isWide = geometry.size.width >= 640
            if isWide {
                wideLayout(width: geometry.size.width)
            } else {
                narrowLayout
            }
        }
        .fullScreenCover(isPresented: $showingMusicPicker) {
            TrailerMusicPickerView(currentID: music?.recordID) { picked in
                var next = picked
                next?.autoDuck = music?.autoDuck ?? true
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
                Button("닫기", action: onClose).uiBarFont()
            }
            if let onSave {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onSave) {
                        Image(systemName: isSaved ? "checkmark.circle" : "square.and.arrow.down")
                    }
                    .disabled(isBusy || isSaved || outputURL == nil)
                    .accessibilityLabel(isSaved ? "폰하드에 저장됨" : "폰하드에 저장")
                }
            }
        }
    }

    private func wideLayout(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: ui(16)) {
            VStack(alignment: .leading, spacing: ui(12)) {
                previewSection
                    .frame(maxHeight: ui(380))
                orderSection
            }
            .frame(width: max(ui(320), (width - ui(48)) * 0.54))

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
        }
        .padding(ui(16))
    }

    private var narrowLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ui(14)) {
                previewSection
                    .frame(maxHeight: ui(260))
                orderSection
                Divider()
                optionsSection
            }
            .padding(ui(16))
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .safeAreaInset(edge: .bottom) { createBar }
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
            onClose: onClose
        )
    }

    private var trailerControlsView: some View {
        HStack(spacing: ui(8)) {
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

    private var orderSection: some View {
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
                    Text(trailerDurationTitle(actualTotal)).font(.ui(.title2).weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(sceneSummary).font(.ui(.subheadline)).foregroundStyle(.secondary)
                }
                if !photoOnly && (mode == .mediaMusic || actualTotal <= originalTotal + 0.000001) {
                    Text(originalSummary).font(.ui(.caption)).foregroundStyle(.secondary)
                }
            }

            if mode == .trailer {
                Divider()
                VStack(alignment: .leading, spacing: ui(4)) {
                    Text("얼마나 길게 볼까요?").font(.ui(.subheadline).weight(.semibold))
                    HStack(spacing: ui(5)) {
                        ForEach([30.0, 60, 120, 180, 300], id: \.self) { value in
                            TrailerChoiceButton(title: trailerDurationTitle(value), selected: abs(total - value) < 0.01, height: 32) {
                                setManualTotal(value)
                                showingDuration = false
                            }
                        }
                    }
                    otherLengthButton(value: trailerDurationTitle(total), expanded: showingDuration) { showingDuration.toggle() }
                    if showingDuration {
                        TrailerTotalDurationSlider(value: Binding(
                            get: { min(VideoTrailerBatchPlan.maximumRequestedDuration, max(1, total.isFinite ? total : 1)) },
                            set: { if abs($0 - total) >= 0.01 { setManualTotal($0) } }))
                            .frame(minHeight: ui(30))
                    }
                }

                VStack(alignment: .leading, spacing: ui(4)) {
                    Text("한 장면은 얼마나 볼까요?").font(.ui(.subheadline).weight(.semibold))
                    HStack(spacing: ui(5)) {
                        ForEach([1.0, 1.5, 2, 4, 6].filter { $0 <= maximumClipLength }, id: \.self) { value in
                            TrailerChoiceButton(title: trailerSceneLengthTitle(value), selected: abs(clipLength - value) < 0.01, height: 32) {
                                clipLength = value
                                showingClipLength = false
                            }
                        }
                    }
                    otherLengthButton(value: trailerSceneLengthTitle(clipLength), expanded: showingClipLength) { showingClipLength.toggle() }
                    if showingClipLength, maximumClipLength > 1 {
                        Slider(value: $clipLength, in: 1...maximumClipLength, step: 1)
                            .accessibilityLabel("공통 장면 길이")
                            .accessibilityValue("\(Int(clipLength))초")
                    }
                }
            }

            Divider()

            aspectSection

            if sources.isEmpty {
                Text("모든 영상이 제거되어 예고편을 만들 수 없습니다. 영상을 다시 추가해 주세요.")
                    .font(.ui(.caption)).foregroundStyle(.red)
            }
            if mode == .trailer, music?.policy != .fitMusic, abs(total - baseTotal) >= 0.5 {
                Text("선택한 \(trailerDurationTitle(total))에 가장 가까운 길이로 맞췄어요")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if skippedCount > 0 {
                Text(trailerSkippedTitle(skippedCount)).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if excludedCount > 0 {
                Text("\(excludedCount)개 영상은 담기지 않아요. 총길이를 늘리거나 장면 길이를 줄여보세요.")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
            HStack {
                if mode == .trailer {
                    Button("자동 추천으로 되돌리기") {
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

    /// The total length picked by hand (a preset or the slider). The music stays, but
    /// neither automatic policy applies any more. Only these controls call this, so a
    /// length that changes for any other reason never clears the chosen policy.
    private func setManualTotal(_ value: Double) {
        total = value.isFinite ? min(VideoTrailerBatchPlan.maximumRequestedDuration, max(1, value)) : 1
        guard var selection = music, selection.policy != .single else { return }
        selection.policy = .single
        selection.fitCount = 1
        music = selection
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
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.ui(.caption2))
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

private struct TrailerChoiceButton: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(3)) {
                Text(title)
                if selected { Image(systemName: "checkmark").font(.ui(.caption2)) }
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
                            Image(systemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if isRevealed {
                            Color.black.opacity(0.35)
                            Button(action: onRemove) {
                                Image(systemName: "trash.fill").font(.ui(.callout).weight(.semibold)).foregroundStyle(.white)
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
private final class VideoTrailerModel: ObservableObject {
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
            if let ratio = ratios[sources[index].id] { sources[index].imageDurationRatio = ratio }
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

    /// Actually decodes the planned ranges of one staged video and returns the error chain
    /// of the first failure. `isDecodable` only reports that a decoder exists for the
    /// track's format; a stream that decoder then rejects mid-file (seen with MPEG-4 Part 2
    /// video: VideoToolbox -8969 after some frames) still fails the whole export with
    /// AVFoundationErrorDomain -11821 / -16977. With `softwareOnly`, tracks that have a
    /// hardware decoder are left to the export itself.
    nonisolated private static func decodeFailure(url: URL, ranges: [CMTimeRange], softwareOnly: Bool) async throws -> String? {
        let work = Task.detached(priority: .userInitiated) { () -> String? in
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    return trailerErrorChain(MediaError.videoTrackUnavailable)
                }
                if softwareOnly {
                    let formats = try await track.load(.formatDescriptions)
                    guard formats.contains(where: { !VTIsHardwareDecodeSupported(CMFormatDescriptionGetMediaSubType($0)) }) else {
                        return nil
                    }
                }
                for range in ranges {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    ])
                    output.alwaysCopiesSampleData = false
                    guard reader.canAdd(output) else { return trailerErrorChain(MediaError.videoTrackUnavailable) }
                    reader.add(output)
                    reader.timeRange = range
                    guard reader.startReading() else { return trailerErrorChain(reader.error ?? MediaError.videoTrackUnavailable) }
                    while output.copyNextSampleBuffer() != nil {
                        if Task.isCancelled {
                            reader.cancelReading()
                            return nil
                        }
                    }
                    if reader.status == .failed { return trailerErrorChain(reader.error ?? MediaError.videoTrackUnavailable) }
                }
                return nil
            } catch {
                return trailerErrorChain(error)
            }
        }
        let failure = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return failure
    }

    /// Runs the actual decode check over every planned video scene, per source.
    private func decodeFailures(in selected: [VideoTrailerScene], softwareOnly: Bool) async throws -> [Int: String] {
        var failures: [Int: String] = [:]
        for source in sources where !source.isImage {
            // A scene repeated to fill the music's length is the same range again.
            var ranges: [CMTimeRange] = []
            for scene in selected where scene.sourceID == source.id {
                let range = CMTimeRange(start: CMTime(seconds: scene.start, preferredTimescale: 600),
                                        duration: CMTime(seconds: scene.length, preferredTimescale: 600))
                if !ranges.contains(range) { ranges.append(range) }
            }
            guard !ranges.isEmpty else { continue }
            if let failure = try await Self.decodeFailure(url: source.url, ranges: ranges, softwareOnly: softwareOnly) {
                failures[source.id] = failure
            }
        }
        return failures
    }

    /// Excludes sources whose planned ranges failed an actual decode, counted and logged
    /// like any other skipped item. Only this run's own staged copies are removed.
    private func exclude(_ failures: [Int: String], at step: String) throws -> Bool {
        guard !failures.isEmpty else { return false }
        for source in sources {
            guard let failure = failures[source.id] else { continue }
            Self.logger.error("trailer source \(source.id, privacy: .public) skipped at \(step, privacy: .public): \(failure, privacy: .public) type \(source.url.pathExtension.lowercased(), privacy: .public)")
            try? FileManager.default.removeItem(at: source.url)
        }
        sources.removeAll { failures[$0.id] != nil }
        skippedCount += failures.count
        skippedSourceIDs.formUnion(failures.keys)
        guard !sources.isEmpty else { throw TrailerError.noUsableSources }
        return true
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
                    status = "\(position + 1)/\(pending.count) · \(source.name) · 한양이 장면을 고르는 중…"
                    let buckets = max(192, min(2048, Int(min(1024, source.duration) * 2)))
                    let analysis = try await AudioAnalysisService.analyze(url: source.url, bucketCount: buckets)
                    try Task.checkCancellation()
                    if let index = sources.firstIndex(where: { $0.id == source.id }) {
                        sources[index] = VideoTrailerSource(id: source.id, name: source.name, url: source.url,
                            plan: VideoTrailerPlan(analysis: analysis, duration: source.duration),
                            isImage: false, contentTypeIdentifier: source.contentTypeIdentifier,
                            captureDate: source.captureDate, imageDurationRatio: source.imageDurationRatio)
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
               music: TrailerMusicSelection? = nil, keepsInputOrder: Bool = false) {
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
            do {
                if directory == nil {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NasFinderTrailer-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    directory = folder
                    skippedCount = 0
                    skippedSourceIDs = []
                    Self.logger.notice("trailer model \(self.identity, privacy: .public) workspace created: items \(items.count, privacy: .public)")
                }
                guard let directory else { throw TrailerError.exportFailed }
                for (index, item) in items.enumerated()
                where !sources.contains(where: { $0.id == index }) && !removedSourceIDs.contains(index)
                    && !skippedSourceIDs.contains(index) {
                    status = "\(index + 1)/\(items.count) · \(item.name) · \(item.isImage ? "사진을 받는 중…" : "영상을 받는 중…")"
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
                            status = "\(index + 1)/\(items.count) · \(item.name) · 한양이 장면을 고르는 중…"
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
                // actual decode, so this ends within as many passes as there are sources.
                while true {
                    stage = "plan"
                    baseSelected = mode == .mediaMusic ? VideoTrailerBatchPlan.wholeMedia(sources: sources)
                        : VideoTrailerBatchPlan.selection(sources: sources, total: total,
                            clipLength: clipLength ?? recommendedClipLength)
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
                    stage = "decode-check"
                    status = "장면을 확인하는 중…"
                    if try exclude(try await decodeFailures(in: selected, softwareOnly: true), at: stage) { continue }
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
                    stage = "compose"
                    layout = "sources \(sources.count) skipped \(skippedCount) segments \(selected.count)"
                    diagnostic.segments = selected.count
                    // Reset to this attempt's own actual count: a decode-exclusion pass or a
                    // photo-render failure both land back here with a freshly recomputed
                    // `selected`, never carrying over the previous attempt's total.
                    joinProgress = (0, selected.count)
                    status = "클립 연결 중 · 0/\(selected.count)개"
                    let composition = AVMutableComposition()
                    guard let outputVideo = composition.addMutableTrack(withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TrailerError.exportUnavailable }
                    let outputAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                    cursor = .zero
                    var clipURLs: [URL] = []
                    var imageClipCache: [String: URL] = [:]
                    var originalSound: [TrailerMusicDucking.Clip] = []
                    var instructions: [AVMutableVideoCompositionInstruction] = []
                    var renderSize = aspectRatio?.renderSize
                    // 원본 = the first video of the current order (orientation-correct), even when
                    // a photo comes first; only a photo-only selection falls back to the first photo.
                    if renderSize == nil,
                       let firstVideo = selected.lazy.compactMap({ sourceByID[$0.sourceID] }).first(where: { !$0.isImage }) {
                        guard let size = try await trailerOrientedVideoSize(url: firstVideo.url) else { throw MediaError.videoTrackUnavailable }
                        renderSize = OutputAspectRatio.renderSize(for: size)
                    }
                    for (segmentIndex, segment) in selected.enumerated() {
                        try Task.checkCancellation()
                        guard let source = sourceByID[segment.sourceID] else { throw TrailerError.exportFailed }
                        let naturalSize: CGSize
                        let transform: CGAffineTransform
                        let video: AVAssetTrack
                        let asset: AVURLAsset
                        if source.isImage {
                            if renderSize == nil {
                                let imageSize = try VideoTrailerImageClip.imageSize(at: source.url)
                                renderSize = OutputAspectRatio.renderSize(for: imageSize)
                            }
                            guard let renderSize else { throw TrailerError.exportUnavailable }
                            status = "\(source.name) · 사진 장면을 만드는 중…"
                            stage = "photo-clip"
                            // Still images render at 60% of the final pixel dimensions; the layer
                            // transform below upscales to the full render size, which is the only
                            // part of the export that actually makes photo scenes faster to encode.
                            let photoRenderSize = Self.photoRenderSize(for: renderSize)
                            let cacheKey = "\(source.id):\(Int64((segment.length * 600).rounded())):\(Int(photoRenderSize.width))x\(Int(photoRenderSize.height))"
                            let clipURL: URL
                            if let cached = imageClipCache[cacheKey] {
                                clipURL = cached
                            } else {
                                clipURL = directory.appendingPathComponent("image-clip-\(segment.id)-\(UUID().uuidString)")
                                    .appendingPathExtension("mov")
                                try await Task.detached(priority: .userInitiated) {
                                    try VideoTrailerImageClip.render(imageURL: source.url, duration: segment.length,
                                        renderSize: photoRenderSize, outputURL: clipURL, seed: segment.id ^ generationSeed)
                                }.value
                                clipURLs.append(clipURL)
                                attemptFiles.append(clipURL)
                                imageClipCache[cacheKey] = clipURL
                            }
                            try Task.checkCancellation()
                            asset = AVURLAsset(url: clipURL)
                            guard let imageVideo = try await asset.loadTracks(withMediaType: .video).first else { throw TrailerError.exportFailed }
                            video = imageVideo
                            naturalSize = photoRenderSize
                            transform = CGAffineTransform(scaleX: renderSize.width / photoRenderSize.width,
                                                           y: renderSize.height / photoRenderSize.height)
                            stage = "compose"
                        } else {
                            asset = AVURLAsset(url: source.url)
                            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.videoTrackUnavailable }
                            video = videoTrack
                            naturalSize = try await video.load(.naturalSize)
                            transform = try await video.load(.preferredTransform)
                            if renderSize == nil {
                                let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
                                renderSize = OutputAspectRatio.renderSize(for: CGSize(width: abs(oriented.width), height: abs(oriented.height)))
                            }
                        }
                        guard let renderSize, naturalSize.width > 0, naturalSize.height > 0 else { throw TrailerError.exportUnavailable }
                        let range = source.isImage
                            ? CMTimeRange(start: .zero, duration: CMTime(seconds: segment.length, preferredTimescale: 600))
                            : CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                                          duration: CMTime(seconds: segment.length, preferredTimescale: 600))
                        try outputVideo.insertTimeRange(range, of: video, at: cursor)
                        if !source.isImage, let audio = try await asset.loadTracks(withMediaType: .audio).first, let outputAudio,
                           try await audio.load(.isDecodable) {
                            let audioRange = try await audio.load(.timeRange)
                            let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                            if overlap.duration.seconds > 0 {
                                let audioStart = CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start))
                                try outputAudio.insertTimeRange(overlap, of: audio, at: audioStart)
                                originalSound.append(TrailerMusicDucking.Clip(outputStart: audioStart.seconds,
                                    sourceStart: overlap.start.seconds, length: overlap.duration.seconds,
                                    envelope: activityBySourceID[source.id]))
                            }
                        }
                        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
                        layer.setTransform(source.isImage ? transform : TrailerOutputRenderer.aspectFillTransform(naturalSize: naturalSize,
                            preferredTransform: transform, renderSize: renderSize), at: cursor)
                        let instruction = AVMutableVideoCompositionInstruction()
                        instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
                        instruction.layerInstructions = [layer]
                        instruction.backgroundColor = UIColor.black.cgColor
                        instructions.append(instruction)
                        cursor = CMTimeAdd(cursor, range.duration)
                        // This scene clip is now actually inserted into the composition, so the
                        // count below reflects real completed work, never an estimate.
                        joinProgress = (segmentIndex + 1, selected.count)
                        status = "클립 연결 중 · \(segmentIndex + 1)/\(selected.count)개"
                    }
                    guard let renderSize else { throw TrailerError.exportUnavailable }
                    // An audio track left without any segment (photos only, or videos without sound)
                    // makes the export's media validation reject the whole composition with
                    // AVFoundationErrorDomain -11838 / -16976 "Operation Stopped".
                    if let outputAudio, outputAudio.segments.isEmpty { composition.removeTrack(outputAudio) }
                    var audioMix: AVMutableAudioMix?
                    if let musicInput {
                        stage = "music"
                        guard let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TrailerError.exportUnavailable }
                        // The track's own range, so a leading offset in the file is skipped the
                        // same way on every repeat; the last piece is cut where the video ends.
                        var musicCursor = CMTime.zero
                        var pieces = 0
                        // A hand-set length plays the music once: it is cut where the video
                        // ends, and a longer video goes on with its own sound only.
                        let playsOnce = music?.policy == .single
                        while CMTimeCompare(musicCursor, cursor) < 0, !(playsOnce && pieces == 1) {
                            pieces += 1
                            guard pieces <= TrailerMusic.maximumRepeats else { throw TrailerMusicError.tooManyRepeats }
                            let piece = CMTimeMinimum(musicInput.range.duration, CMTimeSubtract(cursor, musicCursor))
                            try musicTrack.insertTimeRange(CMTimeRange(start: musicInput.range.start, duration: piece),
                                of: musicInput.track, at: musicCursor)
                            musicCursor = CMTimeAdd(musicCursor, piece)
                            diagnostic.music?.pieces = pieces
                        }
                        // One set of parameters, for the music track alone: the original
                        // sound's track has none and is mixed at its normal level.
                        let parameters = AVMutableAudioMixInputParameters(track: musicTrack)
                        let ramps = TrailerMusicDucking.ramps(clips: originalSound, total: musicCursor.seconds,
                                                              enabled: music?.autoDuck ?? true)
                        for ramp in ramps {
                            // Shared boundaries convert to the same time, so ramps never overlap.
                            let rampStart = CMTime(seconds: ramp.start, preferredTimescale: 600)
                            let rampEnd = CMTime(seconds: ramp.end, preferredTimescale: 600)
                            guard CMTimeCompare(rampStart, rampEnd) < 0 else { continue }
                            parameters.setVolumeRamp(fromStartVolume: ramp.from, toEndVolume: ramp.to,
                                timeRange: CMTimeRange(start: rampStart, end: rampEnd))
                        }
                        if music?.autoDuck == false {
                            parameters.setVolume(TrailerMusicDucking.loudVolume, at: .zero)
                        }
                        let mix = AVMutableAudioMix()
                        mix.inputParameters = [parameters]
                        audioMix = mix
                        layout += " music \(pieces) ducked \(ramps.count)"
                        diagnostic.music?.ducked = ramps.count
                        stage = "compose"
                    }
                    let videoComposition = AVMutableVideoComposition()
                    videoComposition.renderSize = renderSize
                    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
                    videoComposition.instructions = instructions
                    guard let session = AVAssetExportSession(asset: composition,
                        presetName: AVAssetExportPresetHighestQuality) else { throw TrailerError.exportUnavailable }
                    let output = directory.appendingPathComponent("trailer-\(UUID().uuidString).mp4")
                    stage = "export"
                    layout += " tracks \(composition.tracks.count) render \(Int(renderSize.width))x\(Int(renderSize.height)) seconds \(Int(cursor.seconds))"
                    diagnostic.tracks = composition.tracks.count
                    diagnostic.renderWidth = Int(renderSize.width)
                    diagnostic.renderHeight = Int(renderSize.height)
                    diagnostic.outputSeconds = cursor.seconds
                    exportOutput = output
                    // A workspace that has already vanished would let the exporter finish into an
                    // unlinked file; fail here with the folder state instead of after the encode.
                    guard FileManager.default.fileExists(atPath: directory.path) else { throw TrailerError.outputMissing }
                    Self.logger.notice("trailer model \(self.identity, privacy: .public) export start: \(layout, privacy: .public) app \(UIApplication.shared.applicationState.rawValue, privacy: .public)")
                    session.videoComposition = videoComposition
                    session.audioMix = audioMix
                    session.outputURL = output
                    session.outputFileType = .mp4
                    session.shouldOptimizeForNetworkUse = true
                    status = "클립 연결 \(selected.count)/\(selected.count)개 · 영상으로 저장 중"
                    exporter = session
                    exportProgress = 0
                    // Mirrors the session's measured progress only while this export runs; it is
                    // cancelled as soon as the session calls back, on every outcome.
                    let progressTask = Task {
                        while !Task.isCancelled {
                            exportProgress = min(0.99, Double(session.progress))
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        session.exportAsynchronously { continuation.resume() }
                    }
                    progressTask.cancel()
                    // The music asset's last use: it is guaranteed alive through every
                    // insert above and the whole export, on every pass of this loop.
                    withExtendedLifetime(musicInput?.asset) { }
                    try Task.checkCancellation()
                    guard session.status == .completed else {
                        exporter = nil
                        exportProgress = nil
                        let failure = session.error ?? TrailerError.exportFailed
                        Self.logger.error("trailer export failed: \(trailerErrorChain(failure), privacy: .public) segments \(selected.count, privacy: .public) tracks \(composition.tracks.count, privacy: .public) render \(Int(renderSize.width), privacy: .public)x\(Int(renderSize.height), privacy: .public)")
                        // The export stops at the first frame it cannot decode without saying which
                        // source it came from, so decode every planned range to find and exclude
                        // exactly those sources; anything else is reported as the failure it is.
                        stage = "decode-check"
                        status = "풀 수 없는 영상을 찾는 중…"
                        guard try exclude(try await decodeFailures(in: selected, softwareOnly: false), at: stage) else {
                            stage = "export"
                            throw failure
                        }
                        // This attempt's own partial output and photo clips are rebuilt next pass.
                        try? FileManager.default.removeItem(at: output)
                        for clipURL in clipURLs { try? FileManager.default.removeItem(at: clipURL) }
                        attemptFiles = []
                        exportOutput = nil
                        continue
                    }
                    exporter = nil
                    exportProgress = 1
                    break
                }
                guard let output = exportOutput else { throw TrailerError.exportFailed }
                Self.logger.notice("trailer model \(self.identity, privacy: .public) export completed: \(Self.workspaceState(directory: directory, output: output, sources: self.sources), privacy: .public)")
                stage = "verify"
                // A finished export whose file is no longer at its path cannot be opened at all
                // (AVFoundationErrorDomain -11800 / -17913); report that instead of a bare code.
                guard FileManager.default.fileExists(atPath: output.path) else { throw TrailerError.outputMissing }
                let outputAsset = AVURLAsset(url: output)
                guard try await outputAsset.load(.isPlayable) else { throw TrailerError.exportFailed }
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
                status = mode == .mediaMusic
                    ? "영상 \(videoTrailerTime(cursor.seconds)) · \(selected.count)개 장면 · 음악 포함"
                    : "원본 \(videoTrailerTime(originalTotal)) → 예고편 \(videoTrailerTime(cursor.seconds)) · \(selected.count)개 클립"
                        + (music == nil ? "" : " · 음악 포함")
            } catch let error where isSuspending && (error is CancellationError || Task.isCancelled) {
                // Left mid-run without discarding: only this attempt's unfinished output and
                // photo clips go. The staged sources, the picked music's copy and an
                // earlier finished video all stay for when the editor is reopened.
                Self.logger.notice("trailer model \(self.identity, privacy: .public) suspended at \(stage, privacy: .public)")
                exporter = nil
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

    func save(to store: SharedInboxStore, filename: String, suffix: String = "예고편") {
        guard let outputURL, !isBusy, !isSaved else { return }
        isBusy = true
        isSaving = true
        error = nil
        task = Task {
            defer { isSaving = false }
            do {
                let base = (filename as NSString).deletingPathExtension
                _ = try await store.importDownloadedFile(at: outputURL,
                    originalFilename: "\(base)-\(suffix).mp4", contentTypeIdentifier: "public.mpeg-4")
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
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
