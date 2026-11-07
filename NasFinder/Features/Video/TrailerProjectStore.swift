import AVFoundation
import Foundation
import OSLog

// MARK: - 편집 장면

/// 한 장면 또는 전체 장면에 적용되는 자막 정보.
struct TrailerCaption: Codable, Equatable, Sendable {
    enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case top = "상단"
        case center = "가운데"
        case bottom = "하단"
        var id: String { rawValue }
    }

    enum FontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard = "기본"
        case serif = "명조"
        case rounded = "둥근"
        case monospaced = "고정폭"
        var id: String { rawValue }
    }

    var text: String
    var position: Position
    var fontDesign: FontDesign
    var fontSize: Double
    var colorHex: String
    var hasShadow: Bool

    // 5x5 위치 격자 (column: 0...4, row: 0...4)
    var column: Int
    var row: Int
    var fontName: String
    var captionSize: CaptionSize
    var shadowColorHex: String
    var shadowOpacity: Double
    var lineSpacing: Double

    init(
        text: String = "",
        position: Position = .top,
        fontDesign: FontDesign = .standard,
        fontSize: Double = 24.0,
        colorHex: String = "#FFFFFF",
        hasShadow: Bool = true,
        column: Int = 0,
        row: Int = 0,
        fontName: String = "pretendard_bold",
        captionSize: CaptionSize = .normal,
        shadowColorHex: String = "#000000",
        shadowOpacity: Double = 0.7,
        lineSpacing: Double = 1.0
    ) {
        self.text = text
        self.position = position
        self.fontDesign = fontDesign
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.hasShadow = hasShadow
        self.column = min(4, max(0, column))
        self.row = min(4, max(0, row))
        self.fontName = fontName
        self.captionSize = captionSize
        self.shadowColorHex = shadowColorHex
        self.shadowOpacity = min(1.0, max(0.0, shadowOpacity))
        self.lineSpacing = min(2.0, max(0.5, lineSpacing))
    }

    enum CodingKeys: String, CodingKey {
        case text, position, fontDesign, fontSize, colorHex, hasShadow
        case column, row, fontName, captionSize, shadowColorHex, shadowOpacity, lineSpacing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .top
        fontDesign = try c.decodeIfPresent(FontDesign.self, forKey: .fontDesign) ?? .standard
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24.0
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        hasShadow = try c.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? true

        if let col = try c.decodeIfPresent(Int.self, forKey: .column),
           let r = try c.decodeIfPresent(Int.self, forKey: .row) {
            column = min(4, max(0, col))
            row = min(4, max(0, r))
        } else {
            switch position {
            case .top:
                column = 0; row = 0
            case .center:
                column = 2; row = 2
            case .bottom:
                column = 2; row = 4
            }
        }

        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "pretendard_bold"
        captionSize = try c.decodeIfPresent(CaptionSize.self, forKey: .captionSize) ?? .normal
        shadowColorHex = try c.decodeIfPresent(String.self, forKey: .shadowColorHex) ?? "#000000"
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? 0.7
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.0
    }
}

/// 장면 직접 편집에서 쓰는 한 장면. 자동 추천 계획(VideoTrailerScene)을 그대로 씨앗으로 삼고,
/// 사용자가 고친 값만 이 목록에 남는다. 영상은 start/length(트림), 사진은 length(표시 시간).
struct TrailerEditScene: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var sourceID: Int
    var start: Double
    var length: Double
    /// 결과 영상에서 빠지지만 목록에는 남는다. 삭제와 다르다.
    var excluded = false
    /// 이 장면의 원본 소리만 끈다(전역 음악과 별개).
    var muted = false
    /// 이 장면만 화면 전체를 채우지 않고 안에 맞춘다(영상·사진).
    var fitsFrame = false
    /// 이 장면 원본 소리의 음량(0...1). 영상 전용이며 `muted`와 별개로 고른다.
    var volume = 1.0
    /// 사진·영상을 화면에 채울 때 보여 줄 위치(-1...1). 0이 가운데이고, 넘치는 쪽으로만 움직인다.
    /// 화면 안에 맞추기(`fitsFrame`)에서는 쓰지 않는다.
    var offsetX = 0.0
    var offsetY = 0.0
    /// 이 장면에 붙는 자막(nil이면 문구 없음).
    var caption: TrailerCaption? = nil

    /// 사진 장면에서 사용자가 직접 정한 화면 구성이 있는지. 없으면 기존 자동 확대 효과를 그대로 쓴다.
    var hasCustomFraming: Bool { fitsFrame || offsetX != 0 || offsetY != 0 }

    enum CodingKeys: String, CodingKey {
        case id, sourceID, start, length, excluded, muted, fitsFrame, volume, offsetX, offsetY, caption
    }
}

extension TrailerEditScene {
    /// 이전 버전이 저장한 프로젝트에는 새 항목이 없으므로 없는 값은 기본값으로 읽는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sourceID = try c.decode(Int.self, forKey: .sourceID)
        start = try c.decode(Double.self, forKey: .start)
        length = try c.decode(Double.self, forKey: .length)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fitsFrame = try c.decodeIfPresent(Bool.self, forKey: .fitsFrame) ?? false
        volume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1))
        offsetX = min(1, max(-1, try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0))
        offsetY = min(1, max(-1, try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0))
        caption = try c.decodeIfPresent(TrailerCaption.self, forKey: .caption)
    }
}

// MARK: - 저장 형식

/// 영상 시작 또는 마지막에 들어가는 타이틀/서브타이틀 카드 설정.
struct TrailerTitleCard: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var title: String
    var subtitle: String
    var duration: Double
    var usesFirstOrLastImage: Bool
    /// 배경으로 고른 프로젝트 사진의 소스 id(프로젝트에 저장되는 안정된 id). nil이면 기존처럼
    /// `usesFirstOrLastImage`일 때 첫/마지막 장면, 아니면 단색이다. 사진이 사라졌거나 사진이 아니면 같은 기존 규칙으로 돌아간다.
    var backgroundSourceID: Int?
    /// 배경으로 고른 프로젝트 사진 또는 비디오 스틸의 타임스탬프(초). 비디오 스틸일 때 사용되며 nil이면 사진 소스이거나 기본 위치.
    var backgroundTimestamp: Double?
    /// true면 문구를 본편 자막 서체로 그린다. 이전 프로젝트와 폰 시트는 false라 기존 모양을 유지한다.
    var usesBodyTypography: Bool
    /// 제목/부제목 개별 스타일. 둘 다 nil이면 기존의 본편 자막 서체 또는 기본 서체 경로로 중앙 결합 렌더링된다.
    var titleStyle: TrailerCaption?
    var subtitleStyle: TrailerCaption?

    init(
        isEnabled: Bool = false,
        title: String = "",
        subtitle: String = "",
        duration: Double = 3.0,
        usesFirstOrLastImage: Bool = true,
        backgroundSourceID: Int? = nil,
        backgroundTimestamp: Double? = nil,
        usesBodyTypography: Bool = false,
        titleStyle: TrailerCaption? = nil,
        subtitleStyle: TrailerCaption? = nil
    ) {
        self.isEnabled = isEnabled
        self.title = title
        self.subtitle = subtitle
        self.duration = max(1.0, min(10.0, duration))
        self.usesFirstOrLastImage = usesFirstOrLastImage
        self.backgroundSourceID = backgroundSourceID
        self.backgroundTimestamp = backgroundTimestamp
        self.usesBodyTypography = usesBodyTypography
        self.titleStyle = titleStyle
        self.subtitleStyle = subtitleStyle
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, title, subtitle, duration, usesFirstOrLastImage, backgroundSourceID, backgroundTimestamp, usesBodyTypography
        case titleStyle, subtitleStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        let d = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3.0
        duration = max(1.0, min(10.0, d))
        usesFirstOrLastImage = try c.decodeIfPresent(Bool.self, forKey: .usesFirstOrLastImage) ?? true
        backgroundSourceID = try c.decodeIfPresent(Int.self, forKey: .backgroundSourceID)
        backgroundTimestamp = try c.decodeIfPresent(Double.self, forKey: .backgroundTimestamp)
        usesBodyTypography = try c.decodeIfPresent(Bool.self, forKey: .usesBodyTypography) ?? false
        titleStyle = try c.decodeIfPresent(TrailerCaption.self, forKey: .titleStyle)
        subtitleStyle = try c.decodeIfPresent(TrailerCaption.self, forKey: .subtitleStyle)
    }
}

/// 한 편집 프로젝트가 디스크에 남기는 전부. 미디어 파일은 프로젝트 폴더 안의 상대 경로로만 참조한다.
struct TrailerProjectRecord: Codable, Sendable {
    struct Source: Codable, Sendable {
        var id: Int
        var name: String
        var file: String
        var isImage: Bool
        var duration: Double
        var contentTypeIdentifier: String?
        var captureDate: Date?
        var imageDurationRatio: Double
        var waveform: [Double]
        var peakTime: Double
        var peakTimes: [Double]
        var highlightSource: String
        var audioAvailability: String
        var highlightAnalyzed: Bool
        /// 1 = 레거시(0.35...0.75), 2 = 현재 정책(0.10...0.95 + 보너스). 구버전 저장본은 nil(1로 읽음).
        var imageDurationPolicyVersion: Int? = nil
        var isImportant: Bool? = nil
    }

    struct Music: Codable, Sendable {
        var recordID: UUID
        var name: String
        var file: String
        var duration: Double
        var policy: String
        var fitCount: Int
        var autoDuck: Bool
        /// 배경음악 음량 배율(0...1). 이전 프로젝트에는 없어 nil이면 1로 읽는다.
        var level: Double? = nil
    }

    var schema = 1
    var id: UUID
    var customTitle: String?
    var mode: String
    var createdAt: Date
    var updatedAt: Date
    var revision: Int
    /// 사용자가 정한 현재 순서.
    var sources: [Source]
    var nextSourceID: Int
    var removedSourceIDs: [Int]
    var skippedSourceIDs: [Int]
    var knownSourceIDs: [Int]
    var photosAnalyzed: Bool
    var total: Double
    var clipLength: Double
    var aspectRatio: String?
    var music: Music?
    var scenes: [TrailerEditScene]?
    var nextSceneID: Int
    var selectedSceneID: Int?
    var outputFile: String?
    var outputMode: String?
    var showedSettings: Bool
    var linkedCollectionVideoIDs: [UUID]
    /// 비공개 편집본(nil = 공개, 예전 데이터와 같다). 비공개 입력이 한 번 들어오면 풀리지 않는 오염 플래그이며,
    /// 공개로 되돌리는 것은 사용자의 명시적 전환뿐이다. 이 편집본의 출력·컬렉션 영상·폰하드 파일에 이어진다.
    var isPrivate: Bool? = nil
    /// 이 프로젝트에 설정된 일괄 자막 스타일(nil이면 기본값 사용).
    var batchCaption: TrailerCaption? = nil
    /// 시작 화면 타이틀 카드 (구버전은 nil)
    var introCard: TrailerTitleCard? = nil
    /// 마지막 화면 타이틀 카드 (구버전은 nil)
    var outroCard: TrailerTitleCard? = nil
}

/// 저장 요청 한 번에 필요한 값. 메인 액터에서 만들고 디스크 작업은 백그라운드에서 한다.
struct TrailerProjectSnapshot: Sendable {
    var record: TrailerProjectRecord
    /// 소스 id → 지금 편집기가 들고 있는 임시 사본.
    var stagedFiles: [Int: URL]
    var musicFile: URL?
    var outputFile: URL?
}

enum TrailerProjectSaveState: Equatable {
    case idle
    case saving
    case saved(Date)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "변경 없음"
        case .saving: "저장 중…"
        case .saved: "저장됨"
        case .failed(let message): "저장 실패 · \(message)"
        }
    }
}

enum TrailerProjectError: LocalizedError {
    case stagedMissing(String)
    case invalid

    var errorDescription: String? {
        switch self {
        case .stagedMissing(let name): "\(name)의 작업 사본이 없어 저장하지 못했습니다"
        case .invalid: "프로젝트 정보를 검증하지 못했습니다"
        }
    }
}

// MARK: - 디스크 작업

/// 프로젝트 하나는 `<root>/<id>/` 폴더 하나를 소유한다. 미디어는 `media/` 안의 자기 사본뿐이므로
/// 다른 프로젝트·재료함·컬렉션의 파일을 가리킬 수 없고, 삭제도 이 폴더 안으로 한정된다.
/// 메타데이터는 임시 파일에 쓰고 다시 읽어 검증한 뒤에만 기존 파일을 교체하며, 교체 직전의
/// 파일은 `.bak`으로 남는다.
enum TrailerProjectDisk {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder", category: "trailer-project")

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NasFinderProjects", isDirectory: true)
    }

    static func folder(_ id: UUID, root: URL) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func jsonURL(_ folder: URL) -> URL { folder.appendingPathComponent("project.json") }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 상대 경로가 프로젝트 폴더 밖으로 나가지 않을 때만 URL을 돌려준다.
    static func resolve(_ relative: String, in folder: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else { return nil }
        let url = folder.appendingPathComponent(relative)
        let base = folder.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(base) ? url : nil
    }

    private static func referencedFiles(_ record: TrailerProjectRecord) -> Set<String> {
        var files = Set(record.sources.map(\.file))
        if let music = record.music { files.insert(music.file) }
        if let output = record.outputFile { files.insert(output) }
        return files
    }

    /// 임시 이름으로 복사한 뒤 이름을 바꾼다. 중간에 끊겨도 완성되지 않은 파일이 목록에 보이지 않는다.
    private static func copyIn(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            try files.copyItem(at: source, to: partial)
            try files.moveItem(at: partial, to: destination)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    /// 새 미디어를 프로젝트 폴더로 복사하고 메타데이터를 원자적으로 교체한다. 실패하면 이전 상태가 그대로 남는다.
    static func commit(_ snapshot: TrailerProjectSnapshot, root: URL) throws -> TrailerProjectRecord {
        let files = FileManager.default
        var record = snapshot.record
        let folder = folder(record.id, root: root)
        let media = folder.appendingPathComponent("media", isDirectory: true)
        try files.createDirectory(at: media, withIntermediateDirectories: true)
        let previous = load(folder: folder)
        var newlyCopied: [URL] = []
        /// 편집기의 임시 사본 이름(고유)을 그대로 프로젝트 안의 이름으로 쓴다. 이미 있으면 다시 복사하지 않는다.
        func place(_ staged: URL) throws -> String {
            let relative = "media/" + staged.lastPathComponent
            guard let destination = resolve(relative, in: folder) else { throw TrailerProjectError.invalid }
            if !files.fileExists(atPath: destination.path) {
                try copyIn(staged, to: destination)
                newlyCopied.append(destination)
            }
            return relative
        }
        do {
            for index in record.sources.indices {
                let source = record.sources[index]
                guard let staged = snapshot.stagedFiles[source.id], files.fileExists(atPath: staged.path) else {
                    // 임시 사본이 사라졌어도 이전 저장의 사본이 남아 있으면 그것을 유지한다.
                    if let existing = previous?.sources.first(where: { $0.id == source.id }),
                       let url = resolve(existing.file, in: folder), files.fileExists(atPath: url.path) {
                        record.sources[index].file = existing.file
                        continue
                    }
                    throw TrailerProjectError.stagedMissing(source.name)
                }
                record.sources[index].file = try place(staged)
            }
            if var music = record.music {
                if let staged = snapshot.musicFile, files.fileExists(atPath: staged.path) {
                    music.file = try place(staged)
                } else if let existing = previous?.music, existing.recordID == music.recordID,
                          let url = resolve(existing.file, in: folder), files.fileExists(atPath: url.path) {
                    music.file = existing.file
                } else {
                    throw TrailerProjectError.stagedMissing(music.name)
                }
                record.music = music
            }
            if let output = snapshot.outputFile, files.fileExists(atPath: output.path) {
                record.outputFile = try place(output)
            } else {
                record.outputFile = nil
                record.outputMode = nil
            }
            record.revision = (previous?.revision ?? 0) + 1
            record.updatedAt = Date()
            try writeMetadata(record, folder: folder)
        } catch {
            // 이번 저장이 새로 만든 사본만 지운다. 기존 프로젝트 파일은 건드리지 않는다.
            for url in newlyCopied { try? files.removeItem(at: url) }
            logger.error("project commit failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            throw error
        }
        // 새 메타데이터가 자리 잡은 뒤에만, 이 프로젝트가 더 이상 가리키지 않는 자기 사본을 정리한다.
        sweepUnreferenced(record: record, folder: folder)
        return record
    }

    static func writeMetadata(_ record: TrailerProjectRecord, folder: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder().encode(record)
        // 쓰기 전에 되읽어 검증한다.
        guard let check = try? decoder().decode(TrailerProjectRecord.self, from: data), check.id == record.id else {
            throw TrailerProjectError.invalid
        }
        let target = jsonURL(folder)
        let temporary = folder.appendingPathComponent("project.json.tmp")
        try data.write(to: temporary, options: .atomic)
        if files.fileExists(atPath: target.path) {
            // 지금 파일이 읽을 수 있는 올바른 기록일 때만 백업으로 돌린다. 깨진 파일로 좋은 백업을 덮지 않는다.
            // 백업 갱신이 실패하면 교체하지 않는다. 그래야 백업이 가리키는 미디어와 정리 기준이 어긋나지 않는다.
            if decodeValid(target, folder: folder) != nil {
                let backup = folder.appendingPathComponent("project.json.bak")
                let backupTemp = folder.appendingPathComponent("project.json.bak.tmp")
                try? files.removeItem(at: backupTemp)
                do {
                    try files.copyItem(at: target, to: backupTemp)
                    if files.fileExists(atPath: backup.path) {
                        _ = try files.replaceItemAt(backup, withItemAt: backupTemp)
                    } else {
                        try files.moveItem(at: backupTemp, to: backup)
                    }
                } catch {
                    try? files.removeItem(at: backupTemp)
                    try? files.removeItem(at: temporary)
                    throw error
                }
            }
            do {
                _ = try files.replaceItemAt(target, withItemAt: temporary)
            } catch {
                try? files.removeItem(at: temporary)
                throw error
            }
        } else {
            try files.moveItem(at: temporary, to: target)
        }
    }

    /// `url`의 기록이 이 폴더의 프로젝트로 읽히면 돌려준다.
    private static func decodeValid(_ url: URL, folder: URL) -> TrailerProjectRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder().decode(TrailerProjectRecord.self, from: data),
              record.id.uuidString == folder.lastPathComponent else { return nil }
        return record
    }

    /// 현재 기록과 (있다면) 백업 기록이 가리키는 자기 사본은 남기고 나머지만 지운다. 백업은 읽기 실패 때
    /// 되돌아갈 기록이므로 그 미디어도 지켜야 한다. 백업 파일이 있는데 읽을 수 없으면 무엇을 가리키는지
    /// 알 수 없으므로 이번에는 아무것도 지우지 않는다(다음 저장이 올바른 백업으로 바꾼 뒤 정리된다).
    static func sweepUnreferenced(record: TrailerProjectRecord, folder: URL) {
        let files = FileManager.default
        let media = folder.appendingPathComponent("media", isDirectory: true)
        var keep = referencedFiles(record)
        let backup = folder.appendingPathComponent("project.json.bak")
        if files.fileExists(atPath: backup.path) {
            guard let previous = decodeValid(backup, folder: folder) else {
                logger.notice("project sweep skipped: backup metadata unreadable")
                return
            }
            keep.formUnion(referencedFiles(previous))
        }
        guard let names = try? files.contentsOfDirectory(atPath: media.path) else { return }
        for name in names where !keep.contains("media/\(name)") {
            // 방금 만든 임시 복사는 진행 중일 수 있으므로 지우지 않는다.
            if name.hasPrefix(".partial-") { continue }
            if let url = resolve("media/\(name)", in: folder) { try? files.removeItem(at: url) }
        }
    }

    static func load(folder: URL) -> TrailerProjectRecord? {
        for name in ["project.json", "project.json.bak"] {
            let url = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let record = try? decoder().decode(TrailerProjectRecord.self, from: data),
               record.id.uuidString == folder.lastPathComponent {
                return record
            }
        }
        return nil
    }

    /// 읽을 수 없는 폴더는 지우지 않고 이름만 알린다.
    static func loadAll(root: URL) -> (records: [TrailerProjectRecord], unreadable: [String]) {
        let files = FileManager.default
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return ([], []) }
        var records: [TrailerProjectRecord] = []
        var unreadable: [String] = []
        for name in names.sorted() where UUID(uuidString: name) != nil {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            if let record = load(folder: folder) { records.append(record) } else { unreadable.append(name) }
        }
        return (records, unreadable)
    }

    /// 프로젝트가 가리키는 미디어 중 실제로 없는 상대 경로.
    static func missingFiles(_ record: TrailerProjectRecord, root: URL) -> [String] {
        let folder = folder(record.id, root: root)
        return referencedFiles(record).sorted().filter { relative in
            guard let url = resolve(relative, in: folder) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// 삭제: 이 프로젝트 폴더 안의 파일만, 그리고 다른 프로젝트가 같은 경로를 가리키지 않을 때만 지운다.
    static func remove(id: UUID, root: URL, protectedPaths: Set<String>) {
        let files = FileManager.default
        let folder = folder(id, root: root)
        guard files.fileExists(atPath: folder.path) else { return }
        let base = folder.standardizedFileURL.path + "/"
        if let enumerator = files.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
            var all: [URL] = []
            for case let url as URL in enumerator { all.append(url) }
            for url in all.reversed() {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base), !protectedPaths.contains(path) else { continue }
                var isDirectory: ObjCBool = false
                files.fileExists(atPath: path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    if (try? files.contentsOfDirectory(atPath: path))?.isEmpty == true { try? files.removeItem(at: url) }
                } else {
                    try? files.removeItem(at: url)
                }
            }
        }
        if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? files.removeItem(at: folder) }
    }

    /// 복제: 임시 폴더에 완성한 뒤 한 번에 이름을 바꿔 보이게 한다.
    static func duplicate(_ record: TrailerProjectRecord, root: URL, newID: UUID, title: String) throws -> TrailerProjectRecord {
        let files = FileManager.default
        let source = folder(record.id, root: root)
        let staging = root.appendingPathComponent(".dup-\(newID.uuidString)", isDirectory: true)
        try? files.removeItem(at: staging)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let media = source.appendingPathComponent("media", isDirectory: true)
            if files.fileExists(atPath: media.path) {
                try files.copyItem(at: media, to: staging.appendingPathComponent("media", isDirectory: true))
            }
            var copy = record
            copy.id = newID
            copy.customTitle = title
            copy.createdAt = Date()
            copy.updatedAt = Date()
            copy.revision = 1
            copy.linkedCollectionVideoIDs = []
            try writeMetadata(copy, folder: staging)
            try files.moveItem(at: staging, to: folder(newID, root: root))
            return copy
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    /// 시작 때 이전 실행이 남긴 미완성 임시 파일만 치운다.
    static func sweepStale(root: URL) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix(".dup-") { try? files.removeItem(at: url); continue }
            guard UUID(uuidString: name) != nil else { continue }
            try? files.removeItem(at: url.appendingPathComponent("project.json.tmp"))
            try? files.removeItem(at: url.appendingPathComponent("project.json.bak.tmp"))
            let media = url.appendingPathComponent("media", isDirectory: true)
            for partial in (try? files.contentsOfDirectory(atPath: media.path)) ?? [] where partial.hasPrefix(".partial-") {
                try? files.removeItem(at: media.appendingPathComponent(partial))
            }
        }
    }
}

// MARK: - 저장소

@MainActor
final class TrailerProjectStore: ObservableObject {
    static let shared = TrailerProjectStore()

    @Published private(set) var records: [UUID: TrailerProjectRecord] = [:]
    @Published private(set) var states: [UUID: TrailerProjectSaveState] = [:]
    /// 읽을 수 없어 건드리지 않고 남겨 둔 프로젝트 폴더 이름.
    @Published private(set) var unreadable: [String] = []
    let root: URL

    init(root: URL = TrailerProjectDisk.defaultRoot) {
        self.root = root
        TrailerProjectDisk.sweepStale(root: root)
        let loaded = TrailerProjectDisk.loadAll(root: root)
        records = Dictionary(uniqueKeysWithValues: loaded.records.map { ($0.id, $0) })
        unreadable = loaded.unreadable
    }

    func state(_ id: UUID) -> TrailerProjectSaveState { states[id] ?? .idle }
    func folder(_ id: UUID) -> URL { TrailerProjectDisk.folder(id, root: root) }
    func fileURL(_ relative: String, id: UUID) -> URL? { TrailerProjectDisk.resolve(relative, in: folder(id)) }
    func missing(_ record: TrailerProjectRecord) -> [String] { TrailerProjectDisk.missingFiles(record, root: root) }

    /// 프로젝트별 작업 줄의 마지막 작업. 저장·이름 변경·연결·복제·삭제가 모두 이 줄에 차례로 선다.
    /// 자리는 첫 대기(await) 전에 동기적으로 잡으므로 여러 요청이 같은 `project.json.tmp`나 미디어 정리를
    /// 동시에 건드리지 않는다.
    private var chains: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// 삭제된 프로젝트(이번 실행 동안 유지). 삭제 요청 즉시 표시하며, 이후 저장·이름 변경·연결은 받지 않고
    /// 이미 줄에 선 작업도 끝난 뒤 목록에 되살리지 않는다.
    private var deleted: Set<UUID> = []

    /// `operation`을 프로젝트 `id`의 작업 줄 끝에 세운다. 대기 없이 바로 자리를 잡는다.
    @discardableResult
    private func schedule<T: Sendable>(_ id: UUID,
                                       _ operation: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
        let previous = chains[id]?.task
        let token = UUID()
        let work = Task { @MainActor [weak self] () -> T in
            await previous?.value
            let value = await operation()
            if self?.chains[id]?.token == token { self?.chains[id] = nil }
            return value
        }
        chains[id] = (token, Task { _ = await work.value })
        return work
    }

    /// 작업 줄 끝에 세우고 끝날 때까지 기다린다.
    private func enqueue<T: Sendable>(_ id: UUID, _ operation: @escaping @MainActor @Sendable () async -> T) async -> T {
        await schedule(id, operation).value
    }

    @discardableResult
    func save(_ snapshot: TrailerProjectSnapshot) async -> Bool {
        let id = snapshot.record.id
        guard !deleted.contains(id) else {
            TrailerProjectDisk.logger.notice("save rejected for deleted project")
            return false
        }
        let root = self.root
        return await enqueue(id) { [weak self] in
            guard let self else { return false }
            // 줄을 기다리는 사이 삭제됐으면 저장하지 않는다. 사용자가 지운 편집본이다.
            guard !self.deleted.contains(id) else { return false }
            var snapshot = snapshot
            // 이름과 컬렉션 연결은 편집기가 아니라 이 저장소가 바꾼다. 스냅숏을 만든 뒤 바뀐 값을 되돌리지 않는다.
            if let current = self.records[id] {
                snapshot.record.customTitle = current.customTitle
                var links = current.linkedCollectionVideoIDs
                for link in snapshot.record.linkedCollectionVideoIDs where !links.contains(link) { links.append(link) }
                snapshot.record.linkedCollectionVideoIDs = links
                // 오염은 저장 중에도 풀리지 않는다(공개 전환은 `setPrivate`만).
                snapshot.record.isPrivate = (snapshot.record.isPrivate == true || current.isPrivate == true) ? true : nil
            }
            self.states[id] = .saving
            let merged = snapshot
            let result = await Task.detached(priority: .utility) {
                Result { try TrailerProjectDisk.commit(merged, root: root) }
            }.value
            // 디스크 작업 사이 삭제가 요청됐으면 목록에 되살리지 않는다. 폴더는 줄 뒤의 삭제 작업이 지운다.
            guard !self.deleted.contains(id) else { return false }
            switch result {
            case .success(let record):
                self.records[id] = record
                self.states[id] = .saved(Date())
                return true
            case .failure(let error):
                self.states[id] = .failed(error.localizedDescription)
                return false
            }
        }
    }

    /// 편집본을 즉시 저장한다.
    @discardableResult
    func saveNow(_ snapshot: TrailerProjectSnapshot) async -> Bool {
        await save(snapshot)
    }

    /// 이름을 바꿔 기록한다. 기록에 성공했을 때만 목록을 바꾸고 true.
    @discardableResult
    func rename(_ id: UUID, to title: String) async -> Bool {
        guard !deleted.contains(id) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return await updateMetadata(id) { $0.customTitle = trimmed.isEmpty ? nil : trimmed }
    }

    /// 명시적인 공개/비공개 전환. 편집본 내용은 건드리지 않고 플래그만 기록한다.
    @discardableResult
    func setPrivate(_ id: UUID, _ isPrivate: Bool) async -> Bool {
        guard !deleted.contains(id) else { return false }
        return await updateMetadata(id) { $0.isPrivate = isPrivate ? true : nil }
    }

    /// 컬렉션 영상과의 연결을 기록한다. 기록에 성공했을 때만 목록을 바꾼다.
    @discardableResult
    func linkCollectionVideo(_ videoID: UUID, to projectID: UUID) async -> Bool {
        guard !deleted.contains(projectID) else { return false }
        return await updateMetadata(projectID) { record in
            if !record.linkedCollectionVideoIDs.contains(videoID) { record.linkedCollectionVideoIDs.append(videoID) }
        }
    }

    /// 메타데이터만 바꾸는 작업. 작업 줄 안에서 그때의 최신 기록을 읽어 바꾸므로 앞선 저장을 덮지 않는다.
    private func updateMetadata(_ id: UUID, _ change: @escaping @Sendable (inout TrailerProjectRecord) -> Void) async -> Bool {
        let folder = self.folder(id)
        return await enqueue(id) { [weak self] in
            guard let self, !self.deleted.contains(id), var record = self.records[id] else { return false }
            change(&record)
            record.revision += 1
            record.updatedAt = Date()
            let updated = record
            let result = await Task.detached(priority: .utility) {
                Result { try TrailerProjectDisk.writeMetadata(updated, folder: folder) }
            }.value
            guard !self.deleted.contains(id) else { return false }
            switch result {
            case .success:
                self.records[id] = updated
                self.states[id] = .saved(Date())
                return true
            case .failure(let error):
                self.states[id] = .failed(error.localizedDescription)
                return false
            }
        }
    }

    /// 원본 프로젝트의 작업 줄 안에서 복제한다. 저장·정리가 미디어를 바꾸는 도중에 복사하지 않는다.
    @discardableResult
    func duplicate(_ id: UUID) async -> UUID? {
        guard !deleted.contains(id), records[id] != nil else { return nil }
        let root = self.root
        return await enqueue(id) { [weak self] () -> UUID? in
            guard let self, !self.deleted.contains(id), let record = self.records[id] else { return nil }
            let newID = UUID()
            let title = (record.customTitle ?? "편집본") + " 복사본"
            let result = await Task.detached(priority: .utility) {
                Result { try TrailerProjectDisk.duplicate(record, root: root, newID: newID, title: title) }
            }.value
            switch result {
            case .success(let copy):
                self.records[newID] = copy
                return newID
            case .failure(let error):
                if !self.deleted.contains(id) { self.states[id] = .failed("복제하지 못했습니다: \(error.localizedDescription)") }
                return nil
            }
        }
    }

    /// 프로젝트 폴더만 지운다. 재료함·컬렉션 파일과 원본은 다른 폴더라 건드리지 않는다.
    /// 삭제 표시는 즉시 하고, 실제 폴더 삭제는 이미 줄에 선 작업이 끝난 뒤에 한다.
    func delete(_ id: UUID) {
        let others = records.filter { $0.key != id }.values
        var protected = Set<String>()
        for other in others {
            let folder = self.folder(other.id)
            var relatives = other.sources.map(\.file)
            if let music = other.music { relatives.append(music.file) }
            if let output = other.outputFile { relatives.append(output) }
            for relative in relatives {
                if let url = TrailerProjectDisk.resolve(relative, in: folder) { protected.insert(url.standardizedFileURL.path) }
            }
        }
        deleted.insert(id)
        records[id] = nil
        states[id] = nil
        let root = self.root
        let protectedPaths = protected
        schedule(id) {
            await Task.detached(priority: .utility) {
                TrailerProjectDisk.remove(id: id, root: root, protectedPaths: protectedPaths)
            }.value
        }
    }
}

// MARK: - 프로젝트 미디어 서비스

/// 저장된 프로젝트의 자체 사본을 다시 가져오기 위한 서비스. 읽기만 한다.
struct TrailerProjectMediaService: RemoteFileService {
    static let connectionID = UUID(uuidString: "5C2D0B6E-3E1F-4B7B-9A55-0F1E3C7A2D11")!
    let connection = RemoteConnection(id: TrailerProjectMediaService.connectionID,
        name: "편집본", kind: .synology, host: "localhost", username: "")
    func list(directory path: String?) async throws -> [RemoteFileItem] { [] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        let url = URL(fileURLWithPath: item.path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
    func testConnection() async throws {}
}

/// 한 편집기가 여러 출처(NAS·폰하드·사진·시스템 파일)에서 항목을 받을 때 항목별로 원래 서비스로 보낸다.
final class TrailerRoutedService: RemoteFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: any RemoteFileService] = [:]
    private let fallback: any RemoteFileService

    init(fallback: any RemoteFileService) { self.fallback = fallback }

    var connection: RemoteConnection { fallback.connection }
    var permitsFullDownloadForVideoThumbnail: Bool { fallback.permitsFullDownloadForVideoThumbnail }

    func register(_ items: [RemoteFileItem], service: any RemoteFileService) {
        lock.lock(); defer { lock.unlock() }
        for item in items { routes[item.id] = service }
    }

    private func service(for item: RemoteFileItem) -> any RemoteFileService {
        lock.lock(); defer { lock.unlock() }
        return routes[item.id] ?? fallback
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] { try await fallback.list(directory: path) }
    func download(_ item: RemoteFileItem) async throws -> URL { try await service(for: item).download(item) }
    func testConnection() async throws { try await fallback.testConnection() }
}
