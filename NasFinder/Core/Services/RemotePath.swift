import Foundation

/// Lexical remote-path validation shared by all writable backends.
///
/// This protects the configured connection root from `..` traversal. It does
/// not resolve server-side symbolic links, so concrete backends must avoid
/// following a symlink outside the configured root when mutating recursively.
enum RemotePath {
    static func validatedName(_ name: String) throws -> String {
        guard !name.isEmpty else {
            throw RemoteFileOperationError.invalidName(name: name, reason: .empty)
        }
        guard !name.allSatisfy(\.isWhitespace) else {
            throw RemoteFileOperationError.invalidName(
                name: name,
                reason: .whitespaceOnly
            )
        }
        guard name != ".", name != ".." else {
            throw RemoteFileOperationError.invalidName(
                name: name,
                reason: .dotComponent
            )
        }
        guard !name.contains("/") else {
            throw RemoteFileOperationError.invalidName(
                name: name,
                reason: .containsPathSeparator
            )
        }
        guard !name.contains("\0") else {
            throw RemoteFileOperationError.invalidName(
                name: name,
                reason: .containsNullByte
            )
        }
        return name
    }

    /// Returns a canonical path after proving it is inside `rootPath`.
    ///
    /// Absolute roots require absolute paths. Relative SFTP roots require paths
    /// in the same relative namespace. For the special root `.`, canonical
    /// descendants retain the `./name` form used by the SFTP backend.
    static func normalize(_ path: String, within rootPath: String) throws -> String {
        let root = try ParsedPath(rootPath)
        let candidate = try ParsedPath(path)

        guard root.isAbsolute == candidate.isAbsolute else {
            throw RemoteFileOperationError.invalidPath(
                path: path,
                reason: .incompatibleRootStyle
            )
        }
        guard candidate.components.starts(with: root.components) else {
            throw RemoteFileOperationError.pathOutsideRoot(
                path: path,
                rootPath: rootPath
            )
        }

        return candidate.render(dotPrefixed: !root.isAbsolute && root.components.isEmpty)
    }

    static func appending(
        name: String,
        to directoryPath: String,
        within rootPath: String
    ) throws -> String {
        let name = try validatedName(name)
        let directory = try normalize(directoryPath, within: rootPath)

        let joined: String
        if directory == "/" {
            joined = "/\(name)"
        } else if directory == "." {
            joined = "./\(name)"
        } else if directory.hasSuffix("/") {
            joined = "\(directory)\(name)"
        } else {
            joined = "\(directory)/\(name)"
        }
        return try normalize(joined, within: rootPath)
    }

    static func isInside(_ path: String, rootPath: String) -> Bool {
        (try? normalize(path, within: rootPath)) != nil
    }

    /// Generates the first available Finder-style sibling name.
    static func keepBothName<C: Collection>(
        for originalName: String,
        existingNames: C,
        caseSensitive: Bool = true
    ) throws -> String where C.Element == String {
        let originalName = try validatedName(originalName)
        let normalizedExisting: Set<String>
        if caseSensitive {
            normalizedExisting = Set(existingNames)
        } else {
            normalizedExisting = Set(existingNames.map { $0.lowercased() })
        }

        func exists(_ name: String) -> Bool {
            normalizedExisting.contains(caseSensitive ? name : name.lowercased())
        }

        guard exists(originalName) else { return originalName }

        let pathExtension = (originalName as NSString).pathExtension
        let stem = pathExtension.isEmpty
            ? originalName
            : (originalName as NSString).deletingPathExtension
        let baseStem = stemWithoutNumericCopySuffix(stem)

        var index = 1
        while index < Int.max {
            let numberedStem = "\(baseStem) (\(index))"
            let candidate = pathExtension.isEmpty
                ? numberedStem
                : "\(numberedStem).\(pathExtension)"
            if !exists(candidate) {
                return candidate
            }
            index += 1
        }

        // Reaching this would require every positive Int suffix to exist.
        throw RemoteFileOperationError.conflict(
            sourcePath: originalName,
            destinationPath: originalName
        )
    }

    private static func stemWithoutNumericCopySuffix(_ stem: String) -> String {
        guard stem.last == ")",
              let openingParenthesis = stem.lastIndex(of: "("),
              openingParenthesis > stem.startIndex else {
            return stem
        }

        let spaceIndex = stem.index(before: openingParenthesis)
        guard stem[spaceIndex] == " " else { return stem }

        let digitsStart = stem.index(after: openingParenthesis)
        let digitsEnd = stem.index(before: stem.endIndex)
        guard digitsStart < digitsEnd,
              stem[digitsStart..<digitsEnd].allSatisfy(\.isNumber) else {
            return stem
        }

        return String(stem[..<spaceIndex])
    }
}

private extension RemotePath {
    struct ParsedPath {
        let isAbsolute: Bool
        let components: [String]

        init(_ path: String) throws {
            guard !path.isEmpty else {
                throw RemoteFileOperationError.invalidPath(path: path, reason: .empty)
            }
            guard !path.contains("\0") else {
                throw RemoteFileOperationError.invalidPath(
                    path: path,
                    reason: .containsNullByte
                )
            }

            isAbsolute = path.hasPrefix("/")
            let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !rawComponents.contains("..") else {
                throw RemoteFileOperationError.invalidPath(
                    path: path,
                    reason: .parentTraversal
                )
            }
            components = rawComponents
                .filter { $0 != "." }
                .map(String.init)
        }

        func render(dotPrefixed: Bool) -> String {
            if isAbsolute {
                return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))"
            }
            if components.isEmpty { return "." }
            let path = components.joined(separator: "/")
            return dotPrefixed ? "./\(path)" : path
        }
    }
}
