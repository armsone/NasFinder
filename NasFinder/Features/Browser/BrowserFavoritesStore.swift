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

    @Published private(set) var favorites: [String]
    @Published var noticeMessage: String?
    @Published var errorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.values(from: defaults.string(forKey: Self.storageKey) ?? "")
    }

    func contains(_ address: String) -> Bool {
        guard let key = BrowserFavoriteAddress.canonicalKey(address) else { return false }
        return favorites.contains { BrowserFavoriteAddress.canonicalKey($0) == key }
    }

    func toggle(_ address: String) {
        guard let normalized = BrowserFavoriteAddress.normalizedAddress(address),
              let key = BrowserFavoriteAddress.canonicalKey(normalized) else { return }
        if let index = favorites.firstIndex(where: {
            BrowserFavoriteAddress.canonicalKey($0) == key
        }) {
            favorites.remove(at: index)
        } else {
            favorites.append(normalized)
        }
        save()
    }

    func remove(_ address: String) {
        favorites.removeAll { $0 == address }
        save()
    }

    func removeAll() {
        favorites.removeAll()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func makeHomepage(_ address: String) {
        guard let index = favorites.firstIndex(of: address), index != 0 else { return }
        let value = favorites.remove(at: index)
        favorites.insert(value, at: 0)
        save()
    }

    @discardableResult
    func importArchiveData(_ data: Data) throws -> BrowserFavoritesImportResult {
        let archive = try JSONDecoder().decode(BrowserFavoritesArchive.self, from: data)
        var existingKeys = Set(favorites.compactMap(BrowserFavoriteAddress.canonicalKey))
        var result = BrowserFavoritesImportResult()
        for value in archive.favorites {
            guard let normalized = BrowserFavoriteAddress.normalizedAddress(value),
                  let key = BrowserFavoriteAddress.canonicalKey(normalized) else { continue }
            if existingKeys.insert(key).inserted {
                favorites.append(normalized)
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
            let records = try SharedInbox.records().filter(Self.isFavoritesRecord)
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
        defaults.set(favorites.joined(separator: "\n"), forKey: Self.storageKey)
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
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
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
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.favorites, id: \.self) { favorite in
                    HStack(spacing: 12) {
                        BrowserFavoriteFavicon(address: favorite)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(BrowserFavoriteFavicon.displayTitle(for: favorite))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(favorite)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button(role: .destructive) {
                            store.remove(favorite)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 5)
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
                    Button("전체삭제", systemImage: "trash", role: .destructive) {
                        store.removeAll()
                    }
                    .disabled(store.favorites.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            isExporting = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(store.favorites.isEmpty)
                        .accessibilityLabel("즐겨찾기 파일로 저장")
                        Button("닫기", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: BrowserFavoritesDocument(favorites: store.favorites),
            contentType: BrowserFavoritesDocument.contentType,
            defaultFilename: "NasFinder-브라우저-즐겨찾기"
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
            }
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
