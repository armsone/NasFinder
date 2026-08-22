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
    }

    private var themeIconErrorBinding: Binding<Bool> {
        Binding(
            get: { themeIconError != nil },
            set: { if !$0 { themeIconError = nil } }
        )
    }

    private func synchronizeAppIcon(from oldRawValue: String, to newRawValue: String) {
        let oldTheme = AppThemePreference.resolved(oldRawValue)
        let newTheme = AppThemePreference.resolved(newRawValue)
        let icon: AppIconChoice

        if newTheme == .skeuomorphism {
            let current = AppIconChoice.current(
                alternateIconName: UIApplication.shared.alternateIconName
            )
            if current != .enamelNAS {
                appIconBeforeEnamelRawValue = current.rawValue
            }
            icon = .enamelNAS
        } else if oldTheme == .skeuomorphism {
            icon = AppIconChoice(rawValue: appIconBeforeEnamelRawValue) ?? .blueNAS
        } else if newTheme == .digitalRain {
            icon = .vibeCoder
        } else {
            return
        }

        AppIconChoice.apply(icon) { errorMessage in
            themeIconError = errorMessage
        }
    }
}
