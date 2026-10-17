import Combine
import SwiftUI

/// Fetches one remote music file at a time for the music picker, either to audition it
/// or to use it. The server is only ever listed and downloaded from. Every file this
/// object creates lives in its own per-picker temporary folder, and that folder is the
/// only thing it ever deletes; the URL a service hands back is copied, never removed.
@MainActor
final class TrailerMusicRemoteLoader: ObservableObject {
    enum Purpose {
        case audition, use
    }

    enum Phase {
        case downloading, checking, importing
    }

    struct Active {
        let operationID: UUID
        let item: RemoteFileItem
        var purpose: Purpose
        var phase: Phase = .downloading
        var completedByteCount: Int64 = 0
        var totalByteCount: Int64?

        /// nil until the backend has reported real bytes against a known total.
        var fractionCompleted: Double? {
            guard let totalByteCount, totalByteCount > 0, completedByteCount > 0 else { return nil }
            return min(1, Double(completedByteCount) / Double(totalByteCount))
        }
    }

    @Published private(set) var active: Active?
    /// Measured length of every file already copied into the session folder.
    @Published private(set) var durations: [String: Double] = [:]
    @Published private(set) var unusable: [String: String] = [:]
    /// Set once a remote file has been stored in PhoneHard's Music folder for use.
    @Published private(set) var selection: TrailerMusicSelection?
    @Published var failure: String?

    /// The trailer picker needs a 1 second to 1 hour track; plain playback does not.
    var enforcesTrailerLimits = true

    private let sessionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NasFinderTrailerMusic", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var copies: [String: URL] = [:]
    /// Files this picker already imported, so choosing one again makes no second copy.
    private var imported: [String: TrailerMusicSelection] = [:]
    private var task: Task<Void, Never>?
    private var audition: TrailerMusicAuditionPlayer?
    private var inboxStore: SharedInboxStore?

    deinit {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    var isImporting: Bool { active?.phase == .importing }

    func attach(audition: TrailerMusicAuditionPlayer, inboxStore: SharedInboxStore? = nil) {
        self.audition = audition
        self.inboxStore = inboxStore
    }

    func request(_ item: RemoteFileItem, purpose: Purpose, using service: any RemoteFileService) {
        if purpose == .audition, audition?.playingID == item.id {
            audition?.stop()
            return
        }
        if var current = active {
            // The download already running for this file is kept; only its goal changes.
            guard current.item.id == item.id, purpose == .use, current.purpose == .audition,
                  current.phase != .importing else { return }
            current.purpose = .use
            active = current
            return
        }
        guard unusable[item.id] == nil else { return }
        if purpose == .audition {
            if let copy = copies[item.id], durations[item.id] != nil {
                audition?.toggle(id: item.id, url: copy)
                return
            }
            audition?.stop()
        }
        let operationID = UUID()
        active = Active(operationID: operationID, item: item, purpose: purpose, totalByteCount: item.size)
        task = Task { [weak self] in
            await self?.run(item, service: service, operationID: operationID)
        }
    }

    /// Stops the download in progress. A result that still arrives later is dropped.
    func cancel() {
        guard let active, active.phase != .importing else { return }
        task?.cancel()
        task = nil
        self.active = nil
    }

    /// Stops playback and any transfer, then removes this picker's own temporary copies.
    func reset() {
        audition?.stop()
        task?.cancel()
        task = nil
        active = nil
        copies = [:]
        durations = [:]
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func run(_ item: RemoteFileItem, service: any RemoteFileService, operationID: UUID) async {
        do {
            let staged = try await stagedCopy(of: item, service: service, operationID: operationID)
            guard let current = active, current.operationID == operationID else { return }
            if current.purpose == .use {
                try await importCopy(of: item, url: staged.url, duration: staged.duration, operationID: operationID)
            } else {
                active = nil
                // Something else started playing meanwhile: leave this one ready instead.
                if audition?.playingID == nil {
                    audition?.toggle(id: item.id, url: staged.url)
                }
            }
        } catch {
            guard active?.operationID == operationID else { return }
            active = nil
            if let error = error as? TrailerMusicError {
                unusable[item.id] = error.shortTitle
            } else if !RemoteRequestCancellation.isCancellation(error) {
                failure = error.localizedDescription
            }
        }
    }

    private func stagedCopy(
        of item: RemoteFileItem,
        service: any RemoteFileService,
        operationID: UUID
    ) async throws -> (url: URL, duration: Double) {
        if let url = copies[item.id], let duration = durations[item.id] {
            return (url, duration)
        }
        let directory = sessionDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The returned file may be the shared download cache's own entry, so it is only
        // read here, and kept from being trimmed until the copy is made.
        await DownloadCache.shared.protect(item)
        let copy: URL
        do {
            let downloaded = try await service.download(item) { [weak self] progress in
                await self?.report(progress, operationID: operationID)
            }
            try Task.checkCancellation()
            let nameExtension = (item.name as NSString).pathExtension
            let fileExtension = nameExtension.isEmpty ? downloaded.pathExtension : nameExtension
            let filename = UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            let destination = directory.appendingPathComponent(filename)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: downloaded, to: destination)
            }.value
            copy = destination
        } catch {
            await DownloadCache.shared.release(item)
            throw error
        }
        await DownloadCache.shared.release(item)
        var playable = copy
        do {
            guard active?.operationID == operationID else { throw CancellationError() }
            active?.phase = .checking
            // MPEG audio inside a WAVE wrapper is unwrapped into this session's own copy.
            if let unwrapped = await Task.detached(priority: .userInitiated, operation: {
                WAVEMPEGUnwrapper.unwrappedCopy(of: copy)
            }).value {
                try? FileManager.default.removeItem(at: copy)
                playable = unwrapped
            }
            try Task.checkCancellation()
            let duration: Double
            if enforcesTrailerLimits {
                duration = try await TrailerMusic.usableDuration(of: playable)
            } else {
                // Plain playback: the player itself decides whether the file opens.
                duration = (try? await TrailerMusic.measuredDuration(of: playable)) ?? 0
            }
            guard active?.operationID == operationID else { throw CancellationError() }
            copies[item.id] = playable
            durations[item.id] = duration
            return (playable, duration)
        } catch {
            try? FileManager.default.removeItem(at: playable)
            throw error
        }
    }

    private func importCopy(of item: RemoteFileItem, url: URL, duration: Double, operationID: UUID) async throws {
        guard let inboxStore else { throw CocoaError(.fileNoSuchFile) }
        if let existing = imported[item.id], inboxStore.records.contains(where: { $0.id == existing.recordID }),
           FileManager.default.fileExists(atPath: existing.url.path) {
            active = nil
            selection = existing
            return
        }
        try Task.checkCancellation()
        // The import itself cannot be cancelled half way, so the picker stays put for it.
        active?.phase = .importing
        let record = try await inboxStore.importMusicFile(
            at: url,
            originalFilename: item.name,
            contentTypeIdentifier: item.contentTypeIdentifier
        )
        let picked = TrailerMusicSelection(recordID: record.id, name: record.originalFilename,
                                           url: try SharedInbox.fileURL(for: record),
                                           duration: duration, policy: .loopMusic)
        imported[item.id] = picked
        guard active?.operationID == operationID else { return }
        active = nil
        selection = picked
    }

    private func report(_ progress: RemoteDownloadProgress, operationID: UUID) {
        // Some backends deliver progress out of order; the count only ever moves forward.
        guard var current = active, current.operationID == operationID, current.phase == .downloading,
              progress.completedByteCount >= current.completedByteCount else { return }
        current.completedByteCount = progress.completedByteCount
        current.totalByteCount = progress.totalByteCount ?? current.totalByteCount
        active = current
    }
}

/// Rows for the picker's network tab: every saved connection, opened at its start folder.
struct TrailerMusicNetworkRows: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @ObservedObject var loader: TrailerMusicRemoteLoader
    @ObservedObject var audition: TrailerMusicAuditionPlayer

    var body: some View {
        if connectionStore.connections.isEmpty {
            Text("연결된 NAS가 없습니다. 먼저 NasFinder에 네트워크 연결을 추가해 주세요.")
                .font(.ui(.footnote)).foregroundStyle(.secondary)
        }
        ForEach(connectionStore.connections) { connection in
            NavigationLink {
                TrailerMusicRemoteLocationView(connection: connection, path: connection.normalizedRootPath,
                                               title: nil, loader: loader, audition: audition)
            } label: {
                connectionRow(connection)
            }
        }
    }

    private func connectionRow(_ connection: RemoteConnection) -> some View {
        HStack(spacing: ui(12)) {
            Image(systemName: connection.kind.systemImage)
                .font(.ui(.title3))
                .foregroundStyle(.tint)
                .frame(width: ui(34), height: ui(34))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ui(3)) {
                Text(connection.name)
                    .font(.ui(.headline))
                Text(connection.endpointDescription)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(connection.normalizedRootPath, systemImage: "folder")
                    .font(.ui(.caption2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, ui(3))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(connection.name), \(connection.kind.title)")
        .accessibilityValue("시작 폴더 \(connection.normalizedRootPath)")
        .accessibilityHint("음악을 고를 폴더를 엽니다.")
    }
}

/// Rows for the picker's favorites tab. Only folder favorites are listed; one whose
/// connection is gone stays visible but cannot be opened.
struct TrailerMusicFavoriteRows: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @ObservedObject var loader: TrailerMusicRemoteLoader
    @ObservedObject var audition: TrailerMusicAuditionPlayer

    private var folders: [FavoriteItem] {
        favoriteStore.items.filter { $0.kind == .folder }
    }

    var body: some View {
        if folders.isEmpty {
            Text("즐겨찾기한 폴더가 없습니다.")
                .font(.ui(.footnote)).foregroundStyle(.secondary)
        }
        ForEach(folders) { favorite in
            if let connection = connectionStore.connections.first(where: { $0.id == favorite.connectionID }) {
                NavigationLink {
                    TrailerMusicRemoteLocationView(connection: connection, path: favorite.path,
                                                   title: favorite.name, loader: loader, audition: audition)
                } label: {
                    favoriteRow(favorite, detail: connection.name, available: true)
                }
            } else {
                favoriteRow(favorite, detail: "연결을 찾을 수 없습니다", available: false)
            }
        }
    }

    private func favoriteRow(_ favorite: FavoriteItem, detail: String, available: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(favorite.name)
                    .foregroundStyle(available ? Color.primary : Color.secondary)
                    .lineLimit(2)
                Text(detail)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: available ? "folder.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(available ? SkyBreezeTheme.folderBlue : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Builds the connection's service once from its saved login and opens one folder of it.
private struct TrailerMusicRemoteLocationView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var service: (any RemoteFileService)? = nil
    @State private var didResolveService = false

    let connection: RemoteConnection
    let path: String
    let title: String?
    @ObservedObject var loader: TrailerMusicRemoteLoader
    @ObservedObject var audition: TrailerMusicAuditionPlayer

    var body: some View {
        Group {
            if !didResolveService {
                ProgressView("연결을 준비하는 중…")
            } else if let service {
                TrailerMusicRemoteFolderView(connection: connection, path: path, service: service,
                                             title: title, loader: loader, audition: audition)
            } else {
                ContentUnavailableView {
                    Label("로그인 정보 없음", systemImage: "key.slash")
                } description: {
                    Text("연결을 수정해 비밀번호를 다시 저장한 뒤 시도해 주세요.")
                }
                .navigationTitle(title ?? connection.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            resolveServiceIfNeeded()
        }
    }

    @MainActor
    private func resolveServiceIfNeeded() {
        guard !didResolveService else { return }
        defer { didResolveService = true }
        guard let credential = try? connectionStore.credential(for: connection) else {
            return
        }
        service = RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

/// One remote folder showing only its folders and music files. Folders push another
/// copy of this view; a music file can be auditioned or used, as two separate buttons.
private struct TrailerMusicRemoteFolderView: View {
    @StateObject private var viewModel: FileBrowserViewModel

    private let connection: RemoteConnection
    private let service: any RemoteFileService
    private let title: String?
    @ObservedObject private var loader: TrailerMusicRemoteLoader
    @ObservedObject private var audition: TrailerMusicAuditionPlayer

    @MainActor
    init(
        connection: RemoteConnection,
        path: String,
        service: any RemoteFileService,
        title: String?,
        loader: TrailerMusicRemoteLoader,
        audition: TrailerMusicAuditionPlayer
    ) {
        self.connection = connection
        self.service = service
        self.title = title
        _loader = ObservedObject(wrappedValue: loader)
        _audition = ObservedObject(wrappedValue: audition)
        _viewModel = StateObject(
            wrappedValue: FileBrowserViewModel(
                connection: connection,
                path: path,
                service: service
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("폴더를 불러오는 중…")
            } else if let errorMessage = viewModel.errorMessage,
                      viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label("폴더를 열 수 없습니다", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("다시 시도") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("음악이 없습니다", systemImage: "music.note")
                } description: {
                    Text("이 폴더에는 하위 폴더나 음악 파일이 없습니다.")
                }
            } else {
                List(entries) { item in
                    if item.isDirectory {
                        NavigationLink {
                            TrailerMusicRemoteFolderView(connection: connection, path: item.path, service: service,
                                                         title: nil, loader: loader, audition: audition)
                        } label: {
                            Label {
                                Text(item.name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(SkyBreezeTheme.folderBlue)
                            }
                        }
                    } else {
                        musicRow(item)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.load()
                }
            }
        }
        .navigationTitle(title ?? currentFolderName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
    }

    private var entries: [RemoteFileItem] {
        viewModel.displayedItems.filter { $0.isDirectory || $0.isAudio }
    }

    private var currentFolderName: String {
        let name = (viewModel.path as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == "/" {
            return connection.name
        }
        return name
    }

    private func musicRow(_ item: RemoteFileItem) -> some View {
        let isPlaying = audition.playingID == item.id
        let isActive = loader.active?.item.id == item.id
        let isBlocked = loader.unusable[item.id] != nil || (loader.active != nil && !isActive)
        // While this file is being fetched for an audition, "사용" may still take it over.
        let canUse = !isBlocked && (!isActive || (loader.active?.purpose == .audition && !loader.isImporting))
        return HStack(spacing: ui(10)) {
            Button {
                loader.request(item, purpose: .audition, using: service)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.ui(.title3))
                    .foregroundStyle(isPlaying || !(isBlocked || isActive) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isPlaying && (isBlocked || isActive))
            .accessibilityLabel(isPlaying ? "미리듣기 정지" : "미리듣기 재생")

            VStack(alignment: .leading, spacing: ui(2)) {
                Text(item.name).lineLimit(2)
                Text(detail(for: item, isActive: isActive))
                    .font(.ui(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: ui(8))
            Button("사용") {
                loader.request(item, purpose: .use, using: service)
            }
            .buttonStyle(.bordered)
            .disabled(!canUse)
            .accessibilityLabel("\(item.name) 사용")
        }
    }

    private func detail(for item: RemoteFileItem, isActive: Bool) -> String {
        if let reason = loader.unusable[item.id] { return reason }
        var parts: [String] = []
        if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let duration = loader.durations[item.id] {
            parts.append(videoTrailerTime(duration))
        }
        if isActive {
            parts.append(loader.isImporting ? "저장 중…" : "받는 중…")
        }
        return parts.isEmpty ? "음악" : parts.joined(separator: " · ")
    }
}

/// Shows the one remote transfer in progress under every screen of the picker: real
/// bytes when the backend reports them against a known total, a spinner otherwise.
struct TrailerMusicDownloadBanner: View {
    let active: TrailerMusicRemoteLoader.Active
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: ui(12)) {
            VStack(alignment: .leading, spacing: ui(6)) {
                Text(title)
                    .font(.ui(.subheadline).weight(.semibold))
                    .lineLimit(1)
                if active.phase == .downloading, let fraction = active.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                if let byteText {
                    Text(byteText)
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: ui(8))
            if active.phase != .importing {
                Button("취소", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, ui(16))
        .padding(.vertical, ui(10))
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch active.phase {
        case .downloading: "\(active.item.name) 받는 중…"
        case .checking: "\(active.item.name) 확인하는 중…"
        case .importing: "폰하드 Music 폴더에 저장하는 중…"
        }
    }

    private var byteText: String? {
        guard active.phase == .downloading, active.completedByteCount > 0 else { return nil }
        let completed = ByteCountFormatter.string(fromByteCount: active.completedByteCount, countStyle: .file)
        guard let total = active.totalByteCount, total > 0 else { return completed }
        return "\(completed) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

/// Plays one music file at a time from a file list, without leaving it. Remote files are
/// fetched through the music picker's loader (the saved connection's own service and a
/// private temporary copy); files already on the device play from where they are.
@MainActor
final class InlineMusicPlayback: ObservableObject {
    enum State: Equatable {
        case idle, loading(Double?), playing(Double), paused(Double), unusable
    }

    private let player = TrailerMusicAuditionPlayer()
    private let loader = TrailerMusicRemoteLoader()
    private var observers: [AnyCancellable] = []
    /// Lengths learned from playback, kept for as long as this list lives.
    @Published private var playedDurations: [String: Double] = [:]

    init() {
        loader.enforcesTrailerLimits = false
        loader.attach(audition: player)
        observers = [
            player.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            loader.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
            player.$duration.sink { [weak self] seconds in
                guard let self, seconds > 0, let id = self.player.playingID else { return }
                self.playedDurations[id] = seconds
            }
        ]
    }

    /// Why the last attempt did not play, until dismissed.
    var failure: String? {
        get { player.failure ?? loader.failure }
        set { player.failure = newValue; loader.failure = newValue }
    }

    func state(for id: String) -> State {
        if player.playingID == id {
            return player.isPaused ? .paused(player.progress) : .playing(player.progress)
        }
        if let active = loader.active, active.item.id == id { return .loading(active.fractionCompleted) }
        return loader.unusable[id] == nil ? .idle : .unusable
    }

    /// Seconds played so far by the track that is playing or paused.
    func elapsed(for id: String) -> Double? {
        player.playingID == id ? player.elapsed : nil
    }

    /// The track's length once playback has measured it; nil while unknown.
    func knownDuration(for id: String) -> Double? {
        let seconds = playedDurations[id] ?? loader.durations[id]
        return seconds.flatMap { $0 > 0 ? $0 : nil }
    }

    func toggle(_ item: RemoteFileItem, using service: any RemoteFileService) {
        if player.playingID == item.id { return player.pauseOrResume() }
        let wasLoading = loader.active?.item.id == item.id
        loader.cancel()
        // A second tap on the file being fetched gives up on it.
        guard !wasLoading else { return }
        player.stop()
        loader.request(item, purpose: .audition, using: service)
    }

    func toggle(id: String, localURL: URL) {
        if player.playingID == id { return player.pauseOrResume() }
        loader.cancel()
        player.toggle(id: id, url: localURL)
    }

    /// Stops playback and any transfer and drops the temporary copies.
    func stop() {
        loader.reset()
    }
}

/// "size · total" while idle and "elapsed / total" for the selected track, m:ss or
/// h:mm:ss. Draws nothing for a length that is still unknown.
struct InlineMusicTimeText: View {
    @ObservedObject var playback: InlineMusicPlayback
    let id: String
    /// A length already known elsewhere (a PhoneHard file read by its own cache).
    var fallbackTotal: Double?
    /// A PhoneHard item whose length its own cheap reader may supply while idle.
    var localItem: RemoteFileItem?

    var body: some View {
        let total = playback.knownDuration(for: id) ?? fallbackTotal
        switch playback.state(for: id) {
        case .playing, .paused:
            let elapsed = Self.format(playback.elapsed(for: id) ?? 0)
            let text = total.map { "\(elapsed) / \(Self.format($0))" } ?? elapsed
            Text("· \(text)")
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel("재생 \(text)")
        default:
            if let total {
                Text("· \(Self.format(total))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("재생 시간 \(Self.format(total))")
            } else if let localItem {
                LocalInboxDurationLabel(item: localItem)
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The play button over a music file's thumbnail: a play symbol, then a ring showing
/// the playing position with a pause symbol (play while paused). It takes its own tap
/// ahead of the row's, so the file is not opened.
struct InlineMusicThumbnailControl: View {
    @ObservedObject var playback: InlineMusicPlayback
    let id: String
    let name: String
    let action: () -> Void

    var body: some View {
        let state = playback.state(for: id)
        ZStack {
            Circle().fill(.black.opacity(0.5)).padding(ui(8))
            switch state {
            case .loading(let fraction):
                if let fraction {
                    ring(fraction)
                } else {
                    ProgressView().tint(.white)
                }
            case .playing(let progress), .paused(let progress):
                ring(progress)
            case .idle, .unusable:
                EmptyView()
            }
            Image(systemName: symbol(for: state))
                .font(.system(size: ui(15), weight: .bold))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(TapGesture().onEnded { action() })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label(for: state))
        .accessibilityValue(value(for: state))
        .accessibilityAction(.default, action)
    }

    private func ring(_ fraction: Double) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: ui(2.5))
            Circle().trim(from: 0, to: max(0.01, fraction))
                .stroke(.white, style: StrokeStyle(lineWidth: ui(2.5), lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(ui(5))
    }

    private func symbol(for state: InlineMusicPlayback.State) -> String {
        switch state {
        case .playing: "pause.fill"
        case .loading: "xmark"
        case .unusable: "exclamationmark.triangle.fill"
        case .idle, .paused: "play.fill"
        }
    }

    private func label(for state: InlineMusicPlayback.State) -> String {
        switch state {
        case .playing: "\(name) 일시정지"
        case .loading: "\(name) 불러오기 취소"
        case .unusable: "\(name) 재생할 수 없음"
        case .idle, .paused: "\(name) 재생"
        }
    }

    private func value(for state: InlineMusicPlayback.State) -> String {
        switch state {
        case .playing(let progress), .paused(let progress): "\(Int(progress * 100))%"
        case .loading(let fraction): fraction.map { "불러오는 중 \(Int($0 * 100))%" } ?? "불러오는 중"
        case .idle, .unusable: ""
        }
    }
}
