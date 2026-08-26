import Foundation

/// Decides whether the app may touch the alternate-icon API and whether the
/// icon-choice UI should exist at all on the current host.
///
/// iPhone/iPad keep the full alternate-icon behavior. When the iPad app runs
/// as "Designed for iPad" on a Mac (`ProcessInfo.processInfo.isiOSAppOnMac`)
/// the alternate-icon API is unsupported, so the app must never call it,
/// must never surface a warning or error for it, and must hide the icon
/// picker while keeping exactly one fixed, Mac-visible icon.
enum AppIconAvailabilityPolicy {
    /// The only icon a Mac user ever sees: the primary `AppIcon`.
    static let fixedMacIcon: AppIconChoice = .blueNAS

    static var isIOSAppOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// `true` only when the host both supports alternate icons and is not an
    /// iOS app running on a Mac.
    static func canChangeIcon(isIOSAppOnMac: Bool, supportsAlternateIcons: Bool) -> Bool {
        !isIOSAppOnMac && supportsAlternateIcons
    }

    /// The icon picker is removed entirely on the Mac because no choice can
    /// take effect there.
    static func showsIconPicker(isIOSAppOnMac: Bool) -> Bool {
        !isIOSAppOnMac
    }

    /// Resolves the icon to display for the current host. On the Mac the
    /// fixed icon is returned regardless of any stored alternate name.
    static func displayedIcon(
        alternateIconName: String?,
        isIOSAppOnMac: Bool
    ) -> AppIconChoice {
        guard !isIOSAppOnMac else { return fixedMacIcon }
        return AppIconChoice.current(alternateIconName: alternateIconName)
    }

    struct ThemeSynchronization: Equatable {
        /// Icon that the theme change wants installed.
        let icon: AppIconChoice
        /// When `true`, the caller should remember `currentIcon` so leaving
        /// BK Style can restore it later.
        let remembersCurrentIcon: Bool
    }

    /// Mirrors the theme → icon coupling used on iPhone/iPad:
    /// - entering BK Style installs the enamel icon and remembers the
    ///   previous icon,
    /// - leaving BK Style restores the remembered icon,
    /// - entering Vibe Coder installs the Vibe Coder icon,
    /// - every other change leaves the icon alone.
    ///
    /// On the Mac this always returns `nil` so the theme still applies
    /// immediately while the alternate-icon API is never called.
    static func themeSynchronization(
        from oldTheme: AppThemePreference,
        to newTheme: AppThemePreference,
        currentIcon: AppIconChoice,
        iconBeforeEnamel: AppIconChoice?,
        isIOSAppOnMac: Bool
    ) -> ThemeSynchronization? {
        guard !isIOSAppOnMac else { return nil }

        if newTheme == .skeuomorphism {
            return ThemeSynchronization(
                icon: .enamelNAS,
                remembersCurrentIcon: currentIcon != .enamelNAS
            )
        }
        if oldTheme == .skeuomorphism {
            return ThemeSynchronization(
                icon: iconBeforeEnamel ?? .blueNAS,
                remembersCurrentIcon: false
            )
        }
        if newTheme == .digitalRain {
            return ThemeSynchronization(icon: .vibeCoder, remembersCurrentIcon: false)
        }
        return nil
    }
}
