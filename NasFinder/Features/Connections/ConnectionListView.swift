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
        AppThemePreference.system.rawValue

    @State private var isAddingConnection: Bool
    @State private var connectionPendingDeletion: RemoteConnection?
    @State private var editingConnection: RemoteConnection?
    @State private var browserDestination: BrowserDestination?
    @State private var selectedFavorite: FavoriteItem?
    @State private var isImportingFromFiles = false
    @State private var didAttemptAutomaticOpen = false
    @State private var deviceStorage = DeviceStorageSnapshot.current()
    @State private var navigationIdentity = UUID()
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
            List {
                dashboardSections
            }
            .frame(maxWidth: dashboardContentMaxWidth)
            .environment(\.defaultMinListRowHeight, ui(isRunningOnMac ? 72 : 44))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SkyBreezeBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                dashboardLogoToolbar
            }
            .sheet(isPresented: $isAddingConnection) {
                AddConnectionView()
                    .environmentObject(store)
            }
            .sheet(item: $editingConnection) { connection in
                AddConnectionView(connection: connection)
                    .environmentObject(store)
            }
            .navigationDestination(isPresented: $inboxStore.shouldPresentInbox) {
                PhoneHardBrowserView()
            }
            .navigationDestination(item: $browserDestination) { destination in
                FileBrowserContainerView(
                    connection: destination.connection,
                    path: destination.path,
                    title: destination.title,
                    returnToDashboardAction: {
                        returnToDashboard()
                    }
                )
            }
            .navigationDestination(item: $selectedFavorite) { favorite in
                FavoriteDestinationView(favorite: favorite)
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
            .fileDialogConfirmationLabel("가져오기")
            .fileDialogMessage("나의 iPhone 또는 iCloud Drive에서 파일을 선택하세요.")
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
            .task {
                deviceStorage = DeviceStorageSnapshot.current()
                openPreferredConnectionIfNeeded()
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
        myFilesSection
        networkSection
        storageSection
        settingsSection
    }

    private var networkSection: some View {
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
            .accessibilityHint("NAS 연결 없이 iPhone의 사진과 영상을 선택해 미리 보고 예고편을 만듭니다.")

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

            NavigationLink {
                WebBrowserView()
            } label: {
                WebNetworkLocationRow()
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

            Button {
                isAddingConnection = true
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

    private var myFilesSection: some View {
        Section {
            FavoriteShelfView { favorite in
                selectedFavorite = favorite
            }

            NavigationLink {
                PhotoTransferView()
            } label: {
                HStack(spacing: ui(7)) {
                    ThemedSymbol(
                        systemName: "photo.on.rectangle.angled",
                        size: ui(32),
                        symbolSize: ui(17)
                    )
                    Text("Live Photos & Motion Photos")
                }
                .font(.ui(.subheadline))
                .foregroundStyle(.secondary)
            }
            .accessibilityHint("사진과 영상을 함께 보내는 화면을 엽니다.")

            ThumbnailCacheSettingsLink()

            SuperThumbnailLink()
        } header: {
            sectionHeader("내 파일", systemImage: "folder")
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
    }

    private var storageSection: some View {
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
                        Text("iPhone 저장공간")
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
            .accessibilityHint("파일 앱에서 나의 iPhone 또는 iCloud Drive의 파일을 선택합니다.")

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
        } header: {
            sectionHeader("저장공간", systemImage: "internaldrive")
        }
        .font(.ui(.subheadline))
        .foregroundStyle(.secondary)
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                AppSettingsView(connectionCount: store.connections.count)
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
    private func resetToDashboardAfterForegroundReturn() {
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
        Button {
            selectNextTheme()
        } label: {
            Image(systemName: selectedTheme.systemImage)
                .font(.system(size: ui(isRunningOnMac ? 12 : 9), weight: .bold))
                .foregroundStyle(
                    selectedTheme.preferredColorScheme == .dark ? .white : .black.opacity(0.72)
                )
                .frame(
                    width: ui(isRunningOnMac ? 51 : 38),
                    height: ui(isRunningOnMac ? 24 : 18)
                )
                .background {
                    Capsule()
                        .fill(
                            SkyBreezeTheme.skyGradient(
                                for: colorScheme,
                                theme: selectedTheme
                            )
                        )
                }
                .overlay {
                    Capsule()
                        .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                }
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("현재 테마, \(selectedTheme.title)")
        .accessibilityHint("두 번 탭하면 다음 테마로 바뀝니다.")
    }

    private func selectNextTheme() {
        withAnimation(.easeInOut(duration: 0.20)) {
            selectedThemeRawValue = selectedTheme.next.rawValue
        }
    }

    private var dashboardLogo: some View {
        Button(action: openRememberedLocation) {
            HStack(spacing: ui(isRunningOnMac ? 11 : 8)) {
                Image(currentLogoAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: uiBar(isRunningOnMac ? 51 : 38),
                        height: uiBar(isRunningOnMac ? 51 : 38)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: ui(isRunningOnMac ? 12 : 9),
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: ui(isRunningOnMac ? 12 : 9),
                            style: .continuous
                        )
                            .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                    }

                Text("NasFinder")
                    .uiBarFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.primary.opacity(0.82))
                    .fixedSize(horizontal: true, vertical: false)
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
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                Group {
                    dashboardLogo
                }
                .uiBarFont()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Group {
                    currentThemeBadge
                }
                .uiBarFont()
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Group {
                    dashboardLogo
                }
                .uiBarFont()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Group {
                    currentThemeBadge
                }
                .uiBarFont()
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: ui(selectedTheme == .skeuomorphism ? 7 : 3)) {
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

    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

    init(summary: String? = nil) {
        self.summary = summary
    }

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    var body: some View {
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
/// this device. A tap opens it in the same browser those open in. While a trailer or
/// music editor is waiting, a long press on the entry reopens that editor as it was left,
/// or asks which one when there are several.
private struct PhoneHardEntryLink: View {
    let summary: String?
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @State private var resumingDraft: TrailerDraftEntry?
    @State private var isChoosingDraft = false

    private var hasDrafts: Bool { !draftStore.entries.isEmpty }

    private var draftHint: String {
        draftStore.entries.count == 1
            ? "보관한 \(draftStore.entries[0].title) 편집이 있습니다. 길게 누르면 이어서 합니다."
            : "보관한 편집이 \(draftStore.entries.count)개 있습니다. 길게 누르면 골라서 이어서 합니다."
    }

    var body: some View {
        Button {
            inboxStore.shouldPresentInbox = true
        } label: {
            HStack(spacing: ui(7)) {
                WebHardNetworkLocationRow(summary: summary)
                if hasDrafts {
                    Image(systemName: "pencil.circle.fill")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(draftHint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Over the row's content only, and only while an editor is waiting, so the tap
        // that opens PhoneHard and the long press are told apart by one gesture, as in
        // the file browser. The cover below stays attached either way: the editor takes
        // its entry out of the store as soon as it is showing.
        .overlay {
            if hasDrafts {
                Color.clear.contentShape(Rectangle()).gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first:
                                resumeDraft()
                            case .second:
                                inboxStore.shouldPresentInbox = true
                            }
                        }
                )
            }
        }
        .accessibilityActions {
            if hasDrafts {
                Button("보관한 편집 이어서 하기") { resumeDraft() }
            }
        }
        .alert("이어서 할 편집", isPresented: $isChoosingDraft) {
            ForEach(draftStore.entries) { entry in
                Button(entry.title) { resumingDraft = entry }
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("보관해 둔 편집을 골라 주세요. 고르지 않은 편집도 그대로 남습니다.")
        }
        .fullScreenCover(item: $resumingDraft) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
                .environmentObject(inboxStore)
        }
    }

    private func resumeDraft() {
        // One editor at a time: nothing is presented over an editor already showing.
        guard resumingDraft == nil, !isChoosingDraft else { return }
        if draftStore.entries.count == 1 {
            resumingDraft = draftStore.entries[0]
        } else if draftStore.entries.count > 1 {
            isChoosingDraft = true
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
                        Text("iPhone 저장공간 사용량")
                        Spacer()
                        Text(deviceStorage.usedFraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)

                    ProgressView(value: deviceStorage.usedFraction)
                        .tint(.blue)
                        .accessibilityLabel("iPhone 저장공간 사용량")
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
                    .font(.ui(.subheadline).weight(.semibold))
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

                        Text(connection.host)
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
            .accessibilityValue(connection.host)
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
        AppThemePreference.system.rawValue

    private var isBKStyle: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
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
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
