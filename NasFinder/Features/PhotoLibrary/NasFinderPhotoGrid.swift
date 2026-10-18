import AVFoundation
import AVKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private final class NasFinderPhotoPickerGradientView: UIView {
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(gradientLayer, at: 0)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        gradientLayer.colors = [
            UIColor(NasFinderPhotoPickerTheme.backgroundWithBlack).cgColor,
            UIColor(NasFinderPhotoPickerTheme.background).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.12, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.88, y: 1)
    }
}

private enum NasFinderPhotoDurationFilterComparison {
    case atLeast
    case atMost

    var title: String {
        switch self {
        case .atLeast: "이상"
        case .atMost: "이하"
        }
    }
}

private struct NasFinderPhotoDurationFilterEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var minutes: Int
    @State private var seconds: Int
    @State private var comparison: NasFinderPhotoDurationFilterComparison

    private let maximumMinutes: Int
    let onApply: (TimeInterval, NasFinderPhotoDurationFilterComparison) -> Void
    let onClear: () -> Void

    init(
        currentSeconds: TimeInterval?,
        currentComparison: NasFinderPhotoDurationFilterComparison,
        onApply: @escaping (
            TimeInterval,
            NasFinderPhotoDurationFilterComparison
        ) -> Void,
        onClear: @escaping () -> Void
    ) {
        let initialSeconds = max(Int((currentSeconds ?? 180).rounded()), 0)
        _minutes = State(initialValue: initialSeconds / 60)
        _seconds = State(initialValue: initialSeconds % 60)
        _comparison = State(initialValue: currentComparison)
        maximumMinutes = max(180, initialSeconds / 60 + 30)
        self.onApply = onApply
        self.onClear = onClear
    }

    private var totalSeconds: Int {
        minutes * 60 + seconds
    }

    private var resultText: String {
        "\(formattedDuration(totalSeconds)) \(comparison.title)인 영상만 표시"
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 10) {
                Text("빠른 선택")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NasFinderPhotoPickerTheme.text.opacity(0.72))

                HStack(spacing: 8) {
                    presetButton("1분", seconds: 60)
                    presetButton("3분", seconds: 180)
                    presetButton("5분", seconds: 300)
                    presetButton("10분", seconds: 600)
                }
            }

            VStack(spacing: 12) {
                Picker("시간 조건", selection: $comparison) {
                    Text("이상").tag(NasFinderPhotoDurationFilterComparison.atLeast)
                    Text("이하").tag(NasFinderPhotoDurationFilterComparison.atMost)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    timePicker(
                        title: "분",
                        selection: $minutes,
                        values: 0...maximumMinutes
                    )
                    timePicker(
                        title: "초",
                        selection: $seconds,
                        values: 0...59
                    )
                }

                Label(resultText, systemImage: "video.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NasFinderPhotoPickerTheme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        NasFinderPhotoPickerTheme.primary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .padding(14)
            .background(
                NasFinderPhotoPickerTheme.panelFill,
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(NasFinderPhotoPickerTheme.secondary.opacity(0.22))
            }

            HStack(spacing: 10) {
                Button {
                    onClear()
                    dismiss()
                } label: {
                    Text("필터 해제")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(NasFinderPhotoPickerTheme.text.opacity(0.76))
                .padding(.vertical, 14)
                .background(
                    NasFinderPhotoPickerTheme.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16)
                )

                Button {
                    onApply(TimeInterval(totalSeconds), comparison)
                    dismiss()
                } label: {
                    Text("\(comparison.title) 영상 보기")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(NasFinderPhotoPickerTheme.onSecondary)
                .padding(.vertical, 14)
                .background(
                    NasFinderPhotoPickerTheme.primary,
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .disabled(totalSeconds == 0)
                .opacity(totalSeconds == 0 ? 0.38 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(NasFinderPhotoPickerTheme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark.fill")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(NasFinderPhotoPickerTheme.primary)
                .frame(width: 42, height: 42)
                .background(
                    NasFinderPhotoPickerTheme.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("영상 시간 필터")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NasFinderPhotoPickerTheme.text)
                Text("설정한 시간 이상인 영상만 찾습니다.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NasFinderPhotoPickerTheme.text.opacity(0.62))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                InterfaceIcon(systemName: "xmark", size: 18)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NasFinderPhotoPickerTheme.text)
                    .frame(width: 38, height: 38)
                    .background(
                        NasFinderPhotoPickerTheme.secondary.opacity(0.12),
                        in: Circle()
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("닫기")
        }
    }

    private func presetButton(
        _ title: String,
        seconds presetSeconds: Int
    ) -> some View {
        let isSelected = totalSeconds == presetSeconds
        return Button {
            minutes = presetSeconds / 60
            seconds = presetSeconds % 60
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(
                    isSelected ? NasFinderPhotoPickerTheme.onSecondary : NasFinderPhotoPickerTheme.text
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    isSelected
                        ? NasFinderPhotoPickerTheme.primary
                        : NasFinderPhotoPickerTheme.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 13)
                )
        }
        .buttonStyle(.plain)
    }

    private func timePicker(
        title: String,
        selection: Binding<Int>,
        values: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(Array(values), id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.menu)
            .tint(NasFinderPhotoPickerTheme.primary)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NasFinderPhotoPickerTheme.text.opacity(0.68))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            NasFinderPhotoPickerTheme.background.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func formattedDuration(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0, seconds > 0 {
            return "\(minutes)분 \(seconds)초"
        }
        if minutes > 0 {
            return "\(minutes)분"
        }
        return "\(seconds)초"
    }
}

/// 한클립의 실제 UICollectionView 선택기와 미리보기에서 필요한 부분을 재사용한다.
/// 선택은 호스트 바스켓에 즉시 반영하며 원본 내보내기/추가 확인은 호스트가 담당한다.
struct NasFinderPhotoGrid: UIViewControllerRepresentable {
    let assets: PHFetchResult<PHAsset>
    let selection: [String]
    let onSelectionChange: ([String]) -> Void
    func makeUIViewController(context: Context) -> DragSelectionPhotoPickerViewController {
        DragSelectionPhotoPickerViewController(initialSelectionIdentifiers: selection, videoOnly: false,
            assets: assets, onSelectionChange: onSelectionChange)
    }
    func updateUIViewController(_ controller: DragSelectionPhotoPickerViewController, context: Context) {
        controller.onSelectionChange = onSelectionChange
        controller.update(assets: assets, selection: selection)
    }
    static func dismantleUIViewController(_ controller: DragSelectionPhotoPickerViewController, coordinator: ()) {
        controller.tearDown()
    }
    final class DragSelectionPhotoPickerViewController: UIViewController,
        UICollectionViewDataSource,
        UICollectionViewDelegate,
        UICollectionViewDelegateFlowLayout,
        UIGestureRecognizerDelegate {
        var onSelectionChange: ([String]) -> Void
        private var selectionNotificationPending = false
        private var rebuildTask: Task<Void, Never>?
        private let videoOnly: Bool
        private let imageManager = PHCachingImageManager()
        private var assets: PHFetchResult<PHAsset>?
        private var assetSections: [AssetDaySection] = []
        private var selectedMediaFilters: Set<MediaFilter> = [
            .photo,
            .livePhoto,
            .video
        ]
        private var durationFilterSeconds: TimeInterval?
        private var durationFilterComparison: NasFinderPhotoDurationFilterComparison = .atLeast
        private var mediaFiltersBeforeDurationFilter: Set<MediaFilter>?
        private var mediaSortMode: MediaSortMode = .captureDate
        private var isMediaSortAscending = true
        private var selectedIdentifiers: [String] = []
        private var selectedIdentifierSet: Set<String> = []
        private var dragShouldSelect = true
        private var lastDragIndexPath: IndexPath?
        private var suppressNextTap = false
        private var columnCount = 5
        private var dragLocationInView: CGPoint?
        private var autoScrollDisplayLink: CADisplayLink?
        private var lastAutoScrollTimestamp: CFTimeInterval?
        private let filterButton = UIButton(type: .system)
        private let clearSelectionButton = UIButton(type: .system)
        private let previousDayButton = UIButton(type: .system)
        private let todayButton = UIButton(type: .system)
        private var isTodayButtonArmedForSelection = false
        private let collectionView: UICollectionView

        private enum MediaFilter: Int {
            case photo = 0
            case livePhoto = 1
            case video = 2

            var title: String {
                switch self {
                case .photo: "사진"
                case .livePhoto: "라이브"
                case .video: "영상"
                }
            }

            var symbolName: String {
                switch self {
                case .photo: "photo"
                case .livePhoto: "livephoto"
                case .video: "video.fill"
                }
            }
        }

        private enum MediaSortMode: Int {
            case captureDate
            case addedDate

            var title: String {
                switch self {
                case .captureDate: "날짜순"
                case .addedDate: "추가순"
                }
            }

            var symbolName: String {
                switch self {
                case .captureDate: "calendar"
                case .addedDate: "tray.and.arrow.down"
                }
            }
        }

        private struct AssetDaySection: @unchecked Sendable {
            let date: Date
            let assets: [PHAsset]
        }

        init(
            initialSelectionIdentifiers: [String],
            videoOnly: Bool,
            assets: PHFetchResult<PHAsset>,
            onSelectionChange: @escaping ([String]) -> Void
        ) {
            self.assets = assets
            self.onSelectionChange = onSelectionChange
            self.videoOnly = videoOnly
            if videoOnly {
                selectedMediaFilters = [.video]
            }
            selectedIdentifiers = initialSelectionIdentifiers
            selectedIdentifierSet = Set(initialSelectionIdentifiers)
            let layout = UICollectionViewFlowLayout()
            layout.minimumLineSpacing = 2
            layout.minimumInteritemSpacing = 2
            collectionView = UICollectionView(
                frame: .zero,
                collectionViewLayout: layout
            )
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(NasFinderPhotoPickerTheme.background)
            let background = NasFinderPhotoPickerGradientView()
            background.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(background)
            NSLayoutConstraint.activate([
                background.topAnchor.constraint(equalTo: view.topAnchor),
                background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                background.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            configureCollectionView()
            configureToolbar()
            configureDayNavigationButtons()
            requestAccessAndLoadAssets()
        }

        private func configureCollectionView() {
            collectionView.backgroundColor = .clear
            collectionView.alwaysBounceVertical = true
            collectionView.contentInset.bottom = 60
            collectionView.verticalScrollIndicatorInsets.bottom = 60
            collectionView.isDirectionalLockEnabled = true
            collectionView.allowsMultipleSelection = true
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.register(
                DragSelectionPhotoCell.self,
                forCellWithReuseIdentifier: DragSelectionPhotoCell.reuseID
            )
            collectionView.register(
                PhotoPickerDateHeader.self,
                forSupplementaryViewOfKind:
                    UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: PhotoPickerDateHeader.reuseID
            )
            collectionView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(collectionView)

            let pan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleSelectionPan(_:))
            )
            pan.delegate = self
            pan.cancelsTouchesInView = true
            collectionView.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handleGridPinch(_:))
            )
            pinch.delegate = self
            collectionView.addGestureRecognizer(pinch)

            let previewLongPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleMediaPreviewLongPress(_:))
            )
            previewLongPress.minimumPressDuration = 0.45
            previewLongPress.cancelsTouchesInView = true
            previewLongPress.delegate = self
            collectionView.addGestureRecognizer(previewLongPress)
        }

        private func configureToolbar() {
            NSLayoutConstraint.activate([
                collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
        }

        private func configureDayNavigationButtons() {
            configureFloatingDayButton(
                filterButton,
                title: "필터",
                accessibilityHint: "표시할 미디어 종류를 선택합니다."
            )
            filterButton.showsMenuAsPrimaryAction = true
            updateFilterMenu()

            configureFloatingDayButton(
                previousDayButton,
                title: "전날",
                accessibilityHint: "선택이 없으면 어제와 가까운 날짜를 선택하고, 선택이 있으면 선택된 날짜의 전날을 선택합니다."
            )
            previousDayButton.addTarget(
                self,
                action: #selector(previousDayTapped),
                for: .touchUpInside
            )

            configureFloatingDayButton(
                todayButton,
                title: "오늘",
                accessibilityHint: "한 번 누르면 오늘로 이동하고, 다시 누르면 오늘의 미디어를 선택합니다."
            )
            todayButton.addTarget(
                self,
                action: #selector(todayTapped),
                for: .touchUpInside
            )

            configureFloatingDayButton(
                clearSelectionButton,
                title: "해제",
                accessibilityHint: "현재 선택한 미디어를 모두 선택 해제합니다."
            )
            clearSelectionButton.accessibilityLabel = "선택 해제"
            clearSelectionButton.isEnabled = false
            clearSelectionButton.alpha = 0.34
            clearSelectionButton.addTarget(
                self,
                action: #selector(clearSelectionTapped),
                for: .touchUpInside
            )

            let buttonStack = UIStackView(arrangedSubviews: [
                filterButton,
                previousDayButton,
                todayButton,
                clearSelectionButton
            ])
            buttonStack.axis = .horizontal
            buttonStack.alignment = .fill
            buttonStack.distribution = .fillEqually
            buttonStack.spacing = 8
            buttonStack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(buttonStack)
            NSLayoutConstraint.activate([
                buttonStack.leadingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                    constant: 12
                ),
                buttonStack.trailingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -12
                ),
                buttonStack.bottomAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -8
                ),
                buttonStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // 툴바 실제 높이(최소 44) + 위아래 8 간격을 따라 하단 인셋을 맞춘다(기본 44+8+8=60).
            let toolbarHeight = max(44, filterButton.superview?.bounds.height ?? 44)
            let bottomInset = toolbarHeight + 16
            if collectionView.contentInset.bottom != bottomInset {
                collectionView.contentInset.bottom = bottomInset
                collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
            }
        }

        private func configureFloatingDayButton(
            _ button: UIButton,
            title: String,
            accessibilityHint: String
        ) {
            // 둥근 테마 버튼 외형을 Mac idiom에서도 유지한다(Mac 스타일 UIButton 커스텀 API 예외 방지).
            button.preferredBehavioralStyle = .pad
            button.configuration = nil
            button.setTitle(title, for: .normal)
            button.setTitleColor(NasFinderPhotoPickerTheme.primaryUIColor, for: .normal)
            button.titleLabel?.font = UIFontMetrics(
                forTextStyle: .footnote
            ).scaledFont(
                for: PorcelainTypeface.uiFont(size: 13, weight: .medium),
                maximumPointSize: 18
            )
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.backgroundColor = UIColor(NasFinderPhotoPickerTheme.background)
                .withAlphaComponent(0.86)
            button.layer.cornerRadius = 8
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = 1
            button.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.34).cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityLabel = title
            button.accessibilityHint = accessibilityHint
        }

        private func requestAccessAndLoadAssets() {
            rebuildAssetSections()
            updateSelectionCount()
        }

        func update(assets newAssets: PHFetchResult<PHAsset>, selection: [String]) {
            if assets !== newAssets {
                assets = newAssets
                rebuildAssetSections()
            }
            guard Set(selection) != selectedIdentifierSet else { return }
            selectedIdentifiers = selection
            selectedIdentifierSet = Set(selection)
            for case let cell as DragSelectionPhotoCell in collectionView.visibleCells {
                if let id = cell.representedAssetIdentifier { cell.updateSelection(selectedIdentifierSet.contains(id)) }
            }
            updateVisibleCellAccessibility()
            updateSelectionCount(notify: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopAutoScroll()
        }

        private func toggleMediaFilter(_ filter: MediaFilter) {
            if selectedMediaFilters.contains(filter) {
                guard selectedMediaFilters.count > 1 else { return }
                selectedMediaFilters.remove(filter)
            } else {
                selectedMediaFilters.insert(filter)
            }
            applyMediaFilters()
        }

        private func updateFilterMenu() {
            let allAction = UIAction(
                title: videoOnly ? "전체 영상" : "전체",
                image: UIImage(systemName: "square.grid.2x2.fill"),
                state: (videoOnly
                    ? selectedMediaFilters == [.video]
                    : selectedMediaFilters.count == 3)
                    && durationFilterSeconds == nil ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                selectedMediaFilters = videoOnly
                    ? [.video]
                    : [.photo, .livePhoto, .video]
                durationFilterSeconds = nil
                mediaFiltersBeforeDurationFilter = nil
                applyMediaFilters()
            }
            let actions: [UIMenuElement]
            if videoOnly || durationFilterSeconds != nil {
                actions = [
                    UIAction(
                        title: "영상만",
                        image: UIImage(systemName: "video.fill"),
                        attributes: [.disabled],
                        state: .on
                    ) { _ in }
                ]
            } else {
                actions = [
                    MediaFilter.photo,
                    MediaFilter.livePhoto,
                    MediaFilter.video
                ].map { filter in
                    UIAction(
                        title: filter.title,
                        image: UIImage(systemName: filter.symbolName),
                        state: selectedMediaFilters.contains(filter) ? .on : .off
                    ) { [weak self] _ in
                        self?.toggleMediaFilter(filter)
                    }
                }
            }
            let durationAction = UIAction(
                title: durationFilterMenuTitle,
                image: UIImage(systemName: "clock.badge.checkmark"),
                state: durationFilterSeconds == nil ? .off : .on
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.presentDurationFilterEditor()
                }
            }
            let sortActions: [UIMenuElement] = [
                MediaSortMode.captureDate,
                MediaSortMode.addedDate
            ].map { mode in
                let isSelected = mediaSortMode == mode
                let arrow = isSelected && !isMediaSortAscending ? "↓" : "↑"
                return UIAction(
                    title: "\(mode.title) \(arrow)",
                    image: UIImage(systemName: mode.symbolName),
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.selectMediaSort(mode)
                }
            }
            filterButton.menu = UIMenu(
                title: "필터",
                options: .displayInline,
                children: [
                    allAction,
                    UIMenu(options: .displayInline, children: actions),
                    UIMenu(options: .displayInline, children: [durationAction]),
                    UIMenu(
                        title: "정렬",
                        options: .displayInline,
                        children: sortActions
                    )
                ]
            )
            var accessibilityValue = selectedMediaFilters
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.title)
                .joined(separator: ", ")
            if durationFilterSeconds != nil {
                accessibilityValue += ", \(durationFilterMenuTitle)"
            }
            accessibilityValue += ", \(mediaSortMode.title) "
                + (isMediaSortAscending ? "오름차순" : "내림차순")
            filterButton.accessibilityValue = accessibilityValue
        }

        private func selectMediaSort(_ mode: MediaSortMode) {
            if mediaSortMode == mode {
                isMediaSortAscending.toggle()
            } else {
                mediaSortMode = mode
            }
            applyMediaFilters()
        }

        private var durationFilterMenuTitle: String {
            guard let seconds = durationFilterSeconds else {
                return "시간 제한 없음"
            }
            let totalSeconds = max(Int(seconds.rounded()), 0)
            let minutes = totalSeconds / 60
            let remainingSeconds = totalSeconds % 60
            let timeText: String
            if minutes > 0, remainingSeconds > 0 {
                timeText = "\(minutes)분 \(remainingSeconds)초"
            } else if minutes > 0 {
                timeText = "\(minutes)분"
            } else {
                timeText = "\(remainingSeconds)초"
            }
            return "\(timeText) \(durationFilterComparison.title) 영상"
        }

        private func presentDurationFilterEditor() {
            let editor = NasFinderPhotoDurationFilterEditor(
                currentSeconds: durationFilterSeconds,
                currentComparison: durationFilterComparison,
                onApply: { [weak self] seconds, comparison in
                    self?.activateDurationFilter(
                        seconds: seconds,
                        comparison: comparison
                    )
                },
                onClear: { [weak self] in
                    self?.clearDurationFilter()
                }
            )
            let controller = UIHostingController(rootView: editor)
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
                sheet.prefersGrabberVisible = false
                sheet.preferredCornerRadius = 28
            }
            present(controller, animated: true)
        }

        private func activateDurationFilter(
            seconds: TimeInterval,
            comparison: NasFinderPhotoDurationFilterComparison
        ) {
            if durationFilterSeconds == nil {
                mediaFiltersBeforeDurationFilter = selectedMediaFilters
            }
            durationFilterSeconds = max(seconds, 1)
            durationFilterComparison = comparison
            selectedMediaFilters = [.video]
            applyMediaFilters()
        }

        private func clearDurationFilter() {
            durationFilterSeconds = nil
            durationFilterComparison = .atLeast
            selectedMediaFilters = mediaFiltersBeforeDurationFilter
                ?? (videoOnly ? [.video] : [.photo, .livePhoto, .video])
            mediaFiltersBeforeDurationFilter = nil
            applyMediaFilters()
        }

        private func applyMediaFilters() {
            resetTodayButtonState()
            updateFilterMenu()
            rebuildAssetSections()
        }

        private func rebuildAssetSections() {
            rebuildTask?.cancel()
            guard let assets else { assetSections = []; collectionView.reloadData(); return }
            let filters = Set(selectedMediaFilters.map(\.rawValue))
            let duration = durationFilterSeconds
            let atLeast = durationFilterComparison == .atLeast
            let captureDate = mediaSortMode == .captureDate
            let ascending = isMediaSortAscending
            rebuildTask = Task { [weak self] in
                let sections = await Task.detached(priority: .userInitiated) {
                    var filtered: [PHAsset] = []
                    assets.enumerateObjects { asset, _, _ in
                        let type = asset.mediaType == .video ? 2 : asset.mediaSubtypes.contains(.photoLive) ? 1 : 0
                        guard filters.contains(type) else { return }
                        if asset.mediaType == .video, let duration,
                           !(atLeast ? asset.duration >= duration : asset.duration <= duration) { return }
                        filtered.append(asset)
                    }
                    func date(_ asset: PHAsset) -> Date {
                        captureDate ? (asset.creationDate ?? asset.modificationDate ?? .distantPast)
                            : (asset.modificationDate ?? asset.creationDate ?? .distantPast)
                    }
                    filtered.sort {
                        let lhs = date($0), rhs = date($1)
                        if lhs == rhs { return ascending ? $0.localIdentifier < $1.localIdentifier : $0.localIdentifier > $1.localIdentifier }
                        return ascending ? lhs < rhs : lhs > rhs
                    }
                    var dates: [Date] = []
                    var grouped: [Date: [PHAsset]] = [:]
                    for asset in filtered {
                        let day = Calendar.current.startOfDay(for: date(asset))
                        if grouped[day] == nil { dates.append(day) }
                        grouped[day, default: []].append(asset)
                    }
                    return dates.compactMap { day in grouped[day].map { AssetDaySection(date: day, assets: $0) } }
                }.value
                guard !Task.isCancelled, let self else { return }
                self.assetSections = sections
                self.collectionView.reloadData()
                self.collectionView.layoutIfNeeded()
                self.scrollToInitialMediaPosition(animated: false)
            }
        }

        private func sortingDate(for asset: PHAsset) -> Date {
            switch mediaSortMode {
            case .captureDate:
                return asset.creationDate
                    ?? asset.modificationDate
                    ?? .distantPast
            case .addedDate:
                return asset.modificationDate
                    ?? asset.creationDate
                    ?? .distantPast
            }
        }

        private func scrollToInitialMediaPosition(animated: Bool) {
            guard !assetSections.isEmpty else { return }
            if isMediaSortAscending,
               let lastSection = assetSections.indices.last,
               let lastItem = assetSections[lastSection].assets.indices.last {
                collectionView.scrollToItem(
                    at: IndexPath(item: lastItem, section: lastSection),
                    at: .bottom,
                    animated: animated
                )
                return
            }
            guard let firstItem = assetSections[0].assets.indices.first else {
                return
            }
            collectionView.scrollToItem(
                at: IndexPath(item: firstItem, section: 0),
                at: .top,
                animated: animated
            )
        }

        private func includesAsset(_ asset: PHAsset) -> Bool {
            if asset.mediaType == .video {
                guard selectedMediaFilters.contains(.video) else { return false }
                guard let durationFilterSeconds else { return true }
                switch durationFilterComparison {
                case .atLeast:
                    return asset.duration >= durationFilterSeconds
                case .atMost:
                    return asset.duration <= durationFilterSeconds
                }
            }
            if asset.mediaType == .image,
               asset.mediaSubtypes.contains(.photoLive) {
                return selectedMediaFilters.contains(.livePhoto)
            }
            return selectedMediaFilters.contains(.photo)
        }

        private func asset(at indexPath: IndexPath) -> PHAsset? {
            guard assetSections.indices.contains(indexPath.section),
                  assetSections[indexPath.section].assets.indices.contains(
                    indexPath.item
                  ) else { return nil }
            return assetSections[indexPath.section].assets[indexPath.item]
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int {
            assetSections.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard assetSections.indices.contains(section) else { return 0 }
            return assetSections[section].assets.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DragSelectionPhotoCell.reuseID,
                for: indexPath
            ) as? DragSelectionPhotoCell,
                  let asset = asset(at: indexPath)
            else { return UICollectionViewCell() }

            let mediaKind: DragSelectionPhotoCell.MediaKind =
                asset.mediaType == .video
                    ? .video
                    : asset.mediaSubtypes.contains(.photoLive)
                        ? .livePhoto
                        : .photo
            let selectionOrder = selectedIdentifiers.firstIndex(
                of: asset.localIdentifier
            ).map { $0 + 1 }
            cell.representedAssetIdentifier = asset.localIdentifier
            cell.updateSelection(selectionOrder != nil)
            cell.onAccessibilityActivate = { [weak self, weak cell] in
                guard let self, let cell,
                      let current = self.collectionView.indexPath(for: cell) else { return }
                self.toggleAsset(at: current)
            }
            cell.updateMediaKind(mediaKind)
            cell.updateAccessibility(
                mediaKind: mediaKind,
                creationDate: asset.creationDate,
                selectionOrder: selectionOrder
            )
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 240, height: 240),
                contentMode: .aspectFill,
                options: nil
            ) { image, _ in
                guard cell.representedAssetIdentifier
                    == asset.localIdentifier else { return }
                cell.imageView.image = image
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            viewForSupplementaryElementOfKind kind: String,
            at indexPath: IndexPath
        ) -> UICollectionReusableView {
            guard kind == UICollectionView.elementKindSectionHeader,
                  let header = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: PhotoPickerDateHeader.reuseID,
                    for: indexPath
                  ) as? PhotoPickerDateHeader,
                  assetSections.indices.contains(indexPath.section)
            else { return UICollectionReusableView() }
            header.configure(date: assetSections[indexPath.section].date)
            return header
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> CGSize {
            let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: PorcelainTypeface.uiFont(size: 13, weight: .semibold),
                maximumPointSize: 18
            )
            return CGSize(
                width: collectionView.bounds.width,
                height: max(42, font.lineHeight + 22)
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didSelectItemAt indexPath: IndexPath
        ) {
            guard !suppressNextTap else { return }
            collectionView.deselectItem(at: indexPath, animated: false)
            toggleAsset(at: indexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            let spacing = CGFloat(max(0, columnCount - 1)) * 2
            let width = floor(
                (collectionView.bounds.width - spacing) / CGFloat(columnCount)
            )
            return CGSize(width: width, height: width)
        }

        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = pan.velocity(in: collectionView)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
                UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer
                || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        @objc private func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
            dragLocationInView = gesture.location(in: view)
            let point = gesture.location(in: collectionView)
            switch gesture.state {
            case .began:
                guard let indexPath = collectionView.indexPathForItem(
                    at: point
                ), let asset = asset(at: indexPath) else { return }
                dragShouldSelect = !selectedIdentifierSet.contains(
                    asset.localIdentifier
                )
                lastDragIndexPath = indexPath
                suppressNextTap = true
                setAsset(at: indexPath, selected: dragShouldSelect)
                startAutoScroll()

            case .changed:
                continueDragSelection(at: point)

            case .ended, .cancelled, .failed:
                stopAutoScroll()
                dragLocationInView = nil
                lastDragIndexPath = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.suppressNextTap = false
                }

            default:
                break
            }
        }

        private func continueDragSelection(at point: CGPoint) {
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  indexPath != lastDragIndexPath else { return }
            applyDragSelection(from: lastDragIndexPath, to: indexPath)
            lastDragIndexPath = indexPath
        }

        private func startAutoScroll() {
            guard autoScrollDisplayLink == nil else { return }
            let link = CADisplayLink(
                target: self,
                selector: #selector(handleAutoScrollFrame(_:))
            )
            link.add(to: .main, forMode: .common)
            autoScrollDisplayLink = link
        }

        private func stopAutoScroll() {
            autoScrollDisplayLink?.invalidate()
            autoScrollDisplayLink = nil
            lastAutoScrollTimestamp = nil
        }

        @objc private func handleAutoScrollFrame(_ link: CADisplayLink) {
            guard let location = dragLocationInView else { return }
            let edgeZone: CGFloat = 105
            let topEdge = collectionView.frame.minY + edgeZone
            let bottomEdge = collectionView.frame.maxY - edgeZone
            let direction: CGFloat
            let edgeProgress: CGFloat

            if location.y < topEdge {
                direction = -1
                edgeProgress = min(1, (topEdge - location.y) / edgeZone)
            } else if location.y > bottomEdge {
                direction = 1
                edgeProgress = min(1, (location.y - bottomEdge) / edgeZone)
            } else {
                lastAutoScrollTimestamp = link.timestamp
                return
            }

            let previousTimestamp = lastAutoScrollTimestamp ?? link.timestamp
            lastAutoScrollTimestamp = link.timestamp
            let elapsed = min(1.0 / 20.0, link.timestamp - previousTimestamp)
            let pointsPerSecond = 120 + 1_180 * pow(edgeProgress, 2)
            let proposedY = collectionView.contentOffset.y
                + direction * pointsPerSecond * elapsed
            let minimumY = -collectionView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
            let clampedY = min(maximumY, max(minimumY, proposedY))
            guard abs(clampedY - collectionView.contentOffset.y) > 0.01
            else { return }

            collectionView.contentOffset.y = clampedY
            collectionView.layoutIfNeeded()

            var collectionPoint = collectionView.convert(location, from: view)
            collectionPoint.x = min(
                collectionView.bounds.maxX - 1,
                max(collectionView.bounds.minX + 1, collectionPoint.x)
            )
            collectionPoint.y = direction < 0
                ? collectionView.bounds.minY + 2
                : collectionView.bounds.maxY - 2
            continueDragSelection(at: collectionPoint)
        }

        @objc private func handleGridPinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            if gesture.scale > 1.18 {
                changeColumnCount(towardLargerItems: true)
                gesture.scale = 1
            } else if gesture.scale < 0.82 {
                changeColumnCount(towardLargerItems: false)
                gesture.scale = 1
            }
        }

        @objc private func handleMediaPreviewLongPress(
            _ gesture: UILongPressGestureRecognizer
        ) {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.suppressNextTap = false
                }
                return
            }
            guard gesture.state == .began,
                  presentedViewController == nil else { return }
            suppressNextTap = true
            let point = gesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  let asset = asset(at: indexPath) else { return }
            let sourcePoint = collectionView.convert(point, to: nil)
            openPreview(asset: asset, sourcePoint: sourcePoint)
        }

        private func openPreview(asset: PHAsset, sourcePoint: CGPoint) {
            guard presentedViewController == nil else { return }
            let isSelected = selectedIdentifierSet.contains(asset.localIdentifier)

            let preview = MediaAssetPreviewViewController(
                asset: asset,
                imageManager: imageManager,
                showsCloseButton: false,
                sourcePoint: sourcePoint,
                onDelete: isSelected
                    ? { [weak self] in
                        self?.deselectAsset(identifier: asset.localIdentifier)
                    }
                    : nil
            )
            preview.modalPresentationStyle = .overFullScreen
            preview.modalTransitionStyle = .crossDissolve
            present(preview, animated: true)
        }

        private func deselectAsset(identifier: String) {
            selectedIdentifierSet.remove(identifier)
            selectedIdentifiers.removeAll { $0 == identifier }
            for case let cell as DragSelectionPhotoCell
                in collectionView.visibleCells
            where cell.representedAssetIdentifier == identifier {
                cell.updateSelection(false)
            }
            updateSelectionCount()
        }

        private func changeColumnCount(towardLargerItems: Bool) {
            let stops = [1, 3, 5, 8]
            guard let currentIndex = stops.firstIndex(of: columnCount) else {
                columnCount = 5
                return
            }
            let nextIndex = towardLargerItems
                ? max(0, currentIndex - 1)
                : min(stops.count - 1, currentIndex + 1)
            guard nextIndex != currentIndex else { return }

            let centerPoint = CGPoint(
                x: collectionView.bounds.midX,
                y: collectionView.bounds.midY
            )
            let anchor = collectionView.indexPathForItem(at: centerPoint)
            columnCount = stops[nextIndex]
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let anchor {
                collectionView.scrollToItem(
                    at: anchor,
                    at: .centeredVertically,
                    animated: false
                )
            }
        }

        private func applyDragSelection(
            from previous: IndexPath?,
            to current: IndexPath
        ) {
            let startIndexPath = previous ?? current
            guard let start = linearIndex(for: startIndexPath),
                  let end = linearIndex(for: current) else { return }
            let lower = min(start, end)
            let upper = max(start, end)
            for index in lower...upper {
                guard let indexPath = indexPath(forLinearIndex: index) else {
                    continue
                }
                setAsset(at: indexPath, selected: dragShouldSelect)
            }
        }

        private func linearIndex(for indexPath: IndexPath) -> Int? {
            guard assetSections.indices.contains(indexPath.section),
                  assetSections[indexPath.section].assets.indices.contains(
                    indexPath.item
                  ) else { return nil }
            let precedingCount = assetSections.prefix(indexPath.section)
                .reduce(0) { $0 + $1.assets.count }
            return precedingCount + indexPath.item
        }

        private func indexPath(forLinearIndex target: Int) -> IndexPath? {
            guard target >= 0 else { return nil }
            var offset = target
            for (section, daySection) in assetSections.enumerated() {
                if offset < daySection.assets.count {
                    return IndexPath(item: offset, section: section)
                }
                offset -= daySection.assets.count
            }
            return nil
        }

        private func toggleAsset(at indexPath: IndexPath) {
            guard let asset = asset(at: indexPath) else { return }
            setAsset(
                at: indexPath,
                selected: !selectedIdentifierSet.contains(asset.localIdentifier)
            )
        }

        private func setAsset(at indexPath: IndexPath, selected: Bool) {
            guard let asset = asset(at: indexPath) else { return }
            let identifier = asset.localIdentifier
            if selected {
                guard selectedIdentifierSet.insert(identifier).inserted else {
                    return
                }
                selectedIdentifiers.append(identifier)
            } else {
                guard selectedIdentifierSet.remove(identifier) != nil else {
                    return
                }
                selectedIdentifiers.removeAll { $0 == identifier }
            }
            (collectionView.cellForItem(at: indexPath)
                as? DragSelectionPhotoCell)?.updateSelection(selected)
            updateVisibleCellAccessibility()
            updateSelectionCount()
        }

        private func updateVisibleCellAccessibility() {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let asset = asset(at: indexPath),
                      let cell = collectionView.cellForItem(at: indexPath)
                        as? DragSelectionPhotoCell
                else { continue }
                let mediaKind: DragSelectionPhotoCell.MediaKind =
                    asset.mediaType == .video
                        ? .video
                        : asset.mediaSubtypes.contains(.photoLive)
                            ? .livePhoto
                            : .photo
                cell.updateAccessibility(
                    mediaKind: mediaKind,
                    creationDate: asset.creationDate,
                    selectionOrder: selectedIdentifiers.firstIndex(
                        of: asset.localIdentifier
                    ).map { $0 + 1 }
                )
            }
        }

        private func updateSelectionCount(notify: Bool = true) {
            let count = selectedIdentifiers.count
            clearSelectionButton.isEnabled = count > 0
            clearSelectionButton.alpha = count > 0 ? 1 : 0.34
            guard notify, !selectionNotificationPending else { return }
            selectionNotificationPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectionNotificationPending = false
                guard self.viewIfLoaded?.window != nil else { return }
                self.onSelectionChange(self.selectedIdentifiers)
            }
        }

        @objc private func todayTapped() {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            guard let section = assetSections.firstIndex(where: {
                calendar.isDate($0.date, inSameDayAs: today)
            }) else {
                resetTodayButtonState()
                if let latestSection = assetSections.indices.last {
                    scrollToSection(latestSection, animated: true)
                }
                return
            }

            if isTodayButtonArmedForSelection {
                selectAllAssets(in: section)
                resetTodayButtonState()
            } else {
                scrollToSection(section, animated: true)
                isTodayButtonArmedForSelection = true
                updateTodayButtonAppearance()
            }
        }

        @objc private func previousDayTapped() {
            resetTodayButtonState()
            guard let section = previousDayTargetSection() else { return }
            scrollToSection(section, animated: true)
            selectAllAssets(in: section)
        }

        private func previousDayTargetSection() -> Int? {
            let calendar = Calendar.current
            if selectedIdentifiers.isEmpty {
                let yesterday = calendar.date(
                    byAdding: .day,
                    value: -1,
                    to: calendar.startOfDay(for: Date())
                ) ?? Date()
                return assetSections.indices.min { left, right in
                    abs(assetSections[left].date.timeIntervalSince(yesterday))
                        < abs(
                            assetSections[right].date.timeIntervalSince(yesterday)
                        )
                }
            }

            let selectedAssets = PHAsset.fetchAssets(
                withLocalIdentifiers: selectedIdentifiers,
                options: nil
            )
            var earliestSelectedDate: Date?
            selectedAssets.enumerateObjects { asset, _, _ in
                guard let creationDate = asset.creationDate else { return }
                if earliestSelectedDate == nil
                    || creationDate < earliestSelectedDate! {
                    earliestSelectedDate = creationDate
                }
            }
            guard let earliestSelectedDate else { return nil }
            let baseDay = calendar.startOfDay(for: earliestSelectedDate)
            return assetSections.indices.last(where: {
                assetSections[$0].date < baseDay
            })
        }

        private func scrollToSection(_ section: Int, animated: Bool) {
            guard assetSections.indices.contains(section) else { return }
            collectionView.layoutIfNeeded()
            let indexPath = IndexPath(item: 0, section: section)
            if let attributes = collectionView.collectionViewLayout
                .layoutAttributesForSupplementaryView(
                    ofKind: UICollectionView.elementKindSectionHeader,
                    at: indexPath
                ) {
                let minimumY = -collectionView.adjustedContentInset.top
                let maximumY = max(
                    minimumY,
                    collectionView.contentSize.height
                        - collectionView.bounds.height
                        + collectionView.adjustedContentInset.bottom
                )
                let targetY = min(
                    maximumY,
                    max(
                        minimumY,
                        attributes.frame.minY
                            - collectionView.adjustedContentInset.top
                    )
                )
                collectionView.setContentOffset(
                    CGPoint(x: 0, y: targetY),
                    animated: animated
                )
            } else {
                collectionView.scrollToItem(
                    at: indexPath,
                    at: .top,
                    animated: animated
                )
            }
        }

        private func selectAllAssets(in section: Int) {
            guard assetSections.indices.contains(section) else { return }
            for asset in assetSections[section].assets {
                let identifier = asset.localIdentifier
                guard selectedIdentifierSet.insert(identifier).inserted else {
                    continue
                }
                selectedIdentifiers.append(identifier)
            }
            for case let cell as DragSelectionPhotoCell
                in collectionView.visibleCells {
                guard let identifier = cell.representedAssetIdentifier else {
                    continue
                }
                cell.updateSelection(selectedIdentifierSet.contains(identifier))
            }
            updateVisibleCellAccessibility()
            updateSelectionCount()
        }

        private func resetTodayButtonState() {
            guard isTodayButtonArmedForSelection else { return }
            isTodayButtonArmedForSelection = false
            updateTodayButtonAppearance()
        }

        private func updateTodayButtonAppearance() {
            if isTodayButtonArmedForSelection {
                todayButton.backgroundColor = NasFinderPhotoPickerTheme.primaryUIColor
                    .withAlphaComponent(0.18)
                todayButton.layer.borderColor = NasFinderPhotoPickerTheme.primaryUIColor
                    .withAlphaComponent(0.50).cgColor
                todayButton.accessibilityValue = "오늘 미디어 선택 준비"
            } else {
                todayButton.backgroundColor = UIColor(NasFinderPhotoPickerTheme.background)
                    .withAlphaComponent(0.86)
                todayButton.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor
                    .withAlphaComponent(0.34).cgColor
                todayButton.accessibilityValue = nil
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            resetTodayButtonState()
        }

        @objc private func clearSelectionTapped() {
            guard !selectedIdentifiers.isEmpty else { return }
            selectedIdentifiers.removeAll(keepingCapacity: true)
            selectedIdentifierSet.removeAll(keepingCapacity: true)
            for case let cell as DragSelectionPhotoCell
                in collectionView.visibleCells {
                cell.updateSelection(false)
            }
            updateVisibleCellAccessibility()
            updateSelectionCount()
        }

        /// SwiftUI removal is MainActor-isolated; do not touch UIKit resources from deinit.
        func tearDown() {
            stopAutoScroll()
            rebuildTask?.cancel()
            rebuildTask = nil
        }
    }

    final class PhotoPickerDateHeader: UICollectionReusableView {
        static let reuseID = "PhotoPickerDateHeader"
        private let dateLabel = UILabel()
        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월 d일 EEEE"
            return formatter
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = UIColor(NasFinderPhotoPickerTheme.background)
            dateLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: PorcelainTypeface.uiFont(size: 13, weight: .semibold),
                maximumPointSize: 18
            )
            dateLabel.adjustsFontForContentSizeCategory = true
            dateLabel.textColor = UIColor(NasFinderPhotoPickerTheme.text).withAlphaComponent(0.84)
            dateLabel.backgroundColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.12)
            dateLabel.layer.cornerRadius = 8
            dateLabel.clipsToBounds = true
            dateLabel.textAlignment = .center
            dateLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dateLabel)
            NSLayoutConstraint.activate([
                dateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                dateLabel.bottomAnchor.constraint(
                    equalTo: bottomAnchor,
                    constant: -5
                ),
                dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 165)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(date: Date) {
            dateLabel.text = "  \(Self.formatter.string(from: date))  "
        }
    }

    final class MediaAssetPreviewViewController: UIViewController,
        UIScrollViewDelegate,
        UIGestureRecognizerDelegate {
        private let asset: PHAsset
        private let imageManager: PHImageManager
        private let showsCloseButton: Bool
        private let sourcePoint: CGPoint?
        private let onDelete: (() -> Void)?
        private let onDismiss: (() -> Void)?
        private let scrollView = UIScrollView()
        private let previewSurfaceView = UIView()
        private let imageView = UIImageView()
        private let livePhotoView = PHLivePhotoView()
        private let playerViewController = AVPlayerViewController()
        private let videoControlsView = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemThinMaterial)
        )
        private let playPauseButton = UIButton(type: .system)
        private let progressSlider = UISlider()
        private let loopButton = UIButton(type: .system)
        private var videoPlayer: AVPlayer?
        private var videoEndObserver: NSObjectProtocol?
        private var videoTimeObserver: Any?
        private var isSeekingVideo = false
        private var wasPlayingBeforeSeek = false
        private var isVideoLooping = true
        private var livePhotoProgressTimer: Timer?
        private var livePhotoPlaybackStartedAt: Date?
        private var isLivePhotoPlaying = false
        private var previewCenterYConstraint: NSLayoutConstraint?
        private var mediaRequestIDs: [PHImageRequestID] = []
        private var isPreviewActive = true

        init(
            asset: PHAsset,
            imageManager: PHImageManager,
            showsCloseButton: Bool = false,
            sourcePoint: CGPoint? = nil,
            onDelete: (() -> Void)? = nil,
            onDismiss: (() -> Void)? = nil
        ) {
            self.asset = asset
            self.imageManager = imageManager
            self.showsCloseButton = showsCloseButton
            self.sourcePoint = sourcePoint
            self.onDelete = onDelete
            self.onDismiss = onDismiss
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            // 트랙 색과 테마 버튼을 쓰므로 Mac idiom에서도 iPad 동작 스타일을 유지한다.
            playPauseButton.preferredBehavioralStyle = .pad
            progressSlider.preferredBehavioralStyle = .pad
            loopButton.preferredBehavioralStyle = .pad
            configurePreviewSurface()
            configureOutsideTapToDismiss()
            if asset.mediaType == .video {
                configureVideoPreview()
            } else if asset.mediaSubtypes.contains(.photoLive) {
                configureLivePhotoPreview()
            } else {
                configureStillPhotoPreview()
            }

            if showsCloseButton {
                configureCloseButton()
            }
            if asset.mediaType != .video,
               !asset.mediaSubtypes.contains(.photoLive) {
                configureStandaloneDeleteButton()
            }
        }

        private func configurePreviewSurface() {
            previewSurfaceView.backgroundColor = UIColor(NasFinderPhotoPickerTheme.background)
            previewSurfaceView.layer.cornerRadius = 18
            previewSurfaceView.layer.cornerCurve = .continuous
            previewSurfaceView.layer.borderWidth = 1.25
            previewSurfaceView.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.38).cgColor
            previewSurfaceView.clipsToBounds = true
            previewSurfaceView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(previewSurfaceView)
            let centerY = previewSurfaceView.centerYAnchor.constraint(
                equalTo: view.centerYAnchor,
                constant: -38
            )
            previewCenterYConstraint = centerY
            let preferredWidth = previewSurfaceView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.70)
            // Honor the 70% width before intrinsic image sizing; only the Mac height cap may shrink it.
            preferredWidth.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                previewSurfaceView.centerXAnchor.constraint(
                    equalTo: view.centerXAnchor
                ),
                centerY,
                preferredWidth,
                previewSurfaceView.heightAnchor.constraint(
                    equalTo: previewSurfaceView.widthAnchor
                ),
                previewSurfaceView.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, constant: -120)
            ])
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            positionPreviewNearSourcePoint()
        }

        private func positionPreviewNearSourcePoint() {
            guard let sourcePoint, view.bounds.height > 0 else { return }
            let previewWidth = previewSurfaceView.bounds.width > 0 ? previewSurfaceView.bounds.width
                : min(view.bounds.width * 0.70, max(0, view.safeAreaLayoutGuide.layoutFrame.height - 120))
            let controlsHeight: CGFloat = 68
            let totalHeight = previewWidth + controlsHeight
            let spacing: CGFloat = 14
            let topLimit = view.safeAreaInsets.top + 8
            let bottomLimit = view.bounds.height - view.safeAreaInsets.bottom - 8

            let aboveCenter = sourcePoint.y - spacing - totalHeight / 2
            let belowCenter = sourcePoint.y + spacing + totalHeight / 2
            let targetCenter: CGFloat
            if aboveCenter - totalHeight / 2 >= topLimit {
                targetCenter = aboveCenter
            } else {
                targetCenter = min(
                    bottomLimit - totalHeight / 2,
                    max(topLimit + totalHeight / 2, belowCenter)
                )
            }
            previewCenterYConstraint?.constant = targetCenter - view.bounds.midY
        }

        private func configureOutsideTapToDismiss() {
            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(closePreview)
            )
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let touchedView = touch.view else { return true }
            if touchedView.isDescendant(of: videoControlsView)
                || touchedView is UIControl {
                return false
            }
            return true
        }

        override func accessibilityPerformEscape() -> Bool {
            closePreview()
            return true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if asset.mediaType == .video {
                NasFinderPhotoPickerAudio.activatePlayback()
                videoPlayer?.play()
                updatePlayPauseButton()
            } else if asset.mediaSubtypes.contains(.photoLive) {
                startLivePhotoPlayback()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            tearDown()
        }

        /// Both UIKit disappearance and SwiftUI dismantling run on MainActor.
        /// Idempotent cleanup detaches observers before releasing their player.
        func tearDown() {
            isPreviewActive = false
            mediaRequestIDs.forEach { imageManager.cancelImageRequest($0) }
            mediaRequestIDs.removeAll()
            livePhotoView.stopPlayback()
            stopLivePhotoProgress()
            videoPlayer?.pause()
            if let observer = videoTimeObserver {
                videoPlayer?.removeTimeObserver(observer)
                videoTimeObserver = nil
            }
            if let observer = videoEndObserver {
                NotificationCenter.default.removeObserver(observer)
                videoEndObserver = nil
            }
            playerViewController.player = nil
            videoPlayer = nil
            updatePlayPauseButton()
        }

        private func configureVideoPreview() {
            addChild(playerViewController)
            playerViewController.showsPlaybackControls = false
            playerViewController.videoGravity = .resizeAspect
            playerViewController.view.backgroundColor = .black
            playerViewController.view.translatesAutoresizingMaskIntoConstraints =
                false
            previewSurfaceView.addSubview(playerViewController.view)
            NSLayoutConstraint.activate([
                playerViewController.view.topAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor
                ),
                playerViewController.view.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.bottomAnchor
                ),
                playerViewController.view.leadingAnchor.constraint(
                    equalTo: previewSurfaceView.leadingAnchor
                ),
                playerViewController.view.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                )
            ])
            playerViewController.didMove(toParent: self)
            configureVideoControls()

            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            let requestID = imageManager.requestPlayerItem(
                forVideo: asset,
                options: options
            ) { [weak self] playerItem, _ in
                guard let self, let playerItem else { return }
                DispatchQueue.main.async {
                    let player = AVPlayer(playerItem: playerItem)
                    guard self.isPreviewActive else { return }
                    self.videoPlayer = player
                    self.playerViewController.player = player
                    self.observeVideoProgress(player)
                    self.videoEndObserver = NotificationCenter.default
                        .addObserver(
                            forName: .AVPlayerItemDidPlayToEndTime,
                            object: playerItem,
                            queue: .main
                        ) { [weak self, weak player] _ in
                            guard let self else { return }
                            if self.isVideoLooping {
                                player?.seek(to: .zero)
                                player?.play()
                            } else {
                                self.progressSlider.value = 1
                                self.updatePlayPauseButton()
                            }
                        }
                    player.play()
                    self.updatePlayPauseButton()
                }
            }
            mediaRequestIDs.append(requestID)
        }

        private func configureCloseButton() {
            let closeButton = UIButton(type: .system)
            closeButton.preferredBehavioralStyle = .pad
            closeButton.setImage(
                UIImage(systemName: "xmark.circle.fill"),
                for: .normal
            )
            closeButton.tintColor = .white
            closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.32)
            closeButton.layer.cornerRadius = 22
            closeButton.accessibilityLabel = "미리보기 닫기"
            closeButton.addTarget(
                self,
                action: #selector(closePreview),
                for: .touchUpInside
            )
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.topAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor,
                    constant: 10
                ),
                closeButton.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor,
                    constant: -10
                ),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }

        @objc private func closePreview() {
            if let onDismiss {
                onDismiss()
            } else {
                dismiss(animated: true)
            }
        }

        private func configureVideoControls() {
            videoControlsView.layer.cornerRadius = 18
            videoControlsView.layer.borderWidth = 1
            videoControlsView.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.28).cgColor
            videoControlsView.contentView.backgroundColor = UIColor(
                NasFinderPhotoPickerTheme.background
            ).withAlphaComponent(0.42)
            videoControlsView.clipsToBounds = true
            videoControlsView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(videoControlsView)

            playPauseButton.tintColor = NasFinderPhotoPickerTheme.secondaryUIColor
            playPauseButton.accessibilityLabel = "재생"
            playPauseButton.addTarget(
                self,
                action: #selector(toggleVideoPlayback),
                for: .touchUpInside
            )

            progressSlider.minimumValue = 0
            progressSlider.maximumValue = 1
            progressSlider.minimumTrackTintColor = UIColor(
                NasFinderPhotoPickerTheme.primary
            )
            progressSlider.maximumTrackTintColor = UIColor(NasFinderPhotoPickerTheme.text)
                .withAlphaComponent(0.22)
            progressSlider.addTarget(
                self,
                action: #selector(beginVideoSeek),
                for: .touchDown
            )
            progressSlider.addTarget(
                self,
                action: #selector(seekVideo),
                for: .valueChanged
            )
            progressSlider.addTarget(
                self,
                action: #selector(endVideoSeek),
                for: [.touchUpInside, .touchUpOutside, .touchCancel]
            )

            loopButton.setImage(UIImage(systemName: "infinity"), for: .normal)
            loopButton.accessibilityLabel = "무한 재생"
            loopButton.addTarget(
                self,
                action: #selector(toggleVideoLooping),
                for: .touchUpInside
            )
            updateLoopButton()

            let controls = UIStackView(arrangedSubviews: [
                playPauseButton,
                progressSlider
            ])
            controls.addArrangedSubview(makePreviewActionButton())
            controls.addArrangedSubview(loopButton)
            controls.axis = .horizontal
            controls.alignment = .center
            controls.spacing = 10
            controls.translatesAutoresizingMaskIntoConstraints = false
            videoControlsView.contentView.addSubview(controls)

            NSLayoutConstraint.activate([
                videoControlsView.leadingAnchor.constraint(
                    equalTo: previewSurfaceView.leadingAnchor
                ),
                videoControlsView.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                ),
                videoControlsView.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor,
                    constant: -12
                ),
                videoControlsView.heightAnchor.constraint(equalToConstant: 56),
                controls.leadingAnchor.constraint(
                    equalTo: videoControlsView.contentView.leadingAnchor,
                    constant: 8
                ),
                controls.trailingAnchor.constraint(
                    equalTo: videoControlsView.contentView.trailingAnchor,
                    constant: -8
                ),
                controls.topAnchor.constraint(
                    equalTo: videoControlsView.contentView.topAnchor
                ),
                controls.bottomAnchor.constraint(
                    equalTo: videoControlsView.contentView.bottomAnchor
                ),
                playPauseButton.widthAnchor.constraint(equalToConstant: 44),
                playPauseButton.heightAnchor.constraint(equalToConstant: 44),
                loopButton.widthAnchor.constraint(equalToConstant: 44),
                loopButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }

        private func configureStandaloneDeleteButton() {
            let deleteButton = makePreviewActionButton()
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(deleteButton)
            NSLayoutConstraint.activate([
                deleteButton.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                ),
                deleteButton.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor,
                    constant: -12
                ),
                deleteButton.widthAnchor.constraint(equalToConstant: 52),
                deleteButton.heightAnchor.constraint(equalToConstant: 52)
            ])
        }

        private func makePreviewActionButton() -> UIButton {
            let button = UIButton(type: .system)
            button.preferredBehavioralStyle = .pad
            button.setTitle(onDelete == nil ? "닫기" : "제거", for: .normal)
            button.setTitleColor(
                UIColor(NasFinderPhotoPickerTheme.onSecondary),
                for: .normal
            )
            button.titleLabel?.font = NasFinderPhotoPickerTypography.uiFont(
                textStyle: .footnote,
                weight: .semibold
            )
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.tintColor = UIColor(NasFinderPhotoPickerTheme.onSecondary)
            button.backgroundColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.86)
            button.layer.cornerRadius = 18
            button.layer.cornerCurve = .continuous
            button.accessibilityLabel = onDelete == nil
                ? "미리보기 닫기"
                : "선택에서 제거"
            button.addTarget(
                self,
                action: #selector(deletePreviewItem),
                for: .touchUpInside
            )
            return button
        }

        @objc private func deletePreviewItem() {
            if let onDelete {
                onDelete()
                if onDismiss == nil {
                    dismiss(animated: true)
                }
            } else {
                closePreview()
            }
        }

        private func observeVideoProgress(_ player: AVPlayer) {
            videoTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self, weak player] time in
                guard let self, let player else { return }
                if !self.isSeekingVideo {
                    let duration = player.currentItem?.duration.seconds ?? 0
                    if duration.isFinite, duration > 0 {
                        self.progressSlider.value = Float(time.seconds / duration)
                    }
                }
                self.updatePlayPauseButton()
            }
        }

        @objc private func toggleVideoPlayback() {
            guard let videoPlayer else { return }
            if videoPlayer.timeControlStatus == .playing {
                videoPlayer.pause()
            } else {
                if progressSlider.value >= 0.999 {
                    videoPlayer.seek(to: .zero)
                }
                NasFinderPhotoPickerAudio.activatePlayback()
                videoPlayer.play()
            }
            updatePlayPauseButton()
        }

        @objc private func beginVideoSeek() {
            isSeekingVideo = true
            wasPlayingBeforeSeek = videoPlayer?.timeControlStatus == .playing
            videoPlayer?.pause()
        }

        @objc private func seekVideo() {
            guard let videoPlayer,
                  let duration = videoPlayer.currentItem?.duration.seconds,
                  duration.isFinite,
                  duration > 0 else { return }
            let target = duration * Double(progressSlider.value)
            videoPlayer.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        @objc private func endVideoSeek() {
            seekVideo()
            isSeekingVideo = false
            if wasPlayingBeforeSeek {
                videoPlayer?.play()
            }
            updatePlayPauseButton()
        }

        @objc private func toggleVideoLooping() {
            isVideoLooping.toggle()
            updateLoopButton()
        }

        private func updatePlayPauseButton() {
            let isPlaying = videoPlayer?.timeControlStatus == .playing
            let symbol = isPlaying ? "pause.fill" : "play.fill"
            playPauseButton.setImage(UIImage(systemName: symbol), for: .normal)
            playPauseButton.accessibilityLabel = isPlaying ? "일시 정지" : "재생"
        }

        private func updateLoopButton() {
            loopButton.tintColor = isVideoLooping
                ? UIColor(NasFinderPhotoPickerTheme.primary)
                : UIColor(NasFinderPhotoPickerTheme.text).withAlphaComponent(0.45)
            loopButton.accessibilityValue = isVideoLooping ? "켬" : "끔"
        }

        private func configureLivePhotoPreview() {
            livePhotoView.contentMode = .scaleAspectFit
            livePhotoView.translatesAutoresizingMaskIntoConstraints = false
            previewSurfaceView.addSubview(livePhotoView)
            NSLayoutConstraint.activate([
                livePhotoView.topAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor
                ),
                livePhotoView.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.bottomAnchor
                ),
                livePhotoView.leadingAnchor.constraint(
                    equalTo: previewSurfaceView.leadingAnchor
                ),
                livePhotoView.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                )
            ])
            configureLivePhotoControls()

            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let requestID = imageManager.requestLivePhoto(
                for: asset,
                targetSize: CGSize(width: 1_800, height: 1_800),
                contentMode: .aspectFit,
                options: options
            ) { [weak self] livePhoto, _ in
                guard let self, let livePhoto else { return }
                DispatchQueue.main.async {
                    guard self.isPreviewActive else { return }
                    self.livePhotoView.livePhoto = livePhoto
                    self.startLivePhotoPlayback()
                }
            }
            mediaRequestIDs.append(requestID)
        }

        private func configureLivePhotoControls() {
            videoControlsView.layer.cornerRadius = 18
            videoControlsView.layer.borderWidth = 1
            videoControlsView.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.28).cgColor
            videoControlsView.contentView.backgroundColor = UIColor(
                NasFinderPhotoPickerTheme.background
            ).withAlphaComponent(0.42)
            videoControlsView.clipsToBounds = true
            videoControlsView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(videoControlsView)

            playPauseButton.tintColor = NasFinderPhotoPickerTheme.secondaryUIColor
            playPauseButton.setImage(
                UIImage(systemName: "play.fill"),
                for: .normal
            )
            playPauseButton.accessibilityLabel = "라이브 포토 재생"
            playPauseButton.addTarget(
                self,
                action: #selector(toggleLivePhotoPlayback),
                for: .touchUpInside
            )

            progressSlider.minimumValue = 0
            progressSlider.maximumValue = 1
            progressSlider.isUserInteractionEnabled = false
            progressSlider.minimumTrackTintColor = UIColor(NasFinderPhotoPickerTheme.primary)
            progressSlider.maximumTrackTintColor = UIColor(NasFinderPhotoPickerTheme.text)
                .withAlphaComponent(0.22)

            let controls = UIStackView(arrangedSubviews: [
                playPauseButton,
                progressSlider
            ])
            controls.addArrangedSubview(makePreviewActionButton())
            controls.axis = .horizontal
            controls.alignment = .center
            controls.spacing = 10
            controls.translatesAutoresizingMaskIntoConstraints = false
            videoControlsView.contentView.addSubview(controls)

            NSLayoutConstraint.activate([
                videoControlsView.leadingAnchor.constraint(
                    equalTo: previewSurfaceView.leadingAnchor
                ),
                videoControlsView.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                ),
                videoControlsView.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor,
                    constant: -12
                ),
                videoControlsView.heightAnchor.constraint(equalToConstant: 56),
                controls.leadingAnchor.constraint(
                    equalTo: videoControlsView.contentView.leadingAnchor,
                    constant: 8
                ),
                controls.trailingAnchor.constraint(
                    equalTo: videoControlsView.contentView.trailingAnchor,
                    constant: -8
                ),
                controls.topAnchor.constraint(
                    equalTo: videoControlsView.contentView.topAnchor
                ),
                controls.bottomAnchor.constraint(
                    equalTo: videoControlsView.contentView.bottomAnchor
                ),
                playPauseButton.widthAnchor.constraint(equalToConstant: 44),
                playPauseButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }

        @objc private func toggleLivePhotoPlayback() {
            if isLivePhotoPlaying {
                livePhotoView.stopPlayback()
                stopLivePhotoProgress()
            } else {
                startLivePhotoPlayback()
            }
        }

        private func startLivePhotoPlayback() {
            guard livePhotoView.livePhoto != nil else { return }
            livePhotoView.startPlayback(with: .full)
            isLivePhotoPlaying = true
            progressSlider.value = 0
            livePhotoPlaybackStartedAt = Date()
            livePhotoProgressTimer?.invalidate()
            livePhotoProgressTimer = Timer.scheduledTimer(
                withTimeInterval: 0.05,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                guard let self, self.isPreviewActive, let startedAt = self.livePhotoPlaybackStartedAt
                else { return }
                let duration = self.asset.duration > 0
                    ? self.asset.duration
                    : 3
                let progress = Date().timeIntervalSince(startedAt) / duration
                self.progressSlider.value = Float(min(1, progress))
                if progress >= 1 {
                    self.stopLivePhotoProgress()
                }
                }
            }
            updateLivePhotoPlayButton()
        }

        private func stopLivePhotoProgress() {
            livePhotoProgressTimer?.invalidate()
            livePhotoProgressTimer = nil
            livePhotoPlaybackStartedAt = nil
            isLivePhotoPlaying = false
            updateLivePhotoPlayButton()
        }

        private func updateLivePhotoPlayButton() {
            playPauseButton.setImage(
                UIImage(
                    systemName: isLivePhotoPlaying
                        ? "pause.fill"
                        : "play.fill"
                ),
                for: .normal
            )
            playPauseButton.accessibilityLabel = isLivePhotoPlaying
                ? "라이브 포토 일시 정지"
                : "라이브 포토 재생"
        }

        private func configureStillPhotoPreview() {
            scrollView.delegate = self
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 5
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            previewSurfaceView.addSubview(scrollView)

            imageView.contentMode = .scaleAspectFit
            imageView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(imageView)

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(
                    equalTo: previewSurfaceView.topAnchor
                ),
                scrollView.bottomAnchor.constraint(
                    equalTo: previewSurfaceView.bottomAnchor
                ),
                scrollView.leadingAnchor.constraint(
                    equalTo: previewSurfaceView.leadingAnchor
                ),
                scrollView.trailingAnchor.constraint(
                    equalTo: previewSurfaceView.trailingAnchor
                ),
                imageView.topAnchor.constraint(
                    equalTo: scrollView.contentLayoutGuide.topAnchor
                ),
                imageView.bottomAnchor.constraint(
                    equalTo: scrollView.contentLayoutGuide.bottomAnchor
                ),
                imageView.leadingAnchor.constraint(
                    equalTo: scrollView.contentLayoutGuide.leadingAnchor
                ),
                imageView.trailingAnchor.constraint(
                    equalTo: scrollView.contentLayoutGuide.trailingAnchor
                ),
                imageView.widthAnchor.constraint(
                    equalTo: scrollView.frameLayoutGuide.widthAnchor
                ),
                imageView.heightAnchor.constraint(
                    equalTo: scrollView.frameLayoutGuide.heightAnchor
                )
            ])

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 1_800, height: 1_800),
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, _ in
                DispatchQueue.main.async {
                    guard let self, self.isPreviewActive else { return }
                    self.imageView.image = image
                }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }

    final class DragSelectionPhotoCell: UICollectionViewCell {
        enum MediaKind {
            case photo
            case livePhoto
            case video

            var symbolName: String {
                switch self {
                case .photo: "photo.fill"
                case .livePhoto: "livephoto"
                case .video: "video.fill"
                }
            }

            var accessibilityTitle: String {
                switch self {
                case .photo: "사진"
                case .livePhoto: "라이브 포토"
                case .video: "영상"
                }
            }
        }

        static let reuseID = "DragSelectionPhotoCell"
        let imageView = UIImageView()
        var representedAssetIdentifier: String?
        private let selectionOverlay = UIView()
        private let checkLabel = UILabel()
        var onAccessibilityActivate: (() -> Void)?
        private let mediaKindBadge = UIImageView(
            image: UIImage(systemName: "photo.fill")
        )

        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.layer.cornerRadius = 8
            contentView.layer.cornerCurve = .continuous
            contentView.clipsToBounds = true
            isAccessibilityElement = true
            accessibilityTraits = [.button]
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(imageView)

            selectionOverlay.backgroundColor = NasFinderPhotoPickerTheme.secondaryUIColor
                .withAlphaComponent(0.18)
            selectionOverlay.layer.borderColor = NasFinderPhotoPickerTheme.secondaryUIColor.cgColor
            selectionOverlay.layer.borderWidth = 2.4
            selectionOverlay.layer.cornerRadius = 9
            selectionOverlay.layer.cornerCurve = .continuous
            selectionOverlay.isHidden = true
            selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(selectionOverlay)

            checkLabel.text = "✓"
            checkLabel.textAlignment = .center
            checkLabel.font = .systemFont(ofSize: 12, weight: .black)
            checkLabel.textColor = UIColor(NasFinderPhotoPickerTheme.onSecondary)
            checkLabel.backgroundColor = NasFinderPhotoPickerTheme.secondaryUIColor
            checkLabel.layer.cornerRadius = 9
            checkLabel.clipsToBounds = true
            checkLabel.isHidden = true
            checkLabel.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(checkLabel)
            selectionOverlay.isUserInteractionEnabled = false
            checkLabel.isUserInteractionEnabled = false

            mediaKindBadge.tintColor = UIColor(NasFinderPhotoPickerTheme.background)
                .withAlphaComponent(0.80)
            mediaKindBadge.backgroundColor = UIColor(NasFinderPhotoPickerTheme.text)
                .withAlphaComponent(0.32)
            mediaKindBadge.layer.cornerRadius = 7
            mediaKindBadge.contentMode = .center
            mediaKindBadge.preferredSymbolConfiguration =
                UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            mediaKindBadge.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(mediaKindBadge)

            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                selectionOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
                selectionOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                selectionOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                selectionOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                checkLabel.bottomAnchor.constraint(
                    equalTo: contentView.bottomAnchor,
                    constant: -5
                ),
                checkLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
                checkLabel.widthAnchor.constraint(equalToConstant: 18),
                checkLabel.heightAnchor.constraint(equalToConstant: 18),
                mediaKindBadge.leadingAnchor.constraint(
                    equalTo: contentView.leadingAnchor,
                    constant: 5
                ),
                mediaKindBadge.bottomAnchor.constraint(
                    equalTo: contentView.bottomAnchor,
                    constant: -5
                ),
                mediaKindBadge.widthAnchor.constraint(equalToConstant: 20),
                mediaKindBadge.heightAnchor.constraint(equalToConstant: 18)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            representedAssetIdentifier = nil
            onAccessibilityActivate = nil
            imageView.image = nil
            updateSelection(false)
            accessibilityLabel = nil
            accessibilityValue = nil
        }

        override func accessibilityActivate() -> Bool {
            guard let onAccessibilityActivate else { return false }
            onAccessibilityActivate()
            return true
        }
        @objc private func accessibilityToggleSelection() -> Bool { accessibilityActivate() }

        func updateSelection(_ isSelected: Bool) {
            selectionOverlay.isHidden = !isSelected
            checkLabel.isHidden = false
            checkLabel.text = isSelected ? "✓" : "○"
            checkLabel.backgroundColor = isSelected ? UIColor(PorcelainMetrics.solidAction) : UIColor.black.withAlphaComponent(0.4)
            checkLabel.textColor = isSelected ? UIColor(PorcelainMetrics.onAccent) : .white
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: isSelected ? "선택 해제" : "선택에 추가",
                target: self, selector: #selector(accessibilityToggleSelection))]
            let scale: CGFloat = isSelected ? 0.86 : 1
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            imageView.transform = transform
            selectionOverlay.transform = transform
            imageView.layer.cornerRadius = isSelected ? 9 : 0
            contentView.backgroundColor = isSelected
                ? UIColor(PorcelainMetrics.selected)
                : .clear
        }

        func updateMediaKind(_ mediaKind: MediaKind) {
            mediaKindBadge.image = UIImage(systemName: mediaKind.symbolName)
            mediaKindBadge.isHidden = false
        }

        func updateAccessibility(
            mediaKind: MediaKind,
            creationDate: Date?,
            selectionOrder: Int?
        ) {
            let dateText = creationDate.map {
                Self.accessibilityDateFormatter.string(from: $0)
            }
            accessibilityLabel = [dateText, mediaKind.accessibilityTitle]
                .compactMap { $0 }
                .joined(separator: ", ")
            if let selectionOrder {
                accessibilityValue = "선택됨, \(selectionOrder)번째"
                accessibilityTraits.insert(.selected)
            } else {
                accessibilityValue = "선택 안 됨"
                accessibilityTraits.remove(.selected)
            }
            accessibilityHint = "두 번 탭하여 선택하거나 선택 해제합니다."
        }

        private static let accessibilityDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
    }

}

struct NasFinderAssetPreview: UIViewControllerRepresentable {
    let asset: PHAsset
    let onRemoveSelection: (() -> Void)?
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> NasFinderPhotoGrid.MediaAssetPreviewViewController {
        NasFinderPhotoGrid.MediaAssetPreviewViewController(asset: asset, imageManager: PHCachingImageManager(),
            showsCloseButton: false, onDelete: onRemoveSelection, onDismiss: onDismiss)
    }
    func updateUIViewController(_ controller: NasFinderPhotoGrid.MediaAssetPreviewViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: NasFinderPhotoGrid.MediaAssetPreviewViewController, coordinator: ()) {
        controller.tearDown()
    }
}

@MainActor private enum NasFinderPhotoPickerTheme {
    /// 6개 테마 공통: 바탕·표면은 현재 테마의 의미 색.
    static var background: Color {
        PorcelainMetrics.paper
    }
    static var backgroundWithBlack: Color {
        PorcelainMetrics.sidebar
    }
    static var panelFill: Color {
        PorcelainMetrics.card
    }
    static var primary: Color { PorcelainMetrics.accent }
    static var secondary: Color { PorcelainMetrics.accent }
    static var text: Color { PorcelainMetrics.graphite }
    static var onSecondary: Color { PorcelainMetrics.onAccent }
    static var primaryUIColor: UIColor { UIColor(primary) }
    static var secondaryUIColor: UIColor { UIColor(secondary) }
}
@MainActor private enum NasFinderPhotoPickerTypography {
    static func uiFont(textStyle: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(for: PorcelainTypeface.uiFont(size: UIFont.preferredFont(forTextStyle: textStyle).pointSize, weight: weight))
    }
}
@MainActor private enum NasFinderPhotoPickerAudio {
    static func activatePlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
