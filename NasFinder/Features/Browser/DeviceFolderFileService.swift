import CryptoKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// 기기 파일: 사용자가 시스템 폴더 선택기로 한 번 허락한 폴더를 파인더와 같은 화면으로 앱 안에서 연다.
/// 원본은 읽기만 한다. 만들기·이름 바꾸기·삭제·올리기·복사·이동 기능은 없고(`capabilities` 비어 있음),
/// 내려받기는 원본 대신 이 접근이 가진 앱 임시 폴더의 사본을 돌려준다. 그래서 받은 파일을 지우는
/// 화면(썸네일·미리보기 정리 등)이 있어도 원본에는 닿지 않는다.

/// 허락된 폴더에 대한 보안 범위 접근 한 번. 만들 때 열고 마지막 참조가 사라질 때 닫는다(start/stop 한 쌍).
/// 파인더 화면·재료함 받기·편집기 경로가 서비스를 붙잡고 있는 동안만 열려 있다.
/// 닫을 때 이 접근이 만든 사본 폴더(앱 임시 폴더 안의 자기 폴더)만 지운다.
final class DeviceFolderAccess: @unchecked Sendable {
    let rootURL: URL
    let copiesDirectory: URL
    private let didStartAccess: Bool

    init(rootURL: URL) {
        self.rootURL = rootURL
        didStartAccess = rootURL.startAccessingSecurityScopedResource()
        copiesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NasFinderDeviceFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: copiesDirectory)
        if didStartAccess { rootURL.stopAccessingSecurityScopedResource() }
    }

    /// 접근을 연 뒤에도 폴더로 보이는지. 옮겨졌거나 외장 디스크가 빠졌으면 false.
    var isReachableFolder: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 선택한 폴더 위에 폴더가 더 있는지(파일 시스템 맨 위가 아닌지).
    var hasParentFolder: Bool { rootURL.standardizedFileURL.pathComponents.count > 1 }

    /// 지금 이 앱이 그 폴더의 목록을 읽을 수 있는지. 읽을 수 없으면 아직 허락되지 않은 폴더다.
    static func canList(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// 허락된 폴더의 실제 경로에서 결정론적으로 만든 고유 식별자.
    /// 폴더가 바뀌면 다른 connectionID가 되어 다른 루트 간 같은 이름의 파일 충돌을 막는다.
    var connectionID: UUID {
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// 허락된 폴더를 기억하는 북마크. 영상 만들기 파일 페이지와 같은 키·옵션을 써서 권한을 따로 늘리지 않는다.
@MainActor
enum DeviceFolderBookmark {
    enum Restored {
        /// 아직 허락한 폴더가 없다.
        case none
        case granted(DeviceFolderAccess)
        /// 기억한 폴더를 열 수 없다. 북마크는 지우지 않고 사용자가 다시 시도하거나 새로 고르게 한다.
        case unavailable
    }

    private static var key: String { MediaFilesSourcePage.bookmarkKey }

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if targetEnvironment(macCatalyst)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if targetEnvironment(macCatalyst)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    static func restore() -> Restored {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .none }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return .unavailable }
        let access = DeviceFolderAccess(rootURL: url)
        guard access.isReachableFolder else { return .unavailable }
        // 오래된 북마크는 접근을 연 상태에서 새로 만들어 같은 키에 바꿔 둔다.
        if stale, let fresh = try? url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return .granted(access)
    }

    /// 시스템 선택기로 고른 폴더를 연다. 기억하지 못해도 이번에 연 접근은 돌려준다(`remembered` = false).
    static func adopt(_ url: URL) -> (access: DeviceFolderAccess, remembered: Bool)? {
        let access = DeviceFolderAccess(rootURL: url)
        guard access.isReachableFolder else { return nil }
        guard let data = try? url.bookmarkData(
            options: creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return (access, false) }
        UserDefaults.standard.set(data, forKey: key)
        return (access, true)
    }
}

enum DeviceFolderFileError: LocalizedError {
    case outsideFolder
    case notAFile

    var errorDescription: String? {
        switch self {
        case .outsideFolder: "허락한 폴더 밖의 위치는 열 수 없습니다."
        case .notAFile: "파일을 찾을 수 없습니다."
        }
    }
}

/// 허락된 폴더 하나를 파인더·미리보기·재료함·편집기에 원격 연결처럼 넘기는 읽기 전용 서비스.
struct DeviceFolderFileService: RemoteFileService {
    static let baseConnectionID = UUID(uuidString: "3B7E52C4-9A0D-4F61-8E2B-6C1D5A9F0E47")!
    static let rootPath = "/"

    /// 기본 정적 연결 (접근이 없을 때 호환성 유지용)
    static var deviceFolderConnection: RemoteConnection {
        RemoteConnection(
            id: baseConnectionID,
            name: "기기 파일",
            kind: .synology,
            host: "localhost",
            username: "",
            rootPath: rootPath
        )
    }

    static func connection(for access: DeviceFolderAccess) -> RemoteConnection {
        RemoteConnection(
            id: access.connectionID,
            name: "기기 파일",
            kind: .synology,
            host: "localhost",
            username: "",
            rootPath: rootPath
        )
    }

    let connection: RemoteConnection
    /// 읽기 전용: 원본을 만들거나 바꾸거나 옮기거나 지우는 기능은 없다.
    let capabilities: RemoteFileServiceCapabilities = []
    /// 미리보기 썸네일이 없다고 영상 전체를 사본으로 받지 않는다.
    var permitsFullDownloadForVideoThumbnail: Bool { false }

    let access: DeviceFolderAccess

    init(access: DeviceFolderAccess) {
        self.access = access
        self.connection = Self.connection(for: access)
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let browserPath = Self.normalized(path ?? Self.rootPath)
        let folder = try fileURL(forBrowserPath: browserPath)
        let connectionID = connection.id
        return try await Task.detached(priority: .userInitiated) {
            try Self.items(in: folder, browserPath: browserPath, connectionID: connectionID)
        }.value
    }

    /// 허락된 폴더 안의 원본을 복사 없이 그 자리에서 연다.
    func externalPlaybackTarget(for item: RemoteFileItem) -> RemoteExternalPlaybackTarget {
        guard item.connectionID == connection.id,
              let source = try? fileURL(forBrowserPath: item.path),
              FileManager.default.fileExists(atPath: source.path) else {
            return .unavailable(reason: "기기 폴더에서 이 파일을 찾을 수 없습니다.")
        }
        return .localFile(source)
    }

    /// 원본이 아니라 이 접근의 사본 폴더에 만든 사본을 돌려준다. 같은 볼륨이면 APFS 복제라 바로 끝난다.
    func download(_ item: RemoteFileItem) async throws -> URL {
        guard item.connectionID == connection.id else {
            throw DeviceFolderFileError.outsideFolder
        }
        let source = try fileURL(forBrowserPath: item.path)
        let copies = access.copiesDirectory
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { throw DeviceFolderFileError.notAFile }
            let folder = copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                try? fileManager.removeItem(at: folder)
                throw error
            }
            return destination
        }.value
    }

    /// 원본을 읽기만 해서 기기에서 바로 만든다.
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        guard item.connectionID == connection.id else { return nil }
        guard !item.isDirectory, item.supportsQuickLookThumbnail, !item.isAudio else { return nil }
        let fileURL = try fileURL(forBrowserPath: item.path)
        let side: CGFloat
        switch size {
        case .small: side = 360
        case .medium: side = 1_024
        case .large: side = 1_600
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: side, height: side),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        try Task.checkCancellation()
        return representation.uiImage.jpegData(compressionQuality: 0.84)
    }

    func testConnection() async throws {}

    /// 파인더 경로("/", "/a/b")를 허락된 폴더 안의 실제 위치로 바꾼다. 숨김·상위 이동 구성 요소와
    /// 링크를 따라 폴더 밖으로 나가는 위치는 거부한다.
    private func fileURL(forBrowserPath path: String) throws -> URL {
        var url = access.rootURL
        for component in path.split(separator: "/").map(String.init) {
            guard component != "..", !component.hasPrefix(".") else { throw DeviceFolderFileError.outsideFolder }
            url.appendPathComponent(component)
        }
        let root = access.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved == root || resolved.hasPrefix(rootPrefix) else { throw DeviceFolderFileError.outsideFolder }
        return url
    }

    private static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? rootPath : "/" + trimmed
    }

    /// 한 폴더 단계만 읽는다. 숨김 파일, 링크, 패키지(사진 보관함·앱 등 내부 구조)는 보이지 않는다.
    private static func items(in folder: URL, browserPath: String, connectionID: UUID) throws -> [RemoteFileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        let parent = browserPath == rootPath ? "" : browserPath
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isPackage != true else { return nil }
            let isDirectory = values.isDirectory == true
            let name = url.lastPathComponent
            return RemoteFileItem(
                connectionID: connectionID,
                path: parent + "/" + name,
                name: name,
                kind: isDirectory ? .folder : .file,
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                contentTypeIdentifier: values.contentType?.identifier
            )
        }
    }
}

/// 기기 파일 화면. 허락한 폴더가 있으면 파인더 화면을 그대로 쓰고, 없거나 열 수 없으면 이유와 다음 행동을 보여 준다.
/// 폴더 선택은 시스템 선택기로 사용자가 직접 한다. 파일 가져오기(폰하드로 복사)는 기존 동작을 그대로 연다.
struct DeviceFolderBrowserView: View {
    let onImportFiles: () -> Void

    private enum Phase {
        case checking
        case needsFolder
        case unavailable
        case ready(DeviceFolderAccess)
    }

    @State private var phase: Phase = .checking
    @State private var isChoosingFolder = false
    @State private var parentFolderHint: URL?
    @State private var asksForParentAuthorization = false
    @State private var message: String?
    @Environment(\.returnToDashboard) private var returnToDashboard
    private var themeRefresh = ThemeRefresh()

    init(onImportFiles: @escaping () -> Void) {
        self.onImportFiles = onImportFiles
    }

    var body: some View {
        let _ = themeRefresh.theme
        Group {
            switch phase {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsFolder:
                ContentUnavailableView {
                    Label("기기 파일", interfaceSystemImage: "nf.device_files")
                } description: {
                    Text("앱 안에서 볼 폴더를 한 번 선택하세요. 선택한 폴더와 그 위 폴더로 이동해 파일을 읽고, 원본은 바꾸거나 옮기거나 지우지 않습니다.")
                } actions: {
                    Button("폴더 선택") { isChoosingFolder = true }
                        .buttonStyle(PorcelainProminentButtonStyle())
                    Button("파일을 폰하드로 가져오기") { onImportFiles() }
                    Button("메뉴로 돌아가기") { returnToDashboard() }
                }
                .navigationTitle("기기 파일")
            case .unavailable:
                ContentUnavailableView {
                    Label("선택한 폴더를 열 수 없습니다", interfaceSystemImage: "exclamationmark.triangle")
                } description: {
                    Text("폴더가 옮겨졌거나 지워졌거나, 외장 디스크가 연결되어 있지 않을 수 있습니다. 다시 시도하거나 폴더를 다시 선택해 주세요.")
                } actions: {
                    Button("다시 시도") { phase = Self.restoredPhase() }
                        .buttonStyle(PorcelainProminentButtonStyle())
                    Button("폴더 다시 선택") { isChoosingFolder = true }
                    Button("메뉴로 돌아가기") { returnToDashboard() }
                }
                .navigationTitle("기기 파일")
            case .ready(let access):
                let service = DeviceFolderFileService(access: access)
                FileBrowserView(
                    connection: service.connection,
                    path: DeviceFolderFileService.rootPath,
                    service: service,
                    title: service.connection.name
                )
                .id(ObjectIdentifier(access))
                // 어느 폴더를 보고 있는지, 바꾸거나 메뉴로 돌아가는 길을 항상 보이게 한다(사이드바는 그대로).
                .safeAreaInset(edge: .top, spacing: 0) { selectedFolderBar(access) }
            }
        }
        .toolbar {
            if case .ready = phase {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("폴더 변경", interfaceSystemImage: "folder.badge.gearshape") { isChoosingFolder = true }
                        Button("파일을 폰하드로 가져오기", interfaceSystemImage: "nf.import") { onImportFiles() }
                    } label: {
                        Label("기기 파일 메뉴", interfaceSystemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                guard let adopted = DeviceFolderBookmark.adopt(url) else {
                    message = "선택한 폴더를 열 수 없습니다. 다른 폴더를 선택해 주세요."
                    return
                }
                phase = .ready(adopted.access)
                if !adopted.remembered {
                    message = "이번 실행 동안만 이 폴더를 엽니다. 다음에 다시 선택해야 할 수 있습니다."
                }
            case .failure(let error):
                let cocoaError = error as NSError
                guard !(cocoaError.domain == NSCocoaErrorDomain
                        && cocoaError.code == CocoaError.Code.userCancelled.rawValue) else { return }
                message = "폴더를 열지 못했습니다: \(error.localizedDescription)"
            }
        }
        .fileDialogDefaultDirectory(parentFolderHint)
        .fileDialogConfirmationLabel("이 폴더 열기")
        .fileDialogMessage("NasFinder 안에서 볼 폴더를 선택하세요. 파일은 읽기만 합니다.")
        .alert("상위 폴더 허락", isPresented: $asksForParentAuthorization) {
            Button("상위 폴더 선택") { isChoosingFolder = true }
            Button("취소", role: .cancel) { parentFolderHint = nil }
        } message: {
            Text("이 폴더의 상위 폴더는 아직 허락되지 않아 앱이 열 수 없습니다. 시스템 선택기에서 상위 폴더를 직접 고르면 그 폴더부터 볼 수 있습니다. 파일은 읽기만 합니다.")
        }
        .alert("기기 파일 알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("확인", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            if case .checking = phase { phase = Self.restoredPhase() }
        }
    }

    /// 허락한 폴더의 실제 이름을 화면에만 보여 준다(기록하거나 저장하지 않는다). 목록의 "/"는 이 폴더 안의 맨 위를 뜻한다.
    private func selectedFolderBar(_ access: DeviceFolderAccess) -> some View {
        let name = access.rootURL.lastPathComponent
        return HStack(spacing: 10) {
            InterfaceIcon(systemName: "internaldrive", size: 20)
                .foregroundStyle(PorcelainMetrics.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("선택한 폴더").porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                Text(name.isEmpty ? "/" : name)
                    .porcelainFont(.tile, weight: .semibold)
                    .foregroundStyle(PorcelainMetrics.graphite)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if access.hasParentFolder {
                Button("상위 폴더") { openParentFolder(of: access) }
                    .porcelainFont(.body)
                    .buttonStyle(.bordered)
                    .accessibilityHint("선택한 폴더의 위 폴더를 엽니다. 허락되지 않았으면 시스템 선택기로 직접 고르게 합니다.")
            }
            Button("폴더 변경") { parentFolderHint = nil; isChoosingFolder = true }
                .porcelainFont(.body)
                .buttonStyle(.bordered)
            Button("메뉴로") { returnToDashboard() }
                .porcelainFont(.body)
                .buttonStyle(.bordered)
                .accessibilityLabel("메뉴로 돌아가기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PorcelainMetrics.sidebar)
        .overlay(alignment: .bottom) { PorcelainMetrics.line.frame(height: 0.5) }
    }

    /// 이 세션에서 이미 읽을 수 있는 상위 폴더만 바로 연다(권한을 늘리지 않고, 저장된 선택도 바꾸지 않는다).
    /// 읽을 수 없으면 성공한 것처럼 보이지 않고, 시스템 선택기로 상위 폴더를 직접 허락하게 안내한다.
    private func openParentFolder(of access: DeviceFolderAccess) {
        let parent = access.rootURL.deletingLastPathComponent()
        if DeviceFolderAccess.canList(parent) {
            let parentAccess = DeviceFolderAccess(rootURL: parent)
            if parentAccess.isReachableFolder {
                phase = .ready(parentAccess)
                return
            }
        }
        parentFolderHint = parent
        asksForParentAuthorization = true
    }

    private static func restoredPhase() -> Phase {
        switch DeviceFolderBookmark.restore() {
        case .none: .needsFolder
        case .unavailable: .unavailable
        case .granted(let access): .ready(access)
        }
    }
}
