import Foundation
import XCTest
@testable import NasFinder

final class FileBrowserItemSorterTests: XCTestCase {
    func testNameSortUsesNaturalOrderAndKeepsFoldersFirstInBothDirections() {
        let items = [
            item(name: "photo10.jpg", size: 10),
            item(name: "Archive", kind: .folder),
            item(name: "photo2.jpg", size: 2)
        ]

        let ascending = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .name,
                direction: .ascending,
                foldersFirst: true
            )
        )
        let descending = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .name,
                direction: .descending,
                foldersFirst: true
            )
        )

        XCTAssertEqual(ascending.map(\.name), ["Archive", "photo2.jpg", "photo10.jpg"])
        XCTAssertEqual(descending.map(\.name), ["Archive", "photo10.jpg", "photo2.jpg"])
    }

    func testDateDescendingLeavesMissingMetadataAtEnd() {
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        let items = [
            item(name: "unknown.jpg"),
            item(name: "old.jpg", modifiedAt: oldDate),
            item(name: "new.jpg", modifiedAt: newDate)
        ]

        let result = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .modifiedDate,
                direction: .descending,
                foldersFirst: false
            )
        )

        XCTAssertEqual(result.map(\.name), ["new.jpg", "old.jpg", "unknown.jpg"])
    }

    func testSizeSortLeavesMissingMetadataAtEndInBothDirections() {
        let items = [
            item(name: "unknown.bin"),
            item(name: "large.bin", size: 2_000),
            item(name: "small.bin", size: 20)
        ]

        let ascending = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .size,
                direction: .ascending,
                foldersFirst: false
            )
        )
        let descending = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .size,
                direction: .descending,
                foldersFirst: false
            )
        )

        XCTAssertEqual(ascending.map(\.name), ["small.bin", "large.bin", "unknown.bin"])
        XCTAssertEqual(descending.map(\.name), ["large.bin", "small.bin", "unknown.bin"])
    }

    func testKindSortUsesExtensionAndFolderPriorityCanBeDisabled() {
        let items = [
            item(name: "Pictures", kind: .folder),
            item(name: "clip.avi"),
            item(name: "note.txt"),
            item(name: "b.jpg"),
            item(name: "a.JPG")
        ]

        let result = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .kind,
                direction: .ascending,
                foldersFirst: false
            )
        )

        XCTAssertEqual(
            result.map(\.name),
            ["clip.avi", "Pictures", "a.JPG", "b.jpg", "note.txt"]
        )
    }

    func testDisplayedItemsSearchesCaseAndDiacriticsThenAppliesSort() {
        let items = [
            item(name: "resume-10.JPG"),
            item(name: "Résumé-2.jpg"),
            item(name: "notes.txt")
        ]

        let result = FileBrowserItemSorter.displayedItems(
            from: items,
            matching: "  RESUME  ",
            options: FileBrowserSortOptions()
        )

        XCTAssertEqual(result.map(\.name), ["Résumé-2.jpg", "resume-10.JPG"])
    }

    func testNamePriorityCanPutNumbersKoreanOrForeignNamesFirst() {
        let items = [
            item(name: "가족사진.jpg"),
            item(name: "album.jpg"),
            item(name: "10-report.pdf"),
            item(name: "2-report.pdf")
        ]

        let numbersFirst = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .name,
                direction: .ascending,
                namePriority: .numbersFirst,
                foldersFirst: false
            )
        )
        let koreanFirst = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .name,
                direction: .ascending,
                namePriority: .koreanFirst,
                foldersFirst: false
            )
        )
        let foreignFirst = FileBrowserItemSorter.sorted(
            items,
            options: FileBrowserSortOptions(
                field: .name,
                direction: .ascending,
                namePriority: .foreignFirst,
                foldersFirst: false
            )
        )

        XCTAssertEqual(numbersFirst.map(\.name), ["2-report.pdf", "10-report.pdf", "가족사진.jpg", "album.jpg"])
        XCTAssertEqual(koreanFirst.first?.name, "가족사진.jpg")
        XCTAssertEqual(foreignFirst.first?.name, "album.jpg")
    }

    func testSelectedNamePriorityStaysFirstWhenNameDirectionIsDescending() {
        let result = FileBrowserItemSorter.sorted(
            [item(name: "album.jpg"), item(name: "가족사진.jpg"), item(name: "2-report.pdf")],
            options: FileBrowserSortOptions(
                field: .name,
                direction: .descending,
                namePriority: .koreanFirst,
                foldersFirst: false
            )
        )

        XCTAssertEqual(result.first?.name, "가족사진.jpg")
    }

    private func item(
        name: String,
        kind: RemoteFileItem.ItemKind = .file,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(uuidString: "D3A255D8-8EF5-4C02-BD4A-B4D886B350C1")!,
            path: "/share/\(name)",
            name: name,
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: nil
        )
    }
}
