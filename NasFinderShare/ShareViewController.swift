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
    case saved(SharedInboxRecord)
    case failed(String)

    var symbol: String {
        switch self {
        case .waiting: "•"
        case .importing: "↓"
        case .saved: "✓"
        case .failed: "!"
        }
    }

    var detail: String? {
        switch self {
        case .waiting: "대기 중"
        case .importing: "복사 중"
        case let .saved(record): ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)
        case let .failed(message): message
        }
    }
}

private enum ShareCopyResult: Sendable {
    case success(SharedInboxRecord)
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
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private var items: [ShareImportItem] = []
    private var states: [ShareItemState] = []
    private var loadProgresses: [Progress] = []
    private var completedCount = 0
    private var didFinalize = false
    private var didCommit = false
    private var isCancelled = false
    private var attemptedAutomaticOpen = false
    private var committedRecords: [SharedInboxRecord] = []
    private let cancellationGate = ShareCancellationGate()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        collectItemsAndStart()
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground

        titleLabel.text = "NasFinder에 저장"
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

        openButton.configuration = .filled()
        openButton.configuration?.title = "NasFinder 열기"
        openButton.configuration?.image = UIImage(systemName: "arrow.up.forward.app")
        openButton.configuration?.imagePadding = 7
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openNasFinder), for: .touchUpInside)

        doneButton.setTitle("완료", for: .normal)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(completeWithoutOpening), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, doneButton, openButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.alignment = .center
        buttonStack.distribution = .fillEqually

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, progressView, statusTextView, buttonStack])
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

    private func collectItemsAndStart() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        items = providers.prefix(50).compactMap(Self.importItem(from:))
        states = Array(repeating: .waiting, count: items.count)
        renderStatus()

        guard !items.isEmpty else {
            didFinalize = true
            summaryLabel.text = "저장할 사진, 영상 또는 파일을 찾지 못했습니다."
            cancelButton.isHidden = true
            doneButton.isHidden = false
            return
        }

        summaryLabel.text = "0 / \(items.count)개 저장 중"
        for index in items.indices {
            startImport(at: index)
        }
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
                let record = try SharedInbox.importTemporaryFile(
                    at: url,
                    originalFilename: displayName,
                    contentTypeIdentifier: typeIdentifier
                )
                if cancellationGate.isCancelled {
                    try? SharedInbox.delete(record)
                    return
                }
                result = .success(record)
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

        if isCancelled {
            if case let .success(record) = result {
                try? SharedInbox.delete(record)
            }
            return
        }

        switch result {
        case let .success(record):
            states[index] = .saved(record)
        case let .failure(message):
            states[index] = .failed(message)
        }
        completedCount += 1
        progressView.setProgress(Float(completedCount) / Float(items.count), animated: true)
        summaryLabel.text = "\(completedCount) / \(items.count)개 처리함"
        renderStatus()

        if completedCount == items.count {
            finalizeBatch()
        }
    }

    private func finalizeBatch() {
        guard !didFinalize, !isCancelled else { return }
        didFinalize = true

        let successfulRecords = states.compactMap { state -> SharedInboxRecord? in
            if case let .saved(record) = state { return record }
            return nil
        }
        let failedCount = states.count - successfulRecords.count

        guard !successfulRecords.isEmpty else {
            summaryLabel.text = "모든 파일을 저장하지 못했습니다."
            cancelButton.isHidden = true
            doneButton.isHidden = false
            return
        }

        do {
            try SharedInbox.append(records: successfulRecords)
            didCommit = true
            committedRecords = successfulRecords
            if failedCount == 0 {
                summaryLabel.text = "\(successfulRecords.count)개 파일을 저장했습니다."
            } else {
                summaryLabel.text = "\(successfulRecords.count)개 저장, \(failedCount)개 실패"
            }
            cancelButton.isHidden = true
            doneButton.isHidden = false
            openButton.isHidden = false
            attemptToOpenNasFinder(automatic: true)
        } catch {
            for record in successfulRecords {
                try? SharedInbox.delete(record)
            }
            for index in states.indices {
                if case .saved = states[index] {
                    states[index] = .failed("저장 목록 반영 실패: \(error.localizedDescription)")
                }
            }
            renderStatus()
            summaryLabel.text = "파일 목록을 저장하지 못했습니다."
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
        for case let .saved(record) in states {
            try? SharedInbox.delete(record)
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func openNasFinder() {
        attemptToOpenNasFinder(automatic: false)
    }

    private func attemptToOpenNasFinder(automatic: Bool) {
        var components = URLComponents()
        components.scheme = "nasfinder"
        components.host = "inbox"
        if let latestRecord = committedRecords.last {
            components.queryItems = [
                URLQueryItem(name: "id", value: latestRecord.id.uuidString)
            ]
        }
        guard didCommit,
              let deepLink = components.url,
              !automatic || !attemptedAutomaticOpen else { return }
        if automatic { attemptedAutomaticOpen = true }

        openButton.isEnabled = false
        extensionContext?.open(deepLink) { [weak self] didOpen in
            DispatchQueue.main.async {
                guard let self else { return }
                self.openButton.isEnabled = true
                if didOpen {
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } else {
                    // Some iOS versions reject NSExtensionContext.open from a
                    // share extension even though the containing app owns the
                    // URL scheme. HanClip's established compatibility path
                    // walks the responder chain and sends the legacy openURL:
                    // action. Keep it strictly as a fallback after the public
                    // API reports failure.
                    if self.openThroughLegacyResponderChain(deepLink) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.extensionContext?.completeRequest(
                                returningItems: [],
                                completionHandler: nil
                            )
                        }
                    } else {
                        self.openButton.isHidden = false
                        self.doneButton.isHidden = false
                        self.summaryLabel.text = "파일은 저장됐습니다. NasFinder를 직접 열면 받은 파일에서 확인할 수 있습니다."
                    }
                }
            }
        }
    }

    private func openThroughLegacyResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    @objc private func completeWithoutOpening() {
        guard didFinalize else { return }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
