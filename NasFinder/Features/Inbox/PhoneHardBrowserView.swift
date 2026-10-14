import SwiftUI

/// PhoneHard opened from the dashboard: the same browser a network connection opens,
/// over the files stored on this device. Only what belongs to PhoneHard alone is kept
/// here: a file another app handed over is shown once, and files the web server took in
/// reach the list.
struct PhoneHardBrowserView: View {
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var webHardController: WebHardServerController
    @State private var previewItem: RemoteFileItem?

    var body: some View {
        FileBrowserView(
            connection: LocalInboxFileService.phoneHardConnection,
            path: LocalInboxFileService.rootPath,
            service: LocalInboxFileService(),
            title: LocalInboxFileService.phoneHardConnection.name
        )
        .task {
            inboxStore.reload()
            openPendingPreviewIfNeeded()
        }
        .onChange(of: inboxStore.pendingPreviewRecordID) { _, _ in
            openPendingPreviewIfNeeded()
        }
        .onChange(of: webHardController.thumbnailGeneration) { _, _ in
            inboxStore.reload()
        }
        .fullScreenCover(item: $previewItem) { item in
            RemotePreviewView(
                item: item,
                sequentialItems: [item],
                service: LocalInboxFileService()
            )
        }
    }

    private func openPendingPreviewIfNeeded() {
        guard let recordID = inboxStore.consumePendingPreviewRecordID(),
              let record = inboxStore.records.first(where: { $0.id == recordID }),
              !record.isDirectory else { return }
        previewItem = LocalInboxFileService.browserItem(for: record)
    }
}
