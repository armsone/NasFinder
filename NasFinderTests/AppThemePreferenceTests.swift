import SwiftUI
import XCTest
@testable import NasFinder

final class AppThemePreferenceTests: XCTestCase {
    func testUnknownStoredThemeFallsBackToSystem() {
        XCTAssertEqual(AppThemePreference.resolved(nil), .system)
        XCTAssertEqual(AppThemePreference.resolved("removed-theme"), .system)
    }

    func testAllSelectableThemesHaveStableUniqueValues() {
        XCTAssertEqual(AppThemePreference.allCases.count, 7)
        XCTAssertEqual(
            Set(AppThemePreference.allCases.map(\.rawValue)).count,
            AppThemePreference.allCases.count
        )
    }

    func testThemesCycleInDisplayOrder() {
        let themes = AppThemePreference.allCases
        for index in themes.indices.dropLast() {
            XCTAssertEqual(themes[index].next, themes[index + 1])
        }
        XCTAssertEqual(themes.last?.next, themes.first)
    }

    func testVibeCoderTitleAndExtensibleServicePalette() {
        XCTAssertEqual(AppThemePreference.digitalRain.title, "Vibe Coder")
        XCTAssertEqual(ThemeServicePalette.colors(for: .digitalRain).count, 4)
        _ = ThemeServicePalette.color(
            forServiceIdentifier: "future.cloud.provider",
            theme: .digitalRain
        )
    }

    func testServicePaletteHasStableRecognizableBadgeLetters() {
        let expectedLetters = [
            "synology": "N",
            "sftp": "S",
            "smb": "M",
            "webDAV": "W",
            "ftp": "F",
            "dropbox": "D",
            "oneDrive": "O",
            "googleDrive": "G",
            "webHard": "H",
        ]

        XCTAssertEqual(
            Set(expectedLetters.keys),
            Set(ThemeServicePalette.supportedServiceIdentifiers)
        )
        XCTAssertEqual(Set(expectedLetters.values).count, expectedLetters.count)
        for (identifier, letter) in expectedLetters {
            XCTAssertEqual(
                ThemeServicePalette.badgeLetter(forServiceIdentifier: identifier),
                letter
            )
        }
    }

    func testServiceBadgeColorsRemainReadableAcrossThemes() {
        for theme in AppThemePreference.allCases {
            for identifier in ThemeServicePalette.supportedServiceIdentifiers {
                let style = ThemeServicePalette.style(
                    forServiceIdentifier: identifier,
                    theme: theme
                )
                XCTAssertGreaterThanOrEqual(
                    style.foregroundContrastRatio,
                    4.5,
                    "\(identifier) badge should remain readable in \(theme.rawValue)"
                )
            }
        }
    }

    func testBrandBaseColorsStayStableInDayTheme() {
        XCTAssertEqual(
            ThemeServicePalette.style(forServiceIdentifier: "synology", theme: .day),
            ThemeServiceStyle(hex: 0x0067E6)
        )
        XCTAssertEqual(
            ThemeServicePalette.style(forServiceIdentifier: "oneDrive", theme: .day),
            ThemeServiceStyle(hex: 0x0078D4)
        )
        XCTAssertEqual(
            ThemeServicePalette.style(forServiceIdentifier: "dropbox", theme: .day),
            ThemeServiceStyle(hex: 0x0061FF)
        )
    }

    func testThemeColorSchemesMatchTheirIntendedContrast() {
        XCTAssertNil(AppThemePreference.system.preferredColorScheme)
        XCTAssertEqual(AppThemePreference.day.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.night.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.digitalRain.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.windyMeadow.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.workbench.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.skeuomorphism.preferredColorScheme, .light)
    }
}
