import SwiftUI
import UIKit

/// “파란 하늘 · 흰 구름 · 시원한 바람”을 iOS 기본 구성요소 위에
/// 얹는 가벼운 시각 테마. 기능 화면의 대비를 해치지 않도록 배경과
/// 포인트 컬러에만 적용한다.
enum SkyBreezeTheme {
    /// 흰색 위에서도 충분한 대비를 갖는 차분한 번트 오렌지.
    /// 밝은 systemOrange를 그대로 쓰면 작은 글자와 아이콘의 대비가
    /// 부족하므로 조작 요소에만 이 색을 사용한다.
    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.61, blue: 0.29, alpha: 1)
                : UIColor(red: 0.72, green: 0.25, blue: 0.035, alpha: 1)
        }
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
