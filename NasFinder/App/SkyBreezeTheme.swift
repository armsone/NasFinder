import SwiftUI
import UIKit

enum AppThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case day
    case night
    case digitalRain
    case windyMeadow

    static let storageKey = "app.theme.preference.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "자동"
        case .day: "낮"
        case .night: "밤"
        case .digitalRain: "Vibe Coder"
        case .windyMeadow: "Windy Meadow"
        }
    }

    var shortDescription: String {
        switch self {
        case .system: "iPhone 설정"
        case .day: "맑고 밝게"
        case .night: "차분하고 어둡게"
        case .digitalRain: "Black · Mint"
        case .windyMeadow: "Sky · Meadow"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .day: "sun.max.fill"
        case .night: "moon.stars.fill"
        case .digitalRain: "terminal.fill"
        case .windyMeadow: "wind"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day, .windyMeadow: .light
        case .night, .digitalRain: .dark
        }
    }

    static func resolved(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    static var current: Self {
        resolved(UserDefaults.standard.string(forKey: storageKey))
    }
}

/// “파란 하늘 · 흰 구름 · 시원한 바람”을 iOS 기본 구성요소 위에
/// 얹는 가벼운 시각 테마. 기능 화면의 대비를 해치지 않도록 배경과
/// 포인트 컬러에만 적용한다.
enum SkyBreezeTheme {
    static var accent: Color {
        switch AppThemePreference.current {
        case .digitalRain: Color(red: 0.18, green: 0.91, blue: 0.72)
        case .windyMeadow: Color(red: 0.05, green: 0.55, blue: 0.76)
        default: Color(uiColor: .systemBlue)
        }
    }

    static let nasBlue = adaptiveColor(
        light: (0.00, 0.48, 1.00),
        dark: (0.04, 0.52, 1.00)
    )
    static let sftpGreen = adaptiveColor(
        light: (0.20, 0.68, 0.31),
        dark: (0.19, 0.82, 0.35)
    )
    static let browserOrange = adaptiveColor(
        light: (1.00, 0.58, 0.00),
        dark: (1.00, 0.62, 0.04)
    )

    static var folderBlue: Color {
        switch AppThemePreference.current {
        case .digitalRain: Color(red: 0.23, green: 0.84, blue: 0.69)
        case .windyMeadow: Color(red: 0.04, green: 0.48, blue: 0.68)
        default:
            adaptiveColor(
                light: (0.08, 0.47, 0.70),
                dark: (0.36, 0.73, 0.94)
            )
        }
    }

    static var primaryText: Color {
        AppThemePreference.current == .digitalRain
            ? Color(red: 0.90, green: 0.98, blue: 0.95)
            : Color(uiColor: .label)
    }

    static var secondaryText: Color {
        AppThemePreference.current == .digitalRain
            ? Color(red: 0.60, green: 0.75, blue: 0.70)
            : Color(uiColor: .secondaryLabel)
    }

    static var thumbnailSurface: Color {
        switch AppThemePreference.current {
        case .digitalRain: Color(red: 0.035, green: 0.105, blue: 0.095)
        case .windyMeadow: Color(red: 0.985, green: 0.975, blue: 0.91)
        default:
            Color(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.075, green: 0.11, blue: 0.14, alpha: 1)
                        : UIColor(white: 1.0, alpha: 0.88)
                }
            )
        }
    }

    static var thumbnailBorder: Color {
        switch AppThemePreference.current {
        case .digitalRain: Color(red: 0.10, green: 0.32, blue: 0.27)
        case .windyMeadow: Color(red: 0.62, green: 0.73, blue: 0.40)
        default:
            adaptiveColor(
                light: (0.75, 0.89, 0.95),
                dark: (0.18, 0.28, 0.34)
            )
        }
    }

    static var contentBackground: Color {
        switch AppThemePreference.current {
        case .digitalRain: Color(red: 0.012, green: 0.045, blue: 0.042)
        case .windyMeadow: Color(red: 0.93, green: 0.96, blue: 0.82)
        default:
            adaptiveColor(
                light: (0.955, 0.985, 0.995),
                dark: (0.035, 0.075, 0.11)
            )
        }
    }

    static func skyGradient(
        for colorScheme: ColorScheme,
        theme: AppThemePreference = .current
    ) -> LinearGradient {
        let colors: [Color]
        switch theme {
        case .digitalRain:
            colors = [
                Color(red: 0.005, green: 0.035, blue: 0.032),
                Color(red: 0.018, green: 0.09, blue: 0.075),
                Color(red: 0.01, green: 0.045, blue: 0.042),
            ]
        case .windyMeadow:
            colors = [
                Color(red: 0.23, green: 0.74, blue: 0.95),
                Color(red: 0.72, green: 0.90, blue: 0.88),
                Color(red: 0.89, green: 0.94, blue: 0.70),
            ]
        case .night:
            colors = [
                Color(red: 0.035, green: 0.12, blue: 0.19),
                Color(red: 0.055, green: 0.09, blue: 0.13),
            ]
        case .system where colorScheme == .dark:
            colors = [
                Color(red: 0.035, green: 0.12, blue: 0.19),
                Color(red: 0.055, green: 0.09, blue: 0.13),
            ]
        default:
            colors = [
                Color(red: 0.59, green: 0.85, blue: 1.00),
                Color(red: 0.86, green: 0.95, blue: 1.00),
                .white,
            ]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adaptiveColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let components = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: components.0,
                    green: components.1,
                    blue: components.2,
                    alpha: 1
                )
            }
        )
    }
}

struct ThemeServiceStyle: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var foregroundColor: Color {
        usesDarkForeground ? .black : .white
    }

    var usesDarkForeground: Bool {
        let luminance = relativeLuminance
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return blackContrast >= whiteContrast
    }

    var foregroundContrastRatio: Double {
        let luminance = relativeLuminance
        return usesDarkForeground
            ? (luminance + 0.05) / 0.05
            : 1.05 / (luminance + 0.05)
    }

    init(hex: Int) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    fileprivate func blended(
        toward target: (red: Double, green: Double, blue: Double),
        amount: Double
    ) -> Self {
        Self(
            red: red + (target.red - red) * amount,
            green: green + (target.green - green) * amount,
            blue: blue + (target.blue - blue) * amount
        )
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private var relativeLuminance: Double {
        func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}

enum ThemeServicePalette {
    static let supportedServiceIdentifiers = [
        "synology", "sftp", "smb", "webDAV", "ftp",
        "dropbox", "oneDrive", "googleDrive", "webHard",
    ]

    static func colors(for theme: AppThemePreference) -> [Color] {
        fallbackStyles(for: theme).map(\.color)
    }

    static func badgeLetter(forServiceIdentifier identifier: String) -> String {
        switch identifier {
        case "synology": "N"
        case "sftp": "S"
        case "smb": "M"
        case "webDAV": "W"
        case "ftp": "F"
        case "dropbox": "D"
        case "oneDrive": "O"
        case "googleDrive": "G"
        case "webHard": "H"
        default: String(identifier.prefix(1)).uppercased()
        }
    }

    static func style(
        forServiceIdentifier identifier: String,
        theme: AppThemePreference
    ) -> ThemeServiceStyle {
        let base = baseStyle(forServiceIdentifier: identifier)
            ?? fallbackStyle(forServiceIdentifier: identifier, theme: theme)

        switch theme {
        case .night:
            return base.blended(toward: (1, 1, 1), amount: 0.08)
        case .digitalRain:
            return base.blended(toward: (0.74, 1, 0.90), amount: 0.06)
        case .windyMeadow:
            return base.blended(toward: (0, 0, 0), amount: 0.04)
        case .system, .day:
            return base
        }
    }

    static func color(
        forServiceIdentifier identifier: String,
        theme: AppThemePreference
    ) -> Color {
        style(forServiceIdentifier: identifier, theme: theme).color
    }

    static func foregroundColor(
        forServiceIdentifier identifier: String,
        theme: AppThemePreference
    ) -> Color {
        style(forServiceIdentifier: identifier, theme: theme).foregroundColor
    }

    private static func baseStyle(
        forServiceIdentifier identifier: String
    ) -> ThemeServiceStyle? {
        switch identifier {
        case "synology": ThemeServiceStyle(hex: 0x0067E6)
        case "sftp": ThemeServiceStyle(hex: 0x218739)
        case "smb": ThemeServiceStyle(hex: 0x0F6CBD)
        case "webDAV": ThemeServiceStyle(hex: 0x6554C0)
        case "ftp": ThemeServiceStyle(hex: 0xE87500)
        case "dropbox": ThemeServiceStyle(hex: 0x0061FF)
        case "oneDrive": ThemeServiceStyle(hex: 0x0078D4)
        case "googleDrive": ThemeServiceStyle(hex: 0x34A853)
        case "webHard": ThemeServiceStyle(hex: 0x5856D6)
        default: nil
        }
    }

    private static func fallbackStyles(
        for theme: AppThemePreference
    ) -> [ThemeServiceStyle] {
        switch theme {
        case .digitalRain:
            [
                ThemeServiceStyle(hex: 0x52FFC2),
                ThemeServiceStyle(hex: 0x14B8A3),
                ThemeServiceStyle(hex: 0x38D1EB),
                ThemeServiceStyle(hex: 0x8AF2B3),
            ]
        case .windyMeadow:
            [
                ThemeServiceStyle(hex: 0x1F9EDB),
                ThemeServiceStyle(hex: 0x61AD38),
                ThemeServiceStyle(hex: 0xF5B847),
                ThemeServiceStyle(hex: 0x8561B3),
            ]
        case .night:
            [0x0A84FF, 0x30D158, 0xFF9F0A, 0xBF5AF2].map(ThemeServiceStyle.init(hex:))
        case .system, .day:
            [0x007AFF, 0x34C759, 0xFF9500, 0x5856D6].map(ThemeServiceStyle.init(hex:))
        }
    }

    private static func fallbackStyle(
        forServiceIdentifier identifier: String,
        theme: AppThemePreference
    ) -> ThemeServiceStyle {
        let palette = fallbackStyles(for: theme)
        let stableIndex = identifier.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = Int(stableIndex.magnitude % UInt(palette.count))
        return palette[index]
    }
}

struct CodeRainDecoration: View {
    let size: CGSize

    private let columns = [
        "10110", "01A9F", "11001", "0FF10", "10101", "01110",
        "10C0D", "00111", "F0101", "11010", "0A011", "10100",
    ]

    var body: some View {
        HStack(alignment: .top, spacing: max(size.width * 0.035, 8)) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 0) {
                    Text(String(value.prefix(1)))
                        .foregroundStyle(Color(red: 0.74, green: 1, blue: 0.90))
                        .shadow(color: SkyBreezeTheme.accent.opacity(0.85), radius: 4)
                    Text(String(value.dropFirst()))
                        .foregroundStyle(SkyBreezeTheme.accent.opacity(0.20))
                }
                .font(.system(size: max(min(size.width * 0.025, 11), 6), design: .monospaced))
                .offset(y: CGFloat((index * 29) % 90) - 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

struct SkyBreezeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                SkyBreezeTheme.skyGradient(for: colorScheme, theme: selectedTheme)

                if !reduceTransparency {
                    themeDecoration(in: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func themeDecoration(in size: CGSize) -> some View {
        switch selectedTheme {
        case .digitalRain:
            CodeRainDecoration(size: size)
        case .windyMeadow:
            Ellipse()
                .fill(Color(red: 0.43, green: 0.68, blue: 0.20).opacity(0.24))
                .frame(width: size.width * 1.35, height: size.height * 0.46)
                .offset(x: -size.width * 0.18, y: size.height * 0.58)
            Image(systemName: "wind")
                .font(
                    .system(
                        size: max(min(size.width * 0.20, 86), 1),
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(.white.opacity(0.24))
                .offset(x: size.width * 0.24, y: 112)
        default:
            Image(systemName: "cloud.fill")
                .font(.system(size: max(min(size.width * 0.42, 190), 1)))
                .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.06 : 0.38))
                .offset(x: size.width * 0.28, y: 34)
            Image(systemName: "cloud.fill")
                .font(.system(size: max(min(size.width * 0.24, 110), 1)))
                .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.04 : 0.24))
                .offset(x: -size.width * 0.34, y: 122)
            Image(systemName: "wind")
                .font(
                    .system(
                        size: max(min(size.width * 0.20, 86), 1),
                        weight: .ultraLight
                    )
                )
                .foregroundStyle(SkyBreezeTheme.accent.opacity(0.10))
                .offset(x: size.width * 0.24, y: 210)
        }
    }
}
