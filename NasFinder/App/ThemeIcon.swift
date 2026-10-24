import SwiftUI
import UIKit

/// 인터페이스 아이콘 4종 스타일. 시각 테마·앱 아이콘 선택과 별도로 저장한다.
enum InterfaceIconStyle: String, CaseIterable, Identifiable, Sendable {
    case simple
    case solid
    case dimension
    case realistic

    static let storageKey = "app.interface.icon.style.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: "심플"
        case .solid: "솔리드"
        case .dimension: "입체"
        case .realistic: "리얼"
        }
    }

    var isAtlas: Bool { self == .dimension || self == .realistic }

    /// 저장값이 없으면 6개 테마 모두 심플로 시작한다. 한 번 고르면 모든 테마에 적용되고,
    /// 테마를 바꿔도 이 선택은 바뀌지 않는다.
    static func resolved(_ rawValue: String?, theme: AppThemePreference) -> Self? {
        if let rawValue, let style = Self(rawValue: rawValue) { return style }
        return .simple
    }
}

/// 기본 24개 ID 순서는 아틀라스 6열×4행(행 우선)이다. 포켓·Privacy는 승인된 개별 자산을 쓴다.
enum ThemeIconID: String, CaseIterable, Sendable {
    case home, nas, photos, phonehard, cloud, browser
    case video, drafts, transfer, storage, settings, favorites
    case back, close, add, check, save, share
    case edit, play, pause, sort, grid, trash
    case pocket, privacy, brand, connections

    /// 아틀라스에서 한 아이콘을 이루는 분리 본체 수(패키지 manifest 기준).
    /// 입체 색면 아틀라스는 글리프마다 분리된 조각 수를 보존한다. 다른 팩의 추출 규칙은 유지한다.
    func bodyCount(style: InterfaceIconStyle) -> Int {
        if style == .dimension {
            switch self {
            case .nas: return 3
            case .photos, .phonehard, .drafts, .transfer, .storage, .save, .share, .pause, .sort: return 2
            case .grid: return 4
            default: return 1
            }
        }
        return switch self {
        case .check, .save, .share, .pause: 2
        case .edit: 3
        case .grid: 4
        case .sort: 5
        default: 1
        }
    }

    init?(systemName: String) {
        switch systemName {
        case "house", "house.fill": self = .home
        case "point.3.connected.trianglepath.dotted": self = .connections
        case "network", "externaldrive.connected.to.line.below", "externaldrive.badge.wifi",
            "externaldrive.fill.badge.wifi": self = .nas
        case "photo", "photo.on.rectangle.angled", "photo.stack": self = .photos
        case "folder", "folder.fill": self = .pocket
        case "eye.slash", "eye.slash.fill": self = .privacy
        case "iphone", "tray.full.fill": self = .phonehard
        case "cloud", "cloud.fill": self = .cloud
        case "globe": self = .browser
        case "film", "video", "video.fill": self = .video
        case "film.stack": self = .drafts
        case "tray.and.arrow.down.fill", "arrow.up.arrow.down.square",
            "arrow.left.arrow.right": self = .transfer
        case "internaldrive", "internaldrive.fill": self = .storage
        case "gearshape", "gearshape.fill": self = .settings
        case "star", "star.fill": self = .favorites
        case "chevron.backward", "chevron.left": self = .back
        case "xmark": self = .close
        case "plus": self = .add
        case "checkmark": self = .check
        // 작업대(포켓에 담기)는 전용 글리프가 없어 담는 트레이 모양의 save를 쓴다. 다른 루트 탭과 같은 팩으로 보이게 한다.
        case "square.and.arrow.down", "tray.2": self = .save
        case "square.and.arrow.up": self = .share
        case "pencil": self = .edit
        case "play", "play.fill": self = .play
        case "pause", "pause.fill": self = .pause
        case "arrow.up.arrow.down": self = .sort
        case "square.grid.2x2": self = .grid
        case "trash": self = .trash
        default: return nil
        }
    }
}

/// 아틀라스에서 아이콘 본체만 분리해 캐시한다. 균일 셀 크롭은 셀 경계를 넘는
/// 아이콘을 자르고 이웃 조각이 섞이므로, 전체 아틀라스에서 alpha>=180 4방향
/// 연결 성분을 구해 중심이 속한 셀의 ID에 배정한다. 원본 이미지는 바꾸지 않는다.
enum ThemeIconArtwork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var atlasCache: [InterfaceIconStyle: [ThemeIconID: UIImage]] = [:]

    static func image(_ id: ThemeIconID, style: InterfaceIconStyle) -> UIImage? {
        let canonical = id == .save ? "workbench" : id == .storage ? "device_files" : id.rawValue
        if let design = InterfaceDesignArtwork.asset(canonical, style: style) { return design }
        if id == .pocket, style != .dimension { return image(.phonehard, style: style) }
        if style == .dimension, let approved = UIImage(named: "ThemeIconColorPlanes-\(id.rawValue)") {
            return approved.withRenderingMode(.alwaysOriginal)
        }
        // 앱 로고·연결 목록·NAS가 같은 그림이 되지 않도록, 전용 그림이 없는 팩은 심플 팩의 고유 그림을 쓴다.
        if id == .brand || id == .connections {
            return InterfaceDesignArtwork.asset(id.rawValue, style: .simple) ?? image(.nas, style: style)
        }
        if style.isAtlas {
            return atlasImages(style)[id]
        }
        return UIImage(named: "\(namePrefix(nasOnly: true, id: id))-\(style.rawValue)-\(id.rawValue)")?
            .withRenderingMode(.alwaysOriginal)
    }

    /// 정사각 3단 랙 NAS 아이콘 전용 에셋(ThemeIconMac*-nas)은 Mac·iPhone·iPad가 함께 쓴다.
    /// 나머지 아이콘과 아틀라스는 Mac만 전용 에셋을 쓰고 iPhone·iPad는 기존 에셋 그대로다.
    private static func namePrefix(nasOnly: Bool, id: ThemeIconID?) -> String {
        if nasOnly && id == .nas { return "ThemeIconMac" }
        #if targetEnvironment(macCatalyst)
        if !nasOnly || id == .nas { return "ThemeIconMac" }
        #endif
        return "ThemeIcon"
    }

    static func atlasImages(_ style: InterfaceIconStyle) -> [ThemeIconID: UIImage] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = atlasCache[style] { return cached }
        guard let source = UIImage(named: "\(namePrefix(nasOnly: false, id: nil))Atlas-\(style.rawValue)")?.cgImage else {
            return [:]
        }
        let result = isolate(source, style: style)
        atlasCache[style] = result
        return result
    }

    nonisolated(unsafe) private static var fittedCache: [String: UIImage] = [:]

    /// 툴바용으로 비트맵 자체를 size×size pt 캔버스에 비율 유지로 다시 그린다. Catalyst 툴바가
    /// 라벨의 이미지를 bar item 이미지로 꺼내 쓰면 SwiftUI frame이 무시되고 원본 픽셀 크기가
    /// 툴바 최대치(~32pt)까지 커지므로, 고유 크기 자체를 고정한다. 원본 색은 그대로 둔다.
    static func fitted(_ image: UIImage, id: ThemeIconID, style: InterfaceIconStyle, size: CGFloat) -> UIImage {
        let key = "\(style.rawValue)-\(id.rawValue)-\(size)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = fittedCache[key] { return cached }
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let ratio = min(size / source.width, size / source.height)
        let drawn = CGSize(width: source.width * ratio, height: source.height * ratio)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let result = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
            .image { _ in
                image.draw(in: CGRect(
                    x: (size - drawn.width) / 2, y: (size - drawn.height) / 2,
                    width: drawn.width, height: drawn.height
                ))
            }
            .withRenderingMode(.alwaysOriginal)
        fittedCache[key] = result
        return result
    }

    nonisolated(unsafe) private static var tintedCache: [String: UIImage] = [:]

    /// 실루엣(알파)만 남기고 테마 글자색으로 채운 비트맵. 테마별로 캐시한다.
    static func tinted(_ image: UIImage, key: String, theme: AppThemePreference) -> UIImage {
        let cacheKey = "\(key)-\(theme.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = tintedCache[cacheKey] { return cached }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = image.scale
        let rect = CGRect(origin: .zero, size: image.size)
        let result = UIGraphicsImageRenderer(size: image.size, format: format)
            .image { context in
                image.draw(in: rect)
                theme.palette.textUIColor.setFill()
                context.fill(rect, blendMode: .sourceIn)
            }
            .withRenderingMode(.alwaysOriginal)
        tintedCache[cacheKey] = result
        return result
    }

    private static func isolate(_ source: CGImage, style: InterfaceIconStyle) -> [ThemeIconID: UIImage] {
        let width = source.width, height = source.height
        let columns = 6, rows = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [:] }

        var label = [Int32](repeating: -1, count: width * height)
        var components: [[Int]] = []
        for start in 0..<(width * height) where label[start] < 0 && pixels[start * 4 + 3] >= 180 {
            let id = Int32(components.count)
            var points = [start], cursor = 0
            label[start] = id
            while cursor < points.count {
                let point = points[cursor]; cursor += 1
                let x = point % width, y = point / width
                if x > 0, label[point - 1] < 0, pixels[(point - 1) * 4 + 3] >= 180 {
                    label[point - 1] = id; points.append(point - 1)
                }
                if x < width - 1, label[point + 1] < 0, pixels[(point + 1) * 4 + 3] >= 180 {
                    label[point + 1] = id; points.append(point + 1)
                }
                if y > 0, label[point - width] < 0, pixels[(point - width) * 4 + 3] >= 180 {
                    label[point - width] = id; points.append(point - width)
                }
                if y < height - 1, label[point + width] < 0, pixels[(point + width) * 4 + 3] >= 180 {
                    label[point + width] = id; points.append(point + width)
                }
            }
            components.append(points)
        }

        let cellWidth = width / columns, cellHeight = height / rows
        var byCell: [Int: [Int]] = [:]
        for (index, points) in components.enumerated() {
            var sumX = 0, sumY = 0
            for point in points { sumX += point % width; sumY += point / width }
            let column = min(columns - 1, (sumX / points.count) / cellWidth)
            let row = min(rows - 1, (sumY / points.count) / cellHeight)
            byCell[row * columns + column, default: []].append(index)
        }

        var output: [ThemeIconID: UIImage] = [:]
        for (cell, ids) in byCell {
            guard cell < ThemeIconID.allCases.count else { continue }
            let icon = ThemeIconID.allCases[cell]
            let bodies = ids.sorted { components[$0].count > components[$1].count }
                .prefix(icon.bodyCount(style: style))
            let keep = Set(bodies.map(Int32.init))
            var left = width, right = 0, top = height, bottom = 0
            for body in bodies {
                for point in components[body] {
                    let x = point % width, y = point / width
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard left <= right, top <= bottom else { continue }
            left = max(0, left - 2); top = max(0, top - 2)
            right = min(width - 1, right + 2); bottom = min(height - 1, bottom + 2)
            let w = right - left + 1, h = bottom - top + 1
            var crop = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let src = (top + y) * width + left + x
                    // 본체 성분 또는 그 2px 안쪽 가장자리(부드러운 픽셀)만 복사한다.
                    var isBody = keep.contains(label[src])
                    if !isBody {
                        search: for ny in max(0, top + y - 2)...min(height - 1, top + y + 2) {
                            for nx in max(0, left + x - 2)...min(width - 1, left + x + 2)
                            where keep.contains(label[ny * width + nx]) {
                                isBody = true
                                break search
                            }
                        }
                    }
                    guard isBody else { continue }
                    let dst = (y * w + x) * 4
                    crop[dst] = pixels[src * 4]; crop[dst + 1] = pixels[src * 4 + 1]
                    crop[dst + 2] = pixels[src * 4 + 2]; crop[dst + 3] = pixels[src * 4 + 3]
                }
            }
            let image: CGImage? = crop.withUnsafeMutableBytes { buffer in
                CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )?.makeImage()
            }
            if let image { output[icon] = UIImage(cgImage: image).withRenderingMode(.alwaysOriginal) }
        }
        return output
    }
}

/// 선택한 스타일의 인터페이스 아이콘. 실제 사진·영상·폴더 썸네일을 대신하지 않는다.
struct ThemeIcon: View {
    let id: ThemeIconID
    let style: InterfaceIconStyle
    var fallbackSystemName: String? = nil
    var fittedSize: CGFloat? = nil

    @AppStorage(AppThemePreference.storageKey) private var themeRawValue =
        AppThemePreference.light.rawValue
    @State private var atlasImage: UIImage?
    @State private var loadedAtlasStyle: InterfaceIconStyle?

    init(
        _ id: ThemeIconID, style: InterfaceIconStyle, fallbackSystemName: String? = nil,
        fittedSize: CGFloat? = nil
    ) {
        self.id = id
        self.style = style
        self.fallbackSystemName = fallbackSystemName
        self.fittedSize = fittedSize
    }

    /// 어두운 테마의 Simple/Solid만 실루엣 그대로 테마 글자색 한 색으로 칠한다. 밝은 테마의 원색,
    /// 입체·리얼리스틱 아틀라스는 원본 색을 그대로 둔다.
    private var tintTheme: AppThemePreference? {
        let theme = AppThemePreference.resolved(themeRawValue)
        return !style.isAtlas && theme.isDark ? theme : nil
    }

    private var image: UIImage? {
        // 새 스타일이 로드되기 전 이전 그림을 새 스타일 키로 툴바 캐시에 넣지 않는다.
        let raw = style.isAtlas ? (loadedAtlasStyle == style ? atlasImage : nil) : ThemeIconArtwork.image(id, style: style)
        guard let raw else { return nil }
        guard let fittedSize else { return raw }
        let sized = ThemeIconArtwork.fitted(raw, id: id, style: style, size: fittedSize)
        // 툴바는 비트맵을 bar item 이미지로 꺼내 쓰므로 SwiftUI 전경색이 닿지 않는다. 글자색을 픽셀에 굽는다.
        guard let tintTheme else { return sized }
        return ThemeIconArtwork.tinted(sized, key: "\(style.rawValue)-\(id.rawValue)-\(fittedSize)", theme: tintTheme)
    }

    var body: some View {
        Group {
            if let image {
                // UIImage.withTintColor는 SwiftUI Image(uiImage:)가 무시하므로 template + 전경색으로 칠한다.
                Image(uiImage: image)
                    .renderingMode(tintTheme == nil || fittedSize != nil ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tintTheme?.palette.text ?? .primary)
            } else if let fallbackSystemName {
                Image(interfaceSystemName: fallbackSystemName)
            } else {
                Color.clear
            }
        }
        .task(id: style) {
            guard style.isAtlas else { return }
            let style = style, id = id
            let image = await Task.detached(priority: .userInitiated) {
                ThemeIconArtwork.image(id, style: style)
            }.value
            guard !Task.isCancelled else { return }
            atlasImage = image
            loadedAtlasStyle = style
        }
        .accessibilityHidden(true)
    }
}

/// 2.17.0 첫 실행에서 한 번만 라이트 테마(예전 Porcelain)와 리얼리스틱 아이콘을 켠다. 마커가 생긴 뒤에는
/// 사용자가 고른 테마·아이콘 스타일을 다시 덮어쓰지 않는다. 앱 아이콘과 다른 설정은 건드리지 않는다.
enum PorcelainActivation {
    static let markerKey = "app.theme.porcelain.activation.2.17.0"

    static func applyOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(AppThemePreference.light.rawValue, forKey: AppThemePreference.storageKey)
        defaults.set(InterfaceIconStyle.realistic.rawValue, forKey: InterfaceIconStyle.storageKey)
        defaults.set(true, forKey: markerKey)
    }
}

/// 2.28.0(Jarvis 셸) 첫 실행에서 한 번만 승인된 Jarvis 테마를 켠다. 마커가 생긴 뒤에는 사용자가 고른
/// 테마를 다시 덮어쓰지 않으며, 다른 5개 테마는 테마 단추·설정에서 그대로 고를 수 있다. 아이콘 스타일·앱 아이콘은 건드리지 않는다.
enum JarvisShellActivation {
    static let markerKey = "app.theme.jarvis.activation.2.28.0"

    static func applyOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(AppThemePreference.jarvis.rawValue, forKey: AppThemePreference.storageKey)
        defaults.set(true, forKey: markerKey)
    }
}

/// 툴바·버튼 등 주요 커스텀 동작 아이콘. 선택한 스타일이 있고 24개 의미 ID에 해당하면 아이콘 팩을,
/// 아니면 SF Symbol을 쓴다. 시스템 메뉴 항목에는 쓰지 않는다.
struct InterfaceIcon: View {
    let systemName: String
    var size: CGFloat = 22
    var fitsBitmap = false

    @AppStorage(AppThemePreference.storageKey) private var themeRawValue =
        AppThemePreference.light.rawValue
    @AppStorage(InterfaceIconStyle.storageKey) private var styleRawValue = ""

    var body: some View {
        let style = InterfaceIconStyle.resolved(
            styleRawValue, theme: AppThemePreference.resolved(themeRawValue)
        )
        if let style, let canonical = InterfaceDesignArtwork.canonical(systemName),
           let art = InterfaceDesignArtwork.asset(canonical, style: style) {
            Image(uiImage: art).renderingMode(style == .simple || (!style.isAtlas && AppThemePreference.current.isDark) ? .template : .original).resizable().scaledToFit()
                .foregroundStyle(style == .simple ? AppThemePreference.current.palette.text : .primary)
                .frame(width: size, height: size)
        } else if let style, let id = ThemeIconID(systemName: InterfaceDesignArtwork.originalSymbol(systemName)) {
            ThemeIcon(
                id, style: style, fallbackSystemName: systemName,
                fittedSize: fitsBitmap ? size : nil
            )
            .frame(width: size, height: size)
        } else {
            Image(interfaceSystemName: systemName)
        }
    }
}

/// 툴바용 컴팩트 아이콘 버튼 내용. 선택한 팩의 원본 색 아트워크를 20–22pt로 그리고,
/// 44pt 터치 영역을 갖는다. 폭이 늘어나지 않도록 크기를 고정한다.
struct InterfaceToolbarIcon: View {
    let systemName: String
    var artSize: CGFloat = 22

    var body: some View {
        InterfaceIcon(systemName: systemName, size: artSize, fitsBitmap: true)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .fixedSize()
    }
}

/// 앱 헤더 로고 자리: 입체 팩은 브랜드 전용 글리프. OS 앱 아이콘은 바꾸지 않는다.
struct PorcelainHeaderGlyph: View {
    let size: CGFloat

    @AppStorage(InterfaceIconStyle.storageKey) private var styleRawValue = ""

    var body: some View {
        let style = InterfaceIconStyle.resolved(styleRawValue, theme: .current) ?? .simple
        ThemeIcon(.brand, style: style, fallbackSystemName: "externaldrive.connected.to.line.below")
            .frame(width: size, height: size)
            .fixedSize()
    }
}
