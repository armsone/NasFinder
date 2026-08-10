import Foundation

/// Mutation features that a concrete remote backend can perform.
///
/// Listing and downloading are guaranteed by `RemoteFileService` and are not
/// repeated here. A backend must only advertise an option after it implements
/// the corresponding protocol requirement.
struct RemoteFileServiceCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static let createFolder = Self(rawValue: 1 << 0)
    static let rename = Self(rawValue: 1 << 1)
    static let delete = Self(rawValue: 1 << 2)
    static let recursiveDelete = Self(rawValue: 1 << 3)
    static let upload = Self(rawValue: 1 << 4)
    static let replaceFile = Self(rawValue: 1 << 5)
    static let serverSideCopy = Self(rawValue: 1 << 6)
    static let streamingCopy = Self(rawValue: 1 << 7)
    static let serverSideMove = Self(rawValue: 1 << 8)
    static let streamingMove = Self(rawValue: 1 << 9)

    static let all: Self = [
        .createFolder,
        .rename,
        .delete,
        .recursiveDelete,
        .upload,
        .replaceFile,
        .serverSideCopy,
        .streamingCopy,
        .serverSideMove,
        .streamingMove
    ]

    func supports(
        _ operation: RemoteOperationKind,
        strategy: RemoteTransferStrategy = .automatic
    ) -> Bool {
        switch operation {
        case .createFolder:
            contains(.createFolder)
        case .rename:
            contains(.rename)
        case .delete:
            contains(.delete)
        case .upload:
            contains(.upload)
        case .copy:
            switch strategy {
            case .automatic:
                contains(.serverSideCopy) || contains(.streamingCopy)
            case .serverSideOnly:
                contains(.serverSideCopy)
            case .streaming:
                contains(.streamingCopy)
            }
        case .move:
            switch strategy {
            case .automatic:
                contains(.serverSideMove) || contains(.streamingMove)
            case .serverSideOnly:
                contains(.serverSideMove)
            case .streaming:
                contains(.streamingMove)
            }
        }
    }
}

enum RemoteOperationKind: String, Sendable, Hashable {
    case createFolder
    case rename
    case delete
    case upload
    case copy
    case move
}

enum RemoteConflictPolicy: String, Sendable, Hashable, CaseIterable {
    /// Stop before changing the destination when an item already exists.
    case fail
    /// Leave the existing destination unchanged and report a skipped outcome.
    case skip
    /// Replace files only. Replacing a folder is deliberately prohibited.
    case replace
    /// Generate a sibling name such as `Photo (1).jpg`.
    case keepBoth

    func validate(for item: RemoteFileItem, destinationPath: String) throws {
        if self == .replace, item.isDirectory {
            throw RemoteFileOperationError.folderReplacementNotAllowed(
                path: destinationPath
            )
        }
    }
}

/// Selects how a backend transfers data for copy and move operations.
enum RemoteTransferStrategy: String, Sendable, Hashable, CaseIterable {
    /// Prefer a server-side operation, then use streaming when necessary.
    case automatic
    /// Do not download file contents through the client.
    case serverSideOnly
    /// Stream contents through the client. For move, delete only after commit.
    case streaming
}

enum RemoteProgressUnit: String, Sendable, Hashable {
    case bytes
    case items
}

enum RemoteOperationPhase: String, Sendable, Hashable {
    case preparing
    case reading
    case writing
    case committing
    case deleting
    case rollingBack
    case completed
}

struct RemoteOperationProgress: Sendable, Hashable {
    let operationID: UUID
    let operation: RemoteOperationKind
    let phase: RemoteOperationPhase
    let unit: RemoteProgressUnit
    let completedUnitCount: Int64
    let totalUnitCount: Int64?
    let currentPath: String?

    var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else { return nil }
        let fraction = Double(completedUnitCount) / Double(totalUnitCount)
        return min(max(fraction, 0), 1)
    }
}

/// Per-operation state passed down to a backend.
///
/// Cancellation uses Swift structured concurrency. Implementations should call
/// `checkCancellation()` between network requests and chunks. If cancellation
/// happens after a mutation, throw `RemoteOperationInterruptedError` with the
/// partial result so the caller can accurately refresh affected directories.
struct RemoteOperationContext: Sendable {
    typealias ProgressHandler = @Sendable (RemoteOperationProgress) async -> Void

    let operationID: UUID
    private let progressHandler: ProgressHandler?

    init(
        operationID: UUID = UUID(),
        progressHandler: ProgressHandler? = nil
    ) {
        self.operationID = operationID
        self.progressHandler = progressHandler
    }

    func report(
        operation: RemoteOperationKind,
        phase: RemoteOperationPhase,
        unit: RemoteProgressUnit,
        completedUnitCount: Int64,
        totalUnitCount: Int64? = nil,
        currentPath: String? = nil
    ) async {
        guard let progressHandler else { return }
        await progressHandler(
            RemoteOperationProgress(
                operationID: operationID,
                operation: operation,
                phase: phase,
                unit: unit,
                completedUnitCount: completedUnitCount,
                totalUnitCount: totalUnitCount,
                currentPath: currentPath
            )
        )
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
    }
}

enum RemoteOperationOutcomeStatus: String, Sendable, Hashable {
    case succeeded
    case skipped
    case failed
}

enum RemoteOperationIssueCode: String, Sendable, Hashable {
    case conflict
    case permissionDenied
    case notFound
    case directoryNotEmpty
    case unsupported
    case network
    case server
    case unknown
}

/// A Sendable error snapshot suitable for retaining in a partial batch result.
struct RemoteOperationIssue: Sendable, Hashable {
    let code: RemoteOperationIssueCode
    let message: String

    init(code: RemoteOperationIssueCode, message: String) {
        self.code = code
        self.message = message
    }
}

struct RemoteOperationItemOutcome: Sendable, Hashable {
    let sourcePath: String
    let destinationPath: String?
    let status: RemoteOperationOutcomeStatus
    let resultingItem: RemoteFileItem?
    let issue: RemoteOperationIssue?

    static func succeeded(
        sourcePath: String,
        destinationPath: String? = nil,
        resultingItem: RemoteFileItem? = nil
    ) -> Self {
        Self(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            status: .succeeded,
            resultingItem: resultingItem,
            issue: nil
        )
    }

    static func skipped(
        sourcePath: String,
        destinationPath: String? = nil,
        issue: RemoteOperationIssue? = nil
    ) -> Self {
        Self(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            status: .skipped,
            resultingItem: nil,
            issue: issue
        )
    }

    static func failed(
        sourcePath: String,
        destinationPath: String? = nil,
        issue: RemoteOperationIssue
    ) -> Self {
        Self(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            status: .failed,
            resultingItem: nil,
            issue: issue
        )
    }
}

enum RemoteRollbackState: String, Sendable, Hashable {
    case notNeeded
    case notAttempted
    case succeeded
    case failed
}

/// Result of one low-level operation. Recursive backends may include an outcome
/// for every affected descendant, allowing the coordinator to present partial
/// failures without losing successful work.
struct RemoteOperationResult: Sendable, Hashable {
    let operationID: UUID
    let operation: RemoteOperationKind
    let outcomes: [RemoteOperationItemOutcome]
    let wasCancelled: Bool
    let rollbackState: RemoteRollbackState

    init(
        operationID: UUID,
        operation: RemoteOperationKind,
        outcomes: [RemoteOperationItemOutcome],
        wasCancelled: Bool = false,
        rollbackState: RemoteRollbackState = .notNeeded
    ) {
        self.operationID = operationID
        self.operation = operation
        self.outcomes = outcomes
        self.wasCancelled = wasCancelled
        self.rollbackState = rollbackState
    }

    var succeeded: [RemoteOperationItemOutcome] {
        outcomes.filter { $0.status == .succeeded }
    }

    var skipped: [RemoteOperationItemOutcome] {
        outcomes.filter { $0.status == .skipped }
    }

    var failures: [RemoteOperationItemOutcome] {
        outcomes.filter { $0.status == .failed }
    }

    var isPartialSuccess: Bool {
        !succeeded.isEmpty && (wasCancelled || !skipped.isEmpty || !failures.isEmpty)
    }
}

enum RemoteOperationInterruptionReason: String, Sendable, Hashable {
    case cancelled
    case connectionLost
    case unrecoverableFailure
}

struct RemoteOperationInterruptedError: LocalizedError, Sendable, Hashable {
    let reason: RemoteOperationInterruptionReason
    let partialResult: RemoteOperationResult

    var errorDescription: String? {
        switch reason {
        case .cancelled:
            "작업이 취소되었습니다. 완료된 항목은 그대로 유지됩니다."
        case .connectionLost:
            "연결이 끊겨 작업이 일부만 완료되었습니다."
        case .unrecoverableFailure:
            "작업이 일부만 완료되었습니다."
        }
    }
}

enum RemoteNameValidationFailure: String, Sendable, Hashable {
    case empty
    case whitespaceOnly
    case dotComponent
    case containsPathSeparator
    case containsNullByte
}

enum RemotePathValidationFailure: String, Sendable, Hashable {
    case empty
    case containsNullByte
    case parentTraversal
    case incompatibleRootStyle
}

enum RemoteFileOperationError: LocalizedError, Sendable, Hashable {
    case unsupported(operation: RemoteOperationKind)
    case invalidName(name: String, reason: RemoteNameValidationFailure)
    case invalidPath(path: String, reason: RemotePathValidationFailure)
    case pathOutsideRoot(path: String, rootPath: String)
    case conflict(sourcePath: String, destinationPath: String)
    case folderReplacementNotAllowed(path: String)
    case permissionDenied(path: String)
    case notFound(path: String)
    case directoryNotEmpty(path: String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let operation):
            "이 연결은 \(operation.localizedName) 작업을 지원하지 않습니다."
        case .invalidName(_, let reason):
            reason.localizedDescription
        case .invalidPath(_, let reason):
            reason.localizedDescription
        case .pathOutsideRoot:
            "연결에 허용된 최상위 폴더 밖에는 접근할 수 없습니다."
        case .conflict:
            "같은 이름의 항목이 이미 있습니다."
        case .folderReplacementNotAllowed:
            "폴더는 기존 항목을 덮어쓸 수 없습니다. 이름을 바꾸거나 건너뛰어 주세요."
        case .permissionDenied:
            "이 항목을 변경할 권한이 없습니다."
        case .notFound:
            "항목을 찾을 수 없습니다."
        case .directoryNotEmpty:
            "폴더가 비어 있지 않습니다. 재귀 삭제를 선택해 주세요."
        }
    }
}

private extension RemoteOperationKind {
    var localizedName: String {
        switch self {
        case .createFolder: "폴더 만들기"
        case .rename: "이름 변경"
        case .delete: "삭제"
        case .upload: "업로드"
        case .copy: "복사"
        case .move: "이동"
        }
    }
}

private extension RemoteNameValidationFailure {
    var localizedDescription: String {
        switch self {
        case .empty, .whitespaceOnly:
            "파일 또는 폴더 이름을 입력해 주세요."
        case .dotComponent:
            "'.'과 '..'은 이름으로 사용할 수 없습니다."
        case .containsPathSeparator:
            "이름에 '/' 문자를 사용할 수 없습니다."
        case .containsNullByte:
            "이름에 사용할 수 없는 문자가 있습니다."
        }
    }
}

private extension RemotePathValidationFailure {
    var localizedDescription: String {
        switch self {
        case .empty:
            "원격 경로가 비어 있습니다."
        case .containsNullByte:
            "원격 경로에 사용할 수 없는 문자가 있습니다."
        case .parentTraversal:
            "상위 폴더 이동을 포함한 경로는 사용할 수 없습니다."
        case .incompatibleRootStyle:
            "원격 경로 형식이 연결의 최상위 경로와 일치하지 않습니다."
        }
    }
}
