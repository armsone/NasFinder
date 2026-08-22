import SwiftUI
import UIKit
import QuickLookThumbnailing

extension WebHardServerState {
    var isConnectionOpen: Bool {
        switch self {
        case .starting, .ready: true
        case .stopped, .failed: false
        }
    }
}

@MainActor
final class WebHardServerController: ObservableObject {
    @Published private(set) var addresses: [WebHardNetworkAddress] = []
    @Published var selectedAddressID: String?
    @Published var password = ""
    @Published private(set) var state: WebHardServerState = .stopped
    @Published private(set) var files: [WebHardFileItem] = []
    @Published private(set) var uploads: [WebHardUploadProgress] = []
    @Published private(set) var currentPath = "/"
    @Published private(set) var fileErrorMessage: String?
    @Published private(set) var thumbnailGeneration = 0

    private let store: WebHardFileStore?
    private let server: WebHardHTTPServer?

    init() {
        do {
            let store = try WebHardFileStore()
            self.store = store
            server = WebHardHTTPServer(store: store)
        } catch {
            store = nil
            server = nil
            state = .failed("폰하드 저장공간을 준비하지 못했습니다: \(error.localizedDescription)")
        }
        refreshAddresses()
        refreshFiles()
    }

    var selectedAddress: WebHardNetworkAddress? {
        addresses.first { $0.id == selectedAddressID }
    }

    var isRunning: Bool {
        state.isConnectionOpen
    }

    var accessURL: URL? {
        guard let selectedAddress, case let .ready(port) = state else { return nil }
        return URL(string: "http://\(selectedAddress.urlHost):\(port)")
    }

    func refreshAddresses() {
        let previous = selectedAddressID
        addresses = WebHardNetworkAddressDiscovery.availableAddresses()
        if let previous, addresses.contains(where: { $0.id == previous }) {
            selectedAddressID = previous
        } else {
            selectedAddressID = addresses.first?.id
        }
        if addresses.isEmpty, !isRunning {
            state = .failed("접속 가능한 Wi-Fi 주소를 찾지 못했습니다.")
        } else if case .failed = state, server != nil {
            state = .stopped
        }
    }

    func start() {
        guard let server, let selectedAddress else {
            state = .failed("접속 주소를 선택해 주세요.")
            return
        }
        server.start(
            address: selectedAddress,
            password: password,
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            },
            stateHandler: { [weak self] state in
                Task { @MainActor in self?.state = state }
            }
        )
    }

    func stop() {
        server?.stop()
        uploads = []
        state = .stopped
    }

    func applicationDidEnterBackground() {
        guard isRunning else { return }
        stop()
    }

    func refreshFiles() {
        guard let store else { return }
        do {
            files = try store.list(path: currentPath)
            fileErrorMessage = nil
        } catch {
            fileErrorMessage = error.localizedDescription
        }
    }

    func openDirectory(_ item: WebHardFileItem) {
        guard item.isDirectory else { return }
        currentPath = item.path
        refreshFiles()
    }

    func navigateUp() {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
        refreshFiles()
    }

    func fileURL(for item: WebHardFileItem) -> URL? {
        guard !item.isDirectory else { return nil }
        return try? store?.fileURL(path: item.path)
    }

    func exportURL(for item: WebHardFileItem) -> URL? {
        if item.isDirectory {
            return try? store?.directoryURL(path: item.path)
        }
        return try? store?.fileURL(path: item.path)
    }

    func delete(_ item: WebHardFileItem) {
        do {
            try store?.delete(path: item.path)
            refreshFiles()
        } catch {
            fileErrorMessage = error.localizedDescription
        }
    }

    func refreshThumbnails() {
        thumbnailGeneration &+= 1
    }

    private func handle(_ event: WebHardServerEvent) {
        switch event {
        case let .uploadChanged(progress):
            if let index = uploads.firstIndex(where: { $0.id == progress.id }) {
                uploads[index] = progress
            } else {
                uploads.append(progress)
            }
        case let .uploadEnded(id):
            uploads.removeAll { $0.id == id }
        case .contentsChanged:
            refreshFiles()
            refreshThumbnails()
        }
    }

}

private enum WebHardFileLayoutStyle: String, CaseIterable, Identifiable {
    case list
    case smallThumbnails
    case largeThumbnails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "자세히"
        case .smallThumbnails: "작은 썸네일"
        case .largeThumbnails: "포스터"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .smallThumbnails: "square.grid.3x3"
        case .largeThumbnails: "square.grid.2x2"
        }
    }
}

struct WebHardConnectionPanel: View {
    @EnvironmentObject private var controller: WebHardServerController
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if isEnamel {
                    PhoneHardMark(size: 28)
                } else {
                    ThemedSymbol(
                        systemName: "externaldrive.fill.badge.wifi",
                        size: 28,
                        symbolSize: 15
                    )
                }

                Text("서버 열기")
                    .font(.headline.weight(isEnamel ? .bold : .semibold))
                    .foregroundStyle(isEnamel ? bkCharcoal : Color.primary)

                Spacer(minLength: 8)

                Button {
                    controller.refreshAddresses()
                } label: {
                    ThemedSymbol(systemName: "arrow.clockwise", size: 30, symbolSize: 15)
                        .frame(width: 44, height: 44)
                }
                .disabled(controller.isRunning)
                .accessibilityLabel("접속 주소 새로고침")
            }

            WebHardConnectionControls()
        }
        .padding(14)
        .background(
            panelFill,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(panelRim, lineWidth: isEnamel ? 1.25 : 1)
        }
        .overlay(alignment: .top) {
            if isEnamel {
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(height: 1)
                    .padding(.horizontal, 22)
                    .padding(.top, 2)
            }
        }
        .shadow(color: .black.opacity(isEnamel ? 0.14 : 0.06), radius: 8, y: 4)
        .onAppear {
            if !controller.isRunning { controller.refreshAddresses() }
        }
    }

    private var bkCharcoal: Color {
        Color(red: 0.10, green: 0.11, blue: 0.12)
    }

    private var panelFill: AnyShapeStyle {
        if isEnamel {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        .white,
                        Color(red: 0.97, green: 0.965, blue: 0.95),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(SkyBreezeTheme.thumbnailSurface)
    }

    private var panelRim: AnyShapeStyle {
        if isEnamel {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        .white,
                        Color(red: 0.48, green: 0.49, blue: 0.50),
                        .white.opacity(0.82),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(SkyBreezeTheme.thumbnailBorder.opacity(0.72))
    }
}

private struct WebHardConnectionControls: View {
    @EnvironmentObject private var controller: WebHardServerController
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    @State private var isPasswordExpanded = false

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            addressInfoRow

            if isPasswordExpanded {
                passwordControl
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                passwordDisclosureButton
                toggleButton
            }

            if case let .failed(message) = controller.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isPasswordExpanded)
    }

    @ViewBuilder
    private var addressInfoRow: some View {
        if controller.selectedAddress == nil {
            Label("사용 가능한 접속 주소가 없습니다", systemImage: "network.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                LabeledContent {
                    addressText(alignment: .trailing)
                } label: {
                    addressLabel
                }

                VStack(alignment: .leading, spacing: 3) {
                    addressLabel
                    addressText(alignment: .leading)
                }
            }
            .frame(minHeight: 32)
            .accessibilityElement(children: .combine)
        }
    }

    private var addressLabel: some View {
        Text("접속 주소")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func addressText(alignment: TextAlignment) -> some View {
        Text(addressValue)
            .font(.footnote.monospaced())
            .foregroundStyle(
                isEnamel ? Color(red: 0.12, green: 0.13, blue: 0.14) : Color.primary
            )
            .multilineTextAlignment(alignment)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private var addressValue: String {
        if let accessURL = controller.accessURL {
            return accessURL.absoluteString
        }
        guard let address = controller.selectedAddress else { return "" }
        return "\(address.kind.title) · \(address.address)"
    }

    @ViewBuilder
    private var passwordControl: some View {
        if isEnamel {
            passwordField
                .textFieldStyle(.plain)
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.14))
                .padding(.horizontal, 11)
                .frame(minWidth: 140, maxWidth: .infinity, minHeight: 40)
                .background(BKWebHardRecessedSurface())
        } else {
            passwordField
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: .infinity, minHeight: 40)
        }
    }

    private var passwordField: some View {
        SecureField("비밀번호 (선택)", text: $controller.password)
            .font(.subheadline)
            .controlSize(.small)
            .textContentType(.password)
            .disabled(controller.isRunning)
    }

    private var passwordDisclosureButton: some View {
        Button {
            isPasswordExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("비밀번호")
                Image(systemName: isPasswordExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isEnamel ? Color(red: 0.12, green: 0.13, blue: 0.14) : .accentColor)
        .frame(minWidth: 120, maxWidth: .infinity, minHeight: 40)
        .accessibilityValue(isPasswordExpanded ? "펼쳐짐" : "접힘")
        .accessibilityHint(
            isPasswordExpanded ? "비밀번호 입력을 접습니다." : "비밀번호 입력을 펼칩니다."
        )
    }

    @ViewBuilder
    private var toggleButton: some View {
        if isEnamel {
            connectionToggleButton
                .buttonStyle(BKWebHardToggleButtonStyle(isRunning: controller.isRunning))
                .frame(minWidth: 88, maxWidth: .infinity)
                .opacity(toggleIsDisabled ? 0.45 : 1)
        } else {
            connectionToggleButton
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minWidth: 88, maxWidth: .infinity)
        }
    }

    private var connectionToggleButton: some View {
        Button {
            controller.isRunning ? controller.stop() : controller.start()
        } label: {
            Text(controller.isRunning ? "닫기" : "열기")
                .frame(maxWidth: .infinity)
        }
        .disabled(toggleIsDisabled)
        .accessibilityHint(
            controller.isRunning
                ? "다른 기기의 폰하드 접속을 끝냅니다."
                : "다른 기기에서 이 폰하드를 열 수 있게 합니다."
        )
    }

    private var toggleIsDisabled: Bool {
        controller.selectedAddress == nil && !controller.isRunning
    }
}

private struct BKWebHardRecessedSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.87, green: 0.865, blue: 0.85),
                        Color(red: 0.955, green: 0.95, blue: 0.935),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.black.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .white.opacity(0.88), radius: 0, y: 1)
    }
}

private struct BKWebHardToggleButtonStyle: ButtonStyle {
    let isRunning: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(
                isRunning
                    ? Color(red: 0.12, green: 0.13, blue: 0.14)
                    : Color.white
            )
            .padding(.horizontal, 16)
            .frame(minWidth: 88, maxWidth: .infinity, minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(buttonFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(buttonRim, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(isRunning ? 0.92 : 0.36))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
            .shadow(color: .black.opacity(0.20), radius: 4, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var buttonFill: AnyShapeStyle {
        if isRunning {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.white, Color(red: 0.83, green: 0.83, blue: 0.81)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.29, blue: 0.30),
                    Color(red: 0.08, green: 0.09, blue: 0.10),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var buttonRim: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [.white.opacity(0.88), Color(red: 0.42, green: 0.43, blue: 0.44)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct WebHardServerView: View {
    @EnvironmentObject private var controller: WebHardServerController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webHard.fileLayoutStyle.v1")
    private var storedLayoutStyle = WebHardFileLayoutStyle.smallThumbnails.rawValue
    @AppStorage("browser.coverFlowBackground.v1")
    private var coverFlowUsesDarkBackground = false
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    @State private var shareItem: WebHardShareItem?
    @State private var deleteCandidate: WebHardFileItem?

    private var serviceColor: Color {
        ThemeServicePalette.color(
            forServiceIdentifier: "webHard",
            theme: .current
        )
    }

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    var body: some View {
        Group {
            if showsCoverFlow {
                coverFlowContent
            } else {
                standardContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyBreezeBackground())
        .navigationTitle(isEnamel ? "" : "폰하드")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsCoverFlow ? .hidden : .visible, for: .navigationBar)
        .tint(serviceColor)
        .toolbar {
            if !showsCoverFlow {
                if isEnamel {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            PhoneHardMark(size: 26)
                            Text("폰하드")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("주소 새로고침", systemImage: "arrow.clockwise") {
                        controller.refreshAddresses()
                    }
                    .disabled(controller.isRunning)
                }
            }
        }
        .overlay { coverFlowNavigationOverlay }
        .onAppear {
            if !controller.isRunning { controller.refreshAddresses() }
            controller.refreshFiles()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .superThumbnailCacheDidChange)
        ) { _ in
            controller.refreshThumbnails()
        }
        .sheet(item: $shareItem) { item in
            WebHardActivityView(url: item.url)
        }
        .alert("삭제할까요?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("삭제", role: .destructive) {
                if let deleteCandidate { controller.delete(deleteCandidate) }
                deleteCandidate = nil
            }
            Button("취소", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text(deleteCandidate.map { "\($0.name)을(를) 삭제합니다." } ?? "")
        }
    }

    private var standardContent: some View {
        List {
            networkSection
            filesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var showsCoverFlow: Bool {
        layoutStyle == .largeThumbnails && verticalSizeClass == .compact
    }

    private var coverFlowContent: some View {
        FileBrowserCoverFlowView(
            items: controller.files,
            usesDarkBackground: $coverFlowUsesDarkBackground,
            itemName: { $0.name },
            thumbnail: { item, _ in
                WebHardThumbnailView(
                    item: item,
                    fileURL: controller.fileURL(for: item),
                    generation: controller.thumbnailGeneration
                )
            },
            onActivate: { item in
                if item.isDirectory { controller.openDirectory(item) }
            },
            onShowActions: nil
        )
    }

    @ViewBuilder
    private var coverFlowNavigationOverlay: some View {
        if showsCoverFlow {
            GeometryReader { geometry in
                HStack(spacing: 8) {
                    Button {
                        if controller.currentPath == "/" {
                            dismiss()
                        } else {
                            controller.navigateUp()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(coverFlowChromeForeground)
                    .background(coverFlowChromeBackground, in: Circle())
                    .overlay { Circle().stroke(coverFlowChromeBorder, lineWidth: 1) }
                    .shadow(
                        color: .black.opacity(coverFlowUsesDarkBackground ? 0.40 : 0.10),
                        radius: 8,
                        y: 2
                    )
                    .accessibilityLabel(controller.currentPath == "/" ? "폰하드 닫기" : "상위 폴더")

                    Text(controller.currentPath == "/" ? "폰하드" : controller.currentPath)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(coverFlowChromeForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(
                            maxWidth: min(geometry.size.width * 0.44, 340),
                            minHeight: 44,
                            alignment: .leading
                        )

                    Spacer(minLength: 8)

                    Menu {
                        Button("흰색") { coverFlowUsesDarkBackground = false }
                        Button("검정") { coverFlowUsesDarkBackground = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SkyBreezeTheme.accent)
                    .background(coverFlowChromeBackground, in: Circle())
                    .overlay { Circle().stroke(coverFlowChromeBorder, lineWidth: 1) }
                    .shadow(
                        color: .black.opacity(coverFlowUsesDarkBackground ? 0.40 : 0.10),
                        radius: 8,
                        y: 2
                    )
                    .accessibilityLabel("오버플로우 배경")
                }
                .padding(.horizontal, 12)
                .padding(.top, geometry.safeAreaInsets.top + 4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var coverFlowChromeForeground: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.88) : .black.opacity(0.82)
    }

    private var coverFlowChromeBackground: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.10) : .white.opacity(0.92)
    }

    private var coverFlowChromeBorder: Color {
        coverFlowUsesDarkBackground ? .white.opacity(0.16) : .black.opacity(0.10)
    }

    private var networkSection: some View {
        Section {
            WebHardConnectionControls()
        }
    }

    private var layoutStyle: WebHardFileLayoutStyle {
        WebHardFileLayoutStyle(rawValue: storedLayoutStyle) ?? .smallThumbnails
    }

    private var filesSection: some View {
        Section {
            if controller.currentPath != "/" {
                Button {
                    controller.navigateUp()
                } label: {
                    Label("상위 폴더", systemImage: "arrow.up.folder")
                }
            }

            ForEach(controller.uploads) { upload in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(upload.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(Int((upload.fractionCompleted * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: upload.fractionCompleted)
                        .tint(serviceColor)
                    Text("\(ByteCountFormatter.string(fromByteCount: upload.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: upload.totalBytes, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let message = controller.fileErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if controller.files.isEmpty && controller.uploads.isEmpty {
                ContentUnavailableView(
                    "파일이 없습니다",
                    systemImage: "tray",
                    description: Text("접속한 기기에서 파일을 올리면 바로 표시됩니다.")
                )
            } else {
                fileContents
            }
        } header: {
            HStack {
                Text(controller.currentPath == "/" ? "파일" : controller.currentPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(WebHardFileLayoutStyle.allCases) { style in
                        Button {
                            storedLayoutStyle = style.rawValue
                        } label: {
                            Image(systemName: style.systemImage)
                                .frame(width: 24, height: 24)
                                .foregroundStyle(layoutStyle == style ? serviceColor : .secondary)
                                .background(
                                    layoutStyle == style ? serviceColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title)
                        .accessibilityAddTraits(layoutStyle == style ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("보기 방식")
            }
        }
    }

    @ViewBuilder
    private var fileContents: some View {
        if layoutStyle == .list {
            ForEach(controller.files, id: \.path) { item in
                Button {
                    if item.isDirectory { controller.openDirectory(item) }
                } label: {
                    HStack(spacing: 12) {
                        WebHardThumbnailView(
                            item: item,
                            fileURL: controller.fileURL(for: item),
                            generation: controller.thumbnailGeneration
                        )
                        .frame(width: 52, height: 52)
                        fileMetadata(item)
                        Spacer()
                        if item.isDirectory {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { itemContextMenu(item) }
            }
        } else {
            let columnCount = layoutStyle == .largeThumbnails ? 2 : 3
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                    count: columnCount
                ),
                spacing: 14
            ) {
                ForEach(controller.files, id: \.path) { item in
                    fileGridCell(item)
                }
            }
            .frame(
                height: layoutStyle == .largeThumbnails ? portraitPosterGridHeight : nil,
                alignment: .top
            )
        }
    }

    private var portraitPosterGridHeight: CGFloat {
        let screenSize = UIScreen.main.bounds.size
        let portraitWidth = min(screenSize.width, screenSize.height)
        let listContentWidth = max(1, portraitWidth - 32)
        let cellWidth = max(1, (listContentWidth - 10) / 2)
        let rowCount = (controller.files.count + 1) / 2
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * (cellWidth + 50)
            + CGFloat(rowCount - 1) * 14
    }

    private func fileGridCell(_ item: WebHardFileItem) -> some View {
        Button {
            if item.isDirectory { controller.openDirectory(item) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                WebHardThumbnailView(
                    item: item,
                    fileURL: controller.fileURL(for: item),
                    generation: controller.thumbnailGeneration
                )
                .aspectRatio(1, contentMode: .fit)

                fileMetadata(item)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(
                        height: layoutStyle == .largeThumbnails ? 50 : 40,
                        alignment: .topLeading
                    )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(SkyBreezeTheme.thumbnailSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { itemContextMenu(item) }
    }

    private func fileMetadata(_ item: WebHardFileItem) -> some View {
        let filenameExtension = (item.name as NSString).pathExtension
        let filenameStem = filenameExtension.isEmpty
            ? item.name
            : (item.name as NSString).deletingPathExtension
        let metadataFontSize: CGFloat = layoutStyle == .largeThumbnails ? 12.75 : 9

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(filenameStem)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !filenameExtension.isEmpty {
                    Text(".\(filenameExtension)")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
                .font(.system(size: metadataFontSize))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let size = item.size, !item.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: metadataFontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemContextMenu(_ item: WebHardFileItem) -> some View {
        Button {
            if let url = controller.exportURL(for: item) {
                shareItem = WebHardShareItem(url: url)
            }
        } label: {
            Label("받기", systemImage: "square.and.arrow.down")
        }

        Button(role: .destructive) {
            deleteCandidate = item
        } label: {
            Label("삭제", systemImage: "trash")
        }
    }

}

private struct WebHardShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct WebHardActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct WebHardThumbnailView: View {
    let item: WebHardFileItem
    let fileURL: URL?
    let generation: Int
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(SkyBreezeTheme.thumbnailSurface)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .padding(item.isDirectory ? 10 : 16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
            }
        }
        .task(id: "\(item.path)|\(item.modifiedAt?.timeIntervalSince1970 ?? 0)|\(generation)") {
            guard let fileURL, !item.isDirectory else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: fileURL,
                size: CGSize(width: 360, height: 360),
                scale: UIScreen.main.scale,
                representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
                .uiImage
        }
    }
}
