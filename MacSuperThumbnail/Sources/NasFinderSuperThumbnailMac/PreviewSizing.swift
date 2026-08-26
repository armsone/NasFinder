import Foundation

/// Sizing rules for the resizable preview strip. The user drags a horizontal
/// handle below the strip: dragging down grows the strip (and its cards),
/// dragging up shrinks it. All values are points; the view layer applies them
/// directly so the strip and cards stay in step during a live drag.
enum SuperThumbnailPreviewSizing {
    /// Smallest strip height. Matches the previous fixed strip so the
    /// original 112pt cards remain reachable as the lower bound.
    static let minimumHeight: CGFloat = 176
    /// Default is deliberately larger than the old 176pt strip.
    static let defaultHeight: CGFloat = 300
    /// Absolute ceiling regardless of window size.
    static let maximumHeight: CGFloat = 560
    /// Height change per keyboard / VoiceOver adjustable step.
    static let stepHeight: CGFloat = 24
    /// Vertical space the strip needs around a card: top/bottom padding,
    /// the name label and the scroll indicator. `176 - 64 == 112`, so the
    /// minimum strip still yields the original card size.
    static let cardChromeHeight: CGFloat = 64
    /// Room kept for the other cards, header and footer when the window is
    /// short, so the preview can never push the controls out of reach.
    static let reservedHeightAroundPreview: CGFloat = 180

    enum StepDirection {
        case increment
        case decrement
    }

    /// Upper bound that also respects the space actually available in the
    /// window's scrollable content area. `nil` means "unknown", which falls
    /// back to the absolute maximum.
    static func maximumHeight(availableHeight: CGFloat?) -> CGFloat {
        guard let availableHeight, availableHeight.isFinite, availableHeight > 0 else {
            return maximumHeight
        }
        let fitted = availableHeight - reservedHeightAroundPreview
        return min(maximumHeight, max(minimumHeight, fitted))
    }

    static func clamped(_ height: CGFloat, availableHeight: CGFloat? = nil) -> CGFloat {
        guard height.isFinite else { return defaultHeight }
        let upper = maximumHeight(availableHeight: availableHeight)
        return min(upper, max(minimumHeight, height))
    }

    /// Height while dragging the handle. A positive `dragTranslation` (moving
    /// the pointer down) makes the strip taller.
    static func resized(
        from baseHeight: CGFloat,
        dragTranslation: CGFloat,
        availableHeight: CGFloat? = nil
    ) -> CGFloat {
        clamped(baseHeight + dragTranslation, availableHeight: availableHeight)
    }

    static func stepped(
        _ height: CGFloat,
        _ direction: StepDirection,
        availableHeight: CGFloat? = nil
    ) -> CGFloat {
        let delta = direction == .increment ? stepHeight : -stepHeight
        return clamped(height + delta, availableHeight: availableHeight)
    }

    /// Square side of the newest (leading) card for a given strip height.
    static func cardSide(forStripHeight height: CGFloat) -> CGFloat {
        max(minimumHeight - cardChromeHeight, height - cardChromeHeight)
    }

    /// Decode size for `ImageIO` thumbnails. Rounded up to 128px buckets at
    /// 2× so a live drag doesn't re-decode on every pixel, while a large
    /// strip still gets a sharp image on Retina displays.
    static func maxPixelSize(forCardSide side: CGFloat) -> Int {
        let bucket: CGFloat = 128
        let needed = max(side, 1) * 2
        return Int((needed / bucket).rounded(.up) * bucket)
    }

    /// Accessibility value / tooltip text, e.g. "300포인트".
    static func heightText(_ height: CGFloat) -> String {
        "\(Int(height.rounded()))포인트"
    }
}
