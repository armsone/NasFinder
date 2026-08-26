import SwiftUI
import UIKit

struct ZoomableMediaImageView: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void
    let onNavigate: (Int) -> Void
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomContainerView {
        let view = ZoomContainerView()
        view.update(
            image: image,
            onDismiss: onDismiss,
            onNavigate: onNavigate,
            onSingleTap: onSingleTap
        )
        return view
    }

    func updateUIView(_ view: ZoomContainerView, context: Context) {
        view.update(
            image: image,
            onDismiss: onDismiss,
            onNavigate: onNavigate,
            onSingleTap: onSingleTap
        )
    }

    @MainActor
    final class ZoomContainerView: UIView, UIScrollViewDelegate {
        private let scrollView = UIScrollView()
        private let imageView = UIImageView()

        private var onDismiss: () -> Void = {}
        private var onNavigate: (Int) -> Void = { _ in }
        private var onSingleTap: () -> Void = {}

        private var fittedImageSize = CGSize.zero
        private var lastLayoutSize = CGSize.zero
        private var needsImageLayout = true
        private var isUpdatingLayout = false
        private var panBeganAtFittedScale = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            image: UIImage,
            onDismiss: @escaping () -> Void,
            onNavigate: @escaping (Int) -> Void,
            onSingleTap: @escaping () -> Void
        ) {
            self.onDismiss = onDismiss
            self.onNavigate = onNavigate
            self.onSingleTap = onSingleTap

            guard imageView.image !== image else { return }
            imageView.stopAnimating()
            imageView.image = image
            if image.images != nil {
                // Animated GIF frames play inside the same zoomable view.
                imageView.startAnimating()
            }
            needsImageLayout = true
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let newSize = bounds.size
            guard newSize.width > 0, newSize.height > 0 else { return }

            scrollView.frame = bounds

            guard needsImageLayout || newSize != lastLayoutSize else {
                updateContentInsets()
                return
            }

            relayoutImage(in: newSize, preserveViewport: !needsImageLayout)
            needsImageLayout = false
            lastLayoutSize = newSize
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isUpdatingLayout else { return }
            updateContentInsets()
        }

        private func configureView() {
            backgroundColor = .black

            scrollView.backgroundColor = .black
            scrollView.delegate = self
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 6
            scrollView.zoomScale = 1
            scrollView.bouncesZoom = true
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = true
            scrollView.isDirectionalLockEnabled = true
            scrollView.decelerationRate = .fast
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            addSubview(scrollView)

            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            scrollView.addSubview(imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            scrollView.addGestureRecognizer(doubleTap)

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            scrollView.addGestureRecognizer(singleTap)
        }

        private func relayoutImage(in viewportSize: CGSize, preserveViewport: Bool) {
            guard let image = imageView.image else { return }

            let oldZoomScale = scrollView.zoomScale
            let normalizedCenter = preserveViewport ? visibleImageCenter() : CGPoint(x: 0.5, y: 0.5)

            isUpdatingLayout = true
            scrollView.setZoomScale(1, animated: false)
            scrollView.contentInset = .zero
            scrollView.contentOffset = .zero

            let imageSize = displaySize(for: image)
            guard imageSize.width > 0, imageSize.height > 0 else {
                fittedImageSize = .zero
                imageView.frame = .zero
                scrollView.contentSize = .zero
                isUpdatingLayout = false
                return
            }

            let fitScale = min(
                viewportSize.width / imageSize.width,
                viewportSize.height / imageSize.height
            )
            fittedImageSize = CGSize(
                width: imageSize.width * fitScale,
                height: imageSize.height * fitScale
            )
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fittedImageSize)
            scrollView.contentSize = fittedImageSize
            updateContentInsets()

            let restoredZoomScale = preserveViewport
                ? min(max(oldZoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
                : scrollView.minimumZoomScale
            scrollView.setZoomScale(restoredZoomScale, animated: false)
            updateContentInsets()
            restoreVisibleImageCenter(normalizedCenter)
            isUpdatingLayout = false
        }

        private func displaySize(for image: UIImage) -> CGSize {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                CGSize(width: image.size.height, height: image.size.width)
            default:
                image.size
            }
        }

        private func visibleImageCenter() -> CGPoint {
            guard fittedImageSize.width > 0, fittedImageSize.height > 0 else {
                return CGPoint(x: 0.5, y: 0.5)
            }

            let scaledSize = CGSize(
                width: fittedImageSize.width * scrollView.zoomScale,
                height: fittedImageSize.height * scrollView.zoomScale
            )
            let visibleCenter = CGPoint(
                x: scrollView.contentOffset.x + scrollView.bounds.width / 2,
                y: scrollView.contentOffset.y + scrollView.bounds.height / 2
            )

            return CGPoint(
                x: min(max(visibleCenter.x / scaledSize.width, 0), 1),
                y: min(max(visibleCenter.y / scaledSize.height, 0), 1)
            )
        }

        private func restoreVisibleImageCenter(_ normalizedCenter: CGPoint) {
            let scaledSize = CGSize(
                width: fittedImageSize.width * scrollView.zoomScale,
                height: fittedImageSize.height * scrollView.zoomScale
            )
            let desiredOffset = CGPoint(
                x: normalizedCenter.x * scaledSize.width - scrollView.bounds.width / 2,
                y: normalizedCenter.y * scaledSize.height - scrollView.bounds.height / 2
            )

            scrollView.contentOffset = CGPoint(
                x: min(
                    max(desiredOffset.x, -scrollView.contentInset.left),
                    max(-scrollView.contentInset.left, scaledSize.width - scrollView.bounds.width + scrollView.contentInset.right)
                ),
                y: min(
                    max(desiredOffset.y, -scrollView.contentInset.top),
                    max(-scrollView.contentInset.top, scaledSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
                )
            )
        }

        private func updateContentInsets() {
            let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        @objc
        private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            updateContentInsets()
        }

        @objc
        private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onSingleTap()
        }

        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                panBeganAtFittedScale = isAtFittedScale

            case .ended:
                defer { panBeganAtFittedScale = false }
                guard panBeganAtFittedScale, isAtFittedScale else { return }

                let translation = gesture.translation(in: self)
                let horizontalDistance = abs(translation.x)
                let verticalDistance = abs(translation.y)

                if translation.y >= 120, verticalDistance > horizontalDistance {
                    onDismiss()
                } else if horizontalDistance >= 100, horizontalDistance > verticalDistance {
                    onNavigate(translation.x < 0 ? 1 : -1)
                }

            case .cancelled, .failed:
                panBeganAtFittedScale = false

            default:
                break
            }
        }

        private var isAtFittedScale: Bool {
            abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
        }
    }
}
