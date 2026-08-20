import Foundation
import UniformTypeIdentifiers

/// 사진 보관함에서 선택한 항목의 대분류.
enum PhotoTransferMediaKind: String, CaseIterable, Equatable, Hashable {
    case livePhoto
    case photo
    case video
    case unknown

    var title: String {
        switch self {
        case .livePhoto: "Live Photo"
        case .photo: "사진"
        case .video: "영상"
        case .unknown: "알 수 없음"
        }
    }

    var systemImage: String {
        switch self {
        case .livePhoto: "livephoto"
        case .photo: "photo"
        case .video: "video"
        case .unknown: "questionmark.circle"
        }
    }
}

/// 미디어 데이터를 내려받지 않고 PhotosPicker가 알려주는 콘텐츠 타입만으로 분류한다.
enum PhotoTransferMediaClassifier {
    static func classify(supportedContentTypes contentTypes: [UTType]) -> PhotoTransferMediaKind {
        // Live Photo는 이미지 타입도 함께 보고하므로 가장 먼저 판별한다.
        if contentTypes.contains(where: { $0.conforms(to: .livePhoto) }) {
            return .livePhoto
        }
        if contentTypes.contains(where: { $0.conforms(to: .movie) }) {
            return .video
        }
        if contentTypes.contains(where: { $0.conforms(to: .image) }) {
            return .photo
        }
        return .unknown
    }

    /// PhotosPicker의 전달 타입이 정지 이미지로 축약되어도 PhotoKit의 실제 자산 판정을 우선한다.
    static func refinedKind(
        _ kind: PhotoTransferMediaKind,
        assetIsLivePhoto: Bool?
    ) -> PhotoTransferMediaKind {
        kind == .photo && assetIsLivePhoto == true ? .livePhoto : kind
    }

    /// 항목 목록에 표시할 대표 형식 설명. 가장 구체적인 첫 타입의 식별자를 사용한다.
    static func primaryTypeDescription(supportedContentTypes contentTypes: [UTType]) -> String? {
        contentTypes.first?.preferredFilenameExtension.map { $0.uppercased() }
            ?? contentTypes.first?.identifier
    }
}

/// 선택 결과 요약. 분류별 개수를 안정된 순서로 제공한다.
struct PhotoTransferSelectionSummary: Equatable {
    let totalCount: Int
    let countsByKind: [PhotoTransferMediaKind: Int]

    init(kinds: [PhotoTransferMediaKind]) {
        totalCount = kinds.count
        countsByKind = kinds.reduce(into: [:]) { counts, kind in
            counts[kind, default: 0] += 1
        }
    }

    func count(of kind: PhotoTransferMediaKind) -> Int {
        countsByKind[kind] ?? 0
    }
}
