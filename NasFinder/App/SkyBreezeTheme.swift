import SwiftUI
import UIKit

/// “파란 하늘 · 흰 구름 · 시원한 바람”을 iOS 기본 구성요소 위에
/// 얹는 가벼운 시각 테마. 기능 화면의 대비를 해치지 않도록 배경과
/// 포인트 컬러에만 적용한다.
enum SkyBreezeTheme {
    /// iOS 기본 강조색. 시스템이 라이트·다크 모드에 맞춰 자동 조정한다.
    static let accent = Color(uiColor: .systemBlue)

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

    static let folderBlue = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.36, green: 0.73, blue: 0.94, alpha: 1)
                : UIColor(red: 0.08, green: 0.47, blue: 0.70, alpha: 1)
        }
    )

    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)

    static let thumbnailSurface = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.075, green: 0.11, blue: 0.14, alpha: 1)
                : UIColor(white: 1.0, alpha: 0.88)
        }
    )

    static let thumbnailBorder = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.18, green: 0.28, blue: 0.34, alpha: 1)
                : UIColor(red: 0.75, green: 0.89, blue: 0.95, alpha: 1)
        }
    )

    static let contentBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.035, green: 0.075, blue: 0.11, alpha: 1)
                : UIColor(red: 0.955, green: 0.985, blue: 0.995, alpha: 1)
        }
    )

    static func skyGradient(for colorScheme: ColorScheme) -> LinearGradient {
        let colors: [Color]
        if colorScheme == .dark {
            colors = [
                Color(red: 0.035, green: 0.12, blue: 0.19),
                Color(red: 0.055, green: 0.09, blue: 0.13),
            ]
        } else {
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

struct SkyBreezeBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                SkyBreezeTheme.skyGradient(for: colorScheme)

                if !reduceTransparency {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: min(geometry.size.width * 0.42, 190)))
                        .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.06 : 0.38))
                        .offset(x: geometry.size.width * 0.28, y: 34)

                    Image(systemName: "cloud.fill")
                        .font(.system(size: min(geometry.size.width * 0.24, 110)))
                        .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.04 : 0.24))
                        .offset(x: -geometry.size.width * 0.34, y: 122)

                    Image(systemName: "wind")
                        .font(.system(size: min(geometry.size.width * 0.20, 86), weight: .ultraLight))
                        .foregroundStyle(SkyBreezeTheme.accent.opacity(0.10))
                        .offset(x: geometry.size.width * 0.24, y: 210)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
