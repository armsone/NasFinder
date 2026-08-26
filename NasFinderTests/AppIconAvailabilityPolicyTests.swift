import Testing
@testable import NasFinder

struct AppIconAvailabilityPolicyTests {
    @Test func macNeverChangesIconEvenWhenSystemClaimsSupport() {
        #expect(
            AppIconAvailabilityPolicy.canChangeIcon(
                isIOSAppOnMac: true,
                supportsAlternateIcons: true
            ) == false
        )
        #expect(
            AppIconAvailabilityPolicy.canChangeIcon(
                isIOSAppOnMac: true,
                supportsAlternateIcons: false
            ) == false
        )
    }

    @Test func iPhoneAndIPadKeepAlternateIconsWhenSupported() {
        #expect(
            AppIconAvailabilityPolicy.canChangeIcon(
                isIOSAppOnMac: false,
                supportsAlternateIcons: true
            )
        )
        #expect(
            AppIconAvailabilityPolicy.canChangeIcon(
                isIOSAppOnMac: false,
                supportsAlternateIcons: false
            ) == false
        )
    }

    @Test func iconPickerIsRemovedOnMacOnly() {
        #expect(AppIconAvailabilityPolicy.showsIconPicker(isIOSAppOnMac: true) == false)
        #expect(AppIconAvailabilityPolicy.showsIconPicker(isIOSAppOnMac: false))
    }

    @Test func macAlwaysDisplaysTheSingleFixedIcon() {
        #expect(AppIconAvailabilityPolicy.fixedMacIcon == .blueNAS)
        #expect(AppIconAvailabilityPolicy.fixedMacIcon.alternateIconName == nil)
        for name in [nil, "AppIconAlternate", "AppIconEnamel", "AppIconVibeCoder", "Unknown"] {
            #expect(
                AppIconAvailabilityPolicy.displayedIcon(
                    alternateIconName: name,
                    isIOSAppOnMac: true
                ) == .blueNAS
            )
        }
        #expect(
            AppIconAvailabilityPolicy.displayedIcon(
                alternateIconName: "AppIconEnamel",
                isIOSAppOnMac: false
            ) == .enamelNAS
        )
    }

    @Test func macThemeChangesNeverRequestAnIcon() {
        for oldTheme in AppThemePreference.allCases {
            for newTheme in AppThemePreference.allCases {
                #expect(
                    AppIconAvailabilityPolicy.themeSynchronization(
                        from: oldTheme,
                        to: newTheme,
                        currentIcon: .purpleNAS,
                        iconBeforeEnamel: .cyberVault,
                        isIOSAppOnMac: true
                    ) == nil
                )
            }
        }
    }

    @Test func enteringEnamelThemeInstallsEnamelIconAndRemembersPrevious() {
        let sync = AppIconAvailabilityPolicy.themeSynchronization(
            from: .day,
            to: .skeuomorphism,
            currentIcon: .purpleNAS,
            iconBeforeEnamel: nil,
            isIOSAppOnMac: false
        )
        #expect(sync == .init(icon: .enamelNAS, remembersCurrentIcon: true))

        let alreadyEnamel = AppIconAvailabilityPolicy.themeSynchronization(
            from: .skeuomorphism,
            to: .skeuomorphism,
            currentIcon: .enamelNAS,
            iconBeforeEnamel: .purpleNAS,
            isIOSAppOnMac: false
        )
        #expect(alreadyEnamel == .init(icon: .enamelNAS, remembersCurrentIcon: false))
    }

    @Test func leavingEnamelThemeRestoresRememberedIcon() {
        let restored = AppIconAvailabilityPolicy.themeSynchronization(
            from: .skeuomorphism,
            to: .night,
            currentIcon: .enamelNAS,
            iconBeforeEnamel: .cyberVault,
            isIOSAppOnMac: false
        )
        #expect(restored == .init(icon: .cyberVault, remembersCurrentIcon: false))

        let fallback = AppIconAvailabilityPolicy.themeSynchronization(
            from: .skeuomorphism,
            to: .night,
            currentIcon: .enamelNAS,
            iconBeforeEnamel: nil,
            isIOSAppOnMac: false
        )
        #expect(fallback == .init(icon: .blueNAS, remembersCurrentIcon: false))
    }

    @Test func vibeCoderThemeInstallsVibeCoderIconAndOtherThemesLeaveIconAlone() {
        #expect(
            AppIconAvailabilityPolicy.themeSynchronization(
                from: .system,
                to: .digitalRain,
                currentIcon: .blueNAS,
                iconBeforeEnamel: nil,
                isIOSAppOnMac: false
            ) == .init(icon: .vibeCoder, remembersCurrentIcon: false)
        )
        #expect(
            AppIconAvailabilityPolicy.themeSynchronization(
                from: .day,
                to: .workbench,
                currentIcon: .purpleNAS,
                iconBeforeEnamel: nil,
                isIOSAppOnMac: false
            ) == nil
        )
    }
}
