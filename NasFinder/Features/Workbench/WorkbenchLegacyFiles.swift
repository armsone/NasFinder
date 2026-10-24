import Foundation

/// 2.24.4가 잠깐 쓰던 복사 기반 전송 대기 목록(`Application Support/PhotoTransferPending`)의 **읽기 전용** 다리.
/// 작업대가 이 저장소를 대신하므로 새 코드는 이 폴더에 쓰거나 지우지 않는다. 기록(`manifest.json`)에 남은 항목은
/// '기존 전송 대기' 포켓으로 옮겨 앱 안에 이미 있는 복사본을 제자리에서 읽기만 하고, 새로 복사하거나 지우지 않는다.
/// 읽지 못한 기록은 건드리지 않고(해석 불가 복사본도 만들지 않음) 다음 실행에서 다시 시도한다.
/// 구 저장소가 시작 때 지우던 기록 밖 폴더(고아 조각)도 더는 지우지 않는다.
@MainActor
final class LegacyTransferPendingStore {
    static let shared = LegacyTransferPendingStore()

    enum LoadState: Equatable {
        case absent
        case loaded
        case unreadable
    }

    struct Entry: Equatable {
        let id: String
        /// 구 저장소의 출처 이름(사진·동영상 / Google 포토 / 파일)을 작업대 출처 이름으로 바꾼 값.
        let sourceLabel: String
        let displayName: String
        let isVideo: Bool
        let addedAt: Date
        /// 구 저장소의 구성요소 파일 이름(1개, Live/Motion은 이미지+영상 2개).
        let fileNames: [String]
    }

    private(set) var entries: [Entry] = []
    private(set) var loadState: LoadState = .absent
    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTransferPending", isDirectory: true)
        load()
    }

    private var manifestURL: URL { rootURL.appendingPathComponent("manifest.json", isDirectory: false) }
    private var itemsURL: URL { rootURL.appendingPathComponent("items", isDirectory: true) }

    /// 구 기록에서 필요한 필드만 읽는다(와이어 헤더·원본 스냅샷은 읽지 않는다).
    private struct StoredEntry: Decodable {
        struct Component: Decodable { let fileName: String }
        let id: String
        let source: String
        let displayName: String
        let wireKind: String
        let components: [Component]
        let addedAt: Date
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            loadState = .absent
            return
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
            loadState = .unreadable
            return
        }
        entries = stored.map { item in
            let label: String = switch item.source {
            case "google": WorkbenchSourceLabel.googlePhotos
            case "file": WorkbenchSourceLabel.deviceFiles
            default: WorkbenchSourceLabel.media
            }
            return Entry(id: item.id, sourceLabel: label, displayName: item.displayName,
                         isVideo: item.wireKind == "video", addedAt: item.addedAt,
                         fileNames: item.components.map(\.fileName))
        }
        loadState = .loaded
    }

    /// 구 복사본의 위치. 폴더 구분자나 상위 이동이 섞인 이름은 거부하고, 파일이 없으면 nil.
    func fileURL(id: String, fileName: String) -> URL? {
        func isSafe(_ part: String) -> Bool {
            !part.isEmpty && !part.contains("/") && part != "." && part != ".."
        }
        guard isSafe(id), isSafe(fileName) else { return nil }
        let url = itemsURL.appendingPathComponent(id, isDirectory: true).appendingPathComponent(fileName, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// 예전 복사본(영상 재료함·전송 대기)이 앱 안에 이미 가진 파일의 위치. 새로 복사하거나 지우지 않고 읽기만 한다.
@MainActor
enum WorkbenchLegacyFiles {
    /// 전송 대기 복사본을 가리키는 `legacyFilename` 접두사: `pending/<항목 ID>/<파일 이름>`.
    nonisolated static let pendingPrefix = "pending/"

    nonisolated static func pendingName(id: String, fileName: String) -> String { "pending/\(id)/\(fileName)" }

    static func url(forLegacyName name: String) -> URL? {
        if name.hasPrefix(pendingPrefix) {
            let parts = name.dropFirst(pendingPrefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            return LegacyTransferPendingStore.shared.fileURL(id: parts[0], fileName: parts[1])
        }
        return MaterialBasketStore.shared.fileURL(forFilename: name)
    }
}
