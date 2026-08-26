import Foundation

/// UI state for the media discovery that runs after any vault cleanup and
/// before thumbnail generation. Neither pass has a known total, so both
/// render as indeterminate; the phase only tells the user which kind of
/// entry (media files, then folders) is currently being enumerated.
enum MediaDiscoveryPhase: Equatable, Sendable {
    case idle
    case discoveringFiles
    case discoveringFolders

    var isActive: Bool { self != .idle }

    /// Large card title shown for every active phase.
    static let titleText = "사진과 영상을 찾는 중"

    var activityText: String {
        switch self {
        case .idle:
            return ""
        case .discoveringFiles:
            return "사진과 영상 파일을 찾는 중…"
        case .discoveringFolders:
            return "하위 폴더를 찾는 중…"
        }
    }

    var accessibilityLabelText: String { Self.titleText }

    var accessibilityValueText: String {
        switch self {
        case .idle:
            return ""
        case .discoveringFiles:
            return "사진과 영상 파일을 찾는 중"
        case .discoveringFolders:
            return "하위 폴더를 찾는 중"
        }
    }
}
