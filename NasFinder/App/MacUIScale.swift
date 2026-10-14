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

    static let factor: CGFloat = isMac ? 1.5 : 1

    /// The Dynamic Type size the Mac root forces. Text styles are enlarged from their size here,
    /// so the earlier Mac baseline is kept underneath the 1.5x.
    static let dynamicTypeSize: DynamicTypeSize = .accessibility3

    /// `padding()` with no length: the system default on iPhone and iPad, 1.5x of it on the Mac.
    static let defaultPadding: CGFloat? = isMac ? 24 : nil

    /// The smallest list row: the system 44 on iPhone and iPad.
    static let minListRowHeight: CGFloat = isMac ? 66 : 44

    /// List section headers and footers set their own font, so the Mac size is given to them
    /// directly. `nil` off the Mac leaves the list's own font in place.
    static let sectionNoteFont: Font? = isMac ? font(.footnote, design: nil) : nil

    /// The system owns the height of navigation and tool bars, so content placed in one grows
    /// 1.5x only up to these limits and never shrinks below its earlier size.
    static let barItemLimit: CGFloat = 60
    static let barFontSizeLimit: CGFloat = 34

    private static let textStyleSizes = pointSizes(for: UIContentSizeCategory(dynamicTypeSize))

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

    static func font(_ style: Font.TextStyle, design: Font.Design?) -> Font {
        guard isMac else { return .system(style, design: design) }
        return scaledFont(style, base: textStyleSizes[style] ?? 40, design: design)
    }

    /// A font for bar content. Bars may or may not follow the forced Dynamic Type size, so the
    /// size is taken from the Dynamic Type size actually in effect where the content sits.
    static func barFont(
        _ style: Font.TextStyle?,
        weight: Font.Weight?,
        at dynamicTypeSize: DynamicTypeSize
    ) -> Font? {
        guard isMac else {
            guard let style else { return nil }
            return weight.map { Font.system(style).weight($0) } ?? .system(style)
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
        .system(
            size: base * factor,
            weight: style == .headline ? .semibold : .regular,
            design: design
        )
    }

    /// Enlarges the titles UIKit draws in navigation bars. Does nothing off the Mac.
    @MainActor
    static func applyBarAppearance() {
        guard isMac else { return }
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
    /// its previous Mac size on the Mac.
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
