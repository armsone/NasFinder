import SwiftUI
import WidgetKit

private struct NasFinderLockEntry: TimelineEntry {
    let date: Date
}

private struct NasFinderLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> NasFinderLockEntry {
        NasFinderLockEntry(date: .now)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (NasFinderLockEntry) -> Void
    ) {
        completion(NasFinderLockEntry(date: .now))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<NasFinderLockEntry>) -> Void
    ) {
        completion(Timeline(entries: [NasFinderLockEntry(date: .now)], policy: .never))
    }
}

/// The three discovery waves from the simplified NasFinder icon.
private struct NASWaves: Shape {
    func path(in rect: CGRect) -> Path {
        let dimension = min(rect.width, rect.height)
        let scale = dimension / 100
        let originX = rect.midX - dimension / 2
        let originY = rect.midY - dimension / 2
        let curveConstant: CGFloat = 0.552_284_749_8

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        let radii: [(x: CGFloat, y: CGFloat)] = [(39, 34), (27, 22), (15, 10)]

        for radius in radii {
            path.move(to: point(50 - radius.x, 42))
            path.addCurve(
                to: point(50, 42 - radius.y),
                control1: point(50 - radius.x, 42 - curveConstant * radius.y),
                control2: point(50 - curveConstant * radius.x, 42 - radius.y)
            )
            path.addCurve(
                to: point(50 + radius.x, 42),
                control1: point(50 + curveConstant * radius.x, 42 - radius.y),
                control2: point(50 + radius.x, 42 - curveConstant * radius.y)
            )
        }

        return path.strokedPath(
            StrokeStyle(lineWidth: 6 * scale, lineCap: .butt, lineJoin: .round)
        )
    }
}

/// The vertical discovery beam that distinguishes the detailed widget artwork.
private struct NASBeacon: Shape {
    func path(in rect: CGRect) -> Path {
        let dimension = min(rect.width, rect.height)
        let scale = dimension / 100
        let originX = rect.midX - dimension / 2
        let originY = rect.midY - dimension / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var beam = Path()
        beam.move(to: point(50, 8))
        beam.addLine(to: point(50, 49))

        var path = beam.strokedPath(
            StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)
        )
        path.addEllipse(
            in: CGRect(
                x: originX + 46.5 * scale,
                y: originY + 4.5 * scale,
                width: 7 * scale,
                height: 7 * scale
            )
        )
        return path
    }
}

/// The two-bay NAS body from the simplified icon. Even-odd filling cuts out
/// both bays and their indicator lights while preserving a bold silhouette.
private struct NASChassis: Shape {
    func path(in rect: CGRect) -> Path {
        let dimension = min(rect.width, rect.height)
        let scale = dimension / 100
        let originX = rect.midX - dimension / 2
        let originY = rect.midY - dimension / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: originX + x * scale,
                y: originY + y * scale,
                width: width * scale,
                height: height * scale
            )
        }

        func roundedRectangle(_ rect: CGRect, cornerRadius: CGFloat) -> Path {
            RoundedRectangle(
                cornerRadius: cornerRadius * scale,
                style: .continuous
            ).path(in: rect)
        }

        var path = Path()
        path.move(to: point(19, 46))
        path.addLine(to: point(81, 46))
        path.addQuadCurve(to: point(86, 49), control: point(84, 46))
        path.addLine(to: point(90, 53))
        path.addQuadCurve(to: point(92, 59), control: point(92, 55))
        path.addLine(to: point(92, 77))
        path.addQuadCurve(to: point(87, 85), control: point(92, 82))
        path.addLine(to: point(83, 87))
        path.addLine(to: point(80, 91))
        path.addQuadCurve(to: point(77, 92), control: point(79, 92))
        path.addLine(to: point(69, 92))
        path.addLine(to: point(65, 86))
        path.addLine(to: point(35, 86))
        path.addLine(to: point(31, 92))
        path.addLine(to: point(22, 92))
        path.addQuadCurve(to: point(18, 89), control: point(19, 92))
        path.addLine(to: point(16, 85))
        path.addQuadCurve(to: point(8, 77), control: point(8, 82))
        path.addLine(to: point(8, 59))
        path.addQuadCurve(to: point(11, 52), control: point(8, 55))
        path.addLine(to: point(16, 48))
        path.addQuadCurve(to: point(19, 46), control: point(17, 46))
        path.closeSubpath()

        path.addPath(roundedRectangle(box(12, 54, 76, 30), cornerRadius: 5))
        path.addPath(roundedRectangle(box(16, 57, 68, 12), cornerRadius: 3))
        path.addPath(roundedRectangle(box(16, 72, 68, 11), cornerRadius: 3))
        path.addPath(roundedRectangle(box(22, 59, 3, 7), cornerRadius: 1.5))
        path.addPath(roundedRectangle(box(22, 74, 3, 7), cornerRadius: 1.5))
        path.addEllipse(in: box(72, 80, 4, 4))
        path.addEllipse(in: box(79, 80, 4, 4))
        return path
    }
}

private struct NasFinderAccessoryGlyph: View {
    var body: some View {
        ZStack {
            NASWaves()
                .fill(.primary)
            NASBeacon()
                .fill(.primary)
            NASChassis()
                .fill(.primary, style: FillStyle(eoFill: true))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct NasFinderLockWidgetView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            NasFinderAccessoryGlyph()
                .foregroundStyle(.primary)
                .widgetAccentable()
                .padding(2)
                .unredacted()
        }
        .unredacted()
        .widgetLabel("NasFinder 열기")
        .containerBackground(.clear, for: .widget)
        .widgetURL(URL(string: "nasfinder://open"))
        .accessibilityLabel("NasFinder 열기")
    }
}

@main
struct NasFinderLockWidget: Widget {
    private let kind = "com.armsone.nasfinder.lock-screen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NasFinderLockProvider()) { _ in
            NasFinderLockWidgetView()
        }
        .configurationDisplayName("NasFinder 바로 열기")
        .description("잠금 화면에서 NasFinder를 바로 엽니다.")
        .supportedFamilies([.accessoryCircular])
    }
}
