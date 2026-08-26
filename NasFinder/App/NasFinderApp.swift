import SwiftUI
import UIKit

@main
struct NasFinderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var inboxStore = SharedInboxStore()
    @StateObject private var favoriteStore = FavoriteStore()
    @StateObject private var browserFavoritesStore = BrowserFavoritesStore()
    @StateObject private var screenAwakeController = ScreenAwakeController.shared
    @StateObject private var webHardServerController = WebHardServerController()
    @StateObject private var foregroundReturnReset = ForegroundReturnResetCoordinator.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    @AppStorage("appIconBeforeEnamel.v1") private var appIconBeforeEnamelRawValue =
        AppIconChoice.blueNAS.rawValue
    @State private var themeIconError: String?

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    var body: some Scene {
        WindowGroup {
            adaptiveRootView
        }
    }

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    @ViewBuilder
    private var adaptiveRootView: some View {
        if isRunningOnMac {
            GeometryReader { _ in
                configuredRootView
                    .environment(\.dynamicTypeSize, .accessibility3)
                    .controlSize(.large)
            }
        } else {
            configuredRootView
        }
    }

    private var configuredRootView: some View {
        ConnectionListView()
                .environmentObject(connectionStore)
                .environmentObject(inboxStore)
                .environmentObject(favoriteStore)
                .environmentObject(browserFavoritesStore)
                .environmentObject(webHardServerController)
                .tint(SkyBreezeTheme.accent)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
                .onChange(of: selectedThemeRawValue, initial: true) { oldRawValue, newRawValue in
                    synchronizeAppIcon(from: oldRawValue, to: newRawValue)
                }
                .alert("아이콘을 변경할 수 없습니다", isPresented: themeIconErrorBinding) {
                    Button("확인", role: .cancel) { themeIconError = nil }
                } message: {
                    Text(themeIconError ?? "잠시 후 다시 시도해 주세요.")
                }
                .task {
                    await FileProviderThumbnailCache.shared.migrateExistingCachesIfNeeded()
                    browserFavoritesStore.importPendingSharedArchives()
                    inboxStore.reload()
                    #if targetEnvironment(macCatalyst)
                    MacDirectUpdateManager.shared.checkAtStartupIfNeeded()
                    #endif
                }
                .onOpenURL { url in
                    Task {
                        if BrowserFavoritesStore.isFavoritesFile(url) {
                            do {
                                try await browserFavoritesStore.importExternalFile(url)
                            } catch {
                                browserFavoritesStore.errorMessage =
                                    "즐겨찾기 파일을 가져오지 못했습니다: \(error.localizedDescription)"
                            }
                        } else {
                            let importedFavorites =
                                browserFavoritesStore.importPendingSharedArchives()
                            inboxStore.reload()
                            if !importedFavorites || !inboxStore.records.isEmpty {
                                await inboxStore.handleOpenURL(url)
                            }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Returning from the background resets to the dashboard
                    // before activation work so routed inbox/deep-link state
                    // set during activation is not discarded by the reset.
                    foregroundReturnReset.scenePhaseDidChange(phase)
                    guard phase == .active else { return }
                    browserFavoritesStore.importPendingSharedArchives()
                    inboxStore.sceneDidBecomeActive()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    screenAwakeController.updateAppIsActive(phase == .active)
                    if phase != .active {
                        webHardServerController.applicationDidEnterBackground()
                    }
                }
    }

    private var themeIconErrorBinding: Binding<Bool> {
        Binding(
            get: { themeIconError != nil },
            set: { if !$0 { themeIconError = nil } }
        )
    }

    private func synchronizeAppIcon(from oldRawValue: String, to newRawValue: String) {
        // On a Mac (Designed for iPad) the theme applies through AppStorage
        // as usual, but exit before even reading the unsupported
        // alternate-icon API and never raise an alert.
        guard !AppIconAvailabilityPolicy.isIOSAppOnMac else { return }

        let currentIcon = AppIconChoice.current(
            alternateIconName: UIApplication.shared.alternateIconName
        )
        guard let synchronization = AppIconAvailabilityPolicy.themeSynchronization(
            from: AppThemePreference.resolved(oldRawValue),
            to: AppThemePreference.resolved(newRawValue),
            currentIcon: currentIcon,
            iconBeforeEnamel: AppIconChoice(rawValue: appIconBeforeEnamelRawValue),
            isIOSAppOnMac: AppIconAvailabilityPolicy.isIOSAppOnMac
        ) else {
            return
        }

        if synchronization.remembersCurrentIcon {
            appIconBeforeEnamelRawValue = currentIcon.rawValue
        }

        AppIconChoice.apply(synchronization.icon) { errorMessage in
            themeIconError = errorMessage
        }
    }
}
