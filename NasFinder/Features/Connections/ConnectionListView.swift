import Foundation
import SwiftUI
import UIKit

struct ConnectionListView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var favoriteStore: FavoriteStore

    @State private var isAddingConnection: Bool
    @State private var connectionPendingDeletion: RemoteConnection?
    @State private var editingConnection: RemoteConnection?
    @State private var automaticallyOpenedConnection: RemoteConnection?
    @State private var didAttemptAutomaticOpen = false
    @State private var deviceStorage = DeviceStorageSnapshot.current()

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
                Section {
                    if store.connections.isEmpty {
                        Label(
                            "연결된 NAS가 없습니다",
                            systemImage: "externaldrive.badge.plus"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.connections) { connection in
                            NetworkLocationCard(
                                connection: connection,
                                isPreferred: store.preferredConnection?.id == connection.id,
                                requestOpening: {
                                    automaticallyOpenedConnection = connection
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
                                requestEditing: { editingConnection = connection },
                                requestDeletion: { connectionPendingDeletion = connection }
                            )
                        }
                        .onMove { offsets, destination in
                            store.move(from: offsets, to: destination)
                        }
                    }

                    Button("네트워크 추가", systemImage: "plus") {
                        isAddingConnection = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } header: {
                    sectionHeader("네트워크", systemImage: "network")
                } footer: {
                    Group {
                        if let preferred = store.preferredConnection {
                            Text("기본 위치 ‘\(preferred.name)’ · 앱 실행 시 자동으로 열림")
                        } else if store.connections.isEmpty {
                            Text("NAS 또는 SFTP 서버를 연결하면 파일을 탐색할 수 있습니다.")
                        } else {
                            Text("기본 위치 없음 · 앱 실행 시 연결 목록에서 시작")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }

                Section {
                    NavigationLink {
                        ReceivedFilesView()
                    } label: {
                        LabeledContent {
                            Text("\(inboxStore.records.count)개")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("받은 파일", systemImage: "tray.and.arrow.down")
                        }
                    }

                    FavoriteShelfView()
                } header: {
                    sectionHeader("내 파일", systemImage: "folder")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Section {
                    LabeledContent("받은 파일") {
                        Text("\(inboxStore.records.count)개 · \(formattedByteCount(inboxByteCount))")
                    }
                    LabeledContent("iPhone 여유") {
                        Text(
                            deviceStorage.hasCapacity
                                ? formattedByteCount(deviceStorage.availableBytes)
                                : "확인 불가"
                        )
                    }
                    if deviceStorage.hasCapacity {
                        ProgressView(value: deviceStorage.usedFraction) {
                            Text("iPhone 저장공간")
                        } currentValueLabel: {
                            Text(
                                deviceStorage.usedFraction,
                                format: .percent.precision(.fractionLength(0))
                            )
                        }
                    }
                } header: {
                    sectionHeader("iPhone 저장공간", systemImage: "internaldrive")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Section {
                    NavigationLink {
                        AppSettingsView(connectionCount: store.connections.count)
                    } label: {
                        Label("설정", systemImage: "gearshape")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SkyBreezeBackground())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image(currentLogoAssetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                            }

                        Text("NasFinder")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.82))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("NasFinder")
                }
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
                ReceivedFilesView()
            }
            .navigationDestination(item: $automaticallyOpenedConnection) { connection in
                FileBrowserContainerView(connection: connection)
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
            .task {
                deviceStorage = DeviceStorageSnapshot.current()
                guard !didAttemptAutomaticOpen else { return }
                didAttemptAutomaticOpen = true
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled,
                      !inboxStore.shouldPresentInbox,
                      !isAddingConnection,
                      editingConnection == nil else { return }
                automaticallyOpenedConnection = store.preferredConnection
            }
        }
    }

    private var quickLocationsSection: some View {
        DashboardSection(title: "빠른 위치", subtitle: "자주 쓰는 파일 흐름으로 바로 이동합니다.") {
            LazyVGrid(columns: quickLocationColumns, spacing: 12) {
                NavigationLink {
                    ReceivedFilesView()
                } label: {
                    QuickLocationCard(
                        title: "받은 파일",
                        subtitle: inboxStore.records.isEmpty
                            ? "다른 앱에서 파일 가져오기"
                            : "\(inboxStore.records.count)개 · \(formattedByteCount(inboxByteCount))",
                        systemImage: "tray.and.arrow.down.fill",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("다른 앱에서 NasFinder로 받은 파일을 엽니다.")

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
            LazyVGrid(columns: networkColumns, spacing: 12) {
                ForEach(store.connections) { connection in
                    NetworkLocationCard(
                        connection: connection,
                        isPreferred: store.preferredConnection?.id == connection.id,
                        requestOpening: {
                            automaticallyOpenedConnection = connection
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
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }

        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: count
        )
    }

    private var overviewColumns: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return horizontalSizeClass == .regular ? 3 : 2
    }

    private var networkColumns: [GridItem] {
        let count = horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: count
        )
    }

    private var pageHorizontalPadding: CGFloat {
        horizontalSizeClass == .regular ? 24 : 16
    }

    private var inboxByteCount: Int64 {
        inboxStore.records.reduce(into: 0) { result, record in
            result += max(0, record.byteCount)
        }
    }

    private var currentLogoAssetName: String {
        AppIconChoice.current(
            alternateIconName: UIApplication.shared.alternateIconName
        ).previewAssetName
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
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

private struct StorageOverviewCard: View {
    let inboxCount: Int
    let inboxByteCount: Int64
    let connectionCount: Int
    let deviceStorage: DeviceStorageSnapshot
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("저장공간", systemImage: "internaldrive.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("iPhone에 받은 파일과 연결된 원격 위치를 한눈에 확인하세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                    count: columns
                ),
                spacing: 10
            ) {
                StorageMetric(
                    title: "받은 파일",
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
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("iPhone 저장공간 사용량")
                        Spacer()
                        Text(deviceStorage.usedFraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.caption)
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
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)

                    if let badge {
                        Text(badge)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .accessibilityLabel("\(badge)개")
                    }
                }

                Text(subtitle)
                    .font(.subheadline)
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
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        HStack(spacing: 4) {
            Button(action: requestOpening) {
                HStack(spacing: 13) {
                    Image(systemName: connection.kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(connection.kind.dashboardTint)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(connection.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if isPreferred {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(SkyBreezeTheme.accent)
                                    .accessibilityLabel("기본 위치")
                            }

                            Text(connection.kind.dashboardLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(connection.kind.dashboardTint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    connection.kind.dashboardTint.opacity(0.1),
                                    in: Capsule()
                                )
                        }

                        Text(connection.host)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
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
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 54)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(connection.name) 연결 메뉴")
        }
    }
}

private struct AddNetworkLocationCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("네트워크 추가")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Synology File Station 또는 SFTP 서버")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple 파일 앱에서도 열 수 있어요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("파일 앱의 ‘탐색 > 위치’에서 추가한 NAS와 SFTP 연결을 확인하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 64, height: 64)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)

                    Text("NasFinder의 원격 위치를 Apple 파일 앱에서도 찾아볼 수 있습니다.")
                        .font(.title3.weight(.semibold))

                    if let connectionCount {
                        Text(connectionCount == 0
                            ? "먼저 NasFinder에서 NAS 또는 SFTP 연결을 추가해 주세요."
                            : "현재 저장된 원격 위치 \(connectionCount)개가 파일 앱에 각각 표시됩니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("설정 방법")
                        .font(.headline)

                    IntegrationStep(number: 1, text: "Apple 파일 앱을 열고 아래의 ‘탐색’을 선택합니다.")
                    IntegrationStep(number: 2, text: "오른쪽 위의 더 보기(…)를 누른 다음 ‘편집’을 선택합니다.")
                    IntegrationStep(number: 3, text: "NasFinder에서 추가한 NAS 또는 SFTP 이름을 켭니다.")
                    IntegrationStep(number: 4, text: "‘위치’에서 서버 이름을 선택해 원격 파일을 엽니다.")
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))

                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("파일 작업 범위")
                            .font(.subheadline.weight(.semibold))
                        Text("SFTP 위치는 파일 앱에서도 복사, 업로드, 이동, 이름 변경과 삭제를 지원합니다. Synology 위치는 서버 작업 검증이 끝날 때까지 열기와 내려받기만 지원합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
                .padding(16)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .combine)
            }
            .padding(16)
            .frame(maxWidth: 720)
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
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.blue, in: Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
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
        switch self {
        case .synology: .blue
        case .sftp: .teal
        }
    }

    var dashboardLabel: String {
        switch self {
        case .synology: "NAS"
        case .sftp: "SFTP"
        }
    }
}

private func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, byteCount), countStyle: .file)
}
