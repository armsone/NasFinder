@preconcurrency import UIKit
import UniformTypeIdentifiers

private struct ShareImportItem {
    let provider: NSItemProvider
    let typeIdentifier: String
    let displayName: String
    let loadsFileURL: Bool
}

private enum ShareItemState {
    case waiting
    case importing
    case staged(ShareIntentItem)
    case failed(String)

    var symbol: String {
        switch self {
        case .waiting: "•"
        case .importing: "↓"
        case .staged: "✓"
        case .failed: "!"
        }
    }

    var detail: String? {
        switch self {
        case .waiting: "대기 중"
        case .importing: "복사 중"
        case let .staged(item): ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        case let .failed(message): message
        }
    }
}

private enum ShareCopyResult: Sendable {
    case staged(ShareIntentItem)
    case failure(String)
}

private final class ShareCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class ShareViewController: UIViewController, @unchecked Sendable {
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusTextView = UITextView()
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let makeVideoButton = UIButton(type: .system)
    private let photoSelectButton = UIButton(type: .system)
    private let choiceStack = UIStackView()

    /// 공유 시트는 이미지 선별 / 영상 만들기 두 가지만 제공한다(폰하드 저장은 앱 본체 기능으로 그대로 남아 있다).
    private var chosenIntent: ShareIntent?
    private var stagingBatchID: UUID?
    private var unsupportedCount = 0
    private var didChooseDestination = false
    private var stagedItems: [ShareIntentItem] = []

    private var items: [ShareImportItem] = []
    private var states: [ShareItemState] = []
    private var loadProgresses: [Progress] = []
    private var completedCount = 0
    private var didFinalize = false
    private var didCommit = false
    private var isCancelled = false
    /// 동시에 복사하는 항목 수. 많은 항목을 공유해도 확장 메모리·파일 핸들이 한꺼번에 늘지 않게 순서대로 이어 간다.
    private static let maximumConcurrentCopies = 4
    private var nextIndexToStart = 0
    private var activeCopies = 0
    private let cancellationGate = ShareCancellationGate()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        collectItemsAndStart()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground

        titleLabel.text = "NasFinder로 보내기"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.textAlignment = .center
        summaryLabel.numberOfLines = 2

        progressView.progress = 0
        progressView.accessibilityLabel = "공유 파일 저장 진행률"

        statusTextView.isEditable = false
        statusTextView.isSelectable = true
        statusTextView.backgroundColor = .secondarySystemBackground
        statusTextView.layer.cornerRadius = 12
        statusTextView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        statusTextView.font = .preferredFont(forTextStyle: .footnote)
        statusTextView.adjustsFontForContentSizeCategory = true

        cancelButton.setTitle("취소", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelImport), for: .touchUpInside)

        doneButton.setTitle("완료", for: .normal)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(completeWithoutOpening), for: .touchUpInside)

        configureChoiceButton(makeVideoButton, title: "영상 만들기", symbol: "film", action: #selector(chooseMakeVideo))
        configureChoiceButton(photoSelectButton, title: "사진 선별", symbol: "photo.stack", action: #selector(choosePhotoSelect))
        choiceStack.axis = .vertical
        choiceStack.spacing = 10
        choiceStack.isHidden = true
        [photoSelectButton, makeVideoButton].forEach(choiceStack.addArrangedSubview)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.alignment = .center
        buttonStack.distribution = .fillEqually

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, choiceStack, progressView, statusTextView, buttonStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 14
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            statusTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            buttonStack.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configureChoiceButton(_ button: UIButton, title: String, symbol: String, action: Selector) {
        button.configuration = .filled()
        button.configuration?.title = title
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.imagePadding = 7
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func choosePhotoSelect() { beginImport(intent: .photoSelect) }
    @objc private func chooseMakeVideo() { beginImport(intent: .makeVideo) }

    /// 목적을 고른 뒤에만 복사를 시작한다. 모든 항목을 App Group 대기 폴더에 복사한 뒤 매니페스트를 한 번에 확정한다.
    private func beginImport(intent: ShareIntent) {
        guard !didChooseDestination, !items.isEmpty else { return }
        didChooseDestination = true
        chosenIntent = intent
        choiceStack.isHidden = true
        do {
            stagingBatchID = try ShareIntentStaging.createBatch(intent: intent)
        } catch {
            didFinalize = true
            summaryLabel.text = "공유 대기 폴더를 만들지 못했습니다: \(error.localizedDescription)"
            cancelButton.isHidden = true
            doneButton.isHidden = false
            return
        }
        summaryLabel.text = "0 / \(items.count)개 저장 중"
        startNextImports()
    }

    private func startNextImports() {
        while activeCopies < Self.maximumConcurrentCopies, nextIndexToStart < items.count, !isCancelled {
            let index = nextIndexToStart
            nextIndexToStart += 1
            activeCopies += 1
            startImport(at: index)
        }
    }

    private func collectItemsAndStart() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        // 공유 항목 수에는 앱이 정한 상한이 없다. 활성화 여부는 Info.plist의 활성화 조건(NSExtensionActivationRule)이 정한다.
        items = providers.compactMap(Self.importItem(from:))
        unsupportedCount = providers.count - items.count
        states = Array(repeating: .waiting, count: items.count)
        renderStatus()

        guard !items.isEmpty else {
            didFinalize = true
            summaryLabel.text = "저장할 사진, 영상 또는 파일을 찾지 못했습니다."
            cancelButton.isHidden = true
            doneButton.isHidden = false
            return
        }

        summaryLabel.text = unsupportedCount > 0
            ? "\(items.count)개 항목을 어떻게 할까요? (지원하지 않는 \(unsupportedCount)개는 제외)"
            : "\(items.count)개 항목을 어떻게 할까요?"
        choiceStack.isHidden = false
    }

    private static func importItem(from provider: NSItemProvider) -> ShareImportItem? {
        let registered = provider.registeredTypeIdentifiers
        let preferredTypes: [UTType] = [.livePhoto, .movie, .image]

        for preferredType in preferredTypes {
            if let identifier = registered.first(where: {
                UTType($0)?.conforms(to: preferredType) == true
            }) {
                return ShareImportItem(
                    provider: provider,
                    typeIdentifier: identifier,
                    displayName: displayName(for: provider, typeIdentifier: identifier),
                    loadsFileURL: false
                )
            }
        }

        if let identifier = registered.first(where: {
            guard let type = UTType($0) else { return false }
            return type != .fileURL && (type.conforms(to: .content) || type.conforms(to: .data))
        }) {
            return ShareImportItem(
                provider: provider,
                typeIdentifier: identifier,
                displayName: displayName(for: provider, typeIdentifier: identifier),
                loadsFileURL: false
            )
        }

        if let identifier = registered.first(where: {
            UTType($0)?.conforms(to: .fileURL) == true
        }) {
            return ShareImportItem(
                provider: provider,
                typeIdentifier: identifier,
                displayName: displayName(for: provider, typeIdentifier: identifier),
                loadsFileURL: true
            )
        }

        return nil
    }

    private static func displayName(for provider: NSItemProvider, typeIdentifier: String) -> String {
        let proposed = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let type = UTType(typeIdentifier)
        if !proposed.isEmpty {
            if (proposed as NSString).pathExtension.isEmpty,
               let suffix = type?.preferredFilenameExtension {
                return "\(proposed).\(suffix)"
            }
            return (proposed as NSString).lastPathComponent
        }

        let suffix = type?.preferredFilenameExtension.map { ".\($0)" } ?? ""
        return "공유 파일\(suffix)"
    }

    private func startImport(at index: Int) {
        states[index] = .importing
        renderStatus()
        let item = items[index]
        let displayName = item.displayName
        let typeIdentifier = item.typeIdentifier
        // 공유 대기 배치 ID는 메인 액터에서 읽어 백그라운드 복사에 값으로 넘긴다.
        let batchID = stagingBatchID

        if item.loadsFileURL {
            item.provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { [weak self] value, error in
                let loadedURL = Self.decodeFileURL(from: value)
                let errorMessage = error?.localizedDescription
                self?.copyLoadedItem(
                    at: loadedURL,
                    index: index,
                    displayName: loadedURL?.lastPathComponent ?? displayName,
                    typeIdentifier: typeIdentifier,
                    batchID: batchID,
                    providerError: errorMessage
                )
            }
        } else {
            let progress = item.provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { [weak self] url, error in
                let errorMessage = error?.localizedDescription
                self?.copyLoadedItem(
                    at: url,
                    index: index,
                    displayName: displayName,
                    typeIdentifier: typeIdentifier,
                    batchID: batchID,
                    providerError: errorMessage
                )
            }
            loadProgresses.append(progress)
        }
    }

    nonisolated private static func decodeFileURL(from value: NSSecureCoding?) -> URL? {
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let data = value as? Data,
           let string = String(data: data, encoding: .utf8) {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let string = value as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private func copyLoadedItem(
        at url: URL?,
        index: Int,
        displayName: String,
        typeIdentifier: String,
        batchID: UUID?,
        providerError: String?
    ) {
        guard !cancellationGate.isCancelled else { return }
        let result: ShareCopyResult
        if let url {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                if let batchID {
                    let type = UTType(typeIdentifier)
                    let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
                    // 영상 만들기/이미지 선별은 사진·영상만 받는다. 다른 형식은 항목 오류로 남기고 나머지는 계속 진행한다.
                    guard isVideo || type?.conforms(to: .image) == true else {
                        throw ShareIntentStaging.StagingError.unsupportedType
                    }
                    let staged = try ShareIntentStaging.stage(
                        fileAt: url, originalFilename: displayName, contentTypeIdentifier: typeIdentifier,
                        isVideo: isVideo, intoBatch: batchID)
                    if cancellationGate.isCancelled { return }
                    result = .staged(staged)
                } else {
                    result = .failure("공유 대기 폴더가 준비되지 않았습니다.")
                }
            } catch {
                result = .failure(error.localizedDescription)
            }
        } else {
            result = .failure(providerError ?? "공유 파일을 읽을 수 없습니다.")
        }

        DispatchQueue.main.async { [weak self] in
            self?.finishImport(at: index, result: result)
        }
    }

    private func finishImport(at index: Int, result: ShareCopyResult) {
        guard states.indices.contains(index) else { return }

        if isCancelled { return }

        switch result {
        case let .staged(item):
            states[index] = .staged(item)
        case let .failure(message):
            states[index] = .failed(message)
        }
        completedCount += 1
        progressView.setProgress(Float(completedCount) / Float(items.count), animated: true)
        summaryLabel.text = "\(completedCount) / \(items.count)개 처리함"
        renderStatus()

        activeCopies -= 1
        if completedCount == items.count {
            finalizeStagedBatch()
        } else {
            startNextImports()
        }
    }

    /// 받은 순서(공유 항목 순서)를 유지해 배치를 확정한다. 실패 항목은 사유와 함께 앱에도 알린다.
    private func finalizeStagedBatch() {
        guard !didFinalize, !isCancelled, let batchID = stagingBatchID, let intent = chosenIntent else { return }
        didFinalize = true
        var skipped: [String] = []
        var staged: [ShareIntentItem] = []
        for (item, state) in zip(items, states) {
            switch state {
            case let .staged(stagedItem): staged.append(stagedItem)
            case let .failed(message): skipped.append("\(item.displayName): \(message)")
            default: break
            }
        }
        if unsupportedCount > 0 { skipped.append("지원하지 않는 형식 \(unsupportedCount)개") }
        guard !staged.isEmpty else {
            ShareIntentStaging.discardUncommitted(batchID: batchID)
            summaryLabel.text = "가져올 수 있는 사진이나 영상이 없습니다."
            cancelButton.isHidden = true
            doneButton.isHidden = false
            return
        }
        do {
            try ShareIntentStaging.commit(ShareIntentBatch(
                id: batchID, intent: intent, createdAt: Date(), items: staged, skippedReasons: skipped))
            didCommit = true
            stagedItems = staged
            let failed = states.count - staged.count
            // 공유 확장은 앱 자동 열기를 보장받지 못한다(공식 문서: 확장 종류가 open 지원을 정한다). 파일과 작업은 App Group에
            // 원자적으로 남겼으므로 사용자가 NasFinder를 열면 앱이 다음 foreground에서 이어서 처리한다.
            let continuation = intent == .makeVideo
                ? "NasFinder를 열면 작업대에 담을 수 있습니다."
                : "NasFinder를 열면 사진 선별을 이어갑니다."
            summaryLabel.text = failed == 0
                ? "\(staged.count)개를 보관했습니다. \(continuation)"
                : "\(staged.count)개를 보관했고 \(failed)개는 가져오지 못했습니다. \(continuation)"
            cancelButton.isHidden = true
            doneButton.isHidden = false
        } catch {
            ShareIntentStaging.discardUncommitted(batchID: batchID)
            summaryLabel.text = "공유 대기 정보를 저장하지 못했습니다: \(error.localizedDescription)"
            cancelButton.isHidden = true
            doneButton.isHidden = false
        }
    }

    private func renderStatus() {
        let lines = zip(items, states).map { item, state in
            let detail = state.detail.map { " — \($0)" } ?? ""
            return "\(state.symbol) \(item.displayName)\(detail)"
        }
        statusTextView.text = lines.joined(separator: "\n")
    }

    @objc private func cancelImport() {
        guard !didCommit else { return }
        isCancelled = true
        cancellationGate.cancel()
        loadProgresses.forEach { $0.cancel() }
        if let batchID = stagingBatchID { ShareIntentStaging.discardUncommitted(batchID: batchID) }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func completeWithoutOpening() {
        guard didFinalize else { return }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
