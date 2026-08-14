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
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw WebHardFileStoreError.invalidPath
            }
            resolvedRoot = applicationSupport.appendingPathComponent(
                "WebHard",
                isDirectory: true
            )
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

        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
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

    func directoryURL(path: String) throws -> URL {
        let url = try existingURL(for: path)
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WebHardFileStoreError.unsupportedItem
        }
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
        let url = try safeURL(for: path, allowingRoot: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WebHardFileStoreError.itemNotFound
        }
        let resolved = url.resolvingSymlinksInPath()
        try validateInsideRoot(resolved)
        return resolved
    }

    private func safeURL(for path: String, allowingRoot: Bool) throws -> URL {
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
