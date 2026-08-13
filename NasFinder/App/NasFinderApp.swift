import SwiftUI

@main
struct NasFinderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var inboxStore = SharedInboxStore()
    @StateObject private var favoriteStore = FavoriteStore()
    @StateObject private var browserFavoritesStore = BrowserFavoritesStore()
    @StateObject private var screenAwakeController = ScreenAwakeController.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

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
                .tint(SkyBreezeTheme.accent)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
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
                }
        }
    }
}
