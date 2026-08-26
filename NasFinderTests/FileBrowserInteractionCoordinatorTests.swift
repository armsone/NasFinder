import XCTest
@testable import NasFinder

@MainActor
final class FileBrowserInteractionCoordinatorTests: XCTestCase {
    func testDownloadPolicyExcludesFoldersAndKeepsFilesInSelectionOrder() {
        let connectionID = UUID()
        let folder = RemoteFileItem(
            connectionID: connectionID,
            path: "/folder",
            name: "folder",
            kind: .folder,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let files = ["first.mp4", "second.jpg"].map { name in
            RemoteFileItem(
                connectionID: connectionID,
                path: "/\(name)",
                name: name,
                kind: .file,
                size: 1,
                modifiedAt: nil,
                contentTypeIdentifier: nil
            )
        }

        XCTAssertEqual(
            FileBrowserDownloadPolicy.downloadableItems(from: [folder] + files),
            files
        )
    }

    func testPanelActionRunsOnlyAfterPanelDisappearsAndOnlyOnce() {
        let coordinator = FileBrowserInteractionCoordinator()
        var executionCount = 0

        coordinator.showBrowserPanel()
        coordinator.dismissPanel {
            executionCount += 1
        }

        XCTAssertNil(coordinator.panel)
        XCTAssertEqual(executionCount, 0)

        coordinator.panelDidDisappear()
        coordinator.panelDidDisappear()

        XCTAssertEqual(executionCount, 1)
    }

    func testDismissWithoutActionClearsPendingPanelAction() {
        let coordinator = FileBrowserInteractionCoordinator()
        var didExecute = false

        coordinator.showBrowserPanel()
        coordinator.dismissPanel {
            didExecute = true
        }
        coordinator.dismissPanel()
        coordinator.panelDidDisappear()

        XCTAssertFalse(didExecute)
    }

    func testActivationRoutesSelectionFolderAndFileExclusively() {
        let folder = makeItem(path: "/folder", kind: .folder)
        let file = makeItem(path: "/movie.mp4", kind: .file)

        XCTAssertEqual(
            FileBrowserInteractionCoordinator.activation(for: file, isSelecting: true),
            .toggleSelection(file.id)
        )
        XCTAssertEqual(
            FileBrowserInteractionCoordinator.activation(for: folder, isSelecting: false),
            .openFolder(folder)
        )
        XCTAssertEqual(
            FileBrowserInteractionCoordinator.activation(for: file, isSelecting: false),
            .preview(file)
        )
    }

    private func makeItem(
        path: String,
        kind: RemoteFileItem.ItemKind
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(),
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: kind,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}
