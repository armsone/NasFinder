import Foundation

/// 선택한 보관함·시스템 선택기·파일 항목에서 작업 직전에 준비한 앱 소유 임시 파일을 제공한다.
/// 원본 보관함 접근과 복사는 화면의 준비 단계에서 처리하며 이 서비스는 원본을 변경하지 않는다.
struct LocalPhotoLibraryFileService: RemoteFileService {
    static let connectionID = UUID(uuidString: "D15B6B77-9B3E-4E36-9E3A-9C4A9B8F6A2E")!

    let connection = RemoteConnection(
        id: connectionID,
        name: "내 미디어",
        kind: .synology,
        host: "localhost",
        username: ""
    )

    private let urlsByPath: [String: URL]
    private let items: [RemoteFileItem]

    init(entries: [(item: RemoteFileItem, url: URL)]) {
        items = entries.map(\.item)
        urlsByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.path, $0.url) })
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        items
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        guard let url = urlsByPath[item.path], FileManager.default.fileExists(atPath: url.path) else {
            throw LocalPhotoLibraryError.fileUnavailable
        }
        return url
    }

    func testConnection() async throws {}
}

enum LocalPhotoLibraryError: LocalizedError {
    case fileUnavailable

    var errorDescription: String? {
        "선택한 사진 또는 영상을 더 이상 사용할 수 없습니다. 다시 선택해 주세요."
    }
}
