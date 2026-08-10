import Foundation

enum FileBrowserSortField: String, CaseIterable, Identifiable, Sendable {
    case name
    case modifiedDate
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "이름"
        case .modifiedDate: "날짜"
        case .size: "크기"
        case .kind: "종류"
        }
    }
}

enum FileBrowserSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: "오름차순"
        case .descending: "내림차순"
        }
    }
}

struct FileBrowserSortOptions: Equatable, Sendable {
    var field: FileBrowserSortField = .name
    var direction: FileBrowserSortDirection = .ascending
    var foldersFirst = true
}

/// Pure local filtering and sorting used by every browser layout. Remote
/// services keep returning server data unchanged, while list, grid, search,
/// selection, and sequential preview all consume the same deterministic view.
enum FileBrowserItemSorter {
    static func displayedItems(
        from items: [RemoteFileItem],
        matching query: String,
        options: FileBrowserSortOptions
    ) -> [RemoteFileItem] {
        sorted(filtered(items, matching: query), options: options)
    }

    static func filtered(
        _ items: [RemoteFileItem],
        matching query: String
    ) -> [RemoteFileItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }

        return items.filter { item in
            item.name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            ) != nil
        }
    }

    static func sorted(
        _ items: [RemoteFileItem],
        options: FileBrowserSortOptions
    ) -> [RemoteFileItem] {
        items.sorted { lhs, rhs in
            if options.foldersFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let primary = compare(lhs, rhs, by: options.field)
            if primary != .orderedSame {
                // Missing metadata remains at the end in both directions.
                if isMissing(lhs, for: options.field) != isMissing(rhs, for: options.field) {
                    return !isMissing(lhs, for: options.field)
                }
                return options.direction == .ascending
                    ? primary == .orderedAscending
                    : primary == .orderedDescending
            }

            let name = lhs.name.localizedStandardCompare(rhs.name)
            if name != .orderedSame { return name == .orderedAscending }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func compare(
        _ lhs: RemoteFileItem,
        _ rhs: RemoteFileItem,
        by field: FileBrowserSortField
    ) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedDate:
            return compare(lhs.modifiedAt, rhs.modifiedAt)
        case .size:
            return compare(lhs.size, rhs.size)
        case .kind:
            return kindKey(for: lhs).localizedStandardCompare(kindKey(for: rhs))
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }

    private static func isMissing(
        _ item: RemoteFileItem,
        for field: FileBrowserSortField
    ) -> Bool {
        switch field {
        case .modifiedDate:
            item.modifiedAt == nil
        case .size:
            item.size == nil
        case .name, .kind:
            false
        }
    }

    private static func kindKey(for item: RemoteFileItem) -> String {
        if item.isDirectory { return "folder" }

        let filenameExtension = (item.name as NSString).pathExtension.lowercased()
        if !filenameExtension.isEmpty { return filenameExtension }
        return item.contentTypeIdentifier?.lowercased() ?? "file"
    }
}

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published private(set) var items: [RemoteFileItem] = []
    @Published private(set) var displayedItems: [RemoteFileItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let connection: RemoteConnection
    let path: String
    let service: any RemoteFileService
    private var searchQuery = ""
    private var sortOptions = FileBrowserSortOptions()

    init(connection: RemoteConnection, path: String, service: any RemoteFileService) {
        self.connection = connection
        self.path = path
        self.service = service
    }

    func configureDisplay(
        matching query: String,
        options: FileBrowserSortOptions
    ) {
        guard query != searchQuery || options != sortOptions else { return }
        searchQuery = query
        sortOptions = options
        rebuildDisplayedItems()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            items = try await service.list(directory: path)
                .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
            rebuildDisplayedItems()
            errorMessage = nil
        } catch {
            if connection.kind == .sftp {
                let diagnostic = SFTPConnectionDiagnostics.diagnostic(
                    for: error,
                    rootPath: path
                )
                SFTPConnectionDiagnostics.record(diagnostic)
                errorMessage = diagnostic.userMessage
            } else {
                let diagnostic = SynologyConnectionDiagnostics.diagnostic(
                    for: SynologyConnectionTestFailure(
                        stage: .rootPath,
                        underlying: error
                    ),
                    connection: connection
                )
                SynologyConnectionDiagnostics.record(diagnostic)
                errorMessage = diagnostic.userMessage
            }
        }
    }

    private func rebuildDisplayedItems() {
        displayedItems = FileBrowserItemSorter.displayedItems(
            from: items,
            matching: searchQuery,
            options: sortOptions
        )
    }
}
