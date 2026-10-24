import Foundation

/// 예전 영상 재료함에 담긴 항목의 출처 종류. 저장된 기록을 읽기 위해 rawValue를 그대로 둔다.
enum MaterialSourceKind: String, Codable, Sendable {
    case nas = "NAS·클라우드"
    case phoneHard = "폰하드"
    case photoLibrary = "내 사진·영상"
    case systemFile = "기기 파일"
    case browserDownload = "웹 브라우저"
    case googlePhotos = "Google 포토"

    /// 화면에 보이는 이름. rawValue는 저장 기록 호환용이라 바꾸지 않는다.
    var title: String {
        switch self {
        case .photoLibrary: "내 미디어"
        case .browserDownload: "브라우저"
        default: rawValue
        }
    }
}

enum MaterialAvailability: String, Codable, Sendable {
    case localReady
    case needsDownload
    case unavailable
}

struct MaterialItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceKey: String
    let sourceKind: MaterialSourceKind
    var name: String
    var isVideo: Bool
    var byteCount: Int64?
    var localFilename: String?
    var availability: MaterialAvailability
    var failureMessage: String?
    let addedAt: Date
    var connectionID: UUID?
    var remotePath: String?
    var remoteIdentifier: String?
    var contentTypeIdentifier: String?
    var modifiedAt: Date?
}

/// 예전 '영상 재료' 저장소의 **읽기 전용** 다리. 작업대가 하나의 보관 장소이므로 이 저장소는
/// 더는 항목을 담거나 받거나 지우지 않는다. 기존 `MaterialBasket/index.json` 메타데이터를 읽어
/// '기존 재료' 포켓으로 옮길 때와, 이미 앱 안에 있는 복사본 파일의 위치를 알려 줄 때만 쓴다.
/// 인덱스·복사본 파일은 쓰거나 지우지 않고, 읽을 수 없는 인덱스도 건드리지 않는다.
@MainActor
final class MaterialBasketStore {
    static let shared = MaterialBasketStore()

    enum LoadState: Equatable {
        /// 예전 인덱스가 없다(처음부터 작업대만 쓴 기기).
        case absent
        case loaded
        /// 인덱스가 있지만 읽거나 해석하지 못했다. 이 경우 옮기지 않고 파일도 건드리지 않는다.
        case unreadable
    }

    private(set) var items: [MaterialItem] = []
    private(set) var loadState: LoadState = .absent
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaterialBasket", isDirectory: true)
        load()
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// 앱 안에 이미 있는 예전 복사본의 위치. 폴더 바로 아래 일반 파일 이름만 받고, 없으면 nil.
    func fileURL(forFilename name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name != "index.json" else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 앱 안 예전 복사본이 차지하는 용량(저장공간 화면 표시용).
    var legacyCopyByteCount: Int64 {
        items.reduce(0) { $0 + ($1.localFilename == nil ? 0 : ($1.byteCount ?? 0)) }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            loadState = .absent
            return
        }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([MaterialItem].self, from: data) else {
            loadState = .unreadable
            return
        }
        items = decoded
        loadState = .loaded
    }
}
