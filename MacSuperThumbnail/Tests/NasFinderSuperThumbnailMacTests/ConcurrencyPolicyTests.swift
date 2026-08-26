import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class ConcurrencyPolicyTests: XCTestCase {
    func testWorkerPreferenceDefinitionsAndExplicitCounts() {
        XCTAssertEqual(SuperThumbnailWorkerPreference.allCases, [.auto, .one, .two, .four, .eight])

        XCTAssertEqual(SuperThumbnailWorkerPreference.auto.rawValue, "auto")
        XCTAssertNil(SuperThumbnailWorkerPreference.auto.explicitCount)
        XCTAssertEqual(SuperThumbnailWorkerPreference.auto.displayName, "자동")

        XCTAssertEqual(SuperThumbnailWorkerPreference.one.explicitCount, 1)
        XCTAssertEqual(SuperThumbnailWorkerPreference.two.explicitCount, 2)
        XCTAssertEqual(SuperThumbnailWorkerPreference.four.explicitCount, 4)
        XCTAssertEqual(SuperThumbnailWorkerPreference.eight.explicitCount, 8)
    }

    func testBaseWorkerLimitsForStorageTypes() {
        // Auto: network/removable -> 2, local fixed -> 4
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .auto, isNetworkOrRemovable: true),
            2
        )
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .auto, isNetworkOrRemovable: false),
            4
        )

        // Explicit values are upper bounds regardless of storage type
        for isRemote in [true, false] {
            XCTAssertEqual(SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .one, isNetworkOrRemovable: isRemote), 1)
            XCTAssertEqual(SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .two, isNetworkOrRemovable: isRemote), 2)
            XCTAssertEqual(SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .four, isNetworkOrRemovable: isRemote), 4)
            XCTAssertEqual(SuperThumbnailConcurrencyPolicy.baseWorkerLimit(preference: .eight, isNetworkOrRemovable: isRemote), 8)
        }
    }

    func testThermalThrottlingStateDetection() {
        XCTAssertFalse(SuperThumbnailConcurrencyPolicy.isThermalThrottled(thermalState: .nominal))
        XCTAssertFalse(SuperThumbnailConcurrencyPolicy.isThermalThrottled(thermalState: .fair))
        XCTAssertTrue(SuperThumbnailConcurrencyPolicy.isThermalThrottled(thermalState: .serious))
        XCTAssertTrue(SuperThumbnailConcurrencyPolicy.isThermalThrottled(thermalState: .critical))
    }

    func testEffectiveWorkerLimitsClampedUnderThermalPressure() {
        // Normal thermal state: nominal / fair
        for state in [ProcessInfo.ThermalState.nominal, ProcessInfo.ThermalState.fair] {
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .auto,
                    isNetworkOrRemovable: false,
                    thermalState: state
                ),
                4
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .auto,
                    isNetworkOrRemovable: true,
                    thermalState: state
                ),
                2
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .eight,
                    isNetworkOrRemovable: false,
                    thermalState: state
                ),
                8
            )
        }

        // Serious / critical thermal state clamps EVERYTHING to 1
        for throttledState in [ProcessInfo.ThermalState.serious, ProcessInfo.ThermalState.critical] {
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .auto,
                    isNetworkOrRemovable: false,
                    thermalState: throttledState
                ),
                1
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .auto,
                    isNetworkOrRemovable: true,
                    thermalState: throttledState
                ),
                1
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .eight,
                    isNetworkOrRemovable: false,
                    thermalState: throttledState
                ),
                1
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .four,
                    isNetworkOrRemovable: false,
                    thermalState: throttledState
                ),
                1
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .two,
                    isNetworkOrRemovable: false,
                    thermalState: throttledState
                ),
                1
            )
            XCTAssertEqual(
                SuperThumbnailConcurrencyPolicy.effectiveWorkerLimit(
                    preference: .one,
                    isNetworkOrRemovable: false,
                    thermalState: throttledState
                ),
                1
            )
        }
    }

    func testEffectiveFolderWorkerLimitCappedAtTwoAndThermalClamped() {
        // Folder processing concurrency is capped at 2 under nominal state
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .auto,
                isNetworkOrRemovable: false,
                thermalState: .nominal
            ),
            2
        )
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .auto,
                isNetworkOrRemovable: true,
                thermalState: .nominal
            ),
            2
        )
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .eight,
                isNetworkOrRemovable: false,
                thermalState: .nominal
            ),
            2
        )
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .one,
                isNetworkOrRemovable: false,
                thermalState: .nominal
            ),
            1
        )

        // Under serious thermal state, folder limit clamps to 1
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .eight,
                isNetworkOrRemovable: false,
                thermalState: .serious
            ),
            1
        )
        XCTAssertEqual(
            SuperThumbnailConcurrencyPolicy.effectiveFolderWorkerLimit(
                preference: .auto,
                isNetworkOrRemovable: false,
                thermalState: .critical
            ),
            1
        )
    }

    func testFolderDepthGroupingDeepestFirstAndDeterministicOrder() {
        let folders = [
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_b"), depth: 2),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_a"), depth: 2),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent"), depth: 1),
            FolderEntry(url: URL(fileURLWithPath: "/root/parent/child_a/leaf"), depth: 3),
            FolderEntry(url: URL(fileURLWithPath: "/root/other_parent"), depth: 1),
        ]

        let groups = FolderDepthGrouping.groupDeepestFirst(folders: folders)
        XCTAssertEqual(groups.count, 3)

        // Depth 3 (Deepest)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(groups[0][0].url.lastPathComponent, "leaf")
        XCTAssertEqual(groups[0][0].depth, 3)

        // Depth 2
        XCTAssertEqual(groups[1].count, 2)
        XCTAssertEqual(groups[1].map(\.url.lastPathComponent), ["child_a", "child_b"])
        XCTAssertTrue(groups[1].allSatisfy { $0.depth == 2 })

        // Depth 1
        XCTAssertEqual(groups[2].count, 2)
        XCTAssertEqual(groups[2].map(\.url.lastPathComponent), ["other_parent", "parent"])
        XCTAssertTrue(groups[2].allSatisfy { $0.depth == 1 })
    }

    func testFolderDepthGroupingEmptyAndSingleDepth() {
        XCTAssertTrue(FolderDepthGrouping.groupDeepestFirst(folders: []).isEmpty)

        let single = [FolderEntry(url: URL(fileURLWithPath: "/root/sub"), depth: 1)]
        let groups = FolderDepthGrouping.groupDeepestFirst(folders: single)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 1)
    }
}
