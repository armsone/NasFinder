import Foundation

struct WebHardFileItem: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?

    var id: String { path }
}

enum WebHardFileStoreError: LocalizedError, Equatable, Sendable {
    case invalidPath
    case itemNotFound
    case itemAlreadyExists
    case unsupportedItem
    case archiveTooLarge
    case containsHiddenItems

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            "허용되지 않은 파일 경로입니다."
        case .itemNotFound:
            "파일 또는 폴더를 찾을 수 없습니다."
        case .itemAlreadyExists:
            "같은 이름의 파일 또는 폴더가 이미 있습니다."
        case .unsupportedItem:
            "지원하지 않는 파일 형식입니다."
        case .archiveTooLarge:
            "폴더가 웹 다운로드용 ZIP 한도를 초과합니다."
        case .containsHiddenItems:
            "이 폴더에는 여기에 표시되지 않는 항목이 들어 있어 통째로 받거나 삭제할 수 없습니다. 앱에서 폴더를 확인해 주세요."
        }
    }
}

struct WebHardPreparedUpload: Sendable {
    let temporaryURL: URL
    let destinationURL: URL
}

/// Restricts every web request to a private app-owned directory. Path
/// components are validated before URL construction, and existing ancestors
/// are resolved to prevent a symlink from escaping the root.
struct WebHardFileStore: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) throws {
        let resolvedRoot: URL
        if let rootURL {
            resolvedRoot = rootURL
        } else {
            resolvedRoot = try SharedInbox.storageURL()
        }

        try FileManager.default.createDirectory(
            at: resolvedRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        self.rootURL = resolvedRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    func list(path: String) throws -> [WebHardFileItem] {
        let directoryURL = try existingURL(for: path)
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw WebHardFileStoreError.unsupportedItem }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        // 디렉터리를 읽은 뒤에 디스크의 매니페스트로 분류한다: 읽는 순간 보인 파일은 이미 같은 잠금 안에서 기록이 끝난 것이다.
        let scope = try SharedInbox.privateScope()
        return try entries.compactMap { url in
            guard directoryURL != rootURL || url.lastPathComponent != "manifest.json" else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                return nil
            }
            let relativePath = try pathRelativeToRoot(url)
            if scope.contains(storedFilename: String(relativePath.dropFirst())) { return nil }
            return WebHardFileItem(
                name: url.lastPathComponent,
                path: relativePath,
                isDirectory: values.isDirectory == true,
                size: values.isRegularFile == true ? Int64(values.fileSize ?? 0) : nil,
                modifiedAt: values.contentModificationDate
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func fileURL(path: String) throws -> URL {
        let url = try existingURL(for: path)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WebHardFileStoreError.unsupportedItem
        }
        return url
    }

    /// 폴더를 통째로 내보낼 때 쓴다. 안에 이 화면에 보이지 않는 비공개 항목이 있으면 함께 나가지 않도록 거부한다.
    func directoryURL(path: String) throws -> URL {
        let url = try existingURL(for: path)
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WebHardFileStoreError.unsupportedItem
        }
        try rejectHiddenDescendants(of: path)
        return url
    }

    func createDirectory(path: String) throws {
        let url = try safeURL(for: path, allowingRoot: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WebHardFileStoreError.itemAlreadyExists
        }
        try validateExistingAncestor(of: url)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    func delete(path: String) throws {
        let url = try existingURL(for: path)
        guard url.path != rootURL.path else { throw WebHardFileStoreError.invalidPath }
        // 재귀 삭제가 보이지 않는 비공개 하위 항목까지 지우지 않도록, 그런 항목이 있는 폴더는 지우지 않는다.
        try rejectHiddenDescendants(of: path)
        try FileManager.default.removeItem(at: url)
    }

    func prepareUpload(path: String) throws -> WebHardPreparedUpload {
        let requestedURL = try safeURL(for: path, allowingRoot: false)
        try validateExistingAncestor(of: requestedURL)
        let parentURL = requestedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try validateExistingAncestor(of: requestedURL)

        let destinationURL = uniqueDestination(for: requestedURL)
        let temporaryURL = parentURL.appendingPathComponent(
            ".nasfinder-upload-\(UUID().uuidString)",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return WebHardPreparedUpload(
            temporaryURL: temporaryURL,
            destinationURL: destinationURL
        )
    }

    func commitUpload(_ upload: WebHardPreparedUpload) throws {
        guard FileManager.default.fileExists(atPath: upload.temporaryURL.path),
              !FileManager.default.fileExists(atPath: upload.destinationURL.path) else {
            throw WebHardFileStoreError.itemAlreadyExists
        }
        try FileManager.default.moveItem(
            at: upload.temporaryURL,
            to: upload.destinationURL
        )
    }

    func discardUpload(_ upload: WebHardPreparedUpload) {
        try? FileManager.default.removeItem(at: upload.temporaryURL)
    }

    func pathRelativeToRoot(_ url: URL) throws -> String {
        let rootPath = rootURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath == rootPath || itemPath.hasPrefix(rootPath + "/") else {
            throw WebHardFileStoreError.invalidPath
        }
        guard itemPath != rootPath else { return "/" }
        return "/" + String(itemPath.dropFirst(rootPath.count + 1))
    }

    private func existingURL(for path: String) throws -> URL {
        let url = try safeURL(for: path, allowingRoot: true, checksPrivacy: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WebHardFileStoreError.itemNotFound
        }
        let resolved = url.resolvingSymlinksInPath()
        try validateInsideRoot(resolved)
        // 존재를 확인한 뒤에 분류한다(방금 들어온 비공개 파일이 분류 전 상태로 읽히지 않도록).
        try rejectIfPrivate(path)
        return resolved
    }

    private static func storedPath(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// 로컬 웹하드는 앱 모드를 모르는 앱 밖 표면이다. 목록과 직접 접근 모두 비공개 폰하드 경로를 항상 숨기며,
    /// 판정은 메모리 스냅샷이 아니라 지금 디스크 매니페스트 기준이다.
    private func rejectIfPrivate(_ path: String) throws {
        let stored = Self.storedPath(of: path)
        guard !stored.isEmpty else { return }
        if try SharedInbox.privateScope().contains(storedFilename: stored) {
            throw WebHardFileStoreError.itemNotFound
        }
    }

    private func rejectHiddenDescendants(of path: String) throws {
        if try SharedInbox.privateScope().hasPrivateDescendant(of: Self.storedPath(of: path)) {
            throw WebHardFileStoreError.containsHiddenItems
        }
    }

    private func safeURL(for path: String, allowingRoot: Bool, checksPrivacy: Bool = true) throws -> URL {
        guard !path.contains("\0") else { throw WebHardFileStoreError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw WebHardFileStoreError.invalidPath
        }
        if components.isEmpty {
            guard allowingRoot else { throw WebHardFileStoreError.invalidPath }
            return rootURL
        }
        let url = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL
        try validateInsideRoot(url)
        if checksPrivacy { try rejectIfPrivate(path) }
        return url
    }

    private func validateExistingAncestor(of url: URL) throws {
        var candidate = url.deletingLastPathComponent()
        while candidate.path != rootURL.path,
              !FileManager.default.fileExists(atPath: candidate.path) {
            candidate.deleteLastPathComponent()
        }
        let resolved = candidate.resolvingSymlinksInPath()
        try validateInsideRoot(resolved)
    }

    private func validateInsideRoot(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw WebHardFileStoreError.invalidPath
        }
    }

    private func uniqueDestination(for requestedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requestedURL.path) else {
            return requestedURL
        }
        let directory = requestedURL.deletingLastPathComponent()
        let extensionName = requestedURL.pathExtension
        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        for index in 1...9_999 {
            let filename = extensionName.isEmpty
                ? "\(baseName) (\(index))"
                : "\(baseName) (\(index)).\(extensionName)"
            let candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(requestedURL.lastPathComponent)")
    }
}
