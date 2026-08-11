import SwiftUI

@main
struct NasFinderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var inboxStore = SharedInboxStore()
    @StateObject private var favoriteStore = FavoriteStore()

    var body: some Scene {
        WindowGroup {
            ConnectionListView()
                .environmentObject(connectionStore)
                .environmentObject(inboxStore)
                .environmentObject(favoriteStore)
                .tint(SkyBreezeTheme.accent)
                .onOpenURL { url in
                    Task { await inboxStore.handleOpenURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    inboxStore.sceneDidBecomeActive()
                }
        }
    }
}
