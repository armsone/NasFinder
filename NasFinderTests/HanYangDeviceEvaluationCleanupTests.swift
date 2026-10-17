import XCTest

final class HanYangDeviceEvaluationCleanupTests: XCTestCase {
    func testRemoveOnlyTaskFixtures() throws {
        let fileManager = FileManager.default
        let cachesRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).resolvingSymlinksInPath()

        let taskRoot = cachesRoot.appendingPathComponent(
            "HanYangDeviceEvaluation-202610170824",
            isDirectory: true
        )

        guard fileManager.fileExists(atPath: taskRoot.path) else {
            return
        }

        let resolvedTaskRoot = taskRoot.resolvingSymlinksInPath()
        let cachesRootPath = cachesRoot.path.hasSuffix("/") ? cachesRoot.path : cachesRoot.path + "/"

        guard resolvedTaskRoot.path == taskRoot.standardizedFileURL.path,
              resolvedTaskRoot.path.hasPrefix(cachesRootPath),
              resolvedTaskRoot.path != cachesRoot.path else {
            XCTFail("Resolved task root is not safely contained within the caches directory")
            return
        }

        try fileManager.removeItem(at: resolvedTaskRoot)

        XCTAssertFalse(fileManager.fileExists(atPath: taskRoot.path))
    }
}
