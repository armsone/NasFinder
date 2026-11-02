import CoreText
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 자막 크기

/// 렌더 프레임 짧은 변 기준 비율 크기. 기기 해상도에 무관하게 항상 일정 비율로 표시된다.
enum CaptionSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small = "작게"
    case normal = "기본"
    case large = "크게"
    case xlarge = "더크게"

    var id: String { rawValue }

    var shortEdgeFraction: CGFloat {
        switch self {
        case .small: return 0.036
        case .normal: return 0.048
        case .large: return 0.064
        case .xlarge: return 0.084
        }
    }
}

// MARK: - 글꼴 카테고리 및 아이템

enum CaptionFontCategory: String, CaseIterable, Sendable {
    case basic = "기본"
    case golf = "골프"
    case title = "제목"
    case vlog = "브이로그"
    case emotional = "감성"
    case handwriting = "손글씨"
    case user = "사용자"
}

struct CaptionFontItem: Identifiable, Sendable {
    let id: String
    let displayName: String
    let category: CaptionFontCategory
    let assetPath: String?
    let isSystem: Bool

    init(id: String, displayName: String, category: CaptionFontCategory, assetPath: String? = nil, isSystem: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.assetPath = assetPath
        self.isSystem = isSystem
    }
}

// MARK: - 글꼴 저장소

final class TrailerCaptionFontStore: @unchecked Sendable {
    static let shared = TrailerCaptionFontStore()
    static let idPrefix = "imported_font:"

    static let bundledFonts: [CaptionFontItem] = [
        // 기본 (Basic)
        CaptionFontItem(id: "nanum_gothic", displayName: "나눔고딕", category: .basic, assetPath: "Fonts/NanumGothic-Regular.ttf"),
        CaptionFontItem(id: "kakao_big_sans", displayName: "카카오", category: .basic, assetPath: "Fonts/KakaoBigSans-Regular.ttf"),
        CaptionFontItem(id: "pretendard", displayName: "프리텐다드", category: .basic, assetPath: "Fonts/Pretendard-Regular.otf"),
        CaptionFontItem(id: "pretendard_bold", displayName: "프리텐다드 굵게", category: .basic, assetPath: "Fonts/Pretendard-Bold.otf"),
        CaptionFontItem(id: "nexon_lv1_gothic", displayName: "넥슨Lv1", category: .basic, assetPath: "Fonts/NEXONLv1GothicRegular.ttf"),
        CaptionFontItem(id: "serif", displayName: "명조(시스템)", category: .basic, isSystem: true),
        CaptionFontItem(id: "monospace", displayName: "고정폭(시스템)", category: .basic, isSystem: true),

        // 골프 (Golf)
        CaptionFontItem(id: "puradak_gentle_gothic", displayName: "젠틀고딕", category: .golf, assetPath: "Fonts/PuradakGentleGothic.ttf"),

        // 제목 (Title)
        CaptionFontItem(id: "tenada", displayName: "태나다", category: .title, assetPath: "Fonts/Tenada.ttf"),
        CaptionFontItem(id: "black_han_sans", displayName: "검은고딕", category: .title, assetPath: "Fonts/BlackHanSans-Regular.ttf"),
        CaptionFontItem(id: "paperlogy_bold", displayName: "페이퍼로지B", category: .title, assetPath: "Fonts/Paperlogy-7Bold.ttf"),

        // 브이로그 (Vlog)
        CaptionFontItem(id: "poppins", displayName: "Poppins", category: .vlog, assetPath: "Fonts/Poppins-Regular.ttf"),
        CaptionFontItem(id: "cafe24_ssurround", displayName: "써라운드", category: .vlog, assetPath: "Fonts/Cafe24Ssurround.ttf"),
        CaptionFontItem(id: "do_hyeon", displayName: "도현", category: .vlog, assetPath: "Fonts/DoHyeon-Regular.ttf"),

        // 감성 (Emotional)
        CaptionFontItem(id: "maruburi", displayName: "마루부리", category: .emotional, assetPath: "Fonts/MaruBuri-Regular.ttf"),
        CaptionFontItem(id: "gowun_dodum", displayName: "고운돋움", category: .emotional, assetPath: "Fonts/GowunDodum-Regular.ttf"),
        CaptionFontItem(id: "gowun_batang", displayName: "고운바탕", category: .emotional, assetPath: "Fonts/GowunBatang-Regular.ttf"),

        // 손글씨 (Handwriting)
        CaptionFontItem(id: "ddulgi_mayo", displayName: "둘기마요", category: .handwriting, assetPath: "Fonts/DdulgiMayo.otf")
    ]

    private let lock = NSLock()
    private var registeredPostScriptNames: [String: String] = [:]
    private var loadedTypefaces: [String: UIFont] = [:]

    private init() {
        registerBundledFontsIfNeeded()
    }

    private var importedFontsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("NasFinder/imported-fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func isImported(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    static func displayName(id: String) -> String {
        if isImported(id) {
            let filename = String(id.dropFirst(idPrefix.count))
            let withoutExt = (filename as NSString).deletingPathExtension
            if let separator = withoutExt.range(of: "--") {
                return String(withoutExt[..<separator.lowerBound])
            }
            return withoutExt.isEmpty ? "사용자 글꼴" : withoutExt
        }
        if let found = bundledFonts.first(where: { $0.id == id }) {
            return found.displayName
        }
        switch id {
        case "pretendard": return "프리텐다드"
        case "pretendard_bold": return "프리텐다드 굵게"
        case "kakao_big_sans", "kakao": return "카카오"
        case "gowun_batang": return "고운바탕"
        case "gowun_dodum": return "고운돋움"
        case "nanum_gothic": return "나눔고딕"
        case "cafe24_ssurround": return "써라운드"
        case "puradak_gentle_gothic", "puradak_gentle": return "젠틀고딕"
        case "tenada": return "태나다"
        case "do_hyeon": return "도현"
        case "black_han_sans": return "검은고딕"
        case "maruburi": return "마루부리"
        case "ddulgi_mayo": return "둘기마요"
        case "paperlogy_bold": return "페이퍼로지B"
        case "nexon_lv1_gothic": return "넥슨Lv1"
        case "poppins": return "Poppins"
        case "serif": return "명조(시스템)"
        case "monospace": return "고정폭(시스템)"
        default: return id
        }
    }

    func listImportedFonts() -> [CaptionFontItem] {
        let dir = importedFontsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let fontFiles = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        return fontFiles.map { file in
            let id = Self.idPrefix + file.lastPathComponent
            let name = Self.displayName(id: id)
            return CaptionFontItem(id: id, displayName: name, category: .user, assetPath: file.path)
        }
    }

    func importFont(from sourceURL: URL) throws -> String {
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let originalName = sourceURL.lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let allowed = ["ttf", "otf"]
        guard allowed.contains(ext) else {
            throw NSError(domain: "CaptionFontStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "TTF 또는 OTF 글꼴 파일만 가져올 수 있습니다."])
        }

        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(sourceURL as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw NSError(domain: "CaptionFontStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "유효하지 않거나 손상된 글꼴 파일입니다."])
        }

        let baseName = (originalName as NSString).deletingPathExtension
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(40)
        let safeBase = baseName.isEmpty ? "사용자 글꼴" : String(baseName)
        let uniqueFileName = "\(safeBase)--\(UUID().uuidString).\(ext)"
        let targetURL = importedFontsDirectory.appendingPathComponent(uniqueFileName)

        try FileManager.default.copyItem(at: sourceURL, to: targetURL)

        // Try registering font
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(targetURL as CFURL, .process, &error)

        let fontID = Self.idPrefix + uniqueFileName
        return fontID
    }

    private func registerBundledFontsIfNeeded() {
        for item in Self.bundledFonts where !item.isSystem {
            guard let path = item.assetPath else { continue }
            let filename = (path as NSString).lastPathComponent
            let ext = (path as NSString).pathExtension
            let nameOnly = (filename as NSString).deletingPathExtension
            if let url = Bundle.main.url(forResource: nameOnly, withExtension: ext, subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: nameOnly, withExtension: ext) {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                   let first = descriptors.first,
                   let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
                    lock.lock()
                    registeredPostScriptNames[item.id] = psName
                    lock.unlock()
                }
            }
        }
    }

    static func uiFont(fontName: String, size: CGFloat) -> UIFont {
        shared.resolveUIFont(fontName: fontName, size: size)
    }

    private func resolveUIFont(fontName: String, size: CGFloat) -> UIFont {
        let pointSize = max(4.0, size)

        if fontName == "serif" {
            let base = UIFont.systemFont(ofSize: pointSize, weight: .bold)
            if let desc = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: desc, size: pointSize)
            }
            return base
        }

        if fontName == "monospace" {
            return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        }

        if Self.isImported(fontName) {
            let filename = String(fontName.dropFirst(Self.idPrefix.count))
            if filename.contains("/") || filename.contains("\\") || filename.contains("..") || (filename as NSString).lastPathComponent != filename {
                return UIFont.systemFont(ofSize: pointSize, weight: .bold)
            }
            let fileURL = importedFontsDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
                   let first = descriptors.first,
                   let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String,
                   let loaded = UIFont(name: psName, size: pointSize) {
                    return loaded
                }
            }
            return UIFont.systemFont(ofSize: pointSize, weight: .bold)
        }

        lock.lock()
        let knownPS = registeredPostScriptNames[fontName]
        lock.unlock()

        if let knownPS, let font = UIFont(name: knownPS, size: pointSize) {
            return font
        }

        // Try lookup by fontName directly
        if let font = UIFont(name: fontName, size: pointSize) {
            return font
        }

        // Try known PostScript name heuristics
        let candidateNames: [String] = {
            switch fontName {
            case "pretendard_bold": return ["Pretendard-Bold", "PretendardBold"]
            case "pretendard": return ["Pretendard-Regular", "PretendardRegular"]
            case "nanum_gothic": return ["NanumGothic", "NanumGothic-Bold", "NanumGothicBold"]
            case "kakao_big_sans": return ["KakaoBigSans-Regular", "KakaoBigSansRegular", "KakaoBigSans"]
            case "nexon_lv1_gothic": return ["NEXON-Lv1-Gothic-OTF", "NexonLv1Gothic", "NEXON Lv1 Gothic"]
            case "puradak_gentle_gothic": return ["PuradakGentleGothic", "Puradak-Gentle-Gothic"]
            case "tenada": return ["Tenada", "Tenada-Regular"]
            case "black_han_sans": return ["BlackHanSans-Regular", "BlackHanSans"]
            case "paperlogy_bold": return ["Paperlogy-7Bold", "Paperlogy-Bold", "PaperlogyBold"]
            case "poppins": return ["Poppins-Regular", "Poppins-Bold"]
            case "cafe24_ssurround": return ["Cafe24Ssurround", "Cafe24-Ssurround"]
            case "do_hyeon": return ["DoHyeon-Regular", "DoHyeon"]
            case "maruburi": return ["MaruBuri-Regular", "MaruBuri"]
            case "gowun_dodum": return ["GowunDodum-Regular", "GowunDodum"]
            case "gowun_batang": return ["GowunBatang-Regular", "GowunBatang"]
            case "ddulgi_mayo": return ["DdulgiMayo", "Ddulgi-Mayo"]
            default: return [fontName]
            }
        }()

        for name in candidateNames {
            if let font = UIFont(name: name, size: pointSize) {
                lock.lock()
                registeredPostScriptNames[fontName] = name
                lock.unlock()
                return font
            }
        }

        // System fallbacks matching design intent
        switch fontName {
        case "gowun_batang", "maruburi":
            let base = UIFont.systemFont(ofSize: pointSize, weight: .medium)
            if let desc = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: desc, size: pointSize)
            }
            return base
        case "cafe24_ssurround", "do_hyeon", "ddulgi_mayo":
            let base = UIFont.systemFont(ofSize: pointSize, weight: .heavy)
            if let desc = base.fontDescriptor.withDesign(.rounded) {
                return UIFont(descriptor: desc, size: pointSize)
            }
            return base
        case "black_han_sans", "tenada", "paperlogy_bold":
            return UIFont.systemFont(ofSize: pointSize, weight: .black)
        default:
            return UIFont.systemFont(ofSize: pointSize, weight: .bold)
        }
    }
}

// MARK: - 자막 스타일 프리셋 (Android 15종 완전 일치)

enum CaptionStylePreset: String, CaseIterable, Identifiable, Sendable {
    case readable = "가독성"
    case lovely = "러블리"
    case strong = "강력햐"
    case fresh = "청량"
    case travel = "여행"
    case cinema = "시네마"
    case daily = "데일리"
    case sentimental = "감성"
    case greenGolf = "그린골프"
    case magazine = "매거진"
    case sports = "스포츠"
    case clean = "클린"
    case neon = "네온"
    case vlog = "VLOG"
    case pop = "POP"

    var id: String { rawValue }
    var title: String { rawValue }

    var fontName: String {
        switch self {
        case .readable: return "pretendard"
        case .lovely: return "ddulgi_mayo"
        case .strong: return "tenada"
        case .fresh: return "gowun_dodum"
        case .travel: return "gowun_batang"
        case .cinema: return "black_han_sans"
        case .daily: return "do_hyeon"
        case .sentimental: return "gowun_batang"
        case .greenGolf: return "do_hyeon"
        case .magazine: return "paperlogy_bold"
        case .sports: return "paperlogy_bold"
        case .clean: return "nexon_lv1_gothic"
        case .neon: return "nexon_lv1_gothic"
        case .vlog: return "poppins"
        case .pop: return "poppins"
        }
    }

    var previewTextColorHex: String {
        switch self {
        case .readable: return "#FFFFFF"
        case .lovely: return "#FF6FAE"
        case .strong: return "#FFE600"
        case .fresh: return "#FFFFFF"
        case .travel: return "#FFF3D6"
        case .cinema: return "#F8F3E7"
        case .daily: return "#FFFFFF"
        case .sentimental: return "#FFE9F0"
        case .greenGolf: return "#FFFFFF"
        case .magazine: return "#FFF4D6"
        case .sports: return "#D8FF3E"
        case .clean: return "#FFFFFF"
        case .neon: return "#7DF9FF"
        case .vlog: return "#FFFFFF"
        case .pop: return "#FFE45C"
        }
    }

    var shadowColorHex: String {
        switch self {
        case .readable: return "#000000"
        case .lovely: return "#7A3FFF"
        case .strong: return "#000000"
        case .fresh: return "#18A8FF"
        case .travel: return "#3F6F63"
        case .cinema: return "#141414"
        case .daily: return "#FF7A3D"
        case .sentimental: return "#6E5BFF"
        case .greenGolf: return "#10B85A"
        case .magazine: return "#D94A32"
        case .sports: return "#10223A"
        case .clean: return "#1B4D89"
        case .neon: return "#6C2BFF"
        case .vlog: return "#FF6B5E"
        case .pop: return "#642BFF"
        }
    }

    var fontSize: CaptionSize {
        switch self {
        case .readable, .lovely, .fresh, .travel, .daily, .clean, .neon, .vlog:
            return .large
        case .strong, .cinema, .greenGolf, .magazine, .sports, .pop:
            return .xlarge
        case .sentimental:
            return .normal
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .readable, .lovely, .strong, .fresh, .travel, .daily, .sentimental, .greenGolf:
            return 0.5
        case .cinema: return 0.5
        case .magazine, .vlog: return 0.55
        case .sports: return 0.7
        case .clean: return 0.35
        case .neon: return 0.8
        case .pop: return 0.75
        }
    }

    var lineSpacing: Double { 1.0 }

    func matches(fontName: String, fontSize: CaptionSize, textColorHex: String, shadowColorHex: String, shadowOpacity: Double, lineSpacing: Double) -> Bool {
        self.fontName == fontName &&
        self.fontSize == fontSize &&
        self.previewTextColorHex.uppercased() == textColorHex.uppercased() &&
        self.shadowColorHex.uppercased() == shadowColorHex.uppercased() &&
        abs(self.shadowOpacity - shadowOpacity) < 0.08 &&
        abs(self.lineSpacing - lineSpacing) < 0.08
    }
}

// MARK: - 색상 유틸리티 & RGB 반전 계산

enum CaptionColorUtil {
    static let textQuickSwatches: [String] = [
        "#FFFFFF", // 흰색
        "#111111", // 먹색
        "#FFE45C", // 노랑
        "#8FD3FF", // 하늘
        "#FF9EC7", // 분홍
        "#8EF0C8"  // 민트
    ]

    static let shadowQuickSwatches: [String] = [
        "#000000", // 검정
        "#FFFFFF", // 흰색
        "#1A2A6C", // 남색
        "#642BFF", // 보라
        "#18A8FF", // 파랑
        "#3F6F63"  // 초록
    ]

    /// HanClip 완전 동일: 불투명 1-r, 1-g, 1-b 반전 색상 계산
    static func calculateRGBInverse(hex: String) -> String {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let val = UInt64(clean, radix: 16) else { return "#000000" }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        let invR = Int(((1.0 - r) * 255.0).rounded())
        let invG = Int(((1.0 - g) * 255.0).rounded())
        let invB = Int(((1.0 - b) * 255.0).rounded())
        return String(format: "#%02X%02X%02X", invR, invG, invB)
    }

    static func color(fromHex hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r, g, b: Double
        if clean.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 1.0; g = 1.0; b = 1.0
        }
        return Color(red: r, green: g, blue: b)
    }

    static func hex(fromColor color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let intR = Int((r * 255).rounded())
            let intG = Int((g * 255).rounded())
            let intB = Int((b * 255).rounded())
            return String(format: "#%02X%02X%02X", intR, intG, intB)
        }
        return "#FFFFFF"
    }

    static func hsv(fromHex hex: String) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r, g, b: CGFloat
        if clean.count == 6 {
            r = CGFloat((int >> 16) & 0xFF) / 255.0
            g = CGFloat((int >> 8) & 0xFF) / 255.0
            b = CGFloat(int & 0xFF) / 255.0
        } else {
            r = 1.0; g = 1.0; b = 1.0
        }
        let ui = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (h, s, v)
    }

    static func hex(h: CGFloat, s: CGFloat, v: CGFloat) -> String {
        let ui = UIColor(hue: h, saturation: s, brightness: v, alpha: 1.0)
        return hex(fromColor: ui)
    }
}

// MARK: - 날짜 포맷터 (HanClip 완전 동일)

enum CaptionDateFormatter {
    private static let singleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yy. M. d. (EEE)"
        return f
    }()

    static func single(date: Date = Date()) -> String {
        singleFormatter.string(from: date)
    }

    static func range(dates: [Date], fallbackDate: Date = Date()) -> String {
        let valid = dates.filter { $0.timeIntervalSince1970 > 0 }
        let sorted = valid.sorted()
        let first = sorted.first ?? fallbackDate
        let last = sorted.last ?? first
        let firstText = single(date: first).replacingOccurrences(of: ". (", with: ".(")
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return firstText
        }
        let lastText = single(date: last).replacingOccurrences(of: ". (", with: ".(")
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        return "\(firstText) ~\u{00A0}\(lastText)"
    }
}

// MARK: - 공용 자막 렌더러 (미리보기 및 MP4 내보내기 공용)

enum TrailerCaptionRenderer {
    static let safeMargin: CGFloat = 0.08

    static func renderImage(
        text: String,
        fontName: String,
        captionSize: CaptionSize,
        textColorHex: String,
        hasShadow: Bool,
        shadowColorHex: String,
        shadowOpacity: Double,
        lineSpacing: Double,
        column: Int,
        row: Int,
        renderSize: CGSize
    ) -> UIImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, renderSize.width > 0, renderSize.height > 0 else { return nil }

        let safeLeft = renderSize.width * safeMargin
        let safeTop = renderSize.height * safeMargin
        let safeWidth = max(1.0, renderSize.width * (1.0 - 2.0 * safeMargin))
        let safeHeight = max(1.0, renderSize.height * (1.0 - 2.0 * safeMargin))

        let col = min(4, max(0, column))
        let r = min(4, max(0, row))

        let alignment: NSTextAlignment
        switch col {
        case 0, 1: alignment = .left
        case 2: alignment = .center
        default: alignment = .right
        }

        let shortEdge = min(renderSize.width, renderSize.height)
        var textSize = shortEdge * CGFloat(captionSize.shortEdgeFraction)
        let minTextSize = max(6.0, shortEdge * 0.012)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        var layoutFont: UIFont = .systemFont(ofSize: textSize, weight: .bold)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measuredSize: CGSize = .zero
        var shadowPad: CGFloat = 0
        // 1보다 좁은 줄 간격의 배수(Android StaticLayout 배수와 같은 기준). 보통·넓게는 1이라 아래 값이 모두 그대로다.
        let narrowFactor = lineSpacing < 1.0 ? max(0.5, lineSpacing) : 1.0
        var firstLineInset: CGFloat = 0

        // 안전 영역 안에 들어가도록 폰트 크기 축소 반복
        while true {
            layoutFont = TrailerCaptionFontStore.uiFont(fontName: fontName, size: textSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            let spacingBonus = max(0, (lineSpacing - 1.0) * Double(textSize) * 0.4)
            paragraph.lineSpacing = CGFloat(spacingBonus)
            // lineSpacing은 음수를 쓸 수 없어 줄 높이 배수로 줄인다. 줄은 위쪽부터 줄어 첫 줄 글자가 블록 위로 나가므로 그만큼 아래로 내린다.
            if narrowFactor < 1.0 { paragraph.lineHeightMultiple = CGFloat(narrowFactor) }
            firstLineInset = narrowFactor < 1.0 ? ceil(layoutFont.lineHeight * CGFloat(1.0 - narrowFactor)) : 0

            let textColor = UIColor(CaptionColorUtil.color(fromHex: textColorHex))
            attributes = [
                .font: layoutFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]

            shadowPad = hasShadow ? textSize * 0.12 : 0
            let bounding = (trimmed as NSString).boundingRect(
                with: CGSize(width: safeWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            measuredSize = CGSize(width: min(safeWidth, ceil(bounding.width)), height: ceil(bounding.height))

            if measuredSize.height + firstLineInset + shadowPad <= safeHeight || textSize <= minTextSize {
                break
            }
            textSize = max(minTextSize, textSize * 0.88)
        }

        let fullHeight = measuredSize.height + firstLineInset + shadowPad
        let drawScale: CGFloat = fullHeight > safeHeight ? safeHeight / fullHeight : 1.0
        let blockWidth = min(safeWidth, measuredSize.width)
        let free = safeWidth - blockWidth
        let currentLeft: CGFloat
        switch alignment {
        case .center: currentLeft = free / 2.0
        case .right: currentLeft = free
        default: currentLeft = 0.0
        }

        let scaledFree = safeWidth - blockWidth * drawScale
        let dx = CGFloat(col) / 4.0 * scaledFree - currentLeft * drawScale
        let blockHeight = fullHeight * drawScale
        let dy = CGFloat(r) / 4.0 * (safeHeight - blockHeight)

        let drawX = safeLeft + dx
        let drawY = safeTop + dy

        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()

            if hasShadow {
                let sColor = UIColor(CaptionColorUtil.color(fromHex: shadowColorHex))
                    .withAlphaComponent(CGFloat(min(1.0, max(0.0, shadowOpacity))))
                let blur = textSize * 0.08 * drawScale
                let offset = CGSize(width: textSize * 0.035 * drawScale, height: textSize * 0.04 * drawScale)
                cg.setShadow(offset: offset, blur: blur, color: sColor.cgColor)
            }

            if drawScale < 1.0 {
                cg.translateBy(x: drawX, y: drawY)
                cg.scaleBy(x: drawScale, y: drawScale)
                (trimmed as NSString).draw(
                    in: CGRect(x: 0, y: firstLineInset, width: safeWidth, height: measuredSize.height),
                    withAttributes: attributes
                )
            } else {
                (trimmed as NSString).draw(
                    in: CGRect(x: drawX, y: drawY + firstLineInset, width: safeWidth, height: measuredSize.height),
                    withAttributes: attributes
                )
            }

            cg.restoreGState()
        }
    }
}

// MARK: - 인라인 컬러 피커 (SV 그래디언트 88pt + Hue 밴드 48pt 터치)

struct InlineColorPickerView: View {
    @Binding var hexColor: String
    let onColorChange: ((String) -> Void)?

    @State private var currentHue: CGFloat = 0.0
    @State private var currentSat: CGFloat = 0.0
    @State private var currentVal: CGFloat = 1.0
    @State private var hasInitialized = false

    init(hexColor: Binding<String>, onColorChange: ((String) -> Void)? = nil) {
        self._hexColor = hexColor
        self.onColorChange = onColorChange
    }

    var body: some View {
        VStack(spacing: 6) {
            // SV 그라디언트 사각형 (고정 88pt)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    // 배경 색상 베이스
                    Color(hue: Double(currentHue), saturation: 1.0, brightness: 1.0)

                    // 가로 흰색 채도 그래디언트
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    // 세로 검정 명도 그래디언트
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // 선택 지점 인디케이터
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .background(Circle().fill(Color(hue: Double(currentHue), saturation: Double(currentSat), brightness: Double(currentVal))))
                        .frame(width: 18, height: 18)
                        .shadow(radius: 2)
                        .offset(
                            x: min(max(0, currentSat * w - 9), w - 18),
                            y: min(max(0, (1.0 - currentVal) * h - 9), h - 18)
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let sat = min(1.0, max(0.0, val.location.x / max(1.0, w)))
                            let v = min(1.0, max(0.0, 1.0 - (val.location.y / max(1.0, h))))
                            currentSat = sat
                            currentVal = v
                            let newHex = CaptionColorUtil.hex(h: currentHue, s: currentSat, v: currentVal)
                            hexColor = newHex
                            onColorChange?(newHex)
                        }
                )
            }
            .frame(height: 88)

            // Hue 밴드 (터치 타겟 48pt 높이 유지)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [
                            Color(hue: 0.0, saturation: 1, brightness: 1),
                            Color(hue: 0.17, saturation: 1, brightness: 1),
                            Color(hue: 0.33, saturation: 1, brightness: 1),
                            Color(hue: 0.5, saturation: 1, brightness: 1),
                            Color(hue: 0.67, saturation: 1, brightness: 1),
                            Color(hue: 0.83, saturation: 1, brightness: 1),
                            Color(hue: 1.0, saturation: 1, brightness: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // Hue 슬라이더 손잡이
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .background(Circle().fill(Color(hue: Double(currentHue), saturation: 1, brightness: 1)))
                        .frame(width: 22, height: 22)
                        .shadow(radius: 2)
                        .offset(x: min(max(0, currentHue * w - 11), w - 22))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let hVal = min(1.0, max(0.0, val.location.x / max(1.0, w)))
                            currentHue = hVal
                            let newHex = CaptionColorUtil.hex(h: currentHue, s: currentSat, v: currentVal)
                            hexColor = newHex
                            onColorChange?(newHex)
                        }
                )
            }
            .frame(height: 48)
        }
        .onAppear {
            syncHSVFromHex()
        }
        .onChange(of: hexColor) { _, _ in
            syncHSVFromHex()
        }
    }

    private func syncHSVFromHex() {
        let (h, s, v) = CaptionColorUtil.hsv(fromHex: hexColor)
        currentHue = h
        currentSat = s
        currentVal = v
        hasInitialized = true
    }
}

// MARK: - 자막 적용 범위

enum CaptionApplyScope: String, CaseIterable, Identifiable, Sendable {
    case current = "현재 클립"
    case selected = "선택 클립"
    case all = "전체 영상"

    var id: String { rawValue }
}

// MARK: - 카드 A: 내용과 위치

struct TrailerCaptionContentLocationCard: View {
    @ObservedObject var captionDraft: TrailerCaptionDraft
    let sources: [VideoTrailerSource]
    let selectedIDs: Set<Int>
    @Binding var scope: CaptionApplyScope
    let onApply: () -> Void

    init(
        captionDraft: TrailerCaptionDraft,
        sources: [VideoTrailerSource],
        selectedIDs: Set<Int>,
        scope: Binding<CaptionApplyScope>,
        onApply: @escaping () -> Void
    ) {
        self.captionDraft = captionDraft
        self.sources = sources
        self.selectedIDs = selectedIDs
        self._scope = scope
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("내용과 위치")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                // 1. 적용 범위 (3등분) + 우측 적용 버튼
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(CaptionApplyScope.allCases) { sc in
                            let isSelected = scope == sc
                            Button {
                                scope = sc
                                captionDraft.isDirty = true
                            } label: {
                                Text(sc.rawValue)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? PorcelainMetrics.accent : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(
                                        isSelected ? PorcelainMetrics.accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("적용 범위: \(sc.rawValue)")
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        }
                    }

                    let isApplyDisabled = !captionDraft.isDirty && captionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        captionDraft.isDirty = true
                        onApply()
                    } label: {
                        Text("적용")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(isApplyDisabled ? .secondary : (captionDraft.isDirty ? .white : PorcelainMetrics.accent))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .background(
                                isApplyDisabled ? Color(uiColor: .tertiarySystemFill) : (captionDraft.isDirty ? PorcelainMetrics.accent : PorcelainMetrics.accent.opacity(0.15)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplyDisabled)
                }

                // 2. 전체 폭 텍스트 입력창 (최대 2000자)
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("자막 문구를 입력하세요 (최대 2000자)", text: Binding(
                        get: { captionDraft.text },
                        set: { val in
                            captionDraft.text = String(val.prefix(2000))
                            captionDraft.isDirty = true
                        }
                    ), axis: .vertical)
                    .lineLimit(2...)
                    .lineSpacing(CGFloat(captionDraft.lineSpacing))
                    .font(.system(size: 14))
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))

                    if captionDraft.text.count > 1800 {
                        Text("\(captionDraft.text.count)/2000")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 3. 5x5 위치 격자 (160x160) + 우측 날짜 버튼 (76 + 8 + 76 = 160)
                GeometryReader { geo in
                    let isWide = geo.size.width >= 310
                    if isWide {
                        HStack(alignment: .top, spacing: 10) {
                            positionGrid
                                .frame(width: 160, height: 160)

                            VStack(spacing: 8) {
                                todayDateButton
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                captureRangeButton
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(height: 160)
                        }
                    } else {
                        VStack(spacing: 10) {
                            positionGrid
                                .frame(width: 160, height: 160)
                                .frame(maxWidth: .infinity, alignment: .center)

                            HStack(spacing: 8) {
                                todayDateButton
                                    .frame(maxWidth: .infinity, minHeight: 48)

                                captureRangeButton
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                        }
                    }
                }
                .frame(minHeight: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
        }
    }

    private func positionAccessibilityLabel(row: Int, column: Int) -> String {
        let rowNames = ["맨 위", "위", "가운데", "아래", "맨 아래"]
        let colNames = ["맨 왼쪽", "왼쪽", "가운데", "오른쪽", "맨 오른쪽"]
        let rName = rowNames[min(max(row, 0), 4)]
        let cName = colNames[min(max(column, 0), 4)]
        if row == 2 && column == 2 {
            return "자막 위치 정가운데"
        }
        return "자막 위치 \(rName) \(cName)"
    }

    private var positionGrid: some View {
        VStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { c in
                        let isSelected = captionDraft.column == c && captionDraft.row == r
                        Button {
                            captionDraft.column = c
                            captionDraft.row = r
                            captionDraft.isDirty = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? PorcelainMetrics.accent : Color(uiColor: .tertiarySystemFill))

                                if isSelected {
                                    Text("T")
                                        .font(.system(size: 13, weight: .black))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.45))
                                        .frame(width: 4, height: 4)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(positionAccessibilityLabel(row: r, column: c))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var todayDateButton: some View {
        Button {
            let today = CaptionDateFormatter.single()
            if captionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                captionDraft.text = today
            } else {
                captionDraft.text = captionDraft.text + " " + today
            }
            captionDraft.isDirty = true
        } label: {
            VStack(spacing: 4) {
                Image(interfaceSystemName: "calendar", pointSize: 18, tintable: true)
                    .font(.system(size: 18, weight: .semibold))
                Text("오늘 날짜")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(PorcelainMetrics.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var captureRangeButton: some View {
        Button {
            let dates = sources.compactMap(\.captureDate)
            let rangeText = CaptionDateFormatter.range(dates: dates)
            if captionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                captionDraft.text = rangeText
            } else {
                captionDraft.text = captionDraft.text + " " + rangeText
            }
            captionDraft.isDirty = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                Text("촬영 기간")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(PorcelainMetrics.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 카드 B: 스타일과 글꼴

struct TrailerCaptionStyleFontCard: View {
    @ObservedObject var captionDraft: TrailerCaptionDraft
    @State private var openCatalogIndex: Int? = 0 // 0 = 스타일 열림, 1 = 글꼴 열림, nil = 접힘
    @State private var isShowingFileImporter = false
    @State private var importedFontsList: [CaptionFontItem] = []

    init(captionDraft: TrailerCaptionDraft) {
        self.captionDraft = captionDraft
    }

    private var matchingPreset: CaptionStylePreset? {
        CaptionStylePreset.allCases.first { preset in
            preset.matches(
                fontName: captionDraft.fontName,
                fontSize: captionDraft.captionSize,
                textColorHex: captionDraft.colorHex,
                shadowColorHex: captionDraft.shadowColorHex,
                shadowOpacity: captionDraft.shadowOpacity,
                lineSpacing: captionDraft.lineSpacing
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("스타일과 글꼴")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                // 1. 스타일 헤더 (전체 폭 48pt 디스클로저)
                disclosureHeader(
                    title: "스타일",
                    value: matchingPreset?.title ?? "사용자 설정",
                    isOpen: openCatalogIndex == 0
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        openCatalogIndex = openCatalogIndex == 0 ? nil : 0
                    }
                }

                if openCatalogIndex == 0 {
                    styleCatalogGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                // 2. 글꼴 헤더 (전체 폭 48pt 디스클로저)
                disclosureHeader(
                    title: "글꼴",
                    value: TrailerCaptionFontStore.displayName(id: captionDraft.fontName),
                    isOpen: openCatalogIndex == 1
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        openCatalogIndex = openCatalogIndex == 1 ? nil : 1
                    }
                }

                if openCatalogIndex == 1 {
                    fontCatalogGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
        }
        .onAppear {
            importedFontsList = TrailerCaptionFontStore.shared.listImportedFonts()
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.font, UTType(filenameExtension: "ttf")!, UTType(filenameExtension: "otf")!]
        ) { result in
            if case .success(let url) = result {
                if let newID = try? TrailerCaptionFontStore.shared.importFont(from: url) {
                    importedFontsList = TrailerCaptionFontStore.shared.listImportedFonts()
                    captionDraft.fontName = newID
                    captionDraft.isDirty = true
                }
            }
        }
    }

    private func disclosureHeader(title: String, value: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Image(interfaceSystemName: isOpen ? "chevron.up" : "chevron.down", pointSize: 13, tintable: true)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var styleCatalogGrid: some View {
        let cols = UIDevice.current.userInterfaceIdiom == .phone ? 2 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(CaptionStylePreset.allCases) { preset in
                let isSelected = matchingPreset == preset
                Button {
                    captionDraft.fontName = preset.fontName
                    captionDraft.colorHex = preset.previewTextColorHex
                    captionDraft.shadowColorHex = preset.shadowColorHex
                    captionDraft.captionSize = preset.fontSize
                    captionDraft.shadowOpacity = preset.shadowOpacity
                    captionDraft.lineSpacing = preset.lineSpacing
                    captionDraft.hasShadow = preset.shadowOpacity > 0
                    captionDraft.isDirty = true
                } label: {
                    HStack(spacing: 4) {
                        // Aa 뱃지
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(CaptionColorUtil.color(fromHex: preset.shadowColorHex))

                            Text("Aa")
                                .font(Font(TrailerCaptionFontStore.uiFont(fontName: preset.fontName, size: 14)))
                                .foregroundStyle(CaptionColorUtil.color(fromHex: preset.previewTextColorHex))
                        }
                        .frame(width: 24, height: 24)

                        Text(preset.title)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? PorcelainMetrics.accent : .primary)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        if isSelected {
                            Image(interfaceSystemName: "checkmark", pointSize: 12, tintable: true)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(PorcelainMetrics.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        isSelected ? PorcelainMetrics.accent.opacity(0.08) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: isSelected ? 1.5 : 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fontCatalogGrid: some View {
        let cols = UIDevice.current.userInterfaceIdiom == .phone ? 2 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
        let allFonts = TrailerCaptionFontStore.bundledFonts + importedFontsList

        return VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(allFonts) { item in
                    let isSelected = captionDraft.fontName == item.id
                    Button {
                        captionDraft.fontName = item.id
                        captionDraft.isDirty = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.displayName)
                                .font(Font(TrailerCaptionFontStore.uiFont(fontName: item.id, size: 14)))
                                .foregroundStyle(isSelected ? PorcelainMetrics.accent : .primary)
                                .lineLimit(2)

                            Spacer(minLength: 0)

                            if isSelected {
                                Image(interfaceSystemName: "checkmark", pointSize: 12, tintable: true)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(PorcelainMetrics.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            isSelected ? PorcelainMetrics.accent.opacity(0.08) : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: isSelected ? 1.5 : 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                isShowingFileImporter = true
            } label: {
                Label("사용자 글꼴 가져오기 (TTF/OTF)", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 카드 C: 세부 조절

struct TrailerCaptionDetailedAdjustmentCard: View {
    @ObservedObject var captionDraft: TrailerCaptionDraft

    init(captionDraft: TrailerCaptionDraft) {
        self.captionDraft = captionDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("세부 조절")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                // 1. 크기 (4종 선택: 작게, 기본, 크게, 더크게)
                VStack(alignment: .leading, spacing: 4) {
                    Text("크기")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(CaptionSize.allCases) { sizeOption in
                            let isSelected = captionDraft.captionSize == sizeOption
                            Button {
                                captionDraft.captionSize = sizeOption
                                captionDraft.isDirty = true
                            } label: {
                                Text(sizeOption.rawValue)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? PorcelainMetrics.accent : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(
                                        isSelected ? PorcelainMetrics.accent.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: isSelected ? 1.5 : 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                // 2. 두 개의 동일한 열: 글자 색상(좌) 및 그림자(우)
                HStack(alignment: .top, spacing: 12) {
                    // 좌측: 글자 색상
                    VStack(alignment: .leading, spacing: 6) {
                        Text("글자 색상")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(height: 32, alignment: .leading)

                        // 정확히 6개 퀵 스와치
                        quickSwatchesRow(
                            swatches: CaptionColorUtil.textQuickSwatches,
                            selectedHex: captionDraft.colorHex
                        ) { newHex in
                            captionDraft.colorHex = newHex
                            // 텍스트 명시적 선택 시 그림자를 불투명 RGB 반전으로 자동 변경
                            let inv = CaptionColorUtil.calculateRGBInverse(hex: newHex)
                            captionDraft.shadowColorHex = inv
                            captionDraft.isDirty = true
                        }

                        // 인라인 SV 그라디언트 88pt + Hue 48pt
                        InlineColorPickerView(hexColor: Binding(
                            get: { captionDraft.colorHex },
                            set: { next in
                                captionDraft.colorHex = next
                                let inv = CaptionColorUtil.calculateRGBInverse(hex: next)
                                captionDraft.shadowColorHex = inv
                                captionDraft.isDirty = true
                            }
                        ))
                    }
                    .frame(maxWidth: .infinity)

                    // 우측: 그림자
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("그림자")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { captionDraft.hasShadow },
                                set: { captionDraft.hasShadow = $0; captionDraft.isDirty = true }
                            ))
                            .labelsHidden()
                            .controlSize(.small)
                        }
                        .frame(height: 32, alignment: .leading)

                        // 정확히 6개 퀵 스와치
                        quickSwatchesRow(
                            swatches: CaptionColorUtil.shadowQuickSwatches,
                            selectedHex: captionDraft.shadowColorHex
                        ) { newHex in
                            captionDraft.shadowColorHex = newHex
                            captionDraft.isDirty = true
                        }
                        .disabled(!captionDraft.hasShadow)
                        .opacity(captionDraft.hasShadow ? 1 : 0.4)

                        // 인라인 SV 그라디언트 88pt + Hue 48pt
                        InlineColorPickerView(hexColor: Binding(
                            get: { captionDraft.shadowColorHex },
                            set: { next in
                                captionDraft.shadowColorHex = next
                                captionDraft.isDirty = true
                            }
                        ))
                        .disabled(!captionDraft.hasShadow)
                        .opacity(captionDraft.hasShadow ? 1 : 0.4)

                        // 그림자 불투명도 조절
                        HStack {
                            Text("불투명도")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((captionDraft.shadowOpacity * 100).rounded()))%")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { captionDraft.shadowOpacity },
                            set: { captionDraft.shadowOpacity = $0; captionDraft.isDirty = true }
                        ), in: 0...1)
                        .disabled(!captionDraft.hasShadow)
                        .opacity(captionDraft.hasShadow ? 1 : 0.4)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider()

                // 3. 줄 간격 선택지 및 +/- (마지막)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("줄 간격")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text(String(format: "%.1f×", captionDraft.lineSpacing))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        let spacingOptions: [(String, Double)] = [
                            ("좁게", 0.8),
                            ("보통", 1.0),
                            ("넓게", 1.2),
                            ("더 넓게", 1.5)
                        ]
                        ForEach(spacingOptions, id: \.0) { title, val in
                            let isSelected = abs(captionDraft.lineSpacing - val) < 0.05
                            Button {
                                captionDraft.lineSpacing = val
                                captionDraft.isDirty = true
                            } label: {
                                Text(title)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? PorcelainMetrics.accent : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(
                                        isSelected ? PorcelainMetrics.accent.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: isSelected ? 1.5 : 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        // Stepper - / +
                        HStack(spacing: 4) {
                            Button {
                                captionDraft.lineSpacing = max(0.5, captionDraft.lineSpacing - 0.1)
                                captionDraft.isDirty = true
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 38, height: 40)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)

                            Button {
                                captionDraft.lineSpacing = min(2.0, captionDraft.lineSpacing + 0.1)
                                captionDraft.isDirty = true
                            } label: {
                                Image(interfaceSystemName: "plus", pointSize: 14, tintable: true)
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 38, height: 40)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
        }
    }

    private func swatchColorName(hex: String) -> String {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        switch clean {
        case "FFFFFF": return "흰색"
        case "000000": return "검은색"
        case "FFFF00", "FFE600", "FFD700": return "노란색"
        case "FF0000", "FF3B30", "E53935": return "빨간색"
        case "00FF00", "34C759", "4CAF50": return "초록색"
        case "0000FF", "007AFF", "2196F3": return "파란색"
        case "8E8E93", "808080", "9E9E9E": return "회색"
        case "FF9500", "FF9800": return "주황색"
        default: return "#\(clean)"
        }
    }

    private func quickSwatchesRow(swatches: [String], selectedHex: String, onSelect: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 0) {
            ForEach(swatches, id: \.self) { hex in
                let isSelected = selectedHex.uppercased() == hex.uppercased()
                Button {
                    onSelect(hex)
                } label: {
                    Circle()
                        .fill(CaptionColorUtil.color(fromHex: hex))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? PorcelainMetrics.accent : Color.gray.opacity(0.35), lineWidth: isSelected ? 2.5 : 1)
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(swatchColorName(hex: hex)) 색상")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}
