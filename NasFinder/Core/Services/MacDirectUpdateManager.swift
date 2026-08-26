import Combine
import CryptoKit
import Foundation
import Security

#if targetEnvironment(macCatalyst)
import UIKit
#endif

struct DirectUpdateRelease: Equatable, Sendable {
    let version: String
    let build: String
    let releaseNotes: String
    let downloadURL: URL
    let assetName: String
    let expectedSHA256: String
    let expectedByteCount: Int64
}

enum DirectUpdateState: Equatable, Sendable {
    case idle
    case checking
    case latest
    case available(DirectUpdateRelease)
    case downloading(DirectUpdateRelease, progress: Double, isPaused: Bool)
    case installReady(DirectUpdateRelease, fileURL: URL)
    case error(message: String, release: DirectUpdateRelease?)
}

enum DirectUpdateError: LocalizedError, Sendable {
    case invalidMetadata(String)
    case insecureURL
    case serverResponse
    case integrityMismatch
    case invalidDeveloperSignature
    case installerHandoffFailed

    var errorDescription: String? {
        switch self {
        case .invalidMetadata(let reason):
            "업데이트 정보가 올바르지 않습니다: \(reason)"
        case .insecureURL:
            "안전한 HTTPS 업데이트 주소가 아닙니다."
        case .serverResponse:
            "업데이트 서버가 올바르게 응답하지 않았습니다."
        case .integrityMismatch:
            "다운로드 파일이 손상되었거나 변조되어 삭제했습니다."
        case .invalidDeveloperSignature:
            "NasFinder 개발자 서명을 확인할 수 없어 파일을 삭제했습니다."
        case .installerHandoffFailed:
            "설치 파일을 열지 못했습니다. 다시 시도해 주세요."
        }
    }
}

protocol DirectUpdateReleaseProviding: Sendable {
    func latestRelease(currentVersion: String, currentBuild: String) async throws -> DirectUpdateRelease?
}

protocol DirectUpdateTransferring: Sendable {
    func download(
        _ release: DirectUpdateRelease,
        permitsConstrainedNetworkAccess: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    func pause()
    func resume()
    func cancel()
}

protocol DirectUpdateArtifactVerifying: Sendable {
    func verify(fileURL: URL, release: DirectUpdateRelease) async throws
}

protocol DirectUpdateInstallerHandingOff: Sendable {
    @MainActor func openInstaller(at fileURL: URL) async -> Bool
}

@MainActor
final class MacDirectUpdateManager: ObservableObject {
    #if targetEnvironment(macCatalyst)
    static let shared = MacDirectUpdateManager(
        releaseProvider: GitHubDirectUpdateReleaseProvider(),
        transfer: URLSessionDirectUpdateTransfer(),
        verifier: MacDirectUpdateArtifactVerifier(),
        handoff: MacDirectUpdateInstallerHandoff(),
        currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    )
    #endif

    static let automaticDownloadStorageKey = "macDirectUpdateAutomaticDownload.v1"

    @Published private(set) var state: DirectUpdateState = .idle
    @Published private(set) var didHandoffInstaller = false
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { defaults.set(automaticallyDownloadsUpdates, forKey: Self.automaticDownloadStorageKey) }
    }

    private let releaseProvider: any DirectUpdateReleaseProviding
    private let transfer: any DirectUpdateTransferring
    private let verifier: any DirectUpdateArtifactVerifying
    private let handoff: any DirectUpdateInstallerHandingOff
    private let currentVersion: String
    private let currentBuild: String
    private let defaults: UserDefaults
    private let automaticDownloadPermitted: @Sendable () -> Bool
    private var operation: Task<Void, Never>?
    private var lastRelease: DirectUpdateRelease?
    private var hasPerformedAutomaticCheck = false

    init(
        releaseProvider: any DirectUpdateReleaseProviding,
        transfer: any DirectUpdateTransferring,
        verifier: any DirectUpdateArtifactVerifying,
        handoff: any DirectUpdateInstallerHandingOff,
        currentVersion: String,
        currentBuild: String,
        defaults: UserDefaults = .standard,
        automaticDownloadPermitted: @escaping @Sendable () -> Bool = {
            !ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.releaseProvider = releaseProvider
        self.transfer = transfer
        self.verifier = verifier
        self.handoff = handoff
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.defaults = defaults
        self.automaticDownloadPermitted = automaticDownloadPermitted
        self.automaticallyDownloadsUpdates = defaults.object(
            forKey: Self.automaticDownloadStorageKey
        ) as? Bool ?? true
    }

    func checkForUpdates(manual: Bool = true) {
        guard operation == nil else { return }
        didHandoffInstaller = false
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await releaseProvider.latestRelease(
                    currentVersion: currentVersion,
                    currentBuild: currentBuild
                )
                try Task.checkCancellation()
                guard let release else {
                    state = .latest
                    operation = nil
                    return
                }
                lastRelease = release
                state = .available(release)
                operation = nil
                if !manual,
                   automaticallyDownloadsUpdates,
                   automaticDownloadPermitted() {
                    download(release, isAutomatic: true)
                }
            } catch is CancellationError {
                state = .idle
                operation = nil
            } catch {
                state = .error(message: error.localizedDescription, release: nil)
                operation = nil
            }
        }
    }

    func checkAtStartupIfNeeded() {
        guard !hasPerformedAutomaticCheck else { return }
        hasPerformedAutomaticCheck = true
        checkForUpdates(manual: false)
    }

    func downloadAvailableUpdate() {
        guard case .available(let release) = state else { return }
        download(release, isAutomatic: false)
    }

    func pauseDownload() {
        guard case .downloading(let release, let progress, false) = state else { return }
        transfer.pause()
        state = .downloading(release, progress: progress, isPaused: true)
    }

    func resumeDownload() {
        guard case .downloading(let release, let progress, true) = state else { return }
        transfer.resume()
        state = .downloading(release, progress: progress, isPaused: false)
    }

    func cancelDownload() {
        transfer.cancel()
        operation?.cancel()
        operation = nil
        if let lastRelease {
            state = .available(lastRelease)
        } else {
            state = .idle
        }
    }

    func retry() {
        if let lastRelease {
            state = .available(lastRelease)
            download(lastRelease, isAutomatic: false)
        } else {
            checkForUpdates()
        }
    }

    func handoffInstaller() {
        guard case .installReady(_, let fileURL) = state, operation == nil else { return }
        operation = Task { [weak self] in
            guard let self else { return }
            if await handoff.openInstaller(at: fileURL) {
                didHandoffInstaller = true
            } else {
                state = .error(
                    message: DirectUpdateError.installerHandoffFailed.localizedDescription,
                    release: lastRelease
                )
            }
            operation = nil
        }
    }

    private func download(_ release: DirectUpdateRelease, isAutomatic: Bool) {
        guard operation == nil else { return }
        state = .downloading(release, progress: 0, isPaused: false)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await transfer.download(
                    release,
                    permitsConstrainedNetworkAccess: !isAutomatic
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              case .downloading(let activeRelease, _, let isPaused) = self.state,
                              activeRelease == release
                        else { return }
                        self.state = .downloading(
                            release,
                            progress: min(max(progress, 0), 1),
                            isPaused: isPaused
                        )
                    }
                }
                try Task.checkCancellation()
                try await verifier.verify(fileURL: fileURL, release: release)
                try Task.checkCancellation()
                state = .installReady(release, fileURL: fileURL)
                operation = nil
            } catch is CancellationError {
                operation = nil
            } catch {
                state = .error(message: error.localizedDescription, release: release)
                operation = nil
            }
        }
    }
}

struct GitHubDirectUpdateReleaseProvider: DirectUpdateReleaseProviding {
    private static let endpoint = URL(
        string: "https://api.github.com/repos/armsone/NasFinder/releases?per_page=30"
    )!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease(currentVersion: String, currentBuild: String) async throws -> DirectUpdateRelease? {
        guard Self.endpoint.scheme == "https" else { throw DirectUpdateError.insecureURL }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NasFinder-Mac-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectUpdateError.serverResponse
        }
        return try Self.validatedLatestRelease(
            from: data,
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )
    }

    static func validatedLatestRelease(
        from data: Data,
        currentVersion: String,
        currentBuild: String
    ) throws -> DirectUpdateRelease? {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        let candidates = try releases.compactMap { release -> DirectUpdateRelease? in
            guard !release.draft, !release.prerelease, release.tagName.hasPrefix("mac-v") else {
                return nil
            }
            return try Self.validatedRelease(release)
        }
        return candidates
            .filter {
                Self.compare($0.version, currentVersion) == .orderedDescending
                    || (Self.compare($0.version, currentVersion) == .orderedSame
                        && Self.compare($0.build, currentBuild) == .orderedDescending)
            }
            .sorted {
                let versionOrder = Self.compare($0.version, $1.version)
                return versionOrder == .orderedSame
                    ? Self.compare($0.build, $1.build) == .orderedDescending
                    : versionOrder == .orderedDescending
            }
            .first
    }

    private static func validatedRelease(_ release: GitHubRelease) throws -> DirectUpdateRelease {
        let version = String(release.tagName.dropFirst("mac-v".count))
        guard isNumericVersion(version) else {
            throw DirectUpdateError.invalidMetadata("버전")
        }
        let fields = metadataFields(release.body)
        guard fields["Product-ID"] == "com.armsone.nasfinder" else {
            throw DirectUpdateError.invalidMetadata("제품")
        }
        guard fields["Target-OS"] == "macOS" else {
            throw DirectUpdateError.invalidMetadata("운영체제")
        }
        let architectures = Set(
            (fields["Architectures"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        guard architectures == Set(["arm64", "x86_64"]) else {
            throw DirectUpdateError.invalidMetadata("Universal 아키텍처")
        }
        guard let build = fields["Build-Number"],
              !build.isEmpty,
              build.allSatisfy(\.isNumber)
        else {
            throw DirectUpdateError.invalidMetadata("빌드")
        }
        let expectedName = "NasFinder-Mac-\(version)-\(build).dmg"
        guard let asset = release.assets.first(where: { $0.name == expectedName }) else {
            throw DirectUpdateError.invalidMetadata("Mac 설치 파일")
        }
        guard asset.downloadURL.scheme == "https", asset.downloadURL.host == "github.com" else {
            throw DirectUpdateError.insecureURL
        }
        guard let digest = asset.digest?.lowercased(),
              digest.hasPrefix("sha256:"),
              digest.dropFirst("sha256:".count).count == 64,
              digest.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit })
        else {
            throw DirectUpdateError.invalidMetadata("SHA-256")
        }
        return DirectUpdateRelease(
            version: version,
            build: build,
            releaseNotes: release.body,
            downloadURL: asset.downloadURL,
            assetName: expectedName,
            expectedSHA256: String(digest.dropFirst("sha256:".count)),
            expectedByteCount: asset.size
        )
    }

    private static func metadataFields(_ body: String) -> [String: String] {
        body.split(whereSeparator: \.isNewline).reduce(into: [:]) { fields, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
    }

    private static func isNumericVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, draft, prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            let digest: String?
            let size: Int64

            enum CodingKeys: String, CodingKey {
                case name, digest, size
                case downloadURL = "browser_download_url"
            }
        }
    }
}

final class URLSessionDirectUpdateTransfer: NSObject, DirectUpdateTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var request: URLRequest?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var resumeData: Data?
    private var stagedURL: URL?
    private var isPausing = false
    private var isCancelled = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func download(
        _ release: DirectUpdateRelease,
        permitsConstrainedNetworkAccess: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard release.downloadURL.scheme == "https", release.downloadURL.host == "github.com" else {
            throw DirectUpdateError.insecureURL
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.progressHandler = progress
                var request = URLRequest(url: release.downloadURL)
                request.allowsConstrainedNetworkAccess = permitsConstrainedNetworkAccess
                request.allowsExpensiveNetworkAccess = permitsConstrainedNetworkAccess
                self.request = request
                self.resumeData = nil
                self.stagedURL = nil
                self.isPausing = false
                self.isCancelled = false
                let task = session.downloadTask(with: self.request!)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func pause() {
        lock.lock()
        guard let task, !isPausing, !isCancelled else {
            lock.unlock()
            return
        }
        isPausing = true
        lock.unlock()
        let pausedTask = task
        task.cancel(byProducingResumeData: { [weak self, weak pausedTask] data in
            guard let self else { return }
            self.lock.lock()
            if self.task === pausedTask {
                self.resumeData = data
                self.task = nil
            }
            self.lock.unlock()
        })
    }

    func resume() {
        lock.lock()
        guard isPausing, !isCancelled else {
            lock.unlock()
            return
        }
        let newTask: URLSessionDownloadTask?
        if let resumeData {
            newTask = session.downloadTask(withResumeData: resumeData)
        } else if let request {
            newTask = session.downloadTask(with: request)
        } else {
            newTask = nil
        }
        self.resumeData = nil
        self.isPausing = false
        self.task = newTask
        lock.unlock()
        newTask?.resume()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        let continuation = self.continuation
        let stagedURL = self.stagedURL
        self.task = nil
        self.continuation = nil
        self.stagedURL = nil
        self.resumeData = nil
        lock.unlock()
        task?.cancel()
        if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
        continuation?.resume(throwing: CancellationError())
    }
}

extension URLSessionDirectUpdateTransfer: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NasFinderUpdates", directoryHint: .isDirectory)
        let destination = directory.appending(path: UUID().uuidString + ".dmg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            stagedURL = destination
            lock.unlock()
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let isCurrentTask = self.task === task
        let paused = isPausing && !isCancelled
        let destination = stagedURL
        lock.unlock()
        guard isCurrentTask else { return }
        if paused { return }
        if let error {
            finish(.failure(error))
        } else if let destination {
            finish(.success(destination))
        } else {
            finish(.failure(DirectUpdateError.serverResponse))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        let failedStagedURL: URL?
        if case .failure = result {
            failedStagedURL = stagedURL
            stagedURL = nil
        } else {
            failedStagedURL = nil
        }
        self.continuation = nil
        self.task = nil
        lock.unlock()
        if let failedStagedURL { try? FileManager.default.removeItem(at: failedStagedURL) }
        continuation?.resume(with: result)
    }
}

struct MacDirectUpdateArtifactVerifier: DirectUpdateArtifactVerifying {
    func verify(fileURL: URL, release: DirectUpdateRelease) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard byteCount == release.expectedByteCount else {
            try? FileManager.default.removeItem(at: fileURL)
            throw DirectUpdateError.integrityMismatch
        }
        let digest = try Self.sha256(fileURL).lowercased()
        guard digest == release.expectedSHA256.lowercased() else {
            try? FileManager.default.removeItem(at: fileURL)
            throw DirectUpdateError.integrityMismatch
        }
        guard Self.hasExpectedDeveloperSignature(fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw DirectUpdateError.invalidDeveloperSignature
        }
    }

    private static func sha256(_ fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hasExpectedDeveloperSignature(_ fileURL: URL) -> Bool {
        #if targetEnvironment(macCatalyst)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(fileURL as CFURL, [], &code) == errSecSuccess,
              let code
        else { return false }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"T7B4EPLHPK\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)
        )
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        #else
        false
        #endif
    }
}

#if targetEnvironment(macCatalyst)
struct MacDirectUpdateInstallerHandoff: DirectUpdateInstallerHandingOff {
    @MainActor
    func openInstaller(at fileURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(fileURL, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}
#endif
