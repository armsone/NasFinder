import Foundation

/// Lifecycle status of an individual folder job in the queue.
enum SuperThumbnailJobStatus: Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running, .paused:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued:
            return "대기 중"
        case .running:
            return "진행 중"
        case .paused:
            return "일시정지"
        case .completed:
            return "완료"
        case .failed:
            return "실패"
        case .cancelled:
            return "중단됨"
        }
    }
}

/// A queued or processed folder job within the application window.
struct SuperThumbnailJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let folderURL: URL
    var isFresh: Bool
    var status: SuperThumbnailJobStatus
    var totalCount: Int
    var completedCount: Int
    var generatedCount: Int
    var cachedCount: Int
    var failedCount: Int
    var statusMessage: String

    init(
        id: UUID = UUID(),
        folderURL: URL,
        isFresh: Bool = false,
        status: SuperThumbnailJobStatus = .queued,
        totalCount: Int = 0,
        completedCount: Int = 0,
        generatedCount: Int = 0,
        cachedCount: Int = 0,
        failedCount: Int = 0,
        statusMessage: String = ""
    ) {
        self.id = id
        self.folderURL = folderURL
        self.isFresh = isFresh
        self.status = status
        self.totalCount = totalCount
        self.completedCount = completedCount
        self.generatedCount = generatedCount
        self.cachedCount = cachedCount
        self.failedCount = failedCount
        self.statusMessage = statusMessage
    }

    var folderName: String {
        folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.lastPathComponent
    }

    var progress: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }
}
