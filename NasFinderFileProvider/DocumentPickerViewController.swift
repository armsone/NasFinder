import UIKit

@available(iOS, deprecated: 14.0, message: "Compatibility UI for document import hosts")
final class NasFinderDocumentPickerViewController: UIDocumentPickerExtensionViewController {
    private struct ConnectionContext {
        let connection: ProviderConnection
        let backend: any ProviderRemoteBackend
    }

    private struct DirectoryLevel {
        let name: String
        let path: String
    }

    private enum ScreenState {
        case connections
        case directory
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private var connections: [ConnectionContext] = []
    private var selectedConnection: ConnectionContext?
    private var directoryStack: [DirectoryLevel] = []
    private var items: [ProviderRemoteNode] = []
    private var operationTask: Task<Void, Never>?
    private var downloadAlert: UIAlertController?
    private var screenState: ScreenState = .connections

    override func prepareForPresentation(in mode: UIDocumentPickerMode) {
        super.prepareForPresentation(in: mode)
        configureInterfaceIfNeeded()
        showConnections()
    }

    deinit {
        operationTask?.cancel()
    }

    private func configureInterfaceIfNeeded() {
        guard tableView.superview == nil else { return }

        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(tableView)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func showConnections() {
        operationTask?.cancel()
        screenState = .connections
        selectedConnection = nil
        directoryStack = []
        items = []
        title = "NasFinder"
        navigationItem.leftBarButtonItem = nil
        setLoading(true)

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                connections = try loadConnectionContexts()
                setLoading(false)
                if connections.count == 1, let only = connections.first {
                    selectConnection(only)
                } else {
                    updateEmptyMessage()
                    tableView.reloadData()
                }
            } catch is CancellationError {
                setLoading(false)
            } catch {
                setLoading(false)
                showError(error)
            }
        }
    }

    private func selectConnection(_ context: ConnectionContext) {
        selectedConnection = context
        directoryStack = [
            DirectoryLevel(
                name: context.connection.name,
                path: context.connection.normalizedRootPath
            )
        ]
        screenState = .directory
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(navigateBack)
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = "이전"
        loadCurrentDirectory()
    }

    private func loadCurrentDirectory() {
        guard let backend = selectedConnection?.backend,
              let directory = directoryStack.last else { return }
        operationTask?.cancel()
        title = directory.name
        items = []
        tableView.reloadData()
        setLoading(true)

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                items = try await backend.list(directory: directory.path)
                    .filter { !$0.name.hasPrefix(".") }
                    .sorted { lhs, rhs in
                        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                setLoading(false)
                updateEmptyMessage()
                tableView.reloadData()
            } catch is CancellationError {
                setLoading(false)
            } catch {
                setLoading(false)
                showError(error)
            }
        }
    }

    private func open(_ item: ProviderRemoteNode) {
        if item.isDirectory {
            directoryStack.append(DirectoryLevel(name: item.name, path: item.path))
            loadCurrentDirectory()
            return
        }
        download(item)
    }

    private func download(_ item: ProviderRemoteNode) {
        guard let backend = selectedConnection?.backend else { return }
        operationTask?.cancel()

        let alert = UIAlertController(
            title: "파일을 가져오는 중",
            message: downloadMessage(for: item),
            preferredStyle: .alert
        )
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        alert.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -58)
        ])
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in
            self?.operationTask?.cancel()
            self?.operationTask = nil
        })
        downloadAlert = alert
        present(alert, animated: true)

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let destination = try downloadDestination(filename: item.name)
                try await backend.download(path: item.path, to: destination)
                try Task.checkCancellation()
                await dismissDownloadAlert()
                dismissGrantingAccess(to: destination)
            } catch is CancellationError {
                await dismissDownloadAlert()
            } catch {
                await dismissDownloadAlert()
                showError(error)
            }
        }
    }

    @objc private func navigateBack() {
        if directoryStack.count > 1 {
            directoryStack.removeLast()
            loadCurrentDirectory()
        } else {
            showConnections()
        }
    }

    private func setLoading(_ loading: Bool) {
        loading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
        tableView.isUserInteractionEnabled = !loading
        if loading { messageLabel.isHidden = true }
    }

    private func updateEmptyMessage() {
        let message: String?
        switch screenState {
        case .connections:
            message = connections.isEmpty
                ? "NasFinder 앱에서 Synology 또는 SFTP 연결을 먼저 추가하세요."
                : nil
        case .directory:
            message = items.isEmpty ? "이 폴더는 비어 있습니다." : nil
        }
        messageLabel.text = message
        messageLabel.isHidden = message == nil
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(
            title: "파일을 불러오지 못했습니다",
            message: (error as NSError).localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "다시 시도", style: .default) { [weak self] _ in
            guard let self else { return }
            switch screenState {
            case .connections: showConnections()
            case .directory: loadCurrentDirectory()
            }
        })
        alert.addAction(UIAlertAction(title: "확인", style: .cancel))
        present(alert, animated: true)
    }

    private func dismissDownloadAlert() async {
        guard let downloadAlert else { return }
        await withCheckedContinuation { continuation in
            downloadAlert.dismiss(animated: true) {
                continuation.resume()
            }
        }
        self.downloadAlert = nil
    }

    private func loadConnectionContexts() throws -> [ConnectionContext] {
        guard let defaults = UserDefaults(
            suiteName: NasFinderFileProviderIdentifiers.appGroup
        ), let data = defaults.data(
            forKey: NasFinderFileProviderIdentifiers.connectionStorageKey
        ) else {
            return []
        }
        let stored = try JSONDecoder().decode([ProviderConnection].self, from: data)
        return try stored.compactMap { connection in
            let backend: any ProviderRemoteBackend
            switch connection.kind {
            case .synology:
                backend = SynologyProviderBackend(
                    connection: connection,
                    password: try SharedKeychainCredentialReader().password(for: connection.id)
                )
            case .sftp:
                backend = SFTPProviderBackend(
                    connection: connection,
                    password: try SharedKeychainCredentialReader().password(for: connection.id)
                )
            case .smb, .webDAV, .ftp, .dropbox, .oneDrive, .googleDrive:
                return nil
            }
            return ConnectionContext(connection: connection, backend: backend)
        }
    }

    private func downloadDestination(filename: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: NasFinderFileProviderIdentifiers.appGroup
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = container
            .appendingPathComponent("DocumentPickerImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
    }

    private func downloadMessage(for item: ProviderRemoteNode) -> String {
        guard let size = item.size else { return item.name }
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "\(item.name)\n\(sizeText)"
    }
}

extension NasFinderDocumentPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch screenState {
        case .connections: connections.count
        case .directory: items.count
        }
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.imageProperties.tintColor = .tintColor

        switch screenState {
        case .connections:
            let context = connections[indexPath.row]
            configuration.text = context.connection.name
            configuration.secondaryText = context.connection.host
            configuration.image = UIImage(
                systemName: context.connection.kind == .synology
                    ? "externaldrive.connected.to.line.below"
                    : "network.badge.shield.half.filled"
            )
            cell.accessoryType = .disclosureIndicator
        case .directory:
            let item = items[indexPath.row]
            configuration.text = item.name
            configuration.secondaryText = item.isDirectory || item.size == nil
                ? nil
                : ByteCountFormatter.string(fromByteCount: item.size!, countStyle: .file)
            configuration.image = UIImage(systemName: item.isDirectory ? "folder.fill" : fileIcon(item.name))
            cell.accessoryType = item.isDirectory ? .disclosureIndicator : .none
        }
        cell.contentConfiguration = configuration
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch screenState {
        case .connections: selectConnection(connections[indexPath.row])
        case .directory: open(items[indexPath.row])
        }
    }

    private func fileIcon(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp"].contains(ext) { return "photo" }
        if ["mp4", "mov", "mkv", "avi", "wmv", "mpg", "mpeg", "m4v"].contains(ext) { return "film" }
        if ["mp3", "m4a", "wav", "flac", "aac"].contains(ext) { return "waveform" }
        return "doc"
    }
}
