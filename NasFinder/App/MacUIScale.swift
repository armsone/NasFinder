import SwiftUI
import UIKit

/// The Mac app renders every app-owned size at 1.5x what the same build drew before; iPhone and
/// iPad keep their sizes. Layout numbers go through `ui(_:)` and text styles through
/// `Font.ui(_:)`, so the layout itself grows and hit testing and popover anchors stay aligned.
enum MacUIScale {
    static let isMac: Bool = {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()

    /// Catalyst가 Mac idiom(Optimize Interface for Mac, family 6)으로 실행 중인지. 실행 trait를 읽고,
    /// 메인 스레드 밖에서 처음 읽히면 빌드된 UIDeviceFamily로 판단한다. iPad idiom 배율 경로와 iOS는 false.
    static let usesMacIdiom: Bool = {
        #if targetEnvironment(macCatalyst)
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .mac }
        }
        let families = Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int]
        return families?.contains(6) == true
        #else
        false
        #endif
    }()

    /// 모든 테마의 Mac 앱은 1.5배 확대 없이 표준 크기로 그려 창 크기에 맞게 배치한다.
    static var usesCompactScale: Bool { isMac }

    static var factor: CGFloat { isMac ? (usesCompactScale ? 1 : 1.5) : 1 }

    /// The Dynamic Type size the Mac root forces. Text styles are enlarged from their size here,
    /// so the earlier Mac baseline is kept underneath the 1.5x.
    static var dynamicTypeSize: DynamicTypeSize { usesCompactScale ? .large : .accessibility3 }

    /// `padding()` with no length: the system default on iPhone and iPad, 1.5x of it on the Mac.
    /// Mac idiom은 시스템 기본 여백을 그대로 쓴다.
    static var defaultPadding: CGFloat? { isMac && !usesMacIdiom ? 16 * factor : nil }

    /// The smallest list row: the system 44 on iPhone and iPad.
    /// Mac idiom에서는 SwiftUI의 Mac 기본 최소 행 높이를 그대로 둔다.
    static var minListRowHeight: CGFloat {
        if usesMacIdiom { return EnvironmentValues().defaultMinListRowHeight }
        return isMac ? 44 * factor : 44
    }

    /// List section headers and footers set their own font, so the Mac size is given to them
    /// directly. `nil` off the Mac leaves the list's own font in place.
    static var sectionNoteFont: Font? { isMac && !usesMacIdiom ? font(.footnote, design: nil) : nil }

    /// The system owns the height of navigation and tool bars, so content placed in one grows
    /// 1.5x only up to these limits and never shrinks below its earlier size.
    static let barItemLimit: CGFloat = 60
    static let barFontSizeLimit: CGFloat = 34

    private static let largeTextStyleSizes = pointSizes(for: UIContentSizeCategory(DynamicTypeSize.accessibility3))
    private static let compactTextStyleSizes = pointSizes(for: UIContentSizeCategory(DynamicTypeSize.large))
    private static var textStyleSizes: [Font.TextStyle: CGFloat] {
        usesCompactScale ? compactTextStyleSizes : largeTextStyleSizes
    }

    private static func pointSizes(
        for category: UIContentSizeCategory
    ) -> [Font.TextStyle: CGFloat] {
        let styles: [(Font.TextStyle, UIFont.TextStyle)] = [
            (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2),
            (.title3, .title3), (.headline, .headline), (.subheadline, .subheadline),
            (.body, .body), (.callout, .callout), (.footnote, .footnote),
            (.caption, .caption1), (.caption2, .caption2)
        ]
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        var sizes: [Font.TextStyle: CGFloat] = [:]
        for (style, uiStyle) in styles {
            sizes[style] = UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: traits)
                .pointSize
        }
        return sizes
    }

    /// macOS 내장 텍스트 스타일 크기(HIG). Mac idiom에서 `.system(style)`이 쓰던 크기를 그대로 Pretendard에 준다.
    private static let macIdiomTextStyleSizes: [Font.TextStyle: CGFloat] = [
        .largeTitle: 26, .title: 22, .title2: 17, .title3: 15, .headline: 13, .subheadline: 11,
        .body: 13, .callout: 12, .footnote: 10, .caption: 10, .caption2: 10
    ]

    /// 텍스트 스타일의 기본 굵기. 일반 headline은 500(.medium), 나머지는 400이다.
    /// 의미 있는 주요 제목·CTA는 필요한 곳에서 명시적으로 600(.semibold)을 지정한다.
    private static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        guard style == .headline else { return .regular }
        return .medium
    }

    static func font(_ style: Font.TextStyle, design: Font.Design?) -> Font {
        // 고정폭 등 design을 지정한 글자와 글꼴이 등록되지 않은 빌드는 시스템 글꼴을 그대로 쓴다.
        guard design == nil, PorcelainTypeface.isRegistered else {
            guard isMac, !usesMacIdiom else { return .system(style, design: design) }
            return scaledFont(style, base: textStyleSizes[style] ?? 40, design: design)
        }
        let name = PorcelainTypeface.postScriptName(for: defaultWeight(style))
        // Mac idiom의 시스템 텍스트 스타일은 macOS 내장 크기(body 13 등)이고 Dynamic Type으로 커지지 않는다.
        if usesMacIdiom { return .custom(name, fixedSize: macIdiomTextStyleSizes[style] ?? 13) }
        if isMac { return scaledFont(style, base: textStyleSizes[style] ?? 40, design: nil) }
        // iPhone·iPad: 기본(large) 크기에서 시작해 같은 텍스트 스타일의 Dynamic Type을 따른다.
        return .custom(name, size: compactTextStyleSizes[style] ?? 17, relativeTo: style)
    }

    /// A font for bar content. Bars may or may not follow the forced Dynamic Type size, so the
    /// size is taken from the Dynamic Type size actually in effect where the content sits.
    static func barFont(
        _ style: Font.TextStyle?,
        weight: Font.Weight?,
        at dynamicTypeSize: DynamicTypeSize
    ) -> Font? {
        guard isMac, !usesMacIdiom else {
            guard let style else { return nil }
            return weight.map { Font.ui(style).weight($0) } ?? .ui(style)
        }
        let style = style ?? .body
        let base = pointSizes(for: UIContentSizeCategory(dynamicTypeSize))[style] ?? 17
        let font = scaledFont(
            style,
            base: min(base * factor, max(base, barFontSizeLimit)) / factor,
            design: nil
        )
        return weight.map { font.weight($0) } ?? font
    }

    private static func scaledFont(
        _ style: Font.TextStyle,
        base: CGFloat,
        design: Font.Design?
    ) -> Font {
        let weight: Font.Weight = defaultWeight(style)
        guard design == nil else { return .system(size: base * factor, weight: weight, design: design) }
        return PorcelainTypeface.font(size: base * factor, weight: weight)
    }

    /// Mac idiom 창의 최소 크기. 사이드바와 작업 영역이 겹치지 않는 폭을 지킨다(HIG Windows).
    static let macWindowMinimumSize = CGSize(width: 800, height: 560)

    /// Mac idiom일 때만 연결된 창 장면에 최소 크기를 둔다. iPad idiom 배율 경로와 iOS에서는 아무것도 하지 않는다.
    @MainActor
    static func applyWindowSizeRestrictions() {
        guard usesMacIdiom else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = macWindowMinimumSize
        }
    }

    /// Mac 창 제목줄(NSWindow)은 SwiftUI preferredColorScheme이 아니라 UIWindow 스타일을 따른다.
    /// 앱 테마와 같은 밝기로 맞춘다. 폰·패드에서는 아무것도 하지 않는다.
    @MainActor
    static func applyWindowInterfaceStyle(isDark: Bool) {
        guard isMac else { return }
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// 현재 테마의 글자색(palette.text)을 내비게이션 막대 제목과 뒤로 가기 tint로 쓴다.
    /// 앞으로 만들어질 막대(appearance 프록시)와 이미 화면에 있는 막대를 함께 갱신해, 어두운 테마끼리
    /// 바뀌어 창 스타일이 그대로여도 회색 기본 글자가 남지 않게 한다. 글꼴 크기와 Dynamic Type은 건드리지 않는다.
    @MainActor
    static func applyNavigationBarTheme(_ theme: AppThemePreference) {
        let palette = theme.palette
        let ink = palette.textUIColor
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = AppThemePalette.uiColor(palette.backgroundHex)
        appearance.shadowColor = AppThemePalette.uiColor(palette.borderHex)
        var titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
        var largeTitleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: ink]
        if isMac, !usesMacIdiom {
            titleAttributes[.font] = UIFont.systemFont(ofSize: 17 * factor, weight: .semibold)
            largeTitleAttributes[.font] = UIFont.systemFont(ofSize: 34 * factor, weight: .bold)
        }
        appearance.titleTextAttributes = titleAttributes
        appearance.largeTitleTextAttributes = largeTitleAttributes
        for item in [appearance.buttonAppearance, appearance.backButtonAppearance, appearance.doneButtonAppearance] {
            for state in [item.normal, item.highlighted, item.focused] {
                state.titleTextAttributes = [.foregroundColor: ink]
            }
        }
        appearance.setBackIndicatorImage(nil, transitionMaskImage: nil)

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance
        proxy.tintColor = ink

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                refreshNavigationBars(in: window, appearance: appearance, tint: ink)
            }
        }
    }

    @MainActor
    private static func refreshNavigationBars(in view: UIView, appearance: UINavigationBarAppearance, tint: UIColor) {
        if let bar = view as? UINavigationBar {
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.tintColor = tint
        }
        for subview in view.subviews {
            refreshNavigationBars(in: subview, appearance: appearance, tint: tint)
        }
    }

    /// Enlarges the titles UIKit draws in navigation bars. Does nothing off the Mac.
    @MainActor
    static func applyBarAppearance() {
        guard isMac, !usesMacIdiom else { return }
        let navigationBar = UINavigationBar.appearance()
        var titleAttributes = navigationBar.titleTextAttributes ?? [:]
        titleAttributes[.font] = UIFont.systemFont(ofSize: 17 * factor, weight: .semibold)
        navigationBar.titleTextAttributes = titleAttributes
        var largeTitleAttributes = navigationBar.largeTitleTextAttributes ?? [:]
        largeTitleAttributes[.font] = UIFont.systemFont(ofSize: 34 * factor, weight: .bold)
        navigationBar.largeTitleTextAttributes = largeTitleAttributes
    }
}

/// A layout length in points: unchanged on iPhone and iPad, 1.5x on the Mac.
func ui(_ value: CGFloat) -> CGFloat {
    value * MacUIScale.factor
}

/// A length inside a navigation or tool bar: 1.5x on the Mac, held to what the bar can fit.
func uiBar(_ value: CGFloat) -> CGFloat {
    guard MacUIScale.isMac else { return value }
    return min(value * MacUIScale.factor, max(value, MacUIScale.barItemLimit))
}

extension Font {
    /// A text style that keeps its Dynamic Type behavior on iPhone and iPad and renders at 1.5x
    /// its previous Mac size on the Mac. 6개 테마 공통으로 번들 Pretendard의 실제 굵기 파일을 쓰고,
    /// `design`을 준 글자(고정폭 등)만 시스템 글꼴로 둔다. 이어 붙인 `.weight`·`.bold()`는 같은 Pretendard 가족의 등록된 굵기 파일에서 찾는다.
    static func ui(_ style: Font.TextStyle, design: Font.Design? = nil) -> Font {
        MacUIScale.font(style, design: design)
    }
}

private struct MacBarFontModifier: ViewModifier {
    let style: Font.TextStyle?
    let weight: Font.Weight?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(MacUIScale.barFont(style, weight: weight, at: dynamicTypeSize))
    }
}

extension View {
    /// The font for content inside a navigation or tool bar. Without a style the bar's own font
    /// stays in place on iPhone and iPad.
    func uiBarFont(_ style: Font.TextStyle? = nil, weight: Font.Weight? = nil) -> some View {
        modifier(MacBarFontModifier(style: style, weight: weight))
    }
}
