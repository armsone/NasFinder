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

enum FileBrowserNamePriority: String, CaseIterable, Identifiable, Sendable {
    case numbersFirst
    case koreanFirst
    case foreignFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numbersFirst: "숫자 먼저"
        case .koreanFirst: "한글 먼저"
        case .foreignFirst: "외국어 먼저"
        }
    }
}

struct FileBrowserSortOptions: Equatable, Sendable {
    var field: FileBrowserSortField = .name
    var direction: FileBrowserSortDirection = .ascending
    var namePriority: FileBrowserNamePriority = .numbersFirst
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

            if options.field == .name {
                let priority = compareNamePriority(
                    lhs.name,
                    rhs.name,
                    priority: options.namePriority
                )
                if priority != .orderedSame {
                    return priority == .orderedAscending
                }
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

            let priority = compareNamePriority(
                lhs.name,
                rhs.name,
                priority: options.namePriority
            )
            if priority != .orderedSame {
                return priority == .orderedAscending
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

    private static func compareNamePriority(
        _ lhs: String,
        _ rhs: String,
        priority: FileBrowserNamePriority
    ) -> ComparisonResult {
        let lhsRank = nameGroupRank(for: lhs, priority: priority)
        let rhsRank = nameGroupRank(for: rhs, priority: priority)
        if lhsRank < rhsRank { return .orderedAscending }
        if lhsRank > rhsRank { return .orderedDescending }
        return .orderedSame
    }

    private static func nameGroupRank(
        for name: String,
        priority: FileBrowserNamePriority
    ) -> Int {
        let group = nameGroup(for: name)
        switch priority {
        case .numbersFirst:
            return switch group {
            case .number: 0
            case .korean: 1
            case .foreign: 2
            case .other: 3
            }
        case .koreanFirst:
            return switch group {
            case .korean: 0
            case .number: 1
            case .foreign: 2
            case .other: 3
            }
        case .foreignFirst:
            return switch group {
            case .foreign: 0
            case .number: 1
            case .korean: 2
            case .other: 3
            }
        }
    }

    private static func nameGroup(for name: String) -> NameGroup {
        guard let scalar = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .first else {
            return .other
        }

        if CharacterSet.decimalDigits.contains(scalar) {
            return .number
        }
        if isHangul(scalar.value) {
            return .korean
        }
        if CharacterSet.letters.contains(scalar) {
            return .foreign
        }
        return .other
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xD7B0...0xD7FF).contains(value)
    }

    private enum NameGroup {
        case number
        case korean
        case foreign
        case other
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
    private var loadCompletionWaiters: [CheckedContinuation<Void, Never>] = []

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
        defer {
            isLoading = false
            let waiters = loadCompletionWaiters
            loadCompletionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        do {
            items = try await service.list(directory: path)
                .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
            rebuildDisplayedItems()
            errorMessage = nil
        } catch {
            guard !RemoteRequestCancellation.isCancellation(error) else { return }
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

    /// Waits for an in-flight listing, if any, and then starts a new request.
    /// Mutation completions use this so a listing that began before the remote
    /// change cannot make the post-operation refresh appear complete early.
    func reloadAfterCurrentLoad() async {
        while isLoading {
            await waitForCurrentLoadToFinish()
        }
        await load()
    }

    private func waitForCurrentLoadToFinish() async {
        await withCheckedContinuation { continuation in
            guard isLoading else {
                continuation.resume()
                return
            }
            loadCompletionWaiters.append(continuation)
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
