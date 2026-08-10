import Citadel
import XCTest
@testable import NasFinder

final class SFTPFileMutationSupportTests: XCTestCase {
    func testRelativeRootPathPartsStayInsideConfiguredRoot() throws {
        XCTAssertEqual(
            try SFTPPathSafety.parts(of: "./folder/file.mov", within: "."),
            .init(parent: "./folder", name: "file.mov")
        )
        XCTAssertThrowsError(
            try SFTPPathSafety.parts(of: "./..", within: ".")
        )
    }

    func testConfiguredRootCannotBeMutated() {
        XCTAssertThrowsError(
            try SFTPPathSafety.parts(of: "/media", within: "/media")
        ) { error in
            XCTAssertEqual(
                error as? SFTPFileMutationError,
                .configuredRootMutationNotAllowed
            )
        }
    }

    func testCanonicalContainmentUsesComponentBoundaries() {
        XCTAssertTrue(
            SFTPPathSafety.isCanonicalPath(
                "/volume/home/videos/clip.mov",
                inside: "/volume/home"
            )
        )
        XCTAssertFalse(
            SFTPPathSafety.isCanonicalPath(
                "/volume/home-elsewhere/clip.mov",
                inside: "/volume/home"
            )
        )
    }

    func testSymbolicLinkIsNeverClassifiedAsDirectory() {
        var attributes = SFTPFileAttributes.none
        attributes.permissions = 0o120777
        let entry = SFTPRemoteEntry(
            path: "/media/link",
            name: "link",
            longname: "lrwxrwxrwx",
            attributes: attributes
        )

        XCTAssertTrue(entry.isSymbolicLink)
        XCTAssertFalse(entry.isDirectory)
    }

    func testKeepBothPreservesExtension() throws {
        let entries = [
            entry(name: "clip.mov"),
            entry(name: "clip (1).mov")
        ]
        let decision = try SFTPDestinationDecision.resolve(
            originalName: "clip.mov",
            sourcePath: "/source/clip.mov",
            directoryPath: "/destination",
            entries: entries,
            conflictPolicy: .keepBoth,
            rootPath: "/"
        )

        guard case .use(let name, let replacing) = decision else {
            return XCTFail("Expected a usable destination")
        }
        XCTAssertEqual(name, "clip (2).mov")
        XCTAssertNil(replacing)
    }

    func testFailPolicyRejectsAnExistingDestination() {
        XCTAssertThrowsError(
            try SFTPDestinationDecision.resolve(
                originalName: "clip.mov",
                sourcePath: "/source/clip.mov",
                directoryPath: "/destination",
                entries: [entry(name: "clip.mov")],
                conflictPolicy: .fail,
                rootPath: "/"
            )
        ) { error in
            guard case RemoteFileOperationError.conflict = error else {
                return XCTFail("Expected a conflict error, got \(error)")
            }
        }
    }

    func testSkipPolicyDoesNotSelectTheExistingEntryForMutation() throws {
        let decision = try SFTPDestinationDecision.resolve(
            originalName: "clip.mov",
            sourcePath: "/source/clip.mov",
            directoryPath: "/destination",
            entries: [entry(name: "clip.mov")],
            conflictPolicy: .skip,
            rootPath: "/"
        )

        guard case .skip(let path) = decision else {
            return XCTFail("Expected the destination to be skipped")
        }
        XCTAssertEqual(path, "/destination/clip.mov")
    }

    func testReplacePolicySelectsOnlyAnExistingFile() throws {
        let existing = entry(name: "clip.mov")
        let decision = try SFTPDestinationDecision.resolve(
            originalName: "clip.mov",
            sourcePath: "/source/clip.mov",
            directoryPath: "/destination",
            entries: [existing],
            conflictPolicy: .replace,
            rootPath: "/"
        )

        guard case .use(let name, let replacing) = decision else {
            return XCTFail("Expected a replacement destination")
        }
        XCTAssertEqual(name, "clip.mov")
        XCTAssertEqual(replacing?.path, existing.path)
    }

    func testReplacePolicyRejectsAnExistingDirectory() {
        var directoryAttributes = SFTPFileAttributes.none
        directoryAttributes.permissions = 0o040755
        let directory = SFTPRemoteEntry(
            path: "/destination/Photos",
            name: "Photos",
            longname: "drwxr-xr-x",
            attributes: directoryAttributes
        )

        XCTAssertThrowsError(
            try SFTPDestinationDecision.resolve(
                originalName: "Photos",
                sourcePath: "/source/Photos",
                directoryPath: "/destination",
                entries: [directory],
                conflictPolicy: .replace,
                rootPath: "/"
            )
        ) { error in
            guard case RemoteFileOperationError.folderReplacementNotAllowed = error else {
                return XCTFail("Expected folder replacement to be rejected, got \(error)")
            }
        }
    }

    private func entry(name: String) -> SFTPRemoteEntry {
        SFTPRemoteEntry(
            path: "/destination/\(name)",
            name: name,
            longname: "-rw-r--r--",
            attributes: .none
        )
    }
}
