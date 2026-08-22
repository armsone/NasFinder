import Combine
import Foundation
import AuthenticationServices
import UIKit
import UniformTypeIdentifiers

/// Google 포토 가져오기 흐름에서 사용자에게 그대로 보여줄 수 있는 안전한 오류.
/// 토큰·pickerUri·세션 ID 등 민감한 값은 절대 포함하지 않는다.
enum GooglePhotosImportFlowError: LocalizedError, Equatable, Sendable {
    case pickerOpenFailed
    case selectionTimedOut

    var errorDescription: String? {
        switch self {
        case .pickerOpenFailed:
            "Google 포토 선택 화면을 열지 못했습니다. 잠시 후 다시 시도해 주세요."
        case .selectionTimedOut:
            "Google 포토 선택 시간이 만료되었습니다. 다시 시도해 주세요."
        }
    }
}

/// Google 포토 Picker 가져오기 흐름의 단계.
enum GooglePhotosImportFlowPhase: Equatable, Sendable {
    case idle
    case disclosure
    case preparing
    case waitingForSelection
    case importing(completed: Int, total: Int)
    case finished(imported: Int, skipped: Int, failed: Int)
    case cancelled(imported: Int)
    case failed(message: String)
}

/// 사전 고지 → 인증 → Picker 세션 생성 → 선택 대기(폴링) → 순차 가져오기 → 세션 삭제까지
/// 전체 흐름을 관리하는 상태 모델. 모든 외부 효과(OAuth·Keychain·네트워크·외부 URL 열기)는
/// 주입식이라 테스트에서 실제 시스템을 건드리지 않는다.
@MainActor
final class GooglePhotosImportFlowController: ObservableObject {
    struct Dependencies: Sendable {
        var loadConfiguration: @Sendable () throws -> GooglePhotosOAuthConfiguration
        var loadCredential: @Sendable () throws -> GooglePhotosCredential?
        var saveCredential: @Sendable (GooglePhotosCredential) throws -> Void
        var authorize: @MainActor @Sendable (GooglePhotosOAuthConfiguration) async throws -> GooglePhotosCredential
        var refresh: @Sendable (GooglePhotosOAuthConfiguration, GooglePhotosCredential) async throws
            -> GooglePhotosCredential
        var createSession: @Sendable (_ accessToken: String) async throws -> GooglePhotosPickingSession
        var fetchSession: @Sendable (_ accessToken: String, _ sessionID: String) async throws
            -> GooglePhotosPickingSession
        var deleteSession: @Sendable (_ accessToken: String, _ sessionID: String) async throws -> Void
        var listMediaItems: @Sendable (_ accessToken: String, _ sessionID: String) async throws
            -> [GooglePhotosPickedMediaItem]
        var downloadItem: @Sendable (_ accessToken: String, _ item: GooglePhotosPickedMediaItem) async throws -> URL
        var importFile: @MainActor @Sendable (_ fileURL: URL, _ filename: String, _ mimeType: String?) async throws
            -> Void
        var openURL: @MainActor @Sendable (URL) async -> Bool
        var closePicker: @MainActor @Sendable () async -> Void
        var sleep: @Sendable (TimeInterval) async throws -> Void
        var now: @Sendable () -> Date

        static func live(inboxStore: SharedInboxStore) -> Dependencies {
            let credentialStore = GooglePhotosKeychainCredentialStore()
            return Dependencies(
                loadConfiguration: { try GooglePhotosOAuthConfiguration.loadFromMainBundle() },
                loadCredential: { try credentialStore.load() },
                saveCredential: { try credentialStore.save($0) },
                authorize: { configuration in
                    try await GooglePhotosOAuthAuthorizer().authorize(configuration: configuration)
                },
                refresh: { configuration, credential in
                    try await GooglePhotosTokenClient(configuration: configuration).refresh(credential)
                },
                createSession: { accessToken in
                    try await GooglePhotosPickerClient(accessTokenProvider: { accessToken })
                        .createSession(maxItemCount: GooglePhotosPickerClient.defaultMaxItemCount)
                },
                fetchSession: { accessToken, sessionID in
                    try await GooglePhotosPickerClient(accessTokenProvider: { accessToken })
                        .fetchSession(id: sessionID)
                },
                deleteSession: { accessToken, sessionID in
                    try await GooglePhotosPickerClient(accessTokenProvider: { accessToken })
                        .deleteSession(id: sessionID)
                },
                listMediaItems: { accessToken, sessionID in
                    try await GooglePhotosPickerClient(accessTokenProvider: { accessToken })
                        .allMediaItems(sessionID: sessionID)
                },
                downloadItem: { accessToken, item in
                    let client = GooglePhotosPickerClient(accessTokenProvider: { accessToken })
                    let service = GooglePhotosContentDownloadService(pickerClient: client)
                    let temporaryURL = try await service.download(for: item)
                    // URLSession 임시 파일은 즉시 소비해야 하므로 우리 소유의 임시 경로로 옮겨 둔다.
                    let stagedURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("google-photos-import-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
                    return stagedURL
                },
                importFile: { fileURL, filename, mimeType in
                    defer { try? FileManager.default.removeItem(at: fileURL) }
                    let typeIdentifier = mimeType.flatMap { UTType(mimeType: $0)?.identifier }
                    _ = try await inboxStore.importDownloadedFile(
                        at: fileURL,
                        originalFilename: filename,
                        contentTypeIdentifier: typeIdentifier
                    )
                },
                openURL: { url in
                    if await UIApplication.shared.open(url) { return true }
                    return await GooglePhotosPickerURLPresenter.present(url)
                },
                closePicker: {
                    await GooglePhotosPickerURLPresenter.dismissIfPresented()
                },
                sleep: { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                },
                now: { Date() }
            )
        }
    }

    static let maxSelectionCount = GooglePhotosPickerClient.defaultMaxItemCount
    private static let defaultPollInterval: TimeInterval = 5
    private static let inactivePollRetryInterval: TimeInterval = 1
    private static let pickerOpenRetryInterval: TimeInterval = 0.5
    private static let maxPickerOpenAttempts = 3

    @Published private(set) var phase: GooglePhotosImportFlowPhase = .idle

    private let dependencies: Dependencies
    private(set) var activeFlowTask: Task<Void, Never>?
    private var isScenePollingAllowed = true
    private var importedCount = 0
    /// 흐름 동안에만 메모리에 유지하는 세션 식별 정보. 어디에도 영속화하지 않는다.
    private var activeSession: (accessToken: String, sessionID: String)?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isRunning: Bool {
        switch phase {
        case .preparing, .waitingForSelection, .importing: true
        default: false
        }
    }

    func presentDisclosure() {
        guard !isRunning else { return }
        phase = .disclosure
    }

    func declineDisclosure() {
        guard phase == .disclosure else { return }
        phase = .idle
    }

    /// 사전 고지에서 사용자가 `계속`을 누른 뒤에만 인증·세션 생성이 시작된다.
    func confirmDisclosure() {
        guard phase == .disclosure else { return }
        phase = .preparing
        importedCount = 0
        activeFlowTask = Task { await run() }
    }

    func cancel() {
        activeFlowTask?.cancel()
    }

    /// 앱/화면이 비활성·백그라운드인 동안에는 세션 폴링을 하지 않는다.
    func setScenePollingAllowed(_ allowed: Bool) {
        isScenePollingAllowed = allowed
    }

    // MARK: - Flow

    private func run() async {
        do {
            let configuration = try dependencies.loadConfiguration()
            let credential = try await resolveCredential(configuration: configuration)
            let accessToken = credential.accessToken

            let session = try await dependencies.createSession(accessToken)
            activeSession = (accessToken, session.id)

            guard let rawPickerURI = session.pickerURI,
                  let pickerURL = URL(string: rawPickerURI) else {
                throw GooglePhotosImportFlowError.pickerOpenFailed
            }
            phase = .waitingForSelection
            try await openPicker(pickerURL)

            try await waitForSelection(initialSession: session, accessToken: accessToken)
            await dependencies.closePicker()

            let items = try await dependencies.listMediaItems(accessToken, session.id)
            phase = .importing(completed: 0, total: items.count)
            let summary = try await importItems(items, accessToken: accessToken)

            await deleteActiveSession()
            phase = .finished(
                imported: summary.importedCount,
                skipped: summary.skippedCount,
                failed: summary.failedCount
            )
        } catch is CancellationError {
            await dependencies.closePicker()
            await deleteActiveSession()
            phase = .cancelled(imported: importedCount)
        } catch {
            await dependencies.closePicker()
            await deleteActiveSession()
            phase = .failed(message: Self.safeMessage(for: error))
        }
        activeFlowTask = nil
    }

    /// OAuth 화면이 닫히는 동안 씬이 아직 활성화되지 않았으면 외부 URL 열기가
    /// 일시적으로 실패할 수 있다. 씬 활성화를 기다리고 제한된 횟수만 재시도한다.
    private func openPicker(_ url: URL) async throws {
        var attempts = 0
        while true {
            try Task.checkCancellation()
            guard isScenePollingAllowed else {
                try await dependencies.sleep(Self.inactivePollRetryInterval)
                continue
            }

            attempts += 1
            if await dependencies.openURL(url) { return }
            guard attempts < Self.maxPickerOpenAttempts else {
                throw GooglePhotosImportFlowError.pickerOpenFailed
            }
            try await dependencies.sleep(Self.pickerOpenRetryInterval)
        }
    }

    private func resolveCredential(
        configuration: GooglePhotosOAuthConfiguration
    ) async throws -> GooglePhotosCredential {
        if let stored = try dependencies.loadCredential() {
            if !stored.isExpired(now: dependencies.now()) {
                return stored
            }
            do {
                let refreshed = try await dependencies.refresh(configuration, stored)
                try dependencies.saveCredential(refreshed)
                return refreshed
            } catch GooglePhotosOAuthError.reauthorizationRequired {
                // invalid_grant: 저장된 자격 증명으로는 갱신할 수 없으므로 재인가로 진행한다.
            }
        }
        let credential = try await dependencies.authorize(configuration)
        try dependencies.saveCredential(credential)
        return credential
    }

    private func waitForSelection(
        initialSession: GooglePhotosPickingSession,
        accessToken: String
    ) async throws {
        if initialSession.mediaItemsSet { return }
        var interval = initialSession.pollingConfig?.pollInterval ?? Self.defaultPollInterval
        var deadline = initialSession.pollingConfig?.timeoutIn.map {
            dependencies.now().addingTimeInterval($0)
        }
        while true {
            try Task.checkCancellation()
            if let deadline, dependencies.now() >= deadline {
                throw GooglePhotosImportFlowError.selectionTimedOut
            }
            guard isScenePollingAllowed else {
                try await dependencies.sleep(Self.inactivePollRetryInterval)
                continue
            }
            try await dependencies.sleep(max(interval, 1))
            guard isScenePollingAllowed else { continue }
            let latest = try await dependencies.fetchSession(accessToken, initialSession.id)
            if latest.mediaItemsSet { return }
            if let updatedInterval = latest.pollingConfig?.pollInterval {
                interval = updatedInterval
            }
            if let updatedTimeout = latest.pollingConfig?.timeoutIn {
                deadline = dependencies.now().addingTimeInterval(updatedTimeout)
            }
        }
    }

    private func importItems(
        _ items: [GooglePhotosPickedMediaItem],
        accessToken: String
    ) async throws -> GooglePhotosImportSummary {
        let dependencies = self.dependencies
        let total = items.count
        let coordinator = GooglePhotosImportCoordinator(
            download: { item in
                try await dependencies.downloadItem(accessToken, item)
            },
            importFile: { [weak self] fileURL, filename, mimeType in
                try await dependencies.importFile(fileURL, filename, mimeType)
                await self?.noteFileImported(total: total)
            }
        )
        return try await coordinator.importItems(items)
    }

    private func noteFileImported(total: Int) {
        importedCount += 1
        phase = .importing(completed: importedCount, total: total)
    }

    /// 세션 삭제는 최선의 노력으로 시도한다. 취소·실패 상황에서도 호출되며,
    /// 삭제가 실패해도 이미 가져온 파일은 그대로 유지된다.
    private func deleteActiveSession() async {
        guard let session = activeSession else { return }
        activeSession = nil
        let dependencies = self.dependencies
        // 흐름 취소가 삭제 요청까지 취소하지 않도록 비구조 Task로 감싼다.
        await Task {
            try? await dependencies.deleteSession(session.accessToken, session.sessionID)
        }.value
    }

    /// 우리가 정의한 안전한 오류만 메시지를 그대로 노출하고, 그 외에는 일반 메시지로 대체해
    /// URL·토큰·응답 본문 같은 민감한 값이 화면에 새지 않도록 한다.
    static func safeMessage(for error: Error) -> String {
        switch error {
        case let flowError as GooglePhotosImportFlowError:
            flowError.localizedDescription
        case let oauthError as GooglePhotosOAuthError:
            oauthError.localizedDescription
        case let pickerError as GooglePhotosPickerError:
            pickerError.localizedDescription
        default:
            "Google 포토 가져오기에 실패했습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}

/// 외부 브라우저나 Google 포토 앱 전환이 거부되는 환경에서는 동일한 HTTPS Picker를
/// 인증 때와 같은 시스템 웹 세션으로 표시한다. 기존 Google 로그인 쿠키를 재사용하고,
/// iframe이 아니므로 Picker 보안 제약도 그대로 지킨다.
@MainActor
private final class GooglePhotosPickerURLPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GooglePhotosPickerURLPresenter()

    private var session: ASWebAuthenticationSession?

    static func present(_ url: URL) async -> Bool {
        shared.start(url)
    }

    static func dismissIfPresented() async {
        shared.stop()
    }

    private func start(_ url: URL) -> Bool {
        guard session == nil else { return false }
        let webSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { [weak self] _, _ in
            self?.session = nil
        }
        webSession.presentationContextProvider = self
        webSession.prefersEphemeralWebBrowserSession = false
        session = webSession
        guard webSession.start() else {
            session = nil
            return false
        }
        return true
    }

    private func stop() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
