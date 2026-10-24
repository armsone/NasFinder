import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct BrowserFavoritesArchive: Codable, Equatable {
    static let typeIdentifier = "com.intosharp.hanclip.browser-favorites"
    static let filenameExtension = "hanclipfavorites"

    let version: Int
    let favorites: [String]

    init(favorites: [String]) {
        version = 1
        self.favorites = favorites
    }
}

struct BrowserFavoritesImportResult: Equatable {
    var addedCount = 0
    var skippedCount = 0

    mutating func merge(_ other: Self) {
        addedCount += other.addedCount
        skippedCount += other.skippedCount
    }

    var message: String {
        if addedCount > 0, skippedCount > 0 {
            return "즐겨찾기 \(addedCount)개를 추가하고 중복 \(skippedCount)개를 건너뛰었습니다."
        }
        if addedCount > 0 { return "즐겨찾기 \(addedCount)개를 추가했습니다." }
        if skippedCount > 0 { return "이미 등록된 즐겨찾기 \(skippedCount)개를 건너뛰었습니다." }
        return "가져올 즐겨찾기가 없습니다."
    }
}

enum BrowserFavoriteAddress {
    static func canonicalKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        } else {
            while components.path.count > 1, components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string
    }

    static func normalizedAddress(_ value: String) -> String? {
        BrowserURLPolicy.normalizedURL(from: value)?.absoluteString
    }
}

@MainActor
final class BrowserFavoritesStore: ObservableObject {
    static let storageKey = "webBrowserFavorites"
    /// 비공개 웹 즐겨찾기는 기존 키를 건드리지 않고 별도 키에 둔다(두 목록이 분리되어 같은 주소 충돌이 없다).
    static let privateStorageKey = "webBrowserFavorites.private"

    /// 공개 즐겨찾기. 0번이 홈페이지다. 비공개 즐겨찾기는 홈페이지가 될 수 없다.
    @Published private(set) var publicFavorites: [String]
    @Published private(set) var privateFavorites: [String]
    @Published var noticeMessage: String?
    @Published var errorMessage: String?

    /// 지금 모드에서 보이는 즐겨찾기: 일반 모드는 공개만, 프라이버시 모드는 공개 다음에 비공개.
    var favorites: [String] {
        PrivacyMode.currentlyActive ? publicFavorites + privateFavorites : publicFavorites
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        publicFavorites = Self.values(from: defaults.string(forKey: Self.storageKey) ?? "")
        privateFavorites = Self.values(from: defaults.string(forKey: Self.privateStorageKey) ?? "")
    }

    func isPrivate(_ address: String) -> Bool {
        if privateFavorites.contains(address) { return true }
        guard let key = BrowserFavoriteAddress.canonicalKey(address) else { return false }
        return privateFavorites.contains { BrowserFavoriteAddress.canonicalKey($0) == key }
    }

    /// 공개·비공개 전체 원본에서 같은 정규 주소가 이미 있는지(모드와 무관).
    private func rawContains(key: String) -> Bool {
        (publicFavorites + privateFavorites).contains { BrowserFavoriteAddress.canonicalKey($0) == key }
    }

    func contains(_ address: String) -> Bool {
        guard let key = BrowserFavoriteAddress.canonicalKey(address) else { return false }
        return favorites.contains { BrowserFavoriteAddress.canonicalKey($0) == key }
    }

    /// 보이는 즐겨찾기면 해제, 아니면 추가한다. 일반 모드에서 같은 주소의 비공개 항목이 있어도 그 항목은 바꾸지 않는다.
    func toggle(_ address: String) {
        guard let normalized = BrowserFavoriteAddress.normalizedAddress(address),
              let key = BrowserFavoriteAddress.canonicalKey(normalized) else { return }
        if let index = publicFavorites.firstIndex(where: { BrowserFavoriteAddress.canonicalKey($0) == key }) {
            publicFavorites.remove(at: index)
        } else if PrivacyMode.currentlyActive,
                  let index = privateFavorites.firstIndex(where: { BrowserFavoriteAddress.canonicalKey($0) == key }) {
            privateFavorites.remove(at: index)
        } else if PrivacyMode.currentlyActive {
            privateFavorites.append(normalized)
        } else if rawContains(key: key) {
            // 일반 모드에서 같은 주소가 숨겨진 비공개 목록에 있으면 공개 복제본을 만들지 않고 숨겨진 항목도 건드리지 않는다.
            noticeMessage = "지금은 이 주소를 즐겨찾기에 추가할 수 없습니다."
            return
        } else {
            publicFavorites.append(normalized)
        }
        save()
    }

    func remove(_ address: String) {
        let key = BrowserFavoriteAddress.canonicalKey(address)
        func matches(_ value: String) -> Bool {
            value == address || (key != nil && BrowserFavoriteAddress.canonicalKey(value) == key)
        }
        publicFavorites.removeAll(where: matches)
        if PrivacyMode.currentlyActive { privateFavorites.removeAll(where: matches) }
        save()
    }

    /// 지금 보이는 즐겨찾기만 지운다(일반 모드에서는 숨겨진 비공개 목록을 지우지 않는다).
    func removeAll() {
        publicFavorites.removeAll()
        if PrivacyMode.currentlyActive { privateFavorites.removeAll() }
        save()
    }

    /// 보이는 목록 기준 이동. 각 주소는 자기 목록(공개/비공개)에 남고 목록 안 상대 순서만 바뀐다.
    func move(from source: IndexSet, to destination: Int) {
        var combined = favorites
        combined.move(fromOffsets: source, toOffset: destination)
        let publicSet = Set(publicFavorites)
        publicFavorites = combined.filter { publicSet.contains($0) }
        if PrivacyMode.currentlyActive {
            let privateSet = Set(privateFavorites)
            privateFavorites = combined.filter { privateSet.contains($0) }
        }
        save()
    }

    func makeHomepage(_ address: String) {
        guard let index = publicFavorites.firstIndex(of: address), index != 0 else { return }
        let value = publicFavorites.remove(at: index)
        publicFavorites.insert(value, at: 0)
        save()
    }

    /// 명시적인 공개/비공개 전환. 주소 문자열은 그대로 두고 소속 목록만 옮긴다(전환 시 홈페이지 지정은 풀린다).
    func setPrivate(_ address: String, _ isPrivate: Bool) {
        // 같은 정규 주소는 문자열이 조금 달라도 하나의 신원으로 본다(한 주소가 양쪽 목록에 동시에 남지 않게).
        let key = BrowserFavoriteAddress.canonicalKey(address)
        func matches(_ value: String) -> Bool {
            value == address || (key != nil && BrowserFavoriteAddress.canonicalKey(value) == key)
        }
        if isPrivate, let index = publicFavorites.firstIndex(where: matches) {
            let value = publicFavorites.remove(at: index)
            if !privateFavorites.contains(where: matches) { privateFavorites.append(value) }
        } else if !isPrivate, let index = privateFavorites.firstIndex(where: matches) {
            let value = privateFavorites.remove(at: index)
            if !publicFavorites.contains(where: matches) { publicFavorites.append(value) }
        }
        save()
    }

    /// 일괄 내보내기 기본값은 공개만이다. 비공개 포함은 호출자가 명시적으로 고른 경우에만 쓴다.
    func exportableFavorites(includingPrivate: Bool) -> [String] {
        includingPrivate && PrivacyMode.currentlyActive ? publicFavorites + privateFavorites : publicFavorites
    }

    @discardableResult
    func importArchiveData(_ data: Data) throws -> BrowserFavoritesImportResult {
        let archive = try JSONDecoder().decode(BrowserFavoritesArchive.self, from: data)
        let addsPrivate = PrivacyMode.currentlyActive
        // 중복 판정은 보이는 목록이 아니라 공개·비공개 전체 원본 기준이라, 일반 모드 가져오기가 숨겨진 주소를 공개로 복제하지 않는다.
        var existingKeys = Set((publicFavorites + privateFavorites).compactMap(BrowserFavoriteAddress.canonicalKey))
        var result = BrowserFavoritesImportResult()
        for value in archive.favorites {
            guard let normalized = BrowserFavoriteAddress.normalizedAddress(value),
                  let key = BrowserFavoriteAddress.canonicalKey(normalized) else { continue }
            if existingKeys.insert(key).inserted {
                if addsPrivate { privateFavorites.append(normalized) } else { publicFavorites.append(normalized) }
                result.addedCount += 1
            } else {
                result.skippedCount += 1
            }
        }
        save()
        noticeMessage = result.message
        return result
    }

    func importExternalFile(_ url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        _ = try importArchiveData(data)
    }

    @discardableResult
    func importPendingSharedArchives() -> Bool {
        do {
            let all = try SharedInbox.records()
            let scope = PrivateScope(records: all)
            // 일반 모드에서는 비공개 파일을 읽지도 지우지도 않는다.
            let records = all.filter(Self.isFavoritesRecord)
                .filter { PrivacyMode.currentlyActive || !scope.contains($0) }
            guard !records.isEmpty else { return false }
            var combined = BrowserFavoritesImportResult()
            var importedAny = false
            for record in records {
                let url = try SharedInbox.fileURL(for: record)
                guard let data = try? Data(contentsOf: url),
                      let result = try? importArchiveData(data) else { continue }
                combined.merge(result)
                try SharedInbox.delete(record)
                importedAny = true
            }
            if importedAny { noticeMessage = combined.message }
            return importedAny
        } catch {
            errorMessage = "공유한 즐겨찾기를 가져오지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    static func isFavoritesFile(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare(BrowserFavoritesArchive.filenameExtension)
            == .orderedSame
    }

    private static func isFavoritesRecord(_ record: SharedInboxRecord) -> Bool {
        (record.originalFilename as NSString).pathExtension
            .caseInsensitiveCompare(BrowserFavoritesArchive.filenameExtension) == .orderedSame
            || record.contentTypeIdentifier == BrowserFavoritesArchive.typeIdentifier
    }

    private func save() {
        defaults.set(publicFavorites.joined(separator: "\n"), forKey: Self.storageKey)
        if privateFavorites.isEmpty {
            defaults.removeObject(forKey: Self.privateStorageKey)
        } else {
            defaults.set(privateFavorites.joined(separator: "\n"), forKey: Self.privateStorageKey)
        }
    }

    private static func values(from raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

struct BrowserFavoritesDocument: FileDocument {
    static let contentType = UTType(
        importedAs: BrowserFavoritesArchive.typeIdentifier,
        conformingTo: .json
    )
    static var readableContentTypes: [UTType] { [contentType] }

    let archive: BrowserFavoritesArchive

    init(favorites: [String]) {
        archive = BrowserFavoritesArchive(favorites: favorites)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        archive = try JSONDecoder().decode(BrowserFavoritesArchive.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(archive))
    }
}

struct BrowserFavoriteFavicon: View {
    let address: String

    var body: some View {
        AsyncImage(url: faviconURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit()
            } else {
                Image(interfaceSystemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: ui(28), height: ui(28))
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: ui(6)))
    }

    static func displayTitle(for address: String) -> String {
        guard let url = URL(string: address),
              let host = url.host(percentEncoded: false) else { return address }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    private var faviconURL: URL? {
        guard let host = URL(string: address)?.host(percentEncoded: false) else { return nil }
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64")
        ]
        return components?.url
    }
}

struct BrowserFavoritesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: BrowserFavoritesStore
    @State private var editMode = EditMode.active
    @State private var isExporting = false
    @State private var exportIncludesPrivate = false
    @State private var isAskingExportScope = false
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.favorites, id: \.self) { favorite in
                    HStack(spacing: ui(12)) {
                        BrowserFavoriteFavicon(address: favorite)
                        VStack(alignment: .leading, spacing: ui(3)) {
                            Text(BrowserFavoriteFavicon.displayTitle(for: favorite))
                                .font(.ui(.subheadline).weight(.semibold))
                                .lineLimit(1)
                            Text(favorite)
                                .font(.ui(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: ui(6))
                        if store.isPrivate(favorite) {
                            Image(interfaceSystemName: "eye.slash")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("비공개")
                        }
                        Button(role: .destructive) {
                            store.remove(favorite)
                        } label: {
                            ThemedSymbol(systemName: "trash", size: ui(22))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, ui(5))
                    .contextMenu {
                        if store.isPrivate(favorite) {
                            Button("공개로 전환", interfaceSystemImage: "eye") { store.setPrivate(favorite, false) }
                        } else if PrivacyMode.shared.isActive {
                            Button("비공개로 전환", interfaceSystemImage: "eye.slash") { store.setPrivate(favorite, true) }
                        }
                    }
                }
                .onMove(perform: store.move)
            }
            .environment(\.editMode, $editMode)
            .overlay {
                if store.favorites.isEmpty {
                    ContentUnavailableView("등록된 즐겨찾기가 없습니다", systemImage: "bookmark")
                }
            }
            .navigationTitle("즐겨찾기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Group {
                        Button("전체삭제", interfaceSystemImage: "trash", role: .destructive) {
                            store.removeAll()
                        }
                        .disabled(store.favorites.isEmpty)
                    }
                    .uiBarFont()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        HStack(spacing: ui(10)) {
                            Button {
                                if store.privateFavorites.isEmpty || !PrivacyMode.shared.isActive {
                                    exportIncludesPrivate = false
                                    isExporting = true
                                } else {
                                    isAskingExportScope = true
                                }
                            } label: {
                                ThemedSymbol(systemName: "square.and.arrow.up", size: ui(22))
                            }
                            .disabled(store.favorites.isEmpty)
                            .accessibilityLabel("즐겨찾기 파일로 저장")
                            Button("닫기", interfaceSystemImage: "xmark") { dismiss() }
                                .labelStyle(.iconOnly)
                        }
                    }
                    .uiBarFont()
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: BrowserFavoritesDocument(favorites: store.exportableFavorites(includingPrivate: exportIncludesPrivate)),
            contentType: BrowserFavoritesDocument.contentType,
            defaultFilename: "NasFinder-브라우저-즐겨찾기"
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("내보낼 범위", isPresented: $isAskingExportScope, titleVisibility: .visible) {
            Button("공개 즐겨찾기만") { exportIncludesPrivate = false; isExporting = true }
            Button("비공개 포함") { exportIncludesPrivate = true; isExporting = true }
            Button("취소", role: .cancel) {}
        } message: {
            Text("파일에는 공개/비공개 표시가 남지 않습니다. 비공개 포함 파일은 일반 파일과 구별되지 않습니다.")
        }
        .alert("즐겨찾기를 저장할 수 없습니다", isPresented: exportErrorBinding) {
            Button("확인", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )
    }
}
