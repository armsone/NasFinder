import AVFoundation
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 영상 만들기 선택기의 출처 페이지. 순서는 탭과 가로 페이지 순서와 같다.
enum MediaSourcePage: String, CaseIterable, Identifiable {
    case photos = "사진"
    case calendar = "달력"
    case phoneHard = "폰하드"
    case favorites = "즐겨찾기"
    case network = "NAS·네트워크"
    case files = "파일"
    case google = "Google 포토"
    var id: String { rawValue }
}

/// 상단 가로 탭. 터치 영역은 44pt 이상이며 선택된 탭이 보이도록 스크롤한다.
struct MediaSourceTabBar: View {
    @Binding var page: MediaSourcePage

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ui(4)) {
                    ForEach(MediaSourcePage.allCases) { item in
                        Button { page = item } label: {
                            Text(item.rawValue)
                                .font(.ui(.subheadline).weight(page == item ? .bold : .regular))
                                .foregroundStyle(page == item ? SkyBreezeTheme.accent : Color.primary)
                                .padding(.horizontal, ui(12))
                                .frame(minHeight: 44)
                                .overlay(alignment: .bottom) {
                                    if page == item { Capsule().fill(SkyBreezeTheme.accent).frame(height: 3) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item)
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.padding(.horizontal, ui(8))
            }
            .onChange(of: page) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
        }
        .background(.bar)
    }
}

/// 모든 페이지를 한 가로 스크롤에 이어 붙인다. 처음 방문한 페이지만 만들고 이후에는 유지해서
/// 페이지를 넘겨도 폴더 경로·웹 선택 세션이 사라지지 않는다.
struct MediaSourcePager<Content: View>: View {
    @Binding var page: MediaSourcePage
    @State private var visited: Set<MediaSourcePage> = [.photos]
    @State private var scrollID: MediaSourcePage? = .photos
    @ViewBuilder let content: (MediaSourcePage) -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(MediaSourcePage.allCases) { item in
                    Group {
                        if visited.contains(item) { content(item) } else { Color.clear }
                    }
                    .containerRelativeFrame(.horizontal)
                    .frame(maxHeight: .infinity)
                    .id(item)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .onChange(of: scrollID) { _, value in
            if let value, value != page { page = value }
        }
        .onChange(of: page) { _, value in
            visited.insert(value)
            if scrollID != value { withAnimation { scrollID = value } }
        }
    }
}

/// NAS·네트워크 페이지: 저장된 연결을 나열하고 기존 파일 브라우저(선택 모드)를 이 페이지 안에서 연다.
struct MediaNetworkSourcePage: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    let onPickMedia: ([RemoteFileItem], any RemoteFileService) -> Void
    /// 연 연결은 push하지 않고 이 페이지가 가진다. 뒤로가 상위 영상 만들기 화면을 닫지 않게 한다.
    @State private var openedConnection: RemoteConnection?

    var body: some View {
        NavigationStack {
            Group {
                if let openedConnection {
                    FileBrowserContainerView(connection: openedConnection, returnToDashboardAction: {},
                                             onPickMedia: onPickMedia, onExitSelection: { self.openedConnection = nil })
                        .id(openedConnection.id)
                } else if connectionStore.connections.isEmpty {
                    ContentUnavailableView("저장된 연결이 없습니다", systemImage: "externaldrive.badge.questionmark",
                        description: Text("연결 목록에서 NAS·네트워크 연결을 추가하면 여기에 나타납니다."))
                } else {
                    List(connectionStore.connections) { connection in
                        Button { openedConnection = connection } label: {
                            Label(connection.name, systemImage: "externaldrive.connected.to.line.below")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("NAS·네트워크")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 바구니 한 칸의 표시 정보.
struct MediaBasketTrayItem: Identifiable {
    let id: String
    let name: String
    let isVideo: Bool
    let thumbnail: UIImage?
    let asset: PHAsset?
}

/// 모든 출처가 공유하는 하단 썸네일 트레이. 순서는 선택 순서(= 복사·편집 순서)다.
struct MediaBasketTray: View {
    let items: [MediaBasketTrayItem]
    let isBusy: Bool
    let onPreview: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ui(8)) {
                ForEach(items) { item in
                    ZStack(alignment: .topTrailing) {
                        Button { onPreview(item.id) } label: {
                            MediaBasketThumb(item: item)
                                .frame(width: ui(64), height: ui(64))
                                .clipShape(RoundedRectangle(cornerRadius: ui(8)))
                        }
                        .buttonStyle(.plain).disabled(isBusy)
                        .accessibilityLabel("\(item.name) 미리보기")
                        Button { onRemove(item.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.65))
                                .font(.system(size: ui(20)))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(isBusy)
                        .offset(x: 14, y: -14)
                        .accessibilityLabel("\(item.name) 선택 해제")
                    }
                    .frame(width: ui(64), height: ui(64))
                    .padding(.top, 6).padding(.trailing, 6)
                }
            }.padding(.horizontal, ui(12)).padding(.vertical, ui(4))
        }
        .frame(height: ui(64) + 16)
    }
}

private struct MediaBasketThumb: View {
    let item: MediaBasketTrayItem
    @State private var assetImage: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = item.thumbnail ?? assetImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.secondary.opacity(0.15))
                    .overlay(Image(systemName: item.isVideo ? "film" : "photo").foregroundStyle(.secondary))
            }
            if item.isVideo {
                Image(systemName: "play.fill").font(.system(size: ui(10))).foregroundStyle(.white)
                    .padding(ui(3)).shadow(radius: 1)
            }
        }
        .task(id: item.id) {
            guard item.thumbnail == nil, let asset = item.asset else { return }
            assetImage = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 192, height: 192),
                                                      contentMode: .aspectFill, options: options) { image, _ in
                    continuation.resume(returning: image)
                }
            }
        }
    }
}

// MARK: - 파일 페이지

/// 보안 범위 폴더 접근을 페이지 수명 동안 유지한다.
@MainActor
private final class MediaFolderScope: ObservableObject {
    private(set) var url: URL?
    private var didStart = false

    func open(_ newURL: URL) {
        close()
        didStart = newURL.startAccessingSecurityScopedResource()
        url = newURL
    }
    func close() {
        if didStart { url?.stopAccessingSecurityScopedResource() }
        didStart = false
        url = nil
    }
    deinit { if didStart { url?.stopAccessingSecurityScopedResource() } }
}

/// iPhone에서 시스템 문서 선택기를 전체 화면으로 모달 표시한다. 임베드하지 않고 취소 시 빈 선택으로 끝낸다.
struct MediaDocumentPicker: UIViewControllerRepresentable {
    let onFinish: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image, .movie], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Result<[URL], Error>) -> Void
        init(onFinish: @escaping (Result<[URL], Error>) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(.success(urls))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(.success([]))
        }
    }
}

/// 시스템 선택기로 이미 바스켓에 담은 파일(복사본의 썸네일 재사용). 파일 탭 안에서 바로 보이고 해제할 수 있다.
struct MediaImportedFile: Identifiable {
    let id: String
    let name: String
    let isVideo: Bool
    let thumbnail: UIImage?
}

private struct MediaFolderEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let isVideo: Bool
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

/// 파일 페이지: 사용자가 고른 폴더(보안 범위 북마크로 기억)를 실제로 탐색해 사진·영상 썸네일 격자로 보여준다.
/// iOS는 전체 파일시스템을 열거할 수 없으므로 앱이 접근 권한을 받은 폴더만 나타낸다.
/// 다른 Files 제공자의 파일은 보조 버튼(시스템 파일 선택기)으로 고른다.
struct MediaFilesSourcePage: View {
    private static let bookmarkKey = "mediaSourcePage.filesFolderBookmark.v1"
    let selectedIDs: Set<String>
    var isActive = true
    var refreshToken = 0
    var imported: [MediaImportedFile] = []
    let onToggle: (URL) -> Void
    let onRemoveImported: (String) -> Void
    let onOpenSystemImporter: () -> Void

    @StateObject private var scope = MediaFolderScope()
    @State private var rootURL: URL?
    @State private var trail: [URL] = []
    @State private var entries: [MediaFolderEntry] = []
    @State private var isLoading = false
    @State private var isChoosingFolder = false
    @State private var message: String?
    @State private var loadError: String?
    @State private var loadTask: Task<Void, Never>?
    private let columns = [GridItem(.adaptive(minimum: ui(92), maximum: ui(120)), spacing: ui(8))]
    private var currentURL: URL? { trail.last ?? rootURL }
    /// 폴더 목록에 이미 같은 파일 키로 보이는 항목은 중복 표시하지 않는다.
    private var otherImported: [MediaImportedFile] {
        let listed = Set(entries.filter { !$0.isDirectory }.map { "file:" + $0.url.standardizedFileURL.path })
        return imported.filter { !listed.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if rootURL == nil {
                if imported.isEmpty {
                    ContentUnavailableView {
                        Label("파일의 사진·영상", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("사진·영상을 바로 추가하세요. 폴더 연결은 선택 사항입니다.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: ui(8)) { importedTiles(imported) }.padding(ui(8))
                    }
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("폴더를 불러오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("다시 시도") { reload() }.buttonStyle(.borderedProminent)
                    Button("폴더 변경") { isChoosingFolder = true }
                }
            } else if entries.isEmpty && otherImported.isEmpty {
                ContentUnavailableView("이 폴더에 사진·영상이 없습니다", systemImage: "photo.on.rectangle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: ui(8)) {
                        ForEach(entries) { entry in tile(entry) }
                    }.padding(ui(8))
                    if !otherImported.isEmpty {
                        Text("선택한 다른 파일").font(.ui(.footnote)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, ui(8))
                        LazyVGrid(columns: columns, spacing: ui(8)) { importedTiles(otherImported) }.padding(ui(8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): adopt(url)
            case let .failure(error):
                let cocoa = error as NSError
                if !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.Code.userCancelled.rawValue) {
                    message = "폴더를 열지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
        .alert("알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .task { restoreBookmark() }
        .onChange(of: isActive) { _, active in if active, rootURL != nil { reload() } }
        .onChange(of: refreshToken) { _, _ in if rootURL != nil { reload() } }
        .onDisappear { loadTask?.cancel() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: ui(8)) {
                Button { onOpenSystemImporter() } label: {
                    Label("사진·영상 추가", systemImage: "plus.circle.fill").frame(minHeight: 44)
                }
                Spacer()
                Button { isChoosingFolder = true } label: {
                    Label(rootURL == nil ? "폴더 열기" : "폴더 변경", systemImage: "folder").frame(minHeight: 44)
                }
            }
            .font(.ui(.footnote)).padding(.horizontal, ui(12))
            if let rootURL {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ui(2)) {
                        crumb(rootURL.lastPathComponent, systemImage: "house") { go(to: 0) }
                        ForEach(Array(trail.enumerated()), id: \.offset) { index, url in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            crumb(url.lastPathComponent, systemImage: nil) { go(to: index + 1) }
                        }
                    }.padding(.horizontal, ui(12))
                }
                if !trail.isEmpty {
                    Button { go(to: trail.count - 1) } label: {
                        Label("상위 폴더", systemImage: "arrow.up.left").frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                    }.font(.ui(.footnote)).padding(.horizontal, ui(12))
                }
            }
        }
    }

    private func crumb(_ title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ui(4)) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }.font(.ui(.footnote)).padding(.horizontal, ui(8)).frame(minHeight: 44)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func importedTiles(_ files: [MediaImportedFile]) -> some View {
        ForEach(files) { file in
            Button { onRemoveImported(file.id) } label: {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let thumbnail = file.thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                        else { Rectangle().fill(.secondary.opacity(0.15)).overlay(Image(systemName: file.isVideo ? "film" : "photo").foregroundStyle(.secondary)) }
                    }
                    .frame(maxWidth: .infinity).frame(height: ui(100)).clipped()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(ui(4))
                }.clipShape(RoundedRectangle(cornerRadius: ui(10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.name).accessibilityHint("선택 해제")
            .accessibilityAddTraits(.isSelected)
        }
    }

    @ViewBuilder private func tile(_ entry: MediaFolderEntry) -> some View {
        if entry.isDirectory {
            Button { trail.append(entry.url); reload() } label: {
                VStack(spacing: ui(4)) {
                    Image(systemName: "folder.fill").font(.system(size: ui(36))).foregroundStyle(SkyBreezeTheme.folderBlue)
                    Text(entry.name).font(.ui(.caption)).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: ui(100))
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: ui(10)))
            }.buttonStyle(.plain)
        } else {
            let selected = selectedIDs.contains("file:" + entry.url.standardizedFileURL.path)
            Button { onToggle(entry.url) } label: {
                ZStack(alignment: .bottomTrailing) {
                    MediaFolderThumb(url: entry.url, isVideo: entry.isVideo)
                        .frame(height: ui(100)).clipped()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(ui(4))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: ui(10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name).accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private var bookmarkOptions: URL.BookmarkCreationOptions {
        #if targetEnvironment(macCatalyst)
        [.withSecurityScope]
        #else
        []
        #endif
    }
    private var resolveOptions: URL.BookmarkResolutionOptions {
        #if targetEnvironment(macCatalyst)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private func adopt(_ url: URL) {
        scope.open(url)
        if let data = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        rootURL = url
        trail = []
        reload()
    }

    private func restoreBookmark() {
        guard rootURL == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            message = "저장된 폴더에 더 이상 접근할 수 없습니다. 필요하면 폴더를 다시 열어 주세요."
            return
        }
        scope.open(url)
        if stale, let fresh = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        rootURL = url
        reload()
    }

    private func go(to depth: Int) {
        trail = Array(trail.prefix(depth))
        reload()
    }

    private func reload() {
        guard let folder = currentURL else { return }
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        loadTask = Task {
            do {
                let listed = try await Task.detached(priority: .userInitiated) { try Self.list(folder) }.value
                try Task.checkCancellation()
                guard currentURL == folder else { return }
                entries = listed
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, currentURL == folder else { return }
                entries = []
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    nonisolated private static func list(_ folder: URL) throws -> [MediaFolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentTypeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        var result: [MediaFolderEntry] = []
        for url in urls {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                result.append(MediaFolderEntry(url: url, isDirectory: true, isVideo: false))
                continue
            }
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension.lowercased())
            let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            if isVideo || type?.conforms(to: .image) == true {
                result.append(MediaFolderEntry(url: url, isDirectory: false, isVideo: isVideo))
            }
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct MediaFolderThumb: View {
    let url: URL
    let isVideo: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.secondary.opacity(0.15)).overlay(Image(systemName: isVideo ? "film" : "photo").foregroundStyle(.secondary)) }
        }
        .frame(maxWidth: .infinity)
        .task(id: url) {
            let url = url, isVideo = isVideo
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                if isVideo {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 240, height: 240)
                    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
                    return UIImage(cgImage: cg)
                }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 240]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }.value
        }
    }
}
