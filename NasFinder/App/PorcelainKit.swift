import SwiftUI
import UIKit

/// 6개 테마 공통 레이아웃 부품. 홈·보관한 편집·저장공간 등에서 같은 위계와 간격을 쓰고,
/// 색은 현재 테마의 의미 색(AppThemePalette)에서 읽는다.
enum PorcelainMetrics {
    /// 이 폭 이상이면 사이드바 + 콘텐츠 작업 영역.
    static let workspaceWidth: CGFloat = 760
    /// 가로 폰처럼 좁지만 두 칸이 들어가는 최소 폭.
    static let pairedWidth: CGFloat = 600
    /// 사이드바 옆 작업 영역의 바깥 여백.
    static let workspaceMargin: CGFloat = 20
    /// 작업 영역의 실제 내용 폭이 이 이상일 때만 파일 열기·영상 작업을 나란히 둔다. 파일 열기 두 칸(칸당 168)
    /// + 영상 작업 300 + 사이 24. 그보다 좁으면 세로로 쌓는다(공유 홈 시각 명세).
    static let splitContentWidth: CGFloat = 660
    /// 파일 열기와 영상 작업을 나란히 둘 때의 사이 간격.
    static let splitSpacing: CGFloat = 24
    static let rowIconSize: CGFloat = 26
    /// Mac 셸 사이드바 한 줄 높이(포인터 기준).
    static let shellSidebarRowHeight: CGFloat = 36
    /// 홈 파일 열기 2×2 칸의 앞 아이콘. 글 폭을 우선하도록 작게 둔다.
    static let openIconSize: CGFloat = 32
    static let corner: CGFloat = 14
    /// 홈 파일 열기·Browser 묶음 카드 모서리.
    static let groupCorner: CGFloat = 12
    /// 붉은 영상 만들기 행과 보관한 편집 카드 모서리.
    static let ctaCorner: CGFloat = 10
    /// 즐겨찾기 커버 모서리.
    static let coverCorner: CGFloat = 6
    private static var palette: AppThemePalette { AppThemePreference.current.palette }
    /// 브랜드 `Finder`·선택 표식 장식 강조색(병기스타일은 승인안 #E44435).
    static var accent: Color { palette.accent }
    /// 채운 주요 행동(CTA) 바탕과 그 위 글자색.
    static var solidAction: Color { palette.solidAction }
    static var onAccent: Color { palette.onAccent }
    /// 화면 바탕(bg)·카드(surface)·사이드바(elevated)·구분선(border)·본문 글자(text).
    static var paper: Color { palette.background }
    static var card: Color { palette.surface }
    static var sidebar: Color { palette.elevated }
    static var line: Color { palette.border }
    static var graphite: Color { palette.text }
    static var secondary: Color { palette.secondary }
    static var selected: Color { palette.selected }
    static var pressed: Color { palette.pressed }
    static var danger: Color { palette.danger }

    /// 넓은 화면 사이드바 폭: 가용 폭의 약 21%, 200–280pt(승인 보드 01 PAD 비율의 구현 제안).
    static func sidebarWidth(for width: CGFloat) -> CGFloat {
        min(280, max(200, (width * 0.21).rounded()))
    }
}

/// 테마가 바뀌면 이 속성을 가진 뷰를 다시 그리게 한다. 색 자체는 PorcelainMetrics가 현재 테마에서 읽는다.
/// SwiftUI는 body에서 읽지 않은 저장값의 변경으로는 다시 그리지 않으므로, 쓰는 뷰는 body 첫 줄에서
/// `let _ = themeRefresh.theme`로 반드시 읽는다. 읽지 않으면 입력이 같은 하위 뷰가 예전 테마 색에 머문다.
struct ThemeRefresh: DynamicProperty {
    @AppStorage(AppThemePreference.storageKey) private var rawValue = AppThemePreference.light.rawValue

    var theme: AppThemePreference { .resolved(rawValue) }
}

/// 승인안 공통 글자 역할. 폰·패드·Mac이 같은 기본 크기를 쓰고, 기본 크기는 Dynamic Type에 따라 함께 커진다.
enum PorcelainTextRole {
    case brand, bigTitle, section, cta, tile, body, favorite, meta, badge

    var size: CGFloat {
        switch self {
        case .brand: 22
        case .bigTitle: 20
        case .section: 17
        case .cta: 16
        case .tile: 14
        case .body: 12
        case .favorite: 11
        case .meta: 11
        case .badge: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .brand: .bold
        case .bigTitle, .section, .cta, .badge: .semibold
        case .tile: .medium
        case .body, .favorite, .meta: .regular
        }
    }

    /// 크기 확장의 기준 글자 스타일.
    var textStyle: Font.TextStyle {
        switch self {
        case .brand, .bigTitle: .title3
        case .section, .cta: .headline
        case .tile: .subheadline
        case .body: .footnote
        case .favorite, .meta: .caption
        case .badge: .caption2
        }
    }
}

private struct PorcelainTextRoleModifier: ViewModifier {
    let weight: Font.Weight
    @ScaledMetric private var size: CGFloat

    init(_ role: PorcelainTextRole, weight: Font.Weight?) {
        self.weight = weight ?? role.weight
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        content.font(PorcelainTypeface.font(size: size, weight: weight))
    }
}

/// Porcelain 앱 소유 글자의 공통 글꼴(Apple·Android 같은 Pretendard 정적 4굵기).
/// 굵기마다 실제 PostScript 이름을 쓰고 합성 굵기는 쓰지 않는다. 크기는 이미 Dynamic Type으로
/// 늘어난 값이라 fixedSize로 다시 키우지 않는다. 글꼴이 등록되지 않은 빌드에서만 시스템 글꼴을 쓴다.
enum PorcelainTypeface {
    static let isRegistered = UIFont(name: "Pretendard-Regular", size: 12) != nil

    static func postScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Pretendard-Bold"
        case .semibold: "Pretendard-SemiBold"
        case .medium: "Pretendard-Medium"
        default: "Pretendard-Regular"
        }
    }

    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard isRegistered else { return .system(size: size, weight: weight) }
        return .custom(postScriptName(for: weight), fixedSize: size)
    }

    /// UIKit 앱 소유 글자용. 400 미만은 Regular, 700 이상은 Bold 실제 파일에 맞춘다.
    static func uiFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let name = switch weight.rawValue {
        case UIFont.Weight.bold.rawValue...: "Pretendard-Bold"
        case UIFont.Weight.semibold.rawValue...: "Pretendard-SemiBold"
        case UIFont.Weight.medium.rawValue...: "Pretendard-Medium"
        default: "Pretendard-Regular"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension View {
    /// Porcelain 공통 글자 역할. weight를 주면 같은 크기에서 굵기만 바꾼다.
    func porcelainFont(_ role: PorcelainTextRole, weight: Font.Weight? = nil) -> some View {
        modifier(PorcelainTextRoleModifier(role, weight: weight))
    }
}

/// 행 끝 `…` 연결 메뉴의 라벨. Mac에서 기본 Menu가 회색 테두리 선택 상자와 화살표로 폭을 크게
/// 차지하지 않도록 테두리·표시 화살표 없이 라벨 크기만 쓰게 한다. 메뉴 항목과 동작은 그대로다.
struct PorcelainMoreMenuLabel: View {
    private var themeRefresh = ThemeRefresh()
    var width: CGFloat = 30
    var height: CGFloat = 44

    var body: some View {
        let _ = themeRefresh.theme
        Image(systemName: "ellipsis")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PorcelainMetrics.secondary)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
    }
}

extension View {
    /// `PorcelainMoreMenuLabel`을 쓰는 Menu에 건다. 공개 API(menuStyle(.button)·borderless·menuIndicator)만 쓴다.
    func porcelainCompactMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// 앱 소유 브랜드 글자: `Nas` 그래파이트 + `Finder` 강조색(승인 보드 01/02/03/06).
struct PorcelainBrandText: View {
    private var themeRefresh = ThemeRefresh()
    var body: some View {
        let _ = themeRefresh.theme
        Text("\(Text("Nas").foregroundColor(PorcelainMetrics.graphite))\(Text("Finder").foregroundColor(PorcelainMetrics.accent))")
            .porcelainFont(.brand)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("NasFinder")
    }
}

/// 카드로 감싸지 않은 섹션 제목 줄. 즐겨찾기·파일 열기·영상 작업처럼 바탕 위에 바로 놓는다.
struct PorcelainSectionHeader<Trailing: View>: View {
    private var themeRefresh = ThemeRefresh()
    let title: String
    var role: PorcelainTextRole = .bigTitle
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        let _ = themeRefresh.theme
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .porcelainFont(role)
                .foregroundStyle(PorcelainMetrics.graphite)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension PorcelainSectionHeader where Trailing == EmptyView {
    init(title: String, role: PorcelainTextRole = .bigTitle) {
        self.init(title: title, role: role, trailing: { EmptyView() })
    }
}

/// 얇은 선이 있는 한 장의 묶음 카드. 내부 행 사이는 PorcelainDivider·세로선으로 나눈다.
struct PorcelainGroupCard<Content: View>: View {
    private var themeRefresh = ThemeRefresh()
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = themeRefresh.theme
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PorcelainMetrics.card,
                in: RoundedRectangle(cornerRadius: PorcelainMetrics.groupCorner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PorcelainMetrics.groupCorner, style: .continuous)
                    .stroke(PorcelainMetrics.line, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.groupCorner, style: .continuous))
    }
}

/// 파일 열기 2×2의 낮은 칸: 아이콘 32 + 간격 10 + 남는 폭 전부를 쓰는 글(제목·짧은 설명).
/// 칸 안에 메뉴 단추나 그 예약 폭을 두지 않는다(연결 관리는 각 칸의 contextMenu·손쉬운 사용 동작).
/// 제목·설명은 단어 단위로 두 줄까지 늘고, 칸 높이는 글에 맞춰 자연스럽게 커진다.
struct PorcelainOpenCell<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var isMarked = false
    @ViewBuilder let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var themeRefresh = ThemeRefresh()

    private var lineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 3 : 2 }

    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 10) {
            leading()
                .frame(width: PorcelainMetrics.openIconSize, height: PorcelainMetrics.openIconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .porcelainFont(.tile)
                        .foregroundStyle(PorcelainMetrics.graphite)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    if isMarked {
                        InterfaceIcon(systemName: "star.fill", size: 12)
                            .font(.caption2)
                            .foregroundStyle(PorcelainMetrics.accent)
                            .accessibilityLabel("기본 위치")
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .porcelainFont(.body)
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }
}

/// Browser·네트워크 추가처럼 한 줄 두 칸에 놓는 낮은 행.
struct PorcelainInlineAction<Leading: View>: View {
    private var themeRefresh = ThemeRefresh()
    let title: String
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 8) {
            leading().frame(width: 24, height: 24)
            Text(title)
                .porcelainFont(.tile, weight: .medium)
                .foregroundStyle(PorcelainMetrics.graphite)
                .lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PorcelainMetrics.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }
}

/// 승인 보드의 `영상 만들기` 주요 행동. 바탕은 테마 solidAction, 글자·아이콘 바탕은 onAccent.
struct PorcelainVideoCTA: View {
    private var themeRefresh = ThemeRefresh()
    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 12) {
            InterfaceIcon(systemName: "film", size: 20)
                .foregroundStyle(PorcelainMetrics.solidAction)
                .frame(width: 32, height: 32)
                .background(PorcelainMetrics.onAccent, in: Circle())
            Text("영상 만들기")
                .porcelainFont(.cta)
                .foregroundStyle(PorcelainMetrics.onAccent)
                .lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PorcelainMetrics.onAccent)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(
            PorcelainMetrics.solidAction,
            in: RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner, style: .continuous))
        .hoverEffect(.highlight)
    }
}

/// 채운 CTA의 누름 표시: 같은 solidAction 바탕에 얇은 onAccent 안쪽 선만 더해 글자 대비를 유지한다.
struct PorcelainSolidActionButtonStyle: ButtonStyle {
    private var themeRefresh = ThemeRefresh()

    func makeBody(configuration: Configuration) -> some View {
        let _ = themeRefresh.theme
        configuration.label
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner, style: .continuous)
                        .strokeBorder(PorcelainMetrics.onAccent, lineWidth: 1)
                }
            }
    }
}

/// 시스템 `.borderedProminent` 자리의 채운 주요 단추. 바탕 solidAction과 글자·글리프 onAccent를 직접 그려
/// Mac idiom과 dark 4개 테마에서도 tint 위 시스템 흰 글자에 기대지 않는다. 누르면 onAccent 1pt 안쪽 선이 생긴다.
struct PorcelainProminentButtonStyle: ButtonStyle {
    private var themeRefresh = ThemeRefresh()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    private let cornerRadius: CGFloat?

    init(cornerRadius: CGFloat? = nil) {
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        let _ = themeRefresh.theme
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? metrics.corner, style: .continuous)
        configuration.label
            .foregroundStyle(isEnabled ? PorcelainMetrics.onAccent : PorcelainMetrics.secondary)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(isEnabled ? PorcelainMetrics.solidAction : PorcelainMetrics.line, in: shape)
            .overlay {
                if configuration.isPressed {
                    shape.strokeBorder(PorcelainMetrics.onAccent, lineWidth: 1)
                }
            }
            .contentShape(shape)
    }

    /// 시스템 prominent 단추와 비슷한 크기별 여백·모서리.
    private var metrics: (horizontal: CGFloat, vertical: CGFloat, corner: CGFloat) {
        switch controlSize {
        case .mini, .small: (10, 5, 6)
        case .large, .extraLarge: (20, 14, 12)
        default: (14, 7, 8)
        }
    }
}

/// 넓은 화면 사이드바의 주요 목적지 한 줄. 선택된 곳은 옅은 강조면으로 표시한다.
struct PorcelainSidebarItem<Leading: View>: View {
    private var themeRefresh = ThemeRefresh()
    let title: String
    var isSelected = false
    /// false면 접힌 Mac 사이드바처럼 아이콘만 가운데 둔다. 이름은 손쉬운 사용·도움말로 남는다.
    var showsTitle = true
    /// Mac 셸 사이드바는 포인터 기준 36pt로 줄여 한 화면에 세 묶음이 다 들어가게 한다.
    var minHeight: CGFloat = 44
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 10) {
            leading().frame(width: PorcelainMetrics.rowIconSize, height: PorcelainMetrics.rowIconSize)
            if showsTitle {
                Text(title)
                    .porcelainFont(.tile, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(PorcelainMetrics.graphite)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, minHeight < 44 ? 2 : 6)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: showsTitle ? .leading : .center)
        .help(showsTitle ? "" : title)
        .background {
            // 선택 행은 selected 바탕 + 앞쪽 accent 표식. 글자는 항상 text 색이다.
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PorcelainMetrics.selected)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(PorcelainMetrics.accent)
                            .frame(width: 3, height: 18)
                            .padding(.leading, 2)
                    }
            }
        }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct PorcelainPanel<Content: View>: View {
    private var themeRefresh = ThemeRefresh()
    var title: String? = nil
    var systemImage: String? = nil
    var trailing: String? = nil
    /// false면 카드 테두리 없이 바탕 위에 내용만 둔다(자체 경계가 있는 타일 묶음용).
    var framed = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = themeRefresh.theme
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        InterfaceIcon(systemName: systemImage, size: 18)
                    }
                    Text(title)
                        .porcelainFont(.section)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                    }
                }
                .foregroundStyle(PorcelainMetrics.graphite)
                .padding(.horizontal, 4)
            }
            if framed {
                VStack(spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        PorcelainMetrics.card,
                        in: RoundedRectangle(cornerRadius: PorcelainMetrics.corner, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: PorcelainMetrics.corner, style: .continuous)
                            .stroke(PorcelainMetrics.line, lineWidth: 0.75)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.corner, style: .continuous))
            } else {
                VStack(spacing: 0, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PorcelainDivider: View {
    private var themeRefresh = ThemeRefresh()
    var body: some View {
        let _ = themeRefresh.theme
        Rectangle()
            .fill(PorcelainMetrics.line)
            .frame(height: 0.5)
            .padding(.leading, 54)
    }
}

struct PorcelainRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    var badgeTint: Color = SkyBreezeTheme.accent
    var subtitleLineLimit = 1
    var showsChevron = false
    let leading: Leading
    let trailing: Trailing
    private var themeRefresh = ThemeRefresh()

    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        badgeTint: Color = SkyBreezeTheme.accent,
        subtitleLineLimit: Int = 1,
        showsChevron: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.badgeTint = badgeTint
        self.subtitleLineLimit = subtitleLineLimit
        self.showsChevron = showsChevron
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 12) {
            leading.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .porcelainFont(.tile, weight: .medium)
                        .foregroundStyle(PorcelainMetrics.graphite)
                        .lineLimit(2)
                    if let badge {
                        Text(badge)
                            .porcelainFont(.badge)
                            .foregroundStyle(badgeTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(badgeTint.opacity(0.12), in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .porcelainFont(.body)
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: subtitleLineLimit > 1)
                }
            }
            Spacer(minLength: 0)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
    }
}

extension PorcelainRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        badgeTint: Color = SkyBreezeTheme.accent,
        subtitleLineLimit: Int = 1,
        showsChevron: Bool = false,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: title, subtitle: subtitle, badge: badge, badgeTint: badgeTint,
            subtitleLineLimit: subtitleLineLimit,
            showsChevron: showsChevron, leading: leading, trailing: { EmptyView() }
        )
    }
}

/// 로딩·빈 상태·오류에 쓰는 Porcelain 중앙 안내.
struct PorcelainStateView: View {
    private var themeRefresh = ThemeRefresh()
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        let _ = themeRefresh.theme
        VStack(spacing: 10) {
            InterfaceIcon(systemName: systemImage, size: 52)
                .font(.system(size: 40))
                .foregroundStyle(PorcelainMetrics.secondary)
            Text(title).porcelainFont(.bigTitle, weight: .semibold)
                .foregroundStyle(PorcelainMetrics.graphite)
                .multilineTextAlignment(.center)
            if let message {
                Text(message).porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
