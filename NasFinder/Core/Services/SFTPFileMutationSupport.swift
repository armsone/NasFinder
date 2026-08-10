import Citadel
import Foundation

struct SFTPRemoteEntry: Sendable {
    let path: String
    let name: String
    let longname: String
    let attributes: SFTPFileAttributes

    var isSymbolicLink: Bool {
        attributes.permissions.map { ($0 & 0o170000) == 0o120000 }
            ?? longname.hasPrefix("l")
    }

    var isDirectory: Bool {
        guard !isSymbolicLink else { return false }
        return attributes.permissions.map { ($0 & 0o170000) == 0o040000 }
            ?? longname.hasPrefix("d")
    }

    var size: Int64? {
        attributes.size.flatMap(Int64.init(exactly:))
    }

    var modifiedAt: Date? {
        attributes.accessModificationTime?.modificationTime
    }

    func remoteItem(connectionID: UUID) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: name,
            kind: isDirectory ? .folder : .file,
            size: size,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: nil
        )
    }
}

enum SFTPPathSafety {
    struct Parts: Equatable, Sendable {
        let parent: String
        let name: String
    }

    static func parts(
        of path: String,
        within rootPath: String
    ) throws -> Parts {
        let normalized = try RemotePath.normalize(path, within: rootPath)
        let normalizedRoot = try RemotePath.normalize(rootPath, within: rootPath)
        guard normalized != normalizedRoot else {
            throw SFTPFileMutationError.configuredRootMutationNotAllowed
        }

        if normalized.hasPrefix("./") {
            let remainder = String(normalized.dropFirst(2))
            guard let separator = remainder.lastIndex(of: "/") else {
                return Parts(
                    parent: ".",
                    name: try RemotePath.validatedName(remainder)
                )
            }
            return Parts(
                parent: "./\(remainder[..<separator])",
                name: try RemotePath.validatedName(
                    String(remainder[remainder.index(after: separator)...])
                )
            )
        }

        guard let separator = normalized.lastIndex(of: "/") else {
            throw RemoteFileOperationError.invalidPath(
                path: normalized,
                reason: .incompatibleRootStyle
            )
        }
        let nameStart = normalized.index(after: separator)
        let parent = separator == normalized.startIndex
            ? "/"
            : String(normalized[..<separator])
        return Parts(
            parent: parent,
            name: try RemotePath.validatedName(String(normalized[nameStart...]))
        )
    }

    static func isSameOrDescendant(_ path: String, of directory: String) -> Bool {
        if path == directory { return true }
        if directory == "/" { return path.hasPrefix("/") }
        if directory == "." { return path.hasPrefix("./") }
        return path.hasPrefix(directory.hasSuffix("/") ? directory : "\(directory)/")
    }

    static func isCanonicalPath(_ path: String, inside root: String) -> Bool {
        let normalizedRoot = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast())
            : root
        let normalizedPath = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast())
            : path
        return isSameOrDescendant(normalizedPath, of: normalizedRoot)
    }
}

enum SFTPDestinationDecision: Sendable {
    case use(name: String, replacing: SFTPRemoteEntry?)
    case skip(path: String)

    static func resolve(
        originalName: String,
        sourcePath: String,
        directoryPath: String,
        entries: [SFTPRemoteEntry],
        conflictPolicy: RemoteConflictPolicy,
        rootPath: String
    ) throws -> Self {
        let originalName = try RemotePath.validatedName(originalName)
        let existing = entries.first { $0.name == originalName }
        let originalPath = try RemotePath.appending(
            name: originalName,
            to: directoryPath,
            within: rootPath
        )

        guard let existing else {
            return .use(name: originalName, replacing: nil)
        }

        switch conflictPolicy {
        case .fail:
            throw RemoteFileOperationError.conflict(
                sourcePath: sourcePath,
                destinationPath: originalPath
            )
        case .skip:
            return .skip(path: originalPath)
        case .replace:
            guard !existing.isDirectory else {
                throw RemoteFileOperationError.folderReplacementNotAllowed(
                    path: originalPath
                )
            }
            return .use(name: originalName, replacing: existing)
        case .keepBoth:
            let name = try RemotePath.keepBothName(
                for: originalName,
                existingNames: entries.map(\.name)
            )
            return .use(name: name, replacing: nil)
        }
    }
}

enum SFTPFileMutationError: LocalizedError, Sendable, Equatable {
    case configuredRootMutationNotAllowed
    case symbolicLinkTransferUnsupported
    case localSourceIsNotRegularFile
    case sourceChangedDuringTransfer
    case verificationFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .configuredRootMutationNotAllowed:
            "연결의 최상위 폴더 자체는 변경할 수 없습니다."
        case .symbolicLinkTransferUnsupported:
            "심볼릭 링크는 안전하게 복사할 수 없습니다."
        case .localSourceIsNotRegularFile:
            "업로드할 일반 파일을 선택해 주세요."
        case .sourceChangedDuringTransfer:
            "전송 중 원본 파일이 변경되었습니다. 다시 시도해 주세요."
        case .verificationFailed:
            "서버가 파일 작업 완료를 확인하지 못했습니다."
        case .cleanupFailed:
            "임시 파일을 정리하지 못했습니다. 폴더를 새로 고침해 주세요."
        }
    }
}
