import AVFoundation
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct BrowserDestination: Identifiable, Hashable {
    let connection: RemoteConnection
    let path: String
    let title: String

    var id: String { "\(connection.id.uuidString):\(path)" }
}

private struct IOSAppOnMacShortcutModifier: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    @ViewBuilder
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

/// On Mac, the system toolbar compresses or hides the adjacent "NasFinder" text next to the
/// logo, so the logo and theme badge are shown instead in a fixed in-app header above the
/// scrolling dashboard. The header stays put via safeAreaInset; it is not part of the list
/// content and does not scroll with it.
private struct MacDashboardHeaderModifier<Header: View>: ViewModifier {
    let isActive: Bool
    @ViewBuilder let header: () -> Header

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.safeAreaInset(edge: .top, spacing: 0) {
                header()
            }
        } else {
            content
        }
    }
}

enum AppVersionDisplayPolicy {
    static func text(shortVersion: String?, buildNumber: String?) -> String? {
        guard let shortVersion, !shortVersion.isEmpty,
              let buildNumber, !buildNumber.isEmpty else { return nil }
        return "버전 \(shortVersion) · 빌드 \(buildNumber)"
    }

    static func text(bundle: Bundle = .main) -> String? {
        text(
            shortVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

struct ConnectionListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @EnvironmentObject private var browserFavoritesStore: BrowserFavoritesStore
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    @AppStorage("googlePhotos.networkHidden.v1") private var googlePhotosHidden = false
    @AppStorage("googlePhotos.networkName.v1") private var googlePhotosName = "Google 포토"
    @StateObject private var googlePhotosConnection = GooglePhotosConnectionSettingsModel(dependencies: .live())
    @State private var isChoosingNetwork = false
    @State private var isEditingGooglePhotos = false
    @State private var googlePhotosEditedName = ""
    @State private var isDeletingGooglePhotos = false
    @State private var isReconnectingGooglePhotos = false
    @State private var forceGooglePhotosAuthorization = false
    @State private var isAddingConnection: Bool
    @State private var connectionPendingDeletion: RemoteConnection?
    @State private var editingConnection: RemoteConnection?
    @State private var browserDestination: BrowserDestination?
    @State private var selectedFavorite: FavoriteItem?
    @State private var isImportingFromFiles = false
    @State private var isImportingFromGooglePhotos = false
    @State private var didAttemptAutomaticOpen = false
    @State private var deviceStorage = DeviceStorageSnapshot.current()
    @State private var navigationIdentity = UUID()
    @State private var porcelainSidebarActive = false
    @ObservedObject private var foregroundReturnReset = ForegroundReturnResetCoordinator.shared

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    private var dashboardContentMaxWidth: CGFloat? {
        isRunningOnMac ? ui(1_520) : nil
    }

    init() {
        #if DEBUG
        _isAddingConnection = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("-showAddConnection")
        )
        #else
        _isAddingConnection = State(initialValue: false)
        #endif
    }

    var body: some View {
        NavigationStack {
            // 6개 테마 모두 같은 승인안 홈(porcelainHome)을 쓰고 색만 바뀐다. 예전 목록 홈은 쓰지 않는다.
            porcelainHome
            .background(SkyBreezeBackground())
            // 브랜드가 사이드바·헤더에 있어 Mac 막대 제목을 겹쳐 두지 않는다.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                dashboardLogoToolbar
            }
            .navigationDestination(isPresented: $isAddingConnection) {
                porcelainDetailHost {
                    AddConnectionView()
                        .environmentObject(store)
                }
            }
            .navigationDestination(item: $editingConnection) { connection in
                porcelainDetailHost {
                    AddConnectionView(connection: connection)
                        .environmentObject(store)
                }
            }
            .navigationDestination(isPresented: $inboxStore.shouldPresentInbox) {
                porcelainDetailHost { PhoneHardBrowserView() }
            }
            .navigationDestination(item: $browserDestination) { destination in
                porcelainDetailHost {
                    FileBrowserContainerView(
                        connection: destination.connection,
                        path: destination.path,
                        title: destination.title,
                        returnToDashboardAction: {
                            returnToDashboard()
                        }
                    )
                }
            }
            .navigationDestination(item: $selectedFavorite) { favorite in
                porcelainDetailHost { FavoriteDestinationView(favorite: favorite) }
            }
            .onChange(of: inboxStore.shouldPresentInbox) { _, presented in
                // 넓은 Porcelain 호스트에서는 사이드바 선택이 상세를 교체한다.
                guard presented, porcelainSidebarActive else { return }
                browserDestination = nil
                selectedFavorite = nil
            }
            .fileImporter(
                isPresented: $isImportingFromFiles,
                allowedContentTypes: [.data, .content],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    Task {
                        if await inboxStore.importFromFiles(urls) > 0 {
                            inboxStore.shouldPresentInbox = true
                        }
                    }
                case .failure(let error):
                    let cocoaError = error as NSError
                    guard !(cocoaError.domain == NSCocoaErrorDomain
                            && cocoaError.code == CocoaError.Code.userCancelled.rawValue) else {
                        return
                    }
                    inboxStore.errorMessage =
                        "파일을 선택하지 못했습니다: \(error.localizedDescription)"
                }
            }
            .navigationDestination(isPresented: $isImportingFromGooglePhotos) {
                GooglePhotosImportFlowView(inboxStore: inboxStore, forceAuthorization: forceGooglePhotosAuthorization)
            }
            .onChange(of: isImportingFromGooglePhotos) { _, presented in
                if !presented {
                    googlePhotosConnection.refreshConnectionState()
                    forceGooglePhotosAuthorization = false
                }
            }
            .fileDialogConfirmationLabel("가져오기")
            .fileDialogMessage("이 기기 또는 iCloud Drive에서 파일을 선택하세요.")
            .alert("파일 가져오기 오류", isPresented: inboxErrorBinding) {
                Button("확인", role: .cancel) {
                    inboxStore.errorMessage = nil
                }
            } message: {
                Text(inboxStore.errorMessage ?? "")
            }
            .alert("알림", isPresented: errorBinding) {
                Button("확인", role: .cancel) {
                    store.lastErrorMessage = nil
                }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
            .alert(
                "연결을 삭제할까요?",
                isPresented: deletionAlertBinding,
                presenting: connectionPendingDeletion
            ) { connection in
                Button("취소", role: .cancel) {
                    connectionPendingDeletion = nil
                }
                Button("삭제", role: .destructive) {
                    remove(connection)
                }
            } message: { connection in
                Text("\(connection.name)의 저장된 로그인 정보와 파일 앱 위치가 이 iPhone에서 제거됩니다. 서버의 파일은 삭제되지 않습니다.")
            }
            .alert("브라우저 즐겨찾기", isPresented: browserFavoritesMessageBinding) {
                Button("확인", role: .cancel) {
                    browserFavoritesStore.noticeMessage = nil
                    browserFavoritesStore.errorMessage = nil
                }
            } message: {
                Text(
                    browserFavoritesStore.errorMessage
                        ?? browserFavoritesStore.noticeMessage
                        ?? ""
                )
            }
            .confirmationDialog("네트워크 추가", isPresented: $isChoosingNetwork, titleVisibility: .visible) {
                Button(googlePhotosHidden ? "Google 포토" : "Google 포토 열기 · 이미 추가됨") {
                    googlePhotosHidden = false
                    forceGooglePhotosAuthorization = false
                    isImportingFromGooglePhotos = true
                }
                Button("NAS·서버·클라우드 드라이브") { isAddingConnection = true }
                Button("취소", role: .cancel) {}
            }
            .alert("Google 포토 연결 수정", isPresented: $isEditingGooglePhotos) {
                TextField("표시 이름", text: $googlePhotosEditedName)
                Button("취소", role: .cancel) {}
                Button("저장") {
                    let value = googlePhotosEditedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    googlePhotosName = value.isEmpty ? "Google 포토" : value
                }
            } message: {
                Text("이 기기에 표시할 이름을 바꿉니다. 저장된 로그인은 유지됩니다.")
            }
            .confirmationDialog("Google 포토에 다시 연결할까요?", isPresented: $isReconnectingGooglePhotos, titleVisibility: .visible) {
                Button("다시 연결") {
                    forceGooglePhotosAuthorization = true
                    isImportingFromGooglePhotos = true
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("Google 인증을 다시 진행합니다. 완료하기 전까지 기존 연결 정보는 유지됩니다.")
            }
            .confirmationDialog("Google 포토 연결을 삭제할까요?", isPresented: $isDeletingGooglePhotos, titleVisibility: .visible) {
                Button("연결 삭제", role: .destructive) {
                    Task {
                        await googlePhotosConnection.disconnect()
                        if !googlePhotosConnection.isConnected { googlePhotosHidden = true }
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("이 기기의 Google 포토 앱 연결과 목록의 항목을 제거합니다. 폰하드·Google 포토 원본·Google Drive 연결은 유지됩니다. 웹 로그인은 유지되어 재추가할 때 사용할 수 있습니다.")
            }
            .alert("Google 포토", isPresented: Binding(
                get: { googlePhotosConnection.resultMessage != nil },
                set: { if !$0 { googlePhotosConnection.resultMessage = nil } }
            )) {
                Button("확인", role: .cancel) { googlePhotosConnection.resultMessage = nil }
            } message: {
                Text(googlePhotosConnection.resultMessage ?? "")
            }
            .task {
                googlePhotosConnection.refreshConnectionState()
                deviceStorage = DeviceStorageSnapshot.current()
                openPreferredConnectionIfNeeded()
                await store.refreshDropboxAccountMetadata()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyBreezeBackground())
        .environment(\.returnToDashboard) {
            returnToDashboard()
        }
        .id(navigationIdentity)
        .onChange(of: foregroundReturnReset.resetGeneration) { _, _ in
            resetToDashboardAfterForegroundReturn()
        }
    }

    @ViewBuilder
    private var dashboardSections: some View {
        networkSection
        myFilesSection
        deviceStorageSection
        videoEditingSection
        settingsSection
    }

    private var networkSection: some View {
        Section {
            VStack(alignment: .leading, spacing: ui(4)) {
                Text("즐겨찾기")
                    .font(.ui(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)

                FavoriteShelfView { favorite in
                    selectedFavorite = favorite
                }
            }

            if !store.connections.isEmpty {
                ForEach(store.connections) { connection in
                    NetworkLocationCard(
                        connection: connection,
                        isPreferred: store.preferredConnection?.id == connection.id,
                        requestOpening: { open(connection) },
                        requestPreferred: { store.setPreferredConnection(connection) },
                        requestClearPreferred: { store.clearPreferredConnection() },
                        canMoveEarlier: store.connections.first?.id != connection.id,
                        canMoveLater: store.connections.last?.id != connection.id,
                        requestMoveEarlier: { move(connection, by: -1) },
                        requestMoveLater: { move(connection, by: 1) },
                        requestEditing: { editingConnection = connection },
                        requestDeletion: { connectionPendingDeletion = connection }
                    )
                }
                .onMove { offsets, destination in
                    store.move(from: offsets, to: destination)
                }
            }

            if !googlePhotosHidden {
                googlePhotosNetworkRow
            }

            NavigationLink {
                WebBrowserView()
            } label: {
                WebNetworkLocationRow()
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

            Button {
                isChoosingNetwork = true
            } label: {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(systemName: "plus", size: ui(32), symbolSize: ui(17))
                    Text(store.connections.isEmpty ? "네트워크를 추가해 주세요" : "네트워크 추가")
                }
            }
            .font(.ui(.subheadline))
            .foregroundStyle(.secondary)
            .modifier(
                IOSAppOnMacShortcutModifier(key: "n", modifiers: .command)
            )
        } header: {
            sectionHeader("네트워크", systemImage: "network")
                .padding(.top, ui(8))
        } footer: {
            Text(networkFooterText)
                .font(.ui(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, ui(-4))
        }
        .listSectionSpacing(.custom(10))
    }

    private var googlePhotosNetworkRow: some View {
        HStack(spacing: ui(4)) {
            Button {
                forceGooglePhotosAuthorization = false
                isImportingFromGooglePhotos = true
            } label: {
                HStack(spacing: ui(13)) {
                    ThemedSymbol(systemName: "photo.on.rectangle.angled", size: ui(32), symbolSize: ui(17))
                        .foregroundStyle(ConnectionKind.googleDrive.dashboardTint)
                        .frame(width: ui(32), height: ui(32))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ui(4)) {
                        HStack(spacing: ui(6)) {
                            Text(googlePhotosName)
                                .font(.ui(.subheadline).weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if googlePhotosName != "Google 포토" {
                                Text("Google 포토")
                                    .font(.ui(.caption2).weight(.semibold))
                                    .foregroundStyle(ConnectionKind.googleDrive.dashboardTint)
                                    .padding(.horizontal, ui(6))
                                    .padding(.vertical, ui(2))
                                    .background(ConnectionKind.googleDrive.dashboardTint.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, ui(2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Google 포토에서 사진과 영상을 선택합니다.")
            Menu {
                if !googlePhotosConnection.isConnected {
                    Button("연결 추가", systemImage: "plus") {
                        forceGooglePhotosAuthorization = false
                        isImportingFromGooglePhotos = true
                    }
                }
                Button("연결 수정", systemImage: "pencil") {
                    googlePhotosEditedName = googlePhotosName
                    isEditingGooglePhotos = true
                }
                if googlePhotosConnection.isConnected {
                    Button("다시 연결", systemImage: "arrow.triangle.2.circlepath") {
                        isReconnectingGooglePhotos = true
                    }
                }
                Button("연결 삭제", systemImage: "trash", role: .destructive) {
                    isDeletingGooglePhotos = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ui(.body).weight(.semibold))
                    .frame(width: ui(44), height: ui(54))
                    .contentShape(Rectangle())
            }
            .disabled(googlePhotosConnection.isDisconnecting)
            .accessibilityLabel("\(googlePhotosName) 연결 메뉴")
        }
    }

    private var myFilesSection: some View {
        Section {
            // The storage on this device comes first, as one of the places files live.
            PhoneHardEntryLink(summary: inboxSummary)

            NavigationLink {
                LocalPhotoLibraryView()
            } label: {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(
                        systemName: "photo.on.rectangle.angled",
                        size: ui(32),
                        symbolSize: ui(17)
                    )
                    Text("내 사진·영상")
                }
                .font(.ui(.subheadline))
                .foregroundStyle(.secondary)
            }
            .accessibilityHint("NAS 연결 없이 이 기기의 사진과 영상을 선택해 미리 보고 예고편을 만듭니다.")

            NavigationLink {
                PhotoTransferView()
            } label: {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(
                        systemName: "photo.on.rectangle.angled",
                        size: ui(32),
                        symbolSize: ui(17)
                    )
                    Text("기기 간 사진 전송")
                }
                .font(.ui(.subheadline))
                .foregroundStyle(.secondary)
            }
            .accessibilityHint("Live Photos와 Motion Photos를 함께 보내는 화면을 엽니다.")

        } header: {
            sectionHeader("내 파일", systemImage: "folder")
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
    }

    private var deviceStorageSection: some View {
        Section {
            Button {
                isImportingFromFiles = true
            } label: {
                HStack(spacing: ui(12)) {
                    ThemedSymbol(systemName: "folder", size: ui(32), symbolSize: ui(17))
                        .foregroundStyle(.blue)
                        .frame(width: ui(32))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: ui(3)) {
                        Text("이 기기 저장공간")
                            .foregroundStyle(.primary)
                        Text(deviceStorageSummary)
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                        Text("파일 앱 열기 · iCloud Drive 지원")
                            .font(.ui(.caption2))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: ui(8))

                    Image(systemName: "chevron.right")
                        .font(.ui(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("파일 앱에서 이 기기 또는 iCloud Drive의 파일을 선택합니다.")

            if deviceStorage.hasCapacity {
                ProgressView(value: deviceStorage.usedFraction) {
                    Text("저장공간")
                } currentValueLabel: {
                    Text(
                        deviceStorage.usedFraction,
                        format: .percent.precision(.fractionLength(0))
                    )
                }
            }
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
    }

    private var videoEditingSection: some View {
        Section {
            TrailerDraftManagerEntryLink()

            VideoCreateEntryLink()
        } header: {
            sectionHeader("영상 편집", systemImage: "film")
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                porcelainDetailHost { AppSettingsView(connectionCount: store.connections.count) }
            } label: {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(systemName: "gearshape", size: ui(32), symbolSize: ui(17))
                    Text("설정")
                }
                    .font(.ui(.subheadline))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if let versionText = AppVersionDisplayPolicy.text() {
                Text(versionText)
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var browserFavoritesMessageBinding: Binding<Bool> {
        Binding(
            get: {
                browserFavoritesStore.noticeMessage != nil
                    || browserFavoritesStore.errorMessage != nil
            },
            set: {
                if !$0 {
                    browserFavoritesStore.noticeMessage = nil
                    browserFavoritesStore.errorMessage = nil
                }
            }
        )
    }

    private var inboxErrorBinding: Binding<Bool> {
        Binding(
            get: { inboxStore.errorMessage != nil },
            set: { if !$0 { inboxStore.errorMessage = nil } }
        )
    }

    private func openPreferredConnectionIfNeeded() {
        guard !didAttemptAutomaticOpen else { return }
        didAttemptAutomaticOpen = true
        guard !inboxStore.shouldPresentInbox,
              !isAddingConnection,
              editingConnection == nil else { return }
        if let connection = store.preferredConnection {
            open(connection)
        }
    }

    private func returnToDashboard() {
        browserDestination = nil
        selectedFavorite = nil
        inboxStore.shouldPresentInbox = false
        Task { @MainActor in
            await Task.yield()
            navigationIdentity = UUID()
        }
    }

    /// Every sheet, pushed route and media surface returns to the dashboard
    /// after the app comes back from the background. Pending inbox routing is
    /// transient too; the imported file stays stored, but is not auto-opened.
    ///
    /// The Google Photos import sheet is intentionally excluded: its picker and
    /// OAuth steps are shown in-app (SFSafariViewController / ASWebAuthenticationSession),
    /// so a background/foreground cycle during those steps is part of the normal
    /// flow, not a "user left NasFinder" signal, and must not cancel an in-progress
    /// selection or import.
    private func resetToDashboardAfterForegroundReturn() {
        guard !isImportingFromGooglePhotos else { return }
        isAddingConnection = false
        editingConnection = nil
        connectionPendingDeletion = nil
        isImportingFromFiles = false
        inboxStore.resetTransientPresentation()
        returnToDashboard()
    }

    private var quickLocationsSection: some View {
        DashboardSection(title: "빠른 위치", subtitle: "자주 쓰는 파일 흐름으로 바로 이동합니다.") {
            LazyVGrid(columns: quickLocationColumns, spacing: ui(12)) {
                NavigationLink {
                    PhoneHardBrowserView()
                } label: {
                    QuickLocationCard(
                        title: "폰하드",
                        subtitle: inboxStore.records.isEmpty
                            ? "다른 앱에서 파일 가져오기"
                            : inboxSummary,
                        systemImage: "tray.and.arrow.down.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("다른 앱에서 NasFinder로 가져온 폰하드 파일을 엽니다.")

                NavigationLink {
                    FilesAppIntegrationGuideView(connectionCount: store.connections.count)
                } label: {
                    QuickLocationCard(
                        title: "파일 앱 연동",
                        subtitle: store.connections.isEmpty
                            ? "연결을 추가하면 위치에 표시"
                            : "원격 위치 \(store.connections.count)개 사용 가능",
                        systemImage: "folder.fill.badge.gearshape",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Apple 파일 앱에서 NasFinder 위치를 사용하는 방법을 봅니다.")

                Button {
                    isAddingConnection = true
                } label: {
                    QuickLocationCard(
                        title: "새 연결",
                        subtitle: "Synology NAS 또는 SFTP",
                        systemImage: "network.badge.shield.half.filled",
                        tint: .teal
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("새 원격 저장공간 연결 화면을 엽니다.")
            }
        }
    }

    private var networkLocationsSection: some View {
        DashboardSection(
            title: "네트워크",
            subtitle: store.connections.isEmpty
                ? "NAS나 SFTP 서버를 추가해 원격 파일을 관리하세요."
                : "저장된 NAS와 SFTP 서버를 선택해 파일을 엽니다.",
            badge: store.connections.isEmpty ? nil : "\(store.connections.count)"
        ) {
            LazyVGrid(columns: networkColumns, spacing: ui(12)) {
                ForEach(store.connections) { connection in
                    NetworkLocationCard(
                        connection: connection,
                        isPreferred: store.preferredConnection?.id == connection.id,
                        requestOpening: {
                            open(connection)
                        },
                        requestPreferred: {
                            store.setPreferredConnection(connection)
                        },
                        requestClearPreferred: {
                            store.clearPreferredConnection()
                        },
                        canMoveEarlier: store.connections.first?.id != connection.id,
                        canMoveLater: store.connections.last?.id != connection.id,
                        requestMoveEarlier: { move(connection, by: -1) },
                        requestMoveLater: { move(connection, by: 1) },
                        requestEditing: {
                            editingConnection = connection
                        },
                        requestDeletion: {
                            connectionPendingDeletion = connection
                        }
                    )
                }

                AddNetworkLocationCard {
                    isAddingConnection = true
                }
            }
        }
    }

    private var quickLocationColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: ui(12), alignment: .top)]
        }

        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: ui(12), alignment: .top),
            count: count
        )
    }

    private var inboxSummary: String {
        guard !inboxStore.records.isEmpty else { return "0개" }
        let count = inboxStore.records.count
        let size = formattedByteCount(inboxByteCount)
        return "\(count)개 · \(size)"
    }

    private var networkFooterText: String {
        if let preferred = store.preferredConnection {
            return "기본 위치 ‘\(preferred.name)’ · 앱 실행 시 자동으로 열림"
        }
        if store.connections.isEmpty {
            return "NAS 또는 SFTP 서버를 연결하면 파일을 탐색할 수 있습니다."
        }
        return "기본 위치 없음 · 앱 실행 시 연결 목록에서 시작"
    }

    private var overviewColumns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return horizontalSizeClass == .regular ? 3 : 2
    }

    private var networkColumns: [GridItem] {
        let count = horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return Array(
            repeating: GridItem(.flexible(), spacing: ui(12), alignment: .top),
            count: count
        )
    }

    private var pageHorizontalPadding: CGFloat {
        if isRunningOnMac {
            return ui(horizontalSizeClass == .regular ? 48 : 32)
        }
        return horizontalSizeClass == .regular ? 24 : 16
    }

    private var inboxByteCount: Int64 {
        inboxStore.records.reduce(into: 0) { result, record in
            result += max(0, record.byteCount)
        }
    }

    private var deviceStorageSummary: String {
        guard deviceStorage.hasCapacity else { return "확인 불가" }
        return "전체 \(formattedByteCount(deviceStorage.totalBytes)) · "
            + "사용 가능 \(formattedByteCount(deviceStorage.availableBytes))"
    }

    private var currentLogoAssetName: String {
        guard !AppIconAvailabilityPolicy.isIOSAppOnMac else {
            return AppIconAvailabilityPolicy.fixedMacIcon.previewAssetName
        }
        return AppIconChoice.current(
            alternateIconName: UIApplication.shared.alternateIconName
        ).previewAssetName
    }

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    private var currentThemeBadge: some View {
        ByungkiThemeControlButton(
            selectedThemeRawValue: $selectedThemeRawValue,
            isBadgeStyle: true,
            isRunningOnMac: isRunningOnMac
        )
    }

    private func selectNextTheme() {
        withAnimation(.easeInOut(duration: 0.20)) {
            selectedThemeRawValue = selectedTheme.next.rawValue
        }
    }

    private var dashboardLogo: some View {
        Button(action: openRememberedLocation) {
            HStack(spacing: 8) {
                PorcelainHeaderGlyph(size: 24)
                PorcelainBrandText()
            }
            // The Mac logo already fills the bar's height.
            .padding(.vertical, isRunningOnMac ? 0 : 3)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NasFinder")
        .accessibilityHint("마지막으로 보던 네트워크 폴더를 엽니다.")
    }

    private func open(_ connection: RemoteConnection) {
        if porcelainSidebarActive {
            inboxStore.shouldPresentInbox = false
            selectedFavorite = nil
        }
        browserDestination = BrowserDestination(
            connection: connection,
            path: connection.normalizedRootPath,
            title: connection.name
        )
    }

    private func openRememberedLocation() {
        guard let location = store.resumableBrowserLocation,
              let connection = store.connections.first(where: {
                  $0.id == location.connectionID
              }) else {
            return
        }
        browserDestination = BrowserDestination(
            connection: connection,
            path: location.path,
            title: location.title
        )
    }

    @ToolbarContentBuilder
    private var dashboardLogoToolbar: some ToolbarContent {
        // 6개 테마 공통: 폰은 홈 안 앱 헤더, 패드·Mac은 사이드바 브랜드 + 오른쪽 버튼 묶음.
        porcelainToolbar
    }

    private var macDashboardHeader: some View {
        HStack {
            dashboardLogo
            Spacer(minLength: ui(12))
            currentThemeBadge
        }
        .padding(.horizontal, ui(16))
        .padding(.vertical, ui(10))
        .background(.bar)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: ui(3)) {
            ThemedSymbol(systemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
            .font(.ui(.footnote).weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { connectionPendingDeletion != nil },
            set: { if !$0 { connectionPendingDeletion = nil } }
        )
    }

    private func remove(_ connection: RemoteConnection) {
        guard let index = store.connections.firstIndex(where: { $0.id == connection.id }) else {
            connectionPendingDeletion = nil
            return
        }

        connectionPendingDeletion = nil
        Task {
            await store.remove(at: IndexSet(integer: index))
        }
    }

    private func move(_ connection: RemoteConnection, by offset: Int) {
        guard let index = store.connections.firstIndex(where: { $0.id == connection.id }) else {
            return
        }
        let targetIndex = index + offset
        guard store.connections.indices.contains(targetIndex) else { return }
        let destination = offset < 0 ? targetIndex : targetIndex + 1
        store.move(from: IndexSet(integer: index), to: destination)
    }
}

private struct WebNetworkLocationRow: View {
    var body: some View {
        HStack(spacing: ui(4)) {
            HStack(spacing: ui(13)) {
                ThemedSymbol(systemName: "globe", size: ui(32), symbolSize: ui(17))
                    .font(.ui(.title3))
                    .foregroundStyle(SkyBreezeTheme.browserOrange)
                    .frame(width: ui(32), height: ui(32))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ui(4)) {
                    HStack(spacing: ui(6)) {
                        Text("Browser")
                            .font(.ui(.subheadline).weight(.medium))
                            .foregroundStyle(.primary)

                        Text("WWW")
                            .font(.ui(.caption2).weight(.semibold))
                            .foregroundStyle(SkyBreezeTheme.browserOrange)
                            .padding(.horizontal, ui(6))
                            .padding(.vertical, ui(2))
                            .background(SkyBreezeTheme.browserOrange.opacity(0.1), in: Capsule())
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, ui(2))
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.ui(.body).weight(.medium))
                .foregroundStyle(SkyBreezeTheme.accent)
                .frame(width: ui(44), height: ui(48))
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Browser, WWW")
        .accessibilityHint("웹 브라우저를 엽니다.")
    }
}

private struct WebHardNetworkLocationRow: View {
    let summary: String?
    var compact = false
    var tile = false
    var sidebar = false

    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    init(summary: String? = nil, compact: Bool = false, tile: Bool = false, sidebar: Bool = false) {
        self.summary = summary
        self.compact = compact
        self.tile = tile
        self.sidebar = sidebar
    }

    private var isEnamel: Bool {
        false // 예전 에나멜 장식은 6개 테마에 없다.
    }

    @ViewBuilder
    var body: some View {
        if sidebar {
            PorcelainSidebarItem(title: "폰하드") {
                InterfaceIcon(systemName: "folder", size: PorcelainMetrics.rowIconSize)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("폰하드, 이 기기의 로컬 저장소")
            .accessibilityValue(summary ?? "")
            .accessibilityHint("파일 목록을 엽니다.")
        } else if tile {
            // 원안의 짧은 설명만 둔다. 개수·용량은 손쉬운 사용 값과 폰하드 화면에 그대로 있다.
            PorcelainOpenCell(title: "폰하드", subtitle: "가져온 파일") {
                InterfaceIcon(systemName: "folder", size: PorcelainMetrics.openIconSize)
                    .font(.system(size: 24))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("폰하드, 이 기기의 로컬 저장소")
            .accessibilityValue(summary ?? "")
            .accessibilityHint("파일 목록을 엽니다.")
        } else if compact {
            PorcelainRow(
                title: "폰하드",
                subtitle: summary.map { "이 기기 · \($0)" } ?? "이 기기",
                badge: "로컬"
            ) {
                InterfaceIcon(systemName: "folder", size: PorcelainMetrics.rowIconSize)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("폰하드, 이 기기의 로컬 저장소")
            .accessibilityValue(summary ?? "")
            .accessibilityHint("파일 목록을 엽니다.")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        HStack(spacing: ui(13)) {
            if isEnamel {
                PhoneHardMark(size: ui(32))
                    .accessibilityHidden(true)
            } else {
                Image("PhoneHardLogo")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: ui(7), style: .continuous))
                    .frame(width: ui(32), height: ui(32))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: ui(4)) {
                HStack(spacing: ui(6)) {
                    Text("폰하드")
                        .font(.ui(.subheadline).weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("로컬")
                        .font(.ui(.caption2).weight(.semibold))
                        .foregroundStyle(SkyBreezeTheme.accent)
                        .padding(.horizontal, ui(6))
                        .padding(.vertical, ui(2))
                        .background(SkyBreezeTheme.accent.opacity(0.1), in: Capsule())
                }

                Text(summary.map { "이 기기 · \($0)" } ?? "이 기기")
                    .font(.ui(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, ui(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("폰하드, 이 기기의 로컬 저장소")
        .accessibilityValue(summary ?? "")
        .accessibilityHint("파일 목록을 엽니다.")
    }
}

/// The dashboard's PhoneHard entry, listed with the network connections as the storage on
/// this device. A tap opens it in the same browser those open in. A long press on the
/// entry always opens the manager of suspended trailer/music editors, showing an empty
/// state when there are none to resume.
private struct PhoneHardEntryLink: View {
    let summary: String?
    var porcelain = false
    var tile = false
    var sidebar = false
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @State private var resumingDraft: TrailerDraftEntry?
    @State private var showingDraftManager = false
    /// Set while the manager sheet is still closing, so the full-screen editor it asked
    /// for is only ever presented once that sheet is fully gone (avoids a presentation
    /// race between the two on iOS/iPad/Mac).
    @State private var pendingResumeID: UUID?

    var body: some View {
        Button {
            inboxStore.shouldPresentInbox = true
        } label: {
            WebHardNetworkLocationRow(summary: summary, compact: porcelain, tile: tile, sidebar: sidebar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Over the row's content, always present, so the tap that opens PhoneHard and the
        // long press that opens the draft manager are told apart by one gesture, as in the
        // file browser. This also makes a pointer's long hold on Mac Catalyst reliable,
        // since the gesture is attached unconditionally rather than appearing mid-hold.
        .overlay {
            Color.clear.contentShape(Rectangle()).gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first:
                            openDraftManager()
                        case .second:
                            inboxStore.shouldPresentInbox = true
                        }
                    }
            )
        }
        .accessibilityActions {
            Button("보관한 편집 보기") { openDraftManager() }
        }
        .navigationDestination(isPresented: $showingDraftManager) {
            TrailerDraftManagerView { entry in
                pendingResumeID = entry.id
                showingDraftManager = false
                resumingDraft = entry
            }
        }
        .onChange(of: showingDraftManager) { _, isShowing in
            if !isShowing, let id = pendingResumeID {
                pendingResumeID = nil
                if resumingDraft == nil {
                    resumingDraft = draftStore.entries.first { $0.id == id }
                }
            }
        }
        .fullScreenCover(item: $resumingDraft) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
                .environmentObject(inboxStore)
        }
    }

    private func openDraftManager() {
        // One editor/manager at a time: nothing is presented over either already showing.
        guard resumingDraft == nil, !showingDraftManager else { return }
        showingDraftManager = true
    }
}

/// The "영상 편집" section's explicit entry to the same suspended trailer/music editor
/// manager the PhoneHard entry's long press opens, so it does not depend on discovering
/// that gesture.
private struct TrailerDraftManagerEntryLink: View {
    var porcelain = false
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @State private var resumingDraft: TrailerDraftEntry?
    @State private var showingDraftManager = false
    @State private var pendingResumeID: UUID?
    @State private var confirmingDeleteID: UUID?

    /// 홈에 바로 보이는 실제 보관한 편집 카드 수. 보관 개수 자체는 제한하지 않고, 나머지는 관리 화면에서 본다.
    private static let homeCardCount = 2

    var body: some View {
        Group {
            if porcelain {
                porcelainBody
            } else {
                legacyButton
            }
        }
        .navigationDestination(isPresented: $showingDraftManager) {
            TrailerDraftManagerView { entry in
                showingDraftManager = false
                resumingDraft = entry
            }
        }
        .fullScreenCover(item: $resumingDraft) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
                .environmentObject(inboxStore)
        }
        // 관리 화면과 같은 항목별 확인: 고른 편집 하나의 임시 파일만 지운다.
        .alert("이 편집을 지울까요?", isPresented: Binding(
            get: { confirmingDeleteID != nil },
            set: { if !$0 { confirmingDeleteID = nil } })) {
            Button("지우기", role: .destructive) {
                if let id = confirmingDeleteID { draftStore.discard(id) }
                confirmingDeleteID = nil
            }
            Button("취소", role: .cancel) { confirmingDeleteID = nil }
        } message: {
            Text("이 편집의 임시 파일만 지워집니다. 원본 사진·영상은 지워지지 않습니다.")
        }
    }

    private var legacyButton: some View {
        Button {
            showingDraftManager = true
        } label: {
            HStack(spacing: ui(7)) {
                ThemedSymbol(systemName: "film.stack", size: ui(32), symbolSize: ui(17))
                Text("보관한 편집")
                Spacer(minLength: ui(8))
                Text("\(draftStore.entries.count)개")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
        .accessibilityHint("보관한 편집을 이어서 하거나 지웁니다.")
    }

    /// 홈에서는 개별 편집 카드 대신 보관한 편집 개수 행만 두고, 세부 카드는 관리 화면에서 본다.
    private var porcelainBody: some View {
        PorcelainGroupCard {
            Button {
                showingDraftManager = true
            } label: {
                PorcelainRow(
                    title: "보관한 편집",
                    subtitle: "메모리에만 보관 · 앱을 끝내면 사라집니다",
                    subtitleLineLimit: 2,
                    showsChevron: true
                ) {
                    InterfaceIcon(systemName: "film.stack", size: PorcelainMetrics.rowIconSize)
                } trailing: {
                    Text("\(draftStore.entries.count)개")
                        .porcelainFont(.meta)
                        .monospacedDigit()
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("보관한 편집을 이어서 하거나 지웁니다.")
        }
    }

    private func resume(_ entry: TrailerDraftEntry) {
        // 편집기·관리 화면은 한 번에 하나만 띄운다.
        guard resumingDraft == nil, !showingDraftManager else { return }
        resumingDraft = draftStore.entries.first { $0.id == entry.id }
    }
}

/// 홈의 보관한 편집 한 장: 실제 커버, 길이 배지, 제목, 이어서 편집, 메뉴(이어서 편집·지우기).
private struct PorcelainDraftCard: View {
    let entry: TrailerDraftEntry
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var thumbnail: UIImage?
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        HStack(spacing: 0) {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Color(uiColor: .tertiarySystemFill)
                        .frame(width: 112, height: 63)
                        .overlay {
                            if let thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                                    .frame(width: 112, height: 63).clipped()
                            } else {
                                Image(systemName: "film").foregroundStyle(.secondary)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.coverCorner, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Text(videoTrailerTime(entry.totalDuration))
                                .porcelainFont(.badge)
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(5)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .porcelainFont(.tile)
                            .foregroundStyle(PorcelainMetrics.graphite)
                            .lineLimit(2)
                        Text("이어서 편집")
                            .porcelainFont(.body)
                            .foregroundStyle(PorcelainMetrics.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .accessibilityHidden(true)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.title), \(videoTrailerTime(entry.totalDuration))")
            .accessibilityHint("이어서 편집합니다.")

            Menu {
                Button("이어서 편집", systemImage: "play.fill", action: onResume)
                Button("지우기", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(entry.title) 편집 메뉴")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PorcelainMetrics.card,
            in: RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner + 2, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner + 2, style: .continuous)
                .stroke(PorcelainMetrics.line, lineWidth: 0.75)
        }
        .task(id: entry.id) {
            guard thumbnail == nil else { return }
            thumbnail = await trailerDraftThumbnail(url: entry.thumbnailURL, isImage: entry.thumbnailIsImage, maxPixelSize: 240)
        }
    }
}

/// 보관한 편집의 대표 커버(이미지 또는 영상 첫 프레임).
private func trailerDraftThumbnail(url: URL?, isImage: Bool, maxPixelSize: CGFloat) async -> UIImage? {
    guard let url else { return nil }
    if isImage {
        let loaded = await trailerThumbnailImage(at: url, maxPixelSize: maxPixelSize)
        return Task.isCancelled ? nil : loaded
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    do {
        let frame = try await generator.image(at: .zero)
        return Task.isCancelled ? nil : UIImage(cgImage: frame.image)
    } catch {
        return nil
    }
}

/// The single "영상 만들기" entry: it opens the device photo library's media selection
/// directly; trailer or music video is chosen inside the editor itself.
private struct VideoCreateEntryLink: View {
    var porcelain = false
    @State private var showingLibrary = false

    var body: some View {
        Button {
            showingLibrary = true
        } label: {
            if porcelain {
                PorcelainVideoCTA()
            } else {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(systemName: "film", size: ui(32), symbolSize: ui(17))
                    Text("영상 만들기")
                    Spacer(minLength: ui(8))
                    Image(systemName: "chevron.right")
                        .font(.ui(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PorcelainSolidActionButtonStyle())
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
        .accessibilityHint("+ 메뉴에서 기기·파일·폰하드·NAS·Google 포토의 사진과 영상을 골라 영상 편집으로 만듭니다.")
        .navigationDestination(isPresented: $showingLibrary) {
            LocalPhotoLibraryView(initialMode: .trailer)
        }
    }
}

/// The scrollable screen a long press on the PhoneHard entry opens, listing every
/// suspended trailer/music editor kept in `TrailerDraftStore`, however many there are.
/// Nothing here is capped or evicted automatically; each entry stays until the user
/// explicitly resumes and finishes it, or deletes it themselves.
private struct TrailerDraftManagerView: View {
    let onResume: (TrailerDraftEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @State private var confirmingDeleteID: UUID?
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    /// 6개 테마 공통 승인안 화면.
    private var isPorcelain: Bool { true }

    var body: some View {
        Group {
            if draftStore.entries.isEmpty, isPorcelain {
                PorcelainStateView(
                    systemImage: "film.stack",
                    title: "보관한 편집이 없습니다",
                    message: "보관한 편집은 메모리에만 있고 앱을 끝내면 사라집니다."
                )
            } else if draftStore.entries.isEmpty {
                VStack(spacing: ui(8)) {
                    Image(systemName: "film.stack").font(.system(size: ui(32))).foregroundStyle(.secondary)
                    Text("보관한 편집이 없습니다").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isPorcelain {
                // 112x63(16:9) 컴팩트 행 목록. 개수 제한 없이 모두 보인다.
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(draftStore.entries) { entry in
                            PorcelainDraftCard(
                                entry: entry,
                                onResume: { onResume(entry) },
                                onDelete: { confirmingDeleteID = entry.id }
                            )
                        }
                    }
                    .padding(16)
                }
            } else {
                List {
                    ForEach(draftStore.entries) { entry in
                        TrailerDraftRow(entry: entry, onResume: { onResume(entry) },
                            onDelete: { confirmingDeleteID = entry.id })
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(isPorcelain ? PorcelainMetrics.paper : Color.clear)
        .navigationTitle("보관한 편집")
        .navigationBarTitleDisplayMode(.inline)
        // Per-entry confirmation only: nothing here ever deletes more than the one
        // entry the user picked, and only that entry's own staged copies/output.
        .alert("이 편집을 지울까요?", isPresented: Binding(
            get: { confirmingDeleteID != nil },
            set: { if !$0 { confirmingDeleteID = nil } })) {
            Button("지우기", role: .destructive) {
                if let id = confirmingDeleteID { draftStore.discard(id) }
                confirmingDeleteID = nil
            }
            Button("취소", role: .cancel) { confirmingDeleteID = nil }
        } message: {
            Text("이 편집의 임시 파일만 지워집니다. 원본 사진·영상은 지워지지 않습니다.")
        }
    }
}

/// One suspended editor's row: thumbnail, title, mode, video duration, item count and
/// when it was last left, with the re-edit/resume and delete actions right on it.
private struct TrailerDraftRow: View {
    let entry: TrailerDraftEntry
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var thumbnail: UIImage?

    private var modeTitle: String { entry.mode == .mediaMusic ? "뮤직비디오" : "예고편" }

    private var lastEditedTitle: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: entry.suspendedAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: ui(10)) {
            Color(uiColor: .tertiarySystemFill)
                .frame(width: ui(56), height: ui(56))
                .clipShape(RoundedRectangle(cornerRadius: ui(8), style: .continuous))
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: ui(56), height: ui(56)).clipped()
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: ui(8), style: .continuous))

            VStack(alignment: .leading, spacing: ui(3)) {
                Text(entry.title).font(.ui(.subheadline).weight(.medium)).lineLimit(1)
                Text("\(modeTitle) · \(entry.items.count)개 · \(videoTrailerTime(entry.totalDuration))")
                    .font(.ui(.caption)).foregroundStyle(.secondary)
                Text("마지막 편집 \(lastEditedTitle)").font(.ui(.caption2)).foregroundStyle(.secondary)
            }
            Spacer(minLength: ui(4))
            Button("이어서 하기", action: onResume)
                .buttonStyle(.bordered).controlSize(.small)
            Button(role: .destructive, action: onDelete) {
                ThemedSymbol(systemName: "trash", size: ui(22))
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, ui(4))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "이어서 하기", onResume)
        .accessibilityAction(named: "지우기", onDelete)
        .task(id: entry.id) {
            guard thumbnail == nil else { return }
            if let loaded = await trailerDraftThumbnail(url: entry.thumbnailURL, isImage: entry.thumbnailIsImage, maxPixelSize: 160) { thumbnail = loaded }
        }
    }
}

/// Porcelain 보관한 편집 관리 화면의 큰 카드.
private struct PorcelainDraftLargeCard: View {
    let entry: TrailerDraftEntry
    let onResume: () -> Void
    let onDelete: () -> Void
    @State private var thumbnail: UIImage?
    private var themeRefresh = ThemeRefresh()

    private var modeTitle: String { entry.mode == .mediaMusic ? "뮤직비디오" : "예고편" }

    var body: some View {
        let _ = themeRefresh.theme
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onResume) {
                Color(uiColor: .tertiarySystemFill)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text(videoTrailerTime(entry.totalDuration))
                            .porcelainFont(.badge)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(8)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title), \(videoTrailerTime(entry.totalDuration))")
            .accessibilityHint("이어서 편집합니다.")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .porcelainFont(.tile)
                    .foregroundStyle(PorcelainMetrics.graphite)
                    .lineLimit(2)
                Text("\(modeTitle) · \(entry.items.count)개")
                    .porcelainFont(.meta)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button(action: onResume) {
                    Label("이어서 편집", systemImage: "play.fill")
                        .porcelainFont(.body, weight: .medium)
                        .foregroundStyle(PorcelainMetrics.graphite)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(PorcelainMetrics.accent)
                Button(role: .destructive, action: onDelete) {
                    Label("삭제", systemImage: "trash")
                        .porcelainFont(.body, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            PorcelainMetrics.card,
            in: RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner + 2, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PorcelainMetrics.ctaCorner + 2, style: .continuous)
                .stroke(PorcelainMetrics.line, lineWidth: 0.75)
        }
        .task(id: entry.id) {
            guard thumbnail == nil else { return }
            thumbnail = await trailerDraftThumbnail(url: entry.thumbnailURL, isImage: entry.thumbnailIsImage, maxPixelSize: 480)
        }
    }
}

private struct StorageOverviewCard: View {
    let inboxCount: Int
    let inboxByteCount: Int64
    let connectionCount: Int
    let deviceStorage: DeviceStorageSnapshot
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: ui(16)) {
            VStack(alignment: .leading, spacing: ui(5)) {
                Label("저장공간", systemImage: "internaldrive.fill")
                    .font(.ui(.title3).weight(.semibold))
                    .foregroundStyle(.primary)

                Text("iPhone의 폰하드 파일과 연결된 원격 위치를 한눈에 확인하세요.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: ui(10), alignment: .topLeading),
                    count: columns
                ),
                spacing: ui(10)
            ) {
                StorageMetric(
                    title: "폰하드",
                    value: inboxCount == 0 ? "없음" : formattedByteCount(inboxByteCount),
                    detail: "\(inboxCount)개",
                    systemImage: "tray.full.fill",
                    tint: .blue
                )

                StorageMetric(
                    title: "iPhone 여유",
                    value: deviceStorage.hasCapacity
                        ? formattedByteCount(deviceStorage.availableBytes)
                        : "확인 불가",
                    detail: deviceStorage.hasCapacity
                        ? "전체 \(formattedByteCount(deviceStorage.totalBytes))"
                        : "iOS 저장공간",
                    systemImage: "iphone",
                    tint: .blue
                )

                StorageMetric(
                    title: "원격 위치",
                    value: "\(connectionCount)개",
                    detail: connectionCount == 0 ? "연결 필요" : "NAS · SFTP",
                    systemImage: "externaldrive.connected.to.line.below.fill",
                    tint: .teal
                )
            }

            if deviceStorage.hasCapacity {
                VStack(alignment: .leading, spacing: ui(7)) {
                    HStack {
                        Text("이 기기 저장공간 사용량")
                        Spacer()
                        Text(deviceStorage.usedFraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)

                    ProgressView(value: deviceStorage.usedFraction)
                        .tint(.blue)
                        .accessibilityLabel("이 기기 저장공간 사용량")
                        .accessibilityValue(
                            Text(
                                deviceStorage.usedFraction,
                                format: .percent.precision(.fractionLength(0))
                            )
                        )
                }
            }
        }
        .padding(ui(18))
        .background(.background, in: RoundedRectangle(cornerRadius: ui(22), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ui(22), style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct StorageMetric: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: ui(10)) {
            Image(systemName: systemImage)
                .font(.ui(.body).weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: ui(34), height: ui(34))
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: ui(10)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.ui(.subheadline).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.ui(.caption2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    let subtitle: String
    let badge: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        badge: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            VStack(alignment: .leading, spacing: ui(3)) {
                HStack(spacing: ui(8)) {
                    Text(title)
                        .font(.ui(.headline))

                    if let badge {
                        Text(badge)
                            .font(.ui(.caption).monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, ui(7))
                            .padding(.vertical, ui(2))
                            .background(.quaternary, in: Capsule())
                            .accessibilityLabel("\(badge)개")
                    }
                }

                Text(subtitle)
                    .font(.ui(.subheadline))
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}

private struct QuickLocationCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            Image(systemName: systemImage)
                .font(.ui(.title3).weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: ui(42), height: ui(42))
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: ui(12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: ui(3)) {
                Text(title)
                    .font(.ui(.subheadline).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: ui(118), alignment: .topLeading)
        .padding(ui(14))
        .background(.background, in: RoundedRectangle(cornerRadius: ui(18), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: ui(18), style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct NetworkLocationCard: View {
    let connection: RemoteConnection
    let isPreferred: Bool
    let requestOpening: () -> Void
    let requestPreferred: () -> Void
    let requestClearPreferred: () -> Void
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let requestMoveEarlier: () -> Void
    let requestMoveLater: () -> Void
    let requestEditing: () -> Void
    let requestDeletion: () -> Void

    private var dropboxAccountSubtitle: String {
        let account = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty || account.caseInsensitiveCompare("Dropbox") == .orderedSame
            ? "계정 정보 확인 필요" : account
    }

    var body: some View {
        HStack(spacing: ui(4)) {
            Button(action: requestOpening) {
                HStack(spacing: ui(13)) {
                    ThemedSymbol(
                        systemName: connection.kind.systemImage,
                        size: ui(32),
                        symbolSize: ui(17)
                    )
                        .font(.ui(.title3))
                        .foregroundStyle(connection.kind.dashboardTint)
                        .frame(width: ui(32), height: ui(32))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: ui(4)) {
                        HStack(spacing: ui(6)) {
                            Text(connection.name)
                                .font(.ui(.subheadline).weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            if isPreferred {
                                Image(systemName: "star.fill")
                                    .font(.ui(.caption))
                                    .foregroundStyle(SkyBreezeTheme.accent)
                                    .accessibilityLabel("기본 위치")
                            }

                            if connection.name.caseInsensitiveCompare(connection.kind.dashboardLabel) != .orderedSame {
                                Text(connection.kind.dashboardLabel)
                                    .font(.ui(.caption2).weight(.semibold))
                                    .foregroundStyle(connection.kind.dashboardTint)
                                    .padding(.horizontal, ui(6))
                                    .padding(.vertical, ui(2))
                                    .background(
                                        connection.kind.dashboardTint.opacity(0.1),
                                        in: Capsule()
                                    )
                            }
                        }

                        Text(connection.kind == .dropbox ? dropboxAccountSubtitle : connection.host)
                            .font(.ui(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, ui(2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(connection.name), \(connection.kind.title)")
            .accessibilityValue(connection.kind == .dropbox ? dropboxAccountSubtitle : connection.host)
            .accessibilityHint("파일 목록을 엽니다.")

            Menu {
                if isPreferred {
                    Button("기본 위치 해제", systemImage: "star.slash") {
                        requestClearPreferred()
                    }
                } else {
                    Button("기본 위치로 설정", systemImage: "star") {
                        requestPreferred()
                    }
                }
                Button("연결 수정", systemImage: "pencil") {
                    requestEditing()
                }
                if canMoveEarlier || canMoveLater {
                    Section("순서") {
                        Button("위로 이동", systemImage: "arrow.up") {
                            requestMoveEarlier()
                        }
                        .disabled(!canMoveEarlier)
                        Button("아래로 이동", systemImage: "arrow.down") {
                            requestMoveLater()
                        }
                        .disabled(!canMoveLater)
                    }
                }
                Button("연결 삭제", systemImage: "trash", role: .destructive) {
                    requestDeletion()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.ui(.body).weight(.semibold))
                    .frame(width: ui(44), height: ui(54))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(connection.name) 연결 메뉴")
        }
    }
}

private struct AddNetworkLocationCard: View {
    let action: () -> Void
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    private var isBKStyle: Bool {
        false // 예전 에나멜 장식은 6개 테마에 없다.
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui(13)) {
                Group {
                    if isBKStyle {
                        ThemedSymbol(systemName: "plus", size: ui(32), symbolSize: ui(17))
                    } else {
                        Image(systemName: "plus")
                            .font(.ui(.title3).weight(.semibold))
                            .foregroundStyle(.blue)
                            .frame(width: ui(46), height: ui(46))
                            .background(
                                .blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: ui(13))
                            )
                    }
                }
                .frame(width: ui(46), height: ui(46))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ui(4)) {
                    Text("네트워크 추가")
                        .font(.ui(.headline))
                        .foregroundStyle(.primary)
                    Text("Synology File Station 또는 SFTP 서버")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(ui(14))
            .frame(maxWidth: .infinity, minHeight: ui(90), alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: ui(18), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                    .stroke(.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: ui(18), style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("새 원격 저장공간 연결 화면을 엽니다.")
    }
}

private struct FileAppIntegrationBanner: View {
    var body: some View {
        NavigationLink {
            FilesAppIntegrationGuideView(connectionCount: nil)
        } label: {
            HStack(alignment: .top, spacing: ui(12)) {
                Image(systemName: "folder.fill")
                    .font(.ui(.title3))
                    .foregroundStyle(.blue)
                    .frame(width: ui(38), height: ui(38))
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: ui(11)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ui(4)) {
                    Text("Apple 파일 앱에서도 열 수 있어요")
                        .font(.ui(.subheadline).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("파일 앱의 ‘탐색 > 위치’에서 추가한 NAS와 SFTP 연결을 확인하세요.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.ui(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(ui(14))
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: ui(18)))
            .contentShape(RoundedRectangle(cornerRadius: ui(18)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("파일 앱 연동 방법을 봅니다.")
    }
}

struct FilesAppIntegrationGuideView: View {
    let connectionCount: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ui(24)) {
                VStack(alignment: .leading, spacing: ui(12)) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.system(size: ui(34), weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: ui(64), height: ui(64))
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: ui(18)))
                        .accessibilityHidden(true)

                    Text("NasFinder의 원격 위치를 Apple 파일 앱에서도 찾아볼 수 있습니다.")
                        .font(.ui(.title3).weight(.semibold))

                    if let connectionCount {
                        Text(connectionCount == 0
                            ? "먼저 NasFinder에서 NAS 또는 SFTP 연결을 추가해 주세요."
                            : "현재 저장된 원격 위치 \(connectionCount)개가 파일 앱에 각각 표시됩니다.")
                            .font(.ui(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: ui(16)) {
                    Text("설정 방법")
                        .font(.ui(.headline))

                    IntegrationStep(number: 1, text: "Apple 파일 앱을 열고 아래의 ‘탐색’을 선택합니다.")
                    IntegrationStep(number: 2, text: "오른쪽 위의 더 보기(…)를 누른 다음 ‘편집’을 선택합니다.")
                    IntegrationStep(number: 3, text: "NasFinder에서 추가한 NAS 또는 SFTP 이름을 켭니다.")
                    IntegrationStep(number: 4, text: "‘위치’에서 서버 이름을 선택해 원격 파일을 엽니다.")
                }
                .padding(ui(18))
                .background(.background, in: RoundedRectangle(cornerRadius: ui(20)))

                Label {
                    VStack(alignment: .leading, spacing: ui(4)) {
                        Text("파일 작업 범위")
                            .font(.ui(.subheadline).weight(.semibold))
                        Text("SFTP 위치는 파일 앱에서도 복사, 업로드, 이동, 이름 변경과 삭제를 지원합니다. Synology 위치는 서버 작업 검증이 끝날 때까지 열기와 내려받기만 지원합니다.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
                .padding(ui(16))
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: ui(18)))
                .accessibilityElement(children: .combine)
            }
            .padding(ui(16))
            .frame(maxWidth: ui(720))
            .frame(maxWidth: .infinity)
        }
        .background(PorcelainMetrics.paper.ignoresSafeArea())
        .navigationTitle("파일 앱 연동")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IntegrationStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: ui(12)) {
            Text(number, format: .number)
                .font(.ui(.caption).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: ui(26), height: ui(26))
                .background(.blue, in: Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(.ui(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)단계. \(text)")
    }
}

private struct DeviceStorageSnapshot: Equatable {
    let totalBytes: Int64
    let availableBytes: Int64

    var hasCapacity: Bool {
        totalBytes > 0 && availableBytes >= 0
    }

    var usedFraction: Double {
        guard hasCapacity else { return 0 }
        let clampedAvailable = min(totalBytes, availableBytes)
        return Double(totalBytes - clampedAvailable) / Double(totalBytes)
    }

    static func current() -> Self {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
            ])
            let totalBytes = values.volumeTotalCapacity.map(Int64.init) ?? 0
            let availableBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            return Self(totalBytes: totalBytes, availableBytes: max(0, availableBytes))
        } catch {
            return Self(totalBytes: 0, availableBytes: 0)
        }
    }
}

private extension ConnectionKind {
    var dashboardTint: Color {
        ThemeServicePalette.color(
            forServiceIdentifier: rawValue,
            theme: .current
        )
    }

    var dashboardLabel: String {
        switch self {
        case .synology: "NAS"
        case .sftp: "SFTP"
        case .smb: "SMB"
        case .webDAV: "WebDAV"
        case .ftp: "FTP"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google Drive"
        }
    }
}

private func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, byteCount), countStyle: .file)
}

// MARK: - 공통 홈(6개 테마)

/// 6개 테마 공통 홈(승인 보드 01). 색은 현재 테마의 의미 색만 바뀐다. 폰: 브랜드 헤더 → 즐겨찾기 커버 선반 → 파일 열기 2×2 →
/// Browser·추가 → 붉은 영상 만들기·보관한 편집 → 전송·저장공간. 넓은 화면(패드·Mac): 주요 목적지
/// 사이드바 + 큰 즐겨찾기 4열, 그 아래 파일 열기와 영상 작업 두 칸. 기존 연결·메뉴·길게 누르기·
/// 시트·내비게이션 상태를 그대로 쓴다.
extension ConnectionListView {
    @ToolbarContentBuilder
    fileprivate var porcelainToolbar: some ToolbarContent {
        // 넓은 패드에서는 사이드바 맨 위에 브랜드가 있어 상단 막대에 다시 두지 않는다.
        // 폰(사이드바 없음)은 시스템 막대가 설정·테마를 넘침 메뉴로 접지 않도록 막대 대신
        // 홈 안의 앱 소유 헤더(porcelainPhoneHeader)에 브랜드와 추가·설정·테마를 둔다.
        if isRunningOnMac {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    porcelainTrailingCluster
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    porcelainTrailingCluster
                }
            }
        } else if porcelainSidebarActive {
            if #available(iOS 26.0, *) {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    porcelainTrailingItems
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    porcelainTrailingItems
                }
            }
        }
    }

    /// 폰 홈의 시스템 막대를 숨기고 앱 헤더를 쓰는지. 하위 화면은 자기 막대(뒤로 등)를 그대로 쓴다.
    fileprivate var usesPorcelainPhoneHeader: Bool {
        !isRunningOnMac && !porcelainSidebarActive
    }

    /// 폰 홈 맨 위 한 줄: 브랜드(Nas 그래파이트 + Finder 강조색)와 추가·설정·테마 버튼.
    /// 실제 폭에 맞춰 한 줄에 다 들어가지 않으면 브랜드 글자 크기만 기본 크기로 묶는다. 넘침 메뉴는 없다.
    fileprivate var porcelainPhoneHeader: some View {
        ViewThatFits(in: .horizontal) {
            porcelainPhoneHeaderRow(capsBrandSize: false)
            porcelainPhoneHeaderRow(capsBrandSize: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(PorcelainMetrics.paper)
    }

    private func porcelainPhoneHeaderRow(capsBrandSize: Bool) -> some View {
        HStack(spacing: 0) {
            dashboardLogo
                .dynamicTypeSize(capsBrandSize ? ...DynamicTypeSize.large : ...DynamicTypeSize.accessibility5)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                porcelainTrailingItems
            }
            .fixedSize()
        }
    }

    /// Mac 전용: 항목별 시스템 배치로 버튼이 멀리 벌어지지 않도록 한 항목 안의 고정 폭 HStack으로 묶는다.
    fileprivate var porcelainTrailingCluster: some View {
        HStack(spacing: 4) {
            porcelainTrailingItems
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 브랜드·설정과 같은 높이의 작고 독립된 버튼들. 캡슐 배경 없이 44pt 터치 영역만 둔다.
    @ViewBuilder
    fileprivate var porcelainTrailingItems: some View {
        Button {
            isChoosingNetwork = true
        } label: {
            InterfaceToolbarIcon(systemName: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel("네트워크 추가")
        .help("네트워크 추가 (⌘N)")

        NavigationLink {
            porcelainDetailHost { AppSettingsView(connectionCount: store.connections.count) }
        } label: {
            InterfaceToolbarIcon(systemName: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityLabel("설정")
        .help("설정 (⌘,)")

        // 병기스타일 테마 전환 버튼 (짧게 탭: 다음 테마, 500ms 롱프레스: 6종 선택 메뉴).
        ByungkiThemeControlButton(
            selectedThemeRawValue: $selectedThemeRawValue,
            isBadgeStyle: false,
            isRunningOnMac: isRunningOnMac
        )
    }

    fileprivate var porcelainHome: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Group {
                if width >= PorcelainMetrics.workspaceWidth {
                    let sidebarWidth = PorcelainMetrics.sidebarWidth(for: width)
                    HStack(spacing: 0) {
                        porcelainSidebar(isHome: true)
                            .frame(width: sidebarWidth)
                        Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                        porcelainWorkspace(paneWidth: width - sidebarWidth - 0.5)
                    }
                } else if width >= PorcelainMetrics.pairedWidth && width > geometry.size.height {
                    // 가로 폰: 왼쪽 즐겨찾기·파일 열기, 오른쪽 영상 작업·도구.
                    VStack(spacing: 0) {
                        if !isRunningOnMac { porcelainPhoneHeader }
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    porcelainFavorites()
                                    porcelainFileOpen
                                }
                                .padding(16)
                            }
                            Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    porcelainVideo
                                    porcelainUtilities(includesSettings: true)
                                    porcelainSavedConnections
                                }
                                .padding(16)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        if !isRunningOnMac { porcelainPhoneHeader }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                porcelainFavorites()
                                porcelainFileOpen
                                porcelainVideo
                                porcelainUtilities(includesSettings: true)
                                porcelainSavedConnections
                            }
                            .frame(maxWidth: 640)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(width: width, height: geometry.size.height)
            .onChange(of: width, initial: true) { _, newWidth in
                porcelainSidebarActive = newWidth >= PorcelainMetrics.workspaceWidth
            }
        }
        .background(PorcelainMetrics.paper)
        .toolbar(usesPorcelainPhoneHeader ? .hidden : .automatic, for: .navigationBar)
        .transformEnvironment(\.dynamicTypeSize) { size in
            if isRunningOnMac { size = .large }
        }
        .font(.body)
    }

    /// 즐겨찾기 커버는 화면 폭에 비례해 키우지 않고 원래 크기로 둔다: 폰·패드 52, Mac 78.
    /// 가로 선반·스크롤은 그대로다.
    fileprivate var porcelainCoverSide: CGFloat { isRunningOnMac ? 78 : 52 }
    /// 즐겨찾기 타일 폭: 폰·패드 68, Mac 88. 선반 간격 8과 합쳐 커버 사이가 24/18이 된다. 긴 이름 때문에 넓히지 않는다.
    fileprivate var porcelainCaptionWidth: CGFloat { isRunningOnMac ? 88 : 68 }

    /// 넓은 화면의 주요 목적지 사이드바. 브랜드, 홈, 저장된 연결(동적), 내 사진·영상, 폰하드,
    /// Google 포토(숨김 설정을 따름), 영상 작업, 전송, 저장공간, Browser, 추가, 설정 순서다.
    fileprivate func porcelainSidebar(isHome: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                dashboardLogo
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)

                Button {
                    returnToDashboard()
                } label: {
                    PorcelainSidebarItem(title: "홈", isSelected: isHome) {
                        InterfaceIcon(systemName: "house", size: PorcelainMetrics.rowIconSize)
                            .foregroundStyle(isHome ? PorcelainMetrics.accent : PorcelainMetrics.graphite)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("NasFinder 첫 화면으로 돌아갑니다.")

                porcelainSidebarDivider

                ForEach(store.connections) { connection in
                    porcelainSidebarConnection(connection)
                }
                if store.connections.isEmpty {
                    Button {
                        isAddingConnection = true
                    } label: {
                        PorcelainSidebarItem(title: "NAS·서버 추가") {
                            InterfaceIcon(systemName: "externaldrive.connected.to.line.below", size: PorcelainMetrics.rowIconSize)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("NAS 연결을 추가합니다.")
                }

                NavigationLink {
                    porcelainDetailHost { LocalPhotoLibraryView() }
                } label: {
                    PorcelainSidebarItem(title: "내 사진·영상") {
                        InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityHint("NAS 연결 없이 이 기기의 사진과 영상을 선택해 미리 보고 예고편을 만듭니다.")

                PhoneHardEntryLink(summary: inboxSummary, porcelain: true, sidebar: true)

                if !googlePhotosHidden {
                    porcelainSidebarGooglePhotos
                }

                porcelainSidebarDivider

                NavigationLink {
                    porcelainDetailHost { LocalPhotoLibraryView(initialMode: .trailer) }
                } label: {
                    PorcelainSidebarItem(title: "영상 작업") {
                        InterfaceIcon(systemName: "film", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityHint("사진·영상을 골라 예고편이나 뮤직비디오를 만듭니다.")

                NavigationLink {
                    porcelainDetailHost { PhotoTransferView() }
                } label: {
                    PorcelainSidebarItem(title: "기기 간 사진 전송") {
                        InterfaceIcon(systemName: "arrow.left.arrow.right", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityHint("Live Photos와 Motion Photos를 함께 보내는 화면을 엽니다.")

                Button {
                    isImportingFromFiles = true
                } label: {
                    PorcelainSidebarItem(title: "기기 저장공간") {
                        InterfaceIcon(systemName: "internaldrive", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(deviceStorageSummary)
                .accessibilityHint("파일 앱에서 이 기기 또는 iCloud Drive의 파일을 선택합니다.")

                porcelainSidebarDivider

                NavigationLink {
                    porcelainDetailHost { WebBrowserView() }
                } label: {
                    PorcelainSidebarItem(title: "Browser") {
                        InterfaceIcon(systemName: "globe", size: PorcelainMetrics.rowIconSize)
                            .foregroundStyle(SkyBreezeTheme.browserOrange)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityLabel("Browser, WWW")
                .accessibilityHint("웹 브라우저를 엽니다.")

                Button {
                    isChoosingNetwork = true
                } label: {
                    PorcelainSidebarItem(title: "네트워크 추가") {
                        InterfaceIcon(systemName: "plus", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)

                porcelainSidebarDivider

                NavigationLink {
                    porcelainDetailHost { AppSettingsView(connectionCount: store.connections.count) }
                } label: {
                    PorcelainSidebarItem(title: "설정") {
                        InterfaceIcon(systemName: "gearshape", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)

                VStack(alignment: .leading, spacing: 4) {
                    Text(networkFooterText)
                    if let versionText = AppVersionDisplayPolicy.text() {
                        Text(versionText)
                    }
                }
                .porcelainFont(.meta)
                .foregroundStyle(PorcelainMetrics.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .background(PorcelainMetrics.sidebar)
    }

    private var porcelainSidebarDivider: some View {
        Rectangle()
            .fill(PorcelainMetrics.line)
            .frame(height: 0.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    /// 사이드바의 저장된 연결 한 줄. 열기·연결 메뉴·끌어서 순서 바꾸기가 그대로 있다.
    private func porcelainSidebarConnection(_ connection: RemoteConnection) -> some View {
        let isPreferred = store.preferredConnection?.id == connection.id
        return HStack(spacing: 0) {
            Button {
                open(connection)
            } label: {
                PorcelainSidebarItem(title: connection.name) {
                    InterfaceIcon(systemName: connection.kind.systemImage, size: PorcelainMetrics.rowIconSize)
                        .foregroundStyle(connection.kind.dashboardTint)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(connection.name), \(connection.kind.title)")
            .accessibilityValue(isPreferred ? "기본 위치" : "")
            .accessibilityHint("파일 목록을 엽니다.")

            Menu {
                porcelainConnectionActions(connection)
            } label: {
                PorcelainMoreMenuLabel()
            }
            .porcelainCompactMenu()
            .accessibilityLabel("\(connection.name) 연결 메뉴")
        }
        .contextMenu { porcelainConnectionActions(connection) }
        .modifier(PorcelainReorderModifier(connection: connection))
    }

    private var porcelainSidebarGooglePhotos: some View {
        HStack(spacing: 0) {
            Button {
                forceGooglePhotosAuthorization = false
                isImportingFromGooglePhotos = true
            } label: {
                PorcelainSidebarItem(title: googlePhotosName) {
                    Image("GooglePhotosBrand").renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Google 포토에서 사진과 영상을 선택합니다.")

            Menu {
                googlePhotosActions
            } label: {
                PorcelainMoreMenuLabel()
            }
            .porcelainCompactMenu()
            .disabled(googlePhotosConnection.isDisconnecting)
            .accessibilityLabel("\(googlePhotosName) 연결 메뉴")
        }
        .contextMenu { googlePhotosActions }
    }

    /// 사이드바 오른쪽 작업 영역: 즐겨찾기 선반, 그 아래 파일 열기와 영상 작업을 같은 폭 두 칸으로.
    /// 실제 내용 폭이 좁으면 한 칸으로 쌓는다. 남는 세로 공간을 가짜 내용으로 채우지 않는다.
    private func porcelainWorkspace(paneWidth: CGFloat) -> some View {
        let contentWidth = paneWidth - PorcelainMetrics.workspaceMargin * 2
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                porcelainFavorites(showsDivider: true)
                if contentWidth >= PorcelainMetrics.splitContentWidth {
                    HStack(alignment: .top, spacing: PorcelainMetrics.splitSpacing) {
                        porcelainFileOpen
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        porcelainVideo
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    porcelainFileOpen
                    porcelainVideo
                }
            }
            .padding(PorcelainMetrics.workspaceMargin)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 카드로 감싸지 않고 바탕 위에 바로 펼친 즐겨찾기 커버 선반.
    private func porcelainFavorites(showsDivider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PorcelainSectionHeader(title: "즐겨찾기") {
                if !favoriteStore.items.isEmpty {
                    NavigationLink {
                        porcelainDetailHost { FavoriteListView() }
                    } label: {
                        HStack(spacing: 2) {
                            Text("전체 보기")
                            Image(systemName: "chevron.right")
                                .accessibilityHidden(true)
                        }
                        .porcelainFont(.body)
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                    .accessibilityLabel("즐겨찾기 전체 보기")
                }
            }
            FavoriteShelfView(
                openFavorite: { selectedFavorite = $0 },
                tileSide: porcelainCoverSide,
                captionWidth: porcelainCaptionWidth
            )
            if showsDivider {
                Rectangle()
                    .fill(PorcelainMetrics.line)
                    .frame(height: 0.5)
                    .padding(.top, 4)
            }
        }
    }

    /// 대표 NAS: 기본 위치가 NAS면 그것, 아니면 저장된 첫 NAS.
    private var primaryNASConnection: RemoteConnection? {
        func isNAS(_ connection: RemoteConnection) -> Bool {
            switch connection.kind {
            case .dropbox, .oneDrive, .googleDrive: return false
            default: return true
            }
        }
        if let preferred = store.preferredConnection, isNAS(preferred) { return preferred }
        return store.connections.first(where: isNAS)
    }

    /// 파일 열기: 아이콘 왼쪽 + 두 줄 글의 낮은 2×2(NAS·내 사진/영상 / 폰하드·Google 포토),
    /// 그 아래 Browser·네트워크 추가 한 줄 두 칸. 큰 글자에서는 한 열로 쌓는다.
    private var porcelainFileOpen: some View {
        let stacks = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 8) {
            PorcelainSectionHeader(title: "파일 열기")
            PorcelainGroupCard {
                if stacks {
                    porcelainNASCell
                    PorcelainDivider()
                    porcelainPhotosCell
                    PorcelainDivider()
                    PhoneHardEntryLink(summary: inboxSummary, porcelain: true, tile: true)
                    if !googlePhotosHidden {
                        PorcelainDivider()
                        porcelainGooglePhotosCell
                    }
                } else {
                    porcelainCellPair {
                        porcelainNASCell
                    } trailing: {
                        porcelainPhotosCell
                    }
                    Rectangle().fill(PorcelainMetrics.line).frame(height: 0.5)
                    porcelainCellPair {
                        PhoneHardEntryLink(summary: inboxSummary, porcelain: true, tile: true)
                    } trailing: {
                        if !googlePhotosHidden {
                            porcelainGooglePhotosCell
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }
                }
            }
            PorcelainGroupCard {
                if stacks {
                    porcelainBrowserAction
                    PorcelainDivider()
                    porcelainAddNetworkAction
                } else {
                    porcelainCellPair {
                        porcelainBrowserAction
                    } trailing: {
                        porcelainAddNetworkAction
                    }
                }
            }
        }
    }

    /// 같은 높이의 두 칸을 얇은 세로선으로 나눈다.
    private func porcelainCellPair<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var porcelainNASCell: some View {
        if let nas = primaryNASConnection {
            let isPreferred = store.preferredConnection?.id == nas.id
            // 칸 안 메뉴 단추 없이 글 폭을 우선한다. 전체 주소는 손쉬운 사용 값과 연결 수정 화면에,
            // 연결 관리는 기존 contextMenu와 손쉬운 사용 동작에 그대로 있다.
            Button {
                open(nas)
            } label: {
                PorcelainOpenCell(title: nas.name, subtitle: "저장된 연결", isMarked: isPreferred) {
                    InterfaceIcon(systemName: nas.kind.systemImage, size: PorcelainMetrics.openIconSize)
                        .font(.system(size: 24))
                        .foregroundStyle(nas.kind.dashboardTint)
                }
            }
            .buttonStyle(.plain)
            .contextMenu { porcelainConnectionActions(nas) }
            .modifier(PorcelainReorderModifier(connection: nas))
            .accessibilityLabel("\(nas.name), \(nas.kind.title)")
            .accessibilityValue(nas.host)
            .accessibilityHint("파일 목록을 엽니다.")
            .accessibilityActions { porcelainConnectionActions(nas) }
        } else {
            Button {
                isAddingConnection = true
            } label: {
                PorcelainOpenCell(title: "NAS·서버", subtitle: "NAS 연결 추가") {
                    InterfaceIcon(systemName: "externaldrive.connected.to.line.below", size: PorcelainMetrics.openIconSize)
                        .font(.system(size: 24))
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("NAS 연결을 추가합니다.")
        }
    }

    private var porcelainPhotosCell: some View {
        NavigationLink {
            porcelainDetailHost { LocalPhotoLibraryView() }
        } label: {
            PorcelainOpenCell(title: "내 사진·영상", subtitle: "이 기기의 사진과 영상") {
                InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.openIconSize)
                    .font(.system(size: 24))
            }
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityHint("NAS 연결 없이 이 기기의 사진과 영상을 선택해 미리 보고 예고편을 만듭니다.")
    }

    private var porcelainGooglePhotosCell: some View {
        Button {
            googlePhotosHidden = false
            forceGooglePhotosAuthorization = false
            isImportingFromGooglePhotos = true
        } label: {
            PorcelainOpenCell(
                title: googlePhotosName,
                subtitle: googlePhotosName != "Google 포토" ? "Google 포토" : "클라우드 사진"
            ) {
                Image("GooglePhotosBrand").renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { googlePhotosActions }
        .accessibilityHint("Google 포토에서 사진과 영상을 선택합니다.")
        .accessibilityActions {
            if !googlePhotosConnection.isDisconnecting { googlePhotosActions }
        }
    }

    private var porcelainBrowserAction: some View {
        NavigationLink {
            porcelainDetailHost { WebBrowserView() }
        } label: {
            PorcelainInlineAction(title: "Browser") {
                InterfaceIcon(systemName: "globe", size: 24)
                    .foregroundStyle(SkyBreezeTheme.browserOrange)
            }
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityLabel("Browser, WWW")
        .accessibilityHint("웹 브라우저를 엽니다.")
    }

    private var porcelainAddNetworkAction: some View {
        Button {
            isChoosingNetwork = true
        } label: {
            PorcelainInlineAction(title: store.connections.isEmpty ? "네트워크를 추가해 주세요" : "네트워크 추가") {
                InterfaceIcon(systemName: "plus", size: 24)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("네트워크 추가")
    }

    @ViewBuilder
    private var googlePhotosActions: some View {
        if !googlePhotosConnection.isConnected {
            Button("연결 추가", systemImage: "plus") {
                forceGooglePhotosAuthorization = false
                isImportingFromGooglePhotos = true
            }
        }
        Button("연결 수정", systemImage: "pencil") {
            googlePhotosEditedName = googlePhotosName
            isEditingGooglePhotos = true
        }
        if googlePhotosConnection.isConnected {
            Button("다시 연결", systemImage: "arrow.triangle.2.circlepath") {
                isReconnectingGooglePhotos = true
            }
        }
        Button("연결 삭제", systemImage: "trash", role: .destructive) {
            isDeletingGooglePhotos = true
        }
    }

    /// 대표 NAS 외의 모든 저장된 연결(Dropbox·다른 NAS 등). 열기·메뉴·순서 변경이 그대로 있다.
    @ViewBuilder
    private var porcelainSavedConnections: some View {
        let primaryID = primaryNASConnection?.id
        let extras = store.connections.filter { $0.id != primaryID }
        if !extras.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PorcelainSectionHeader(title: "저장된 연결", role: .section)
                PorcelainGroupCard {
                    ForEach(Array(extras.enumerated()), id: \.element.id) { index, connection in
                        if index > 0 { PorcelainDivider() }
                        porcelainConnectionRow(connection)
                    }
                }
                Text(networkFooterText)
                    .porcelainFont(.meta)
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func porcelainConnectionRow(_ connection: RemoteConnection) -> some View {
        let isPreferred = store.preferredConnection?.id == connection.id
        let account = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = connection.kind == .dropbox
            ? (account.isEmpty || account.caseInsensitiveCompare("Dropbox") == .orderedSame
                ? "계정 정보 확인 필요" : account)
            : connection.host
        let showsKindBadge = connection.name.caseInsensitiveCompare(connection.kind.dashboardLabel) != .orderedSame
        return HStack(spacing: 0) {
            Button {
                open(connection)
            } label: {
                PorcelainRow(
                    title: connection.name,
                    subtitle: subtitle,
                    badge: showsKindBadge ? connection.kind.dashboardLabel : nil,
                    badgeTint: connection.kind.dashboardTint
                ) {
                    InterfaceIcon(systemName: connection.kind.systemImage, size: PorcelainMetrics.rowIconSize)
                        .foregroundStyle(connection.kind.dashboardTint)
                } trailing: {
                    if isPreferred {
                        InterfaceIcon(systemName: "star.fill", size: 16)
                            .foregroundStyle(SkyBreezeTheme.accent)
                            .accessibilityLabel("기본 위치")
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(connection.name), \(connection.kind.title)")
            .accessibilityValue(subtitle)
            .accessibilityHint("파일 목록을 엽니다.")

            Menu {
                porcelainConnectionActions(connection)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(PorcelainMetrics.graphite)
                    .frame(width: 40, height: 48)
                    .contentShape(Rectangle())
            }
            .porcelainCompactMenu()
            .accessibilityLabel("\(connection.name) 연결 메뉴")
        }
        // 목록의 끌어서 순서 바꾸기를 대체한다. 위/아래 이동 메뉴도 그대로 있다.
        .modifier(PorcelainReorderModifier(connection: connection))
    }

    @ViewBuilder
    fileprivate func porcelainConnectionActions(_ connection: RemoteConnection) -> some View {
        let isPreferred = store.preferredConnection?.id == connection.id
        let canMoveEarlier = store.connections.first?.id != connection.id
        let canMoveLater = store.connections.last?.id != connection.id
        if isPreferred {
            Button("기본 위치 해제", systemImage: "star.slash") {
                store.clearPreferredConnection()
            }
        } else {
            Button("기본 위치로 설정", systemImage: "star") {
                store.setPreferredConnection(connection)
            }
        }
        Button("연결 수정", systemImage: "pencil") {
            editingConnection = connection
        }
        if canMoveEarlier || canMoveLater {
            Section("순서") {
                Button("위로 이동", systemImage: "arrow.up") { move(connection, by: -1) }
                    .disabled(!canMoveEarlier)
                Button("아래로 이동", systemImage: "arrow.down") { move(connection, by: 1) }
                    .disabled(!canMoveLater)
            }
        }
        Button("연결 삭제", systemImage: "trash", role: .destructive) {
            connectionPendingDeletion = connection
        }
    }

    /// 영상 작업: 붉은 영상 만들기, 실제 보관한 편집이 있을 때만 그 커버·시간·이어서 편집 카드.
    private var porcelainVideo: some View {
        VStack(alignment: .leading, spacing: 8) {
            PorcelainSectionHeader(title: "영상 작업")
            VideoCreateEntryLink(porcelain: true)
            TrailerDraftManagerEntryLink(porcelain: true)
        }
    }

    /// 전송·저장공간(폰에서는 설정도) 낮은 행.
    private func porcelainUtilities(includesSettings: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PorcelainGroupCard {
                NavigationLink {
                    PhotoTransferView()
                } label: {
                    PorcelainRow(
                        title: "기기 간 사진 전송",
                        subtitle: "Live Photos·Motion Photos 함께 보내기",
                        showsChevron: true
                    ) {
                        InterfaceIcon(systemName: "arrow.left.arrow.right", size: PorcelainMetrics.rowIconSize)
                    }
                }
                .buttonStyle(.plain)
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityHint("Live Photos와 Motion Photos를 함께 보내는 화면을 엽니다.")
                PorcelainDivider()

                Button {
                    isImportingFromFiles = true
                } label: {
                    VStack(spacing: 0) {
                        PorcelainRow(
                            title: "기기 저장공간",
                            subtitle: deviceStorageSummary,
                            showsChevron: true
                        ) {
                            InterfaceIcon(systemName: "internaldrive", size: PorcelainMetrics.rowIconSize)
                        } trailing: {
                            if deviceStorage.hasCapacity {
                                Text(deviceStorage.usedFraction, format: .percent.precision(.fractionLength(0)))
                                    .porcelainFont(.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(PorcelainMetrics.secondary)
                            }
                        }
                        if deviceStorage.hasCapacity {
                            ProgressView(value: deviceStorage.usedFraction)
                                .tint(SkyBreezeTheme.accent)
                                .padding(.leading, 54)
                                .padding(.trailing, 12)
                                .padding(.bottom, 10)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("파일 앱에서 이 기기 또는 iCloud Drive의 파일을 선택합니다.")

                if includesSettings {
                    PorcelainDivider()
                    porcelainSettingsLink
                }
            }
            if includesSettings, let versionText = AppVersionDisplayPolicy.text() {
                Text(versionText).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary).padding(.horizontal, 4)
            }
        }
    }

    private var porcelainSettingsLink: some View {
        NavigationLink {
            porcelainDetailHost { AppSettingsView(connectionCount: store.connections.count) }
        } label: {
            PorcelainRow(title: "설정", showsChevron: true) {
                InterfaceIcon(systemName: "gearshape", size: PorcelainMetrics.rowIconSize)
            }
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
    }

    /// 넓은 창에서는 사이드바를 유지한 채 상세(파일 목록 등)만 오른쪽에 둔다.
    /// 좁은 창·폰에서는 내용만 그대로 두어 기본 뒤로가기 스택을 쓴다.
    fileprivate func porcelainDetailHost<Detail: View>(
        @ViewBuilder _ detail: () -> Detail
    ) -> AnyView {
        let content = detail()
        // AnyView: 사이드바가 다시 이 호스트를 쓰는 재귀 구조라 불투명 타입을 끊는다.
        // 6개 테마 모두 넓은 화면에서 같은 사이드바 호스트를 쓴다.
        return AnyView(
            GeometryReader { geometry in
                let width = geometry.size.width
                Group {
                    if width >= PorcelainMetrics.workspaceWidth {
                        HStack(spacing: 0) {
                            porcelainSidebar(isHome: false)
                                .frame(width: PorcelainMetrics.sidebarWidth(for: width))
                            Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        content
                    }
                }
                .frame(width: width, height: geometry.size.height)
                .onChange(of: width, initial: true) { _, newWidth in
                    porcelainSidebarActive = newWidth >= PorcelainMetrics.workspaceWidth
                }
            }
        )
    }
}

/// 연결 행/카드를 끌어서 순서를 바꾸는 공통 동작.
private struct PorcelainReorderModifier: ViewModifier {
    let connection: RemoteConnection
    @EnvironmentObject private var store: ConnectionStore

    func body(content: Content) -> some View {
        content
            .draggable(connection.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let draggedID = UUID(uuidString: raw),
                      draggedID != connection.id,
                      let from = store.connections.firstIndex(where: { $0.id == draggedID }),
                      let target = store.connections.firstIndex(where: { $0.id == connection.id })
                else { return false }
                store.move(from: IndexSet(integer: from), to: from < target ? target + 1 : target)
                return true
            }
    }
}
