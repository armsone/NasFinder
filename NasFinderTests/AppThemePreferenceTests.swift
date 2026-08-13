import SwiftUI
import XCTest
@testable import NasFinder

final class AppThemePreferenceTests: XCTestCase {
    func testUnknownStoredThemeFallsBackToSystem() {
        XCTAssertEqual(AppThemePreference.resolved(nil), .system)
        XCTAssertEqual(AppThemePreference.resolved("removed-theme"), .system)
    }

    func testAllSelectableThemesHaveStableUniqueValues() {
        XCTAssertEqual(AppThemePreference.allCases.count, 5)
        XCTAssertEqual(
            Set(AppThemePreference.allCases.map(\.rawValue)).count,
            AppThemePreference.allCases.count
        )
    }

    func testVibeCoderTitleAndExtensibleServicePalette() {
        XCTAssertEqual(AppThemePreference.digitalRain.title, "Vibe Coder")
        XCTAssertEqual(ThemeServicePalette.colors(for: .digitalRain).count, 4)
        _ = ThemeServicePalette.color(
            forServiceIdentifier: "future.cloud.provider",
            theme: .digitalRain
        )
    }

    func testThemeColorSchemesMatchTheirIntendedContrast() {
        XCTAssertNil(AppThemePreference.system.preferredColorScheme)
        XCTAssertEqual(AppThemePreference.day.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.night.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.digitalRain.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.windyMeadow.preferredColorScheme, .light)
    }
}
