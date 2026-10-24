import SwiftUI
import UIKit

/// 사용자가 고르는 정확히 6개 테마. 모든 테마가 같은 배치·같은 Pretendard 글자·같은 썸네일 크기를 쓰고
/// 의미 색(AppThemePalette)만 바뀐다. 예전 원시 저장값(system/day/porcelain 등)은 저장값을 고치지 않고
/// 읽을 때만 라이트로 해석한다.
/// 사용자가 고르는 정확히 6개 테마 (병기스타일 테마).
/// 순서: light(밝은), medium(중간), dark(어두운), jarvis(자비스), friday(프라이데이), ultron(울트론).
/// 예전 저장값 night는 dark, bkstyle은 medium으로 읽으며, 저장값을 다시 쓰지 않는다.
enum AppThemePreference: String, CaseIterable, Identifiable, Sendable {
    case light
    case bkstyle = "medium"
    case night = "dark"
    case jarvis
    case friday
    case ultron

    static let storageKey = "app.theme.preference.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "밝은"
        case .bkstyle: "중간"
        case .night: "어두운"
        case .jarvis: "자비스"
        case .friday: "프라이데이"
        case .ultron: "울트론"
        }
    }

    var shortDescription: String {
        switch self {
        case .light: "밝은 바탕 · 올리브 녹색 강조"
        case .bkstyle: "중간 바탕 · 깊은 올리브 강조"
        case .night: "어두운 바탕 · 연두 강조"
        case .jarvis: "어두운 청록 · 시안 강조"
        case .friday: "밝은 호박색 바탕 · 오렌지 강조"
        case .ultron: "어두운 그래파이트 · 코랄 강조"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "sun.max"
        case .bkstyle: "circle.righthalf.filled"
        case .night: "moon"
        case .jarvis: "circle.dashed"
        case .friday: "hexagon"
        case .ultron: "shield"
        }
    }

    var preferredColorScheme: ColorScheme? {
        isDark ? .dark : .light
    }

    var isDark: Bool {
        switch self {
        case .light, .bkstyle, .friday: false
        case .night, .jarvis, .ultron: true
        }
    }

    /// 6개 표준 값 매핑. 예전 'night'는 dark, 'bkstyle'은 medium으로 읽고, 그 밖의 값은 light로 읽는다.
    static func resolved(_ rawValue: String?) -> Self {
        guard let rawValue else { return .light }
        if rawValue == "night" { return .night }
        if rawValue == "bkstyle" { return .bkstyle }
        return Self(rawValue: rawValue) ?? .light
    }

    var next: Self {
        let themes = Self.allCases
        guard let currentIndex = themes.firstIndex(of: self) else { return .light }
        let nextIndex = themes.index(after: currentIndex)
        return nextIndex == themes.endIndex ? themes[themes.startIndex] : themes[nextIndex]
    }

    static var current: Self {
        resolved(UserDefaults.standard.string(forKey: storageKey))
    }

    var palette: AppThemePalette {
        switch self {
        case .light:
            AppThemePalette(
                background: 0xF5F4F0, surface: 0xFFFFFF, elevated: 0xFBFAF7, border: 0xE2DFD5,
                text: 0x1F211C, secondary: 0x4A4C44, accent: 0x5C6B3C, selected: 0xE8EBDB,
                danger: 0x9C3B2A, pressed: 0xECEBE4, onAccent: 0xFFFFFF, solidAction: 0x5C6B3C
            )
        case .bkstyle:
            // medium (중간)
            AppThemePalette(
                background: 0xD9D3C7, surface: 0xECE8DF, elevated: 0xE6E1D6, border: 0xBDB6A7,
                text: 0x1F211C, secondary: 0x3A3A34, accent: 0x46532C, selected: 0xCDD0B8,
                danger: 0x8A2F1F, pressed: 0xCFC8BA, onAccent: 0xFFFFFF, solidAction: 0x46532C
            )
        case .night:
            // dark (어두운)
            AppThemePalette(
                background: 0x1C1C1A, surface: 0x262622, elevated: 0x242422, border: 0x35342E,
                text: 0xE9E7DF, secondary: 0xC2BFB3, accent: 0x93B163, selected: 0x2A3022,
                danger: 0xE08674, pressed: 0x2E2E29, onAccent: 0x14180D, solidAction: 0x93B163
            )
        case .jarvis:
            AppThemePalette(
                background: 0x0C1420, surface: 0x162337, elevated: 0x121C2B, border: 0x20324A,
                text: 0xE3EDF7, secondary: 0xB3C4D6, accent: 0x4CC2E6, selected: 0x12324A,
                danger: 0xF28B82, pressed: 0x1C2D44, onAccent: 0x04202B, solidAction: 0x4CC2E6
            )
        case .friday:
            AppThemePalette(
                background: 0xF7EFE3, surface: 0xFFFDF8, elevated: 0xFFFAF1, border: 0xE8D8C0,
                text: 0x2A1F16, secondary: 0x55422F, accent: 0x9A4A12, selected: 0xF6DFC0,
                danger: 0xA3204A, pressed: 0xF0E2CC, onAccent: 0xFFFFFF, solidAction: 0x9A4A12
            )
        case .ultron:
            AppThemePalette(
                background: 0x121316, surface: 0x202328, elevated: 0x1A1C20, border: 0x2B2E34,
                text: 0xE6E7EA, secondary: 0xB8BBC2, accent: 0xF2566A, selected: 0x3A1A20,
                danger: 0xFF9A9A, pressed: 0x272A30, onAccent: 0x1A0508, solidAction: 0xF2566A
            )
        }
    }
}

/// 공유 홈 시각 명세 §4의 의미 색(불투명 sRGB). 양 플랫폼이 같은 값을 쓴다.
struct AppThemePalette: Sendable {
    let backgroundHex, surfaceHex, elevatedHex, borderHex, textHex, secondaryHex: Int
    let accentHex, selectedHex, dangerHex, pressedHex, onAccentHex, solidActionHex: Int

    init(
        background: Int, surface: Int, elevated: Int, border: Int, text: Int, secondary: Int,
        accent: Int, selected: Int, danger: Int, pressed: Int, onAccent: Int, solidAction: Int? = nil
    ) {
        backgroundHex = background; surfaceHex = surface; elevatedHex = elevated
        borderHex = border; textHex = text; secondaryHex = secondary
        accentHex = accent; selectedHex = selected; dangerHex = danger
        pressedHex = pressed; onAccentHex = onAccent
        solidActionHex = solidAction ?? accent
    }

    var background: Color { Self.color(backgroundHex) }
    var surface: Color { Self.color(surfaceHex) }
    var elevated: Color { Self.color(elevatedHex) }
    var border: Color { Self.color(borderHex) }
    var text: Color { Self.color(textHex) }
    var secondary: Color { Self.color(secondaryHex) }
    /// 브랜드 `Finder`·선택 표식 등 장식 강조색.
    var accent: Color { Self.color(accentHex) }
    var selected: Color { Self.color(selectedHex) }
    var danger: Color { Self.color(dangerHex) }
    var pressed: Color { Self.color(pressedHex) }
    /// solidAction 위의 글자·글리프 색.
    var onAccent: Color { Self.color(onAccentHex) }
    /// 채운 CTA 바탕. 병기스타일만 accent와 다르다(#C93629).
    var solidAction: Color { Self.color(solidActionHex) }
    /// 주의 글자·글리프 색. 항상 기호와 문구를 함께 쓰며 색만으로 전하지 않는다. 어두운 테마는 밝은 호박색, 밝은 테마는 짙은 호박색.
    var warn: Color { Self.color(Self.isDark(backgroundHex) ? 0xE5B85C : 0x8A5A00) }
    private static func isDark(_ hex: Int) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 128
    }
    var textUIColor: UIColor { Self.uiColor(textHex) }

    static func uiColor(_ hex: Int) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func color(_ hex: Int) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 예전 이름을 유지한 공용 색 접근점. 이제 모든 값은 현재 테마의 의미 색에서 온다.
enum SkyBreezeTheme {
    private static var palette: AppThemePalette { AppThemePreference.current.palette }

    /// 앱 전체 tint와 채운 단추 바탕(solidAction).
    static var accent: Color { palette.solidAction }
    /// `accent`(solidAction)로 채운 면 위의 글자·글리프 색.
    static var onAccent: Color { palette.onAccent }

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

    static var folderBlue: Color { palette.text }
    static var primaryText: Color { palette.text }
    static var secondaryText: Color { palette.secondary }
    static var thumbnailSurface: Color { palette.surface }
    static var thumbnailBorder: Color { palette.border }
    static var contentBackground: Color { palette.background }

    static func skyGradient(
        for colorScheme: ColorScheme,
        theme: AppThemePreference = .current
    ) -> LinearGradient {
        LinearGradient(
            colors: [theme.palette.background],
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

        // 어두운 4테마는 서비스 고유색을 조금 밝혀 어두운 바탕에서 구분되게 한다.
        return theme.isDark ? base.blended(toward: (1, 1, 1), amount: 0.08) : base
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
        // 알 수 없는 서비스는 현재 테마의 의미 색(강조·글자·보조·선)에서 고른다.
        let palette = theme.palette
        return [palette.accentHex, palette.textHex, palette.secondaryHex, palette.borderHex]
            .map(ThemeServiceStyle.init(hex:))
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

struct WorkbenchDecoration: View {
    let size: CGSize

    private let lines = [
        "let client = NAS()",
        "await client.connect()",
        "git status --short",
        "func browse(path: URL)",
        "guard result.isReady else",
        "return .success(files)",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: max(size.height * 0.022, 12)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: ui(10)) {
                    Text(String(format: "%02d", index + 1))
                        .foregroundStyle(Color.white.opacity(0.18))
                    Text(line)
                        .foregroundStyle(
                            index.isMultiple(of: 3)
                                ? Color(red: 0.36, green: 0.78, blue: 1.00).opacity(0.19)
                                : Color.white.opacity(0.10)
                        )
                }
            }
        }
        .font(.system(size: max(min(size.width * 0.032, 12), 7), design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, max(size.height * 0.08, 24))
        .padding(.trailing, max(size.width * 0.04, 12))
        .clipped()
    }
}

struct ThemedSymbol: View {
    let systemName: String
    var size: CGFloat = ui(25)
    var symbolSize: CGFloat? = nil
    var showsStatus = false
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue
    @AppStorage(InterfaceIconStyle.storageKey) private var iconStyleRawValue = ""

    private var packIcon: ThemeIconID? {
        guard InterfaceIconStyle.resolved(
            iconStyleRawValue,
            theme: AppThemePreference.resolved(selectedThemeRawValue)
        ) != nil else { return nil }
        return ThemeIconID(systemName: systemName)
    }

    var body: some View {
        if let id = packIcon,
           let style = InterfaceIconStyle.resolved(
               iconStyleRawValue,
               theme: AppThemePreference.resolved(selectedThemeRawValue)
           ) {
            ThemeIcon(id, style: style, fallbackSystemName: systemName)
                .frame(width: symbolSize ?? size * 0.62, height: symbolSize ?? size * 0.62)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if showsStatus {
                        Circle()
                            .fill(SkyBreezeTheme.accent)
                            .frame(width: max(4, size * 0.16), height: max(4, size * 0.16))
                    }
                }
        } else {
            Image(interfaceSystemName: systemName)
        }
    }
}

struct PhoneHardMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: size * 0.015) {
                Text("Phone")
                    .font(.system(size: size * 0.225, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Hard")
                    .font(.system(size: size * 0.285, weight: .black, design: .rounded))
                    .foregroundStyle(Color(white: 0.075))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: size * 0.36)
                    .background {
                        RoundedRectangle(cornerRadius: size * 0.075, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.00, green: 0.56, blue: 0.08),
                                        Color(red: 0.96, green: 0.32, blue: 0.00),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(alignment: .top) {
                                Color.white.opacity(0.35)
                                    .frame(height: max(0.5, size * 0.018))
                                    .clipShape(Capsule())
                                    .padding(.horizontal, size * 0.045)
                            }
                    }
            }
            .padding(size * 0.105)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.95), Color(white: 0.36), .white.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1, size * 0.045)
                )
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white, Color(white: 0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.09, height: size * 0.09)
                .overlay {
                    Capsule()
                        .fill(Color(white: 0.26))
                        .frame(width: size * 0.055, height: max(0.5, size * 0.012))
                }
                .padding(size * 0.075)
        }
        .shadow(color: .black.opacity(0.24), radius: size * 0.08, y: size * 0.055)
    }
}

struct SkyBreezeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    var body: some View {
        GeometryReader { geometry in
            // 6개 테마 모두 장식 없이 테마 바탕색만 깐다.
            SkyBreezeTheme.skyGradient(for: colorScheme, theme: selectedTheme)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - 병기스타일 테마 6종 네이티브 24×24 벡터 글리프 및 공통 상호작용 부품

/// 24×24 SVG 뷰박스 기준의 정확한 기하 구조를 네이티브 SwiftUI Shape/Canvas로 렌더링.
/// stroke 1.7 round, tint = currentColor (테마 accent 또는 호출부 전경색).
struct ByungkiThemeGlyph: View {
    let theme: AppThemePreference
    var size: CGFloat = 24
    var tintColor: Color? = nil

    @AppStorage(InterfaceIconStyle.storageKey) private var iconStyleRaw = "simple"

    private var canonical: String? {
        switch theme {
        case .light: return "display_light"
        case .bkstyle: return "theme_half"
        case .night: return "display_dark"
        case .friday: return "theme_hexagon"
        case .jarvis, .ultron: return nil // These two marks identify the named colour themes.
        }
    }

    @ViewBuilder var body: some View {
        let style = InterfaceIconStyle(rawValue: iconStyleRaw) ?? .simple
        if let canonical, let artwork = InterfaceDesignArtwork.asset(canonical, style: style) {
            Image(uiImage: artwork)
                .renderingMode(style == .simple ? .template : .original)
                .resizable().scaledToFit()
                .foregroundStyle(theme.isDark ? Color.white : Color.black)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            legacyGlyph
        }
    }

    private var legacyGlyph: some View {
        let style = InterfaceIconStyle(rawValue: iconStyleRaw) ?? .simple
        let drawColor = style == .simple ? (theme.isDark ? Color.white : Color.black) : (tintColor ?? theme.palette.accent)
        return Canvas { context, canvasSize in
            let scale = canvasSize.width / 24.0
            context.scaleBy(x: scale, y: scale)

            let strokeStyle = StrokeStyle(
                lineWidth: 1.7,
                lineCap: .round,
                lineJoin: .round
            )

            switch theme {
            case .light:
                // circle cx=12 cy=12 r=3.8
                let circlePath = Path(ellipseIn: CGRect(x: 12 - 3.8, y: 12 - 3.8, width: 7.6, height: 7.6))
                context.stroke(circlePath, with: .color(drawColor), style: strokeStyle)

                // rays: M12 3.5v2.2M12 18.3v2.2M3.5 12h2.2M18.3 12h2.2M6 6l1.6 1.6M16.4 16.4L18 18M6 18l1.6-1.6M16.4 7.6L18 6
                var rays = Path()
                rays.move(to: CGPoint(x: 12, y: 3.5)); rays.addLine(to: CGPoint(x: 12, y: 5.7))
                rays.move(to: CGPoint(x: 12, y: 18.3)); rays.addLine(to: CGPoint(x: 12, y: 20.5))
                rays.move(to: CGPoint(x: 3.5, y: 12)); rays.addLine(to: CGPoint(x: 5.7, y: 12))
                rays.move(to: CGPoint(x: 18.3, y: 12)); rays.addLine(to: CGPoint(x: 20.5, y: 12))
                rays.move(to: CGPoint(x: 6, y: 6)); rays.addLine(to: CGPoint(x: 7.6, y: 7.6))
                rays.move(to: CGPoint(x: 16.4, y: 16.4)); rays.addLine(to: CGPoint(x: 18, y: 18))
                rays.move(to: CGPoint(x: 6, y: 18)); rays.addLine(to: CGPoint(x: 7.6, y: 16.4))
                rays.move(to: CGPoint(x: 16.4, y: 7.6)); rays.addLine(to: CGPoint(x: 18, y: 6))
                context.stroke(rays, with: .color(drawColor), style: strokeStyle)

            case .bkstyle:
                // medium (중간)
                // circle cx=12 cy=12 r=8
                let circlePath = Path(ellipseIn: CGRect(x: 4, y: 4, width: 16, height: 16))
                context.stroke(circlePath, with: .color(drawColor), style: strokeStyle)

                // path d="M12 4a8 8 0 0 0 0 16z" fill=currentColor (좌측 반원, sweep=0 → 12,4에서 x=4 쪽으로)
                var halfPath = Path()
                halfPath.move(to: CGPoint(x: 12, y: 4))
                halfPath.addArc(
                    center: CGPoint(x: 12, y: 12),
                    radius: 8,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(90),
                    clockwise: true
                )
                halfPath.closeSubpath()
                context.fill(halfPath, with: .color(drawColor))

            case .night:
                // dark (어두운)
                // path d="M19.5 14.6A8 8 0 0 1 9.4 4.5a8 8 0 1 0 10.1 10.1z"
                var moon = Path()
                moon.move(to: CGPoint(x: 19.500, y: 14.600))
                moon.addCurve(to: CGPoint(x: 11.342, y: 12.658), control1: CGPoint(x: 16.632, y: 15.544), control2: CGPoint(x: 13.477, y: 14.793))
                moon.addCurve(to: CGPoint(x: 9.400, y: 4.500), control1: CGPoint(x: 9.207, y: 10.523), control2: CGPoint(x: 8.456, y: 7.368))
                moon.addCurve(to: CGPoint(x: 3.946, y: 12.945), control1: CGPoint(x: 5.819, y: 5.678), control2: CGPoint(x: 3.547, y: 9.197))
                moon.addCurve(to: CGPoint(x: 11.055, y: 20.054), control1: CGPoint(x: 4.345, y: 16.694), control2: CGPoint(x: 7.306, y: 19.655))
                moon.addCurve(to: CGPoint(x: 19.500, y: 14.600), control1: CGPoint(x: 14.803, y: 20.453), control2: CGPoint(x: 18.322, y: 18.181))
                moon.closeSubpath()
                context.stroke(moon, with: .color(drawColor), style: strokeStyle)

            case .jarvis:
                // circle cx=12 cy=12 r=9 stroke-dasharray="15.4 3.45" transform="rotate(-80 12 12)"
                var jarvisContext = context
                jarvisContext.translateBy(x: 12, y: 12)
                jarvisContext.rotate(by: .degrees(-80))
                jarvisContext.translateBy(x: -12, y: -12)

                let outerCircle = Path(ellipseIn: CGRect(x: 3, y: 3, width: 18, height: 18))
                let dashedStroke = StrokeStyle(
                    lineWidth: 1.7,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: [15.4, 3.45]
                )
                jarvisContext.stroke(outerCircle, with: .color(drawColor), style: dashedStroke)

                // circle cx=12 cy=12 r=5 stroke-width=1.4
                let midCircle = Path(ellipseIn: CGRect(x: 7, y: 7, width: 10, height: 10))
                let midStroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                context.stroke(midCircle, with: .color(drawColor), style: midStroke)

                // circle cx=12 cy=12 r=1.7 fill=currentColor stroke=none
                let centerDot = Path(ellipseIn: CGRect(x: 12 - 1.7, y: 12 - 1.7, width: 3.4, height: 3.4))
                context.fill(centerDot, with: .color(drawColor))

            case .friday:
                // path d="M12 3l7.8 4.5v9L12 21l-7.8-4.5v-9z"
                var hex = Path()
                hex.move(to: CGPoint(x: 12, y: 3))
                hex.addLine(to: CGPoint(x: 19.8, y: 7.5))
                hex.addLine(to: CGPoint(x: 19.8, y: 16.5))
                hex.addLine(to: CGPoint(x: 12, y: 21))
                hex.addLine(to: CGPoint(x: 4.2, y: 16.5))
                hex.addLine(to: CGPoint(x: 4.2, y: 7.5))
                hex.closeSubpath()
                context.stroke(hex, with: .color(drawColor), style: strokeStyle)

                // circle cx=12 cy=12 r=3 fill=currentColor stroke=none
                let centerCircle = Path(ellipseIn: CGRect(x: 9, y: 9, width: 6, height: 6))
                context.fill(centerCircle, with: .color(drawColor))

                // path d="M12 9V6.5M12 17.5V15M9 12H6.5M17.5 12H15" stroke-width=1.4
                var cross = Path()
                cross.move(to: CGPoint(x: 12, y: 9)); cross.addLine(to: CGPoint(x: 12, y: 6.5))
                cross.move(to: CGPoint(x: 12, y: 17.5)); cross.addLine(to: CGPoint(x: 12, y: 15))
                cross.move(to: CGPoint(x: 9, y: 12)); cross.addLine(to: CGPoint(x: 6.5, y: 12))
                cross.move(to: CGPoint(x: 17.5, y: 12)); cross.addLine(to: CGPoint(x: 15, y: 12))
                let crossStroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                context.stroke(cross, with: .color(drawColor), style: crossStroke)

            case .ultron:
                // path d="M6 4h12l2.5 5v6l-4 5h-9l-4-5V9z"
                var mask = Path()
                mask.move(to: CGPoint(x: 6, y: 4))
                mask.addLine(to: CGPoint(x: 18, y: 4))
                mask.addLine(to: CGPoint(x: 20.5, y: 9))
                mask.addLine(to: CGPoint(x: 20.5, y: 15))
                mask.addLine(to: CGPoint(x: 16.5, y: 20))
                mask.addLine(to: CGPoint(x: 7.5, y: 20))
                mask.addLine(to: CGPoint(x: 3.5, y: 15))
                mask.addLine(to: CGPoint(x: 3.5, y: 9))
                mask.closeSubpath()
                context.stroke(mask, with: .color(drawColor), style: strokeStyle)

                // path d="M7.4 10.4l3.6 1.3-.3 1.4-3.3-.9zM16.6 10.4L13 11.7l.3 1.4 3.3-.9z" fill=currentColor stroke=none
                var eyes = Path()
                eyes.move(to: CGPoint(x: 7.4, y: 10.4))
                eyes.addLine(to: CGPoint(x: 11.0, y: 11.7))
                eyes.addLine(to: CGPoint(x: 10.7, y: 13.1))
                eyes.addLine(to: CGPoint(x: 7.4, y: 12.2))
                eyes.closeSubpath()

                eyes.move(to: CGPoint(x: 16.6, y: 10.4))
                eyes.addLine(to: CGPoint(x: 13.0, y: 11.7))
                eyes.addLine(to: CGPoint(x: 13.3, y: 13.1))
                eyes.addLine(to: CGPoint(x: 16.6, y: 12.2))
                eyes.closeSubpath()
                context.fill(eyes, with: .color(drawColor))

                // path d="M9.5 16.5h5" stroke-width=1.4
                var mouth = Path()
                mouth.move(to: CGPoint(x: 9.5, y: 16.5))
                mouth.addLine(to: CGPoint(x: 14.5, y: 16.5))
                let mouthStroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                context.stroke(mouth, with: .color(drawColor), style: mouthStroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension AppThemePreference {
    /// 선택기 배지 전용 채움/테두리(=글리프) 색. 앱 팔레트 accent와는 별개다.
    fileprivate var chooserBadgeColors: (fill: Color, border: Color) {
        func rgb(_ hex: Int) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
        }
        switch self {
        case .light: return (rgb(0xF5F4F0), rgb(0x5C6B3C))
        case .bkstyle: return (rgb(0xD9D3C7), rgb(0x46532B))
        case .night: return (rgb(0x1C1C1A), rgb(0x93B163))
        case .jarvis: return (rgb(0x0C1520), rgb(0x4DC2E6))
        case .friday: return (rgb(0xF8EFE3), rgb(0xB8651B))
        case .ultron: return (rgb(0x121316), rgb(0xF2566A))
        }
    }
}

/// 테마 선택기 28 정원 배지: 채움 + 1 테두리 + 20 글리프(테두리와 같은 단색).
private struct ByungkiThemeChooserBadge: View {
    let theme: AppThemePreference

    var body: some View {
        let colors = theme.chooserBadgeColors
        ZStack {
            Circle().fill(colors.fill)
            Circle().strokeBorder(colors.border, lineWidth: 1)
            ByungkiThemeGlyph(theme: theme, size: 20, tintColor: colors.border)
        }
        .frame(width: 28, height: 28)
    }
}

/// 우클릭 메뉴는 Mac에서만 붙인다. iOS의 contextMenu는 롱프레스에도 반응해 홀드 목록과 겹치기 때문이다.
private struct ThemeRightClickMenu<MenuItems: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { menuItems() }
        } else {
            content
        }
    }
}

/// 병기스타일 테마 전환 공통 컨트롤 (짧게 탭: 다음 테마 순환, 500ms 롱프레스: 6종 선택 메뉴 열기).
struct ByungkiThemeControlButton: View {
    @Binding var selectedThemeRawValue: String
    var isBadgeStyle: Bool = false
    var isRunningOnMac: Bool = false

    @State private var showingThemeSheet: Bool = false
    /// 500ms 홀드가 인식되면 true. 이어지는 버튼 release 탭 1회를 소비한다.
    @State private var holdConsumedTap: Bool = false

    private var currentTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    private var nextTheme: AppThemePreference {
        currentTheme.next
    }

    private var accessibilityLabelText: String {
        "테마: \(currentTheme.title) (누르면 \(nextTheme.title), 길게 누르면 목록)"
    }

    var body: some View {
        Button {
            if holdConsumedTap {
                holdConsumedTap = false
                return
            }
            withAnimation(.easeInOut(duration: 0.20)) {
                selectedThemeRawValue = nextTheme.rawValue
            }
        } label: {
            if isBadgeStyle {
                ByungkiThemeGlyph(theme: currentTheme, size: ui(isRunningOnMac ? 15 : 12))
                    .frame(
                        width: ui(isRunningOnMac ? 51 : 38),
                        height: ui(isRunningOnMac ? 24 : 18)
                    )
                    .background {
                        Capsule().fill(currentTheme.palette.background)
                    }
                    .overlay {
                        Capsule().stroke(currentTheme.palette.border, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            } else {
                ByungkiThemeGlyph(theme: currentTheme, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                .onEnded { _ in
                    holdConsumedTap = true
                    showingThemeSheet = true
                }
        )
        .onChange(of: showingThemeSheet) { _, showing in
            // 목록이 닫히면(선택/취소/바깥 탭) 소비되지 못한 홀드 플래그를 비워 키보드/AX 활성화를 막지 않게 한다.
            if !showing { holdConsumedTap = false }
        }
        .modifier(ThemeRightClickMenu(isEnabled: isRunningOnMac) {
            themeContextMenuContent
        })
        .popover(isPresented: $showingThemeSheet) {
            themePopoverContent
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("두 번 탭하면 \(nextTheme.title) 테마로 바뀝니다. 길게 누르면 6종 선택 목록이 열립니다.")
    }

    /// 버튼에 anchor된 작은 목록. 6종 모두 실제 테마 글리프 + 이름 + 현재 선택 체크를 그린다.
    /// 행 선택은 해당 테마만 설정하고 목록을 닫는다(순환 없음). 바깥 탭/취소로 닫혀도 onChange가 홀드 플래그를 비운다.
    private var themePopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AppThemePreference.allCases) { theme in
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        selectedThemeRawValue = theme.rawValue
                    }
                    showingThemeSheet = false
                } label: {
                    HStack(spacing: 10) {
                        ByungkiThemeChooserBadge(theme: theme)
                        Text(theme.title)
                            .font(PorcelainTypeface.font(size: 14, weight: theme == currentTheme ? .semibold : .regular))
                            .foregroundStyle(currentTheme.palette.text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        Image(interfaceSystemName: "checkmark", pointSize: 12)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.chooserBadgeColors.border)
                            .frame(width: 20)
                            .opacity(theme == currentTheme ? 1 : 0)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(theme == currentTheme ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("테마")
    }

    @ViewBuilder
    private var themeContextMenuContent: some View {
        ForEach(AppThemePreference.allCases) { theme in
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    selectedThemeRawValue = theme.rawValue
                }
            } label: {
                Label {
                    Text("\(theme.title)\(theme == currentTheme ? " ✓" : "")")
                } icon: {
                    menuGlyphImage(for: theme)
                }
            }
        }
    }

    /// 네이티브 메뉴는 아이콘을 템플릿(검정)으로 칠하므로, 선택기와 같은 28 원형 배지+20 글리프를 original 렌더링 이미지로 넘긴다.
    @MainActor
    private func menuGlyphImage(for theme: AppThemePreference) -> Image {
        let renderer = ImageRenderer(content: ByungkiThemeChooserBadge(theme: theme))
        renderer.scale = 3
        guard let uiImage = renderer.uiImage else {
            return Image(interfaceSystemName: theme.systemImage)
        }
        return Image(uiImage: uiImage.withRenderingMode(.alwaysOriginal))
    }
}
