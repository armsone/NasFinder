import Combine
import Sparkle

enum UpdatePreferenceLogic {
    static func statusText(automaticDownloadEnabled: Bool) -> String {
        automaticDownloadEnabled ? "자동 다운로드 상태: 켬" : "자동 다운로드 상태: 끔"
    }
}

/// Sparkle 기반 자동/수동 업데이트 진입점. Info.plist의 SUFeedURL/SUPublicEDKey 등을 그대로 사용한다.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticDownloadEnabled = true

    private let updaterController: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        automaticDownloadEnabled = updaterController.updater.automaticallyDownloadsUpdates
        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticDownloadEnabled(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        automaticDownloadEnabled = updaterController.updater.automaticallyDownloadsUpdates
    }
}
