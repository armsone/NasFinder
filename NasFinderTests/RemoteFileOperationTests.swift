import XCTest
@testable import NasFinder

@MainActor
final class RemoteFileOperationTests: XCTestCase {
    func testAbsolutePathCannotEscapeConfiguredRoot() throws {
        XCTAssertEqual(
            try RemotePath.normalize("/photo//family/./2026", within: "/photo"),
            "/photo/family/2026"
        )

        XCTAssertThrowsError(
            try RemotePath.normalize("/photo/../private", within: "/photo")
        ) { error in
            XCTAssertEqual(
                error as? RemoteFileOperationError,
                .invalidPath(path: "/photo/../private", reason: .parentTraversal)
            )
        }

        XCTAssertThrowsError(
            try RemotePath.normalize("/photography/file.jpg", within: "/photo")
        ) { error in
            XCTAssertEqual(
                error as? RemoteFileOperationError,
                .pathOutsideRoot(path: "/photography/file.jpg", rootPath: "/photo")
            )
        }
    }

    func testRelativeSFTPRootCannotEscapeAndKeepsDotPrefix() throws {
        XCTAssertEqual(
            try RemotePath.appending(name: "clip.mp4", to: ".", within: "."),
            "./clip.mp4"
        )
        XCTAssertEqual(
            try RemotePath.normalize("./family/photo.jpg", within: "."),
            "./family/photo.jpg"
        )

        XCTAssertThrowsError(
            try RemotePath.normalize("../outside", within: ".")
        ) { error in
            XCTAssertEqual(
                error as? RemoteFileOperationError,
                .invalidPath(path: "../outside", reason: .parentTraversal)
            )
        }
        XCTAssertFalse(RemotePath.isInside("/absolute", rootPath: "."))
    }

    func testNameValidationRejectsUnsafeComponents() throws {
        let invalidNames: [(String, RemoteNameValidationFailure)] = [
            ("", .empty),
            ("   ", .whitespaceOnly),
            (".", .dotComponent),
            ("..", .dotComponent),
            ("family/photo.jpg", .containsPathSeparator),
            ("bad\0name", .containsNullByte)
        ]

        for (name, expectedReason) in invalidNames {
            XCTAssertThrowsError(try RemotePath.validatedName(name)) { error in
                XCTAssertEqual(
                    error as? RemoteFileOperationError,
                    .invalidName(name: name, reason: expectedReason)
                )
            }
        }

        XCTAssertEqual(try RemotePath.validatedName("2026 행사 사진.heic"), "2026 행사 사진.heic")
    }

    func testKeepBothNamePreservesExtensionAndAdvancesSuffix() throws {
        let existing = [
            "photo.jpg",
            "photo (1).jpg",
            "photo (2).jpg",
            "archive.tar.gz",
            "archive.tar (1).gz"
        ]

        XCTAssertEqual(
            try RemotePath.keepBothName(for: "photo.jpg", existingNames: existing),
            "photo (3).jpg"
        )
        XCTAssertEqual(
            try RemotePath.keepBothName(for: "photo (1).jpg", existingNames: existing),
            "photo (3).jpg"
        )
        XCTAssertEqual(
            try RemotePath.keepBothName(for: "archive.tar.gz", existingNames: existing),
            "archive.tar (2).gz"
        )
        XCTAssertEqual(
            try RemotePath.keepBothName(for: "new.mov", existingNames: existing),
            "new.mov"
        )
    }

    func testKeepBothCanUseCaseInsensitiveCollisionRules() throws {
        XCTAssertEqual(
            try RemotePath.keepBothName(
                for: "PHOTO.JPG",
                existingNames: ["photo.jpg", "photo (1).jpg"],
                caseSensitive: false
            ),
            "PHOTO (2).JPG"
        )
    }

    func testFolderReplaceIsRejectedBeforeBackendMutation() {
        let folder = makeItem(path: "/photo/album", name: "album", kind: .folder)

        XCTAssertThrowsError(
            try RemoteConflictPolicy.replace.validate(
                for: folder,
                destinationPath: "/photo/archive/album"
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteFileOperationError,
                .folderReplacementNotAllowed(path: "/photo/archive/album")
            )
        }
    }

    func testReadOnlyServiceHasNoMutationCapabilitiesAndThrowsUnsupported() async {
        let service: any RemoteFileService = ReadOnlyService()
        let item = makeItem(path: "/photo/image.jpg", name: "image.jpg", kind: .file)

        XCTAssertTrue(service.capabilities.isEmpty)
        do {
            _ = try await service.delete(
                item,
                recursive: false,
                context: RemoteOperationContext()
            )
            XCTFail("Read-only default should reject delete")
        } catch {
            XCTAssertEqual(
                error as? RemoteFileOperationError,
                .unsupported(operation: .delete)
            )
        }
    }

    func testProgressContextOwnsOperationIdentifier() async {
        let operationID = UUID()
        let recorder = ProgressRecorder()
        let context = RemoteOperationContext(operationID: operationID) { progress in
            await recorder.append(progress)
        }

        await context.report(
            operation: .upload,
            phase: .writing,
            unit: .bytes,
            completedUnitCount: 25,
            totalUnitCount: 100,
            currentPath: "/photo/image.jpg"
        )

        let progress = await recorder.last
        XCTAssertEqual(progress?.operationID, operationID)
        XCTAssertEqual(progress?.fractionCompleted, 0.25)
    }

    private func makeItem(
        path: String,
        name: String,
        kind: RemoteFileItem.ItemKind
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(),
            path: path,
            name: name,
            kind: kind,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}

private actor ProgressRecorder {
    private(set) var last: RemoteOperationProgress?

    func append(_ progress: RemoteOperationProgress) {
        last = progress
    }
}

private struct ReadOnlyService: RemoteFileService {
    let connection = RemoteConnection(
        name: "Read only",
        kind: .synology,
        host: "nas.example.com",
        username: "tester"
    )

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }
}
