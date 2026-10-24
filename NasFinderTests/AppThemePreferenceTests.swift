import SwiftUI
import XCTest
@testable import NasFinder

final class AppThemePreferenceTests: XCTestCase {
    func testUnknownStoredThemeFallsBackToSystem() {
        XCTAssertEqual(AppThemePreference.resolved(nil), .resolved("system"))
        XCTAssertEqual(AppThemePreference.resolved("removed-theme"), .resolved("system"))
    }

    func testAllSelectableThemesHaveStableUniqueValues() {
        XCTAssertEqual(AppThemePreference.allCases.count, 6)
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

    func testRemovedThemeTitleFallsBackAndServicePaletteStaysExtensible() {
        XCTAssertEqual(AppThemePreference.resolved("digitalRain"), .light, "삭제된 테마 값은 밝은 테마로 읽습니다.")
        XCTAssertEqual(AppThemePreference.resolved("digitalRain").title, "밝은")
        XCTAssertEqual(ThemeServicePalette.colors(for: .resolved("digitalRain")).count, 4)
        _ = ThemeServicePalette.color(
            forServiceIdentifier: "future.cloud.provider",
            theme: .resolved("digitalRain")
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
            ThemeServicePalette.style(forServiceIdentifier: "synology", theme: .resolved("day")),
            ThemeServiceStyle(hex: 0x0067E6)
        )
        XCTAssertEqual(
            ThemeServicePalette.style(forServiceIdentifier: "oneDrive", theme: .resolved("day")),
            ThemeServiceStyle(hex: 0x0078D4)
        )
        XCTAssertEqual(
            ThemeServicePalette.style(forServiceIdentifier: "dropbox", theme: .resolved("day")),
            ThemeServiceStyle(hex: 0x0061FF)
        )
    }

    func testThemeColorSchemesMatchTheirIntendedContrast() {
        XCTAssertEqual(AppThemePreference.light.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.bkstyle.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.friday.preferredColorScheme, .light)
        XCTAssertEqual(AppThemePreference.night.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.jarvis.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.ultron.preferredColorScheme, .dark)
        XCTAssertEqual(AppThemePreference.resolved("night").preferredColorScheme, .dark, "예전 night 값은 어두운 테마로 읽습니다.")
        XCTAssertEqual(AppThemePreference.resolved("system").preferredColorScheme, .light)
    }

    func testJarvisShellActivationAppliesOnceAndKeepsLaterChoice() throws {
        let suiteName = "AppThemePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppThemePreference.night.rawValue, forKey: AppThemePreference.storageKey)

        JarvisShellActivation.applyOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AppThemePreference.storageKey), AppThemePreference.jarvis.rawValue)

        defaults.set(AppThemePreference.night.rawValue, forKey: AppThemePreference.storageKey)
        JarvisShellActivation.applyOnce(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: AppThemePreference.storageKey),
            AppThemePreference.night.rawValue,
            "첫 적용 뒤 사용자가 고른 테마는 다시 덮어쓰지 않습니다."
        )
    }
}
