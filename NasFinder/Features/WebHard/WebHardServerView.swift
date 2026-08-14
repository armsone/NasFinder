import SwiftUI
import UIKit
import QuickLookThumbnailing

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
        if case .ready = state { return true }
        if case .starting = state { return true }
        return false
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

struct WebHardServerView: View {
    @EnvironmentObject private var controller: WebHardServerController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webHard.fileLayoutStyle.v1")
    private var storedLayoutStyle = WebHardFileLayoutStyle.smallThumbnails.rawValue
    @AppStorage("browser.coverFlowBackground.v1")
    private var coverFlowUsesDarkBackground = false
    @State private var shareItem: WebHardShareItem?
    @State private var deleteCandidate: WebHardFileItem?

    private var serviceColor: Color {
        ThemeServicePalette.color(
            forServiceIdentifier: "webHard",
            theme: .current
        )
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
        .navigationTitle("폰하드")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsCoverFlow ? .hidden : .visible, for: .navigationBar)
        .tint(serviceColor)
        .toolbar {
            if !showsCoverFlow {
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
            accessSection
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
            if controller.addresses.isEmpty {
                Label("사용 가능한 접속 주소가 없습니다", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
            } else {
                Picker("주소", selection: $controller.selectedAddressID) {
                    ForEach(controller.addresses) { address in
                        Text(address.address)
                        .tag(Optional(address.id))
                    }
                }
                .disabled(controller.isRunning)
                .labelsHidden()
            }

            HStack(spacing: 12) {
                SecureField("비밀번호 (선택)", text: $controller.password)
                    .textContentType(.password)
                    .disabled(controller.isRunning)

                Button(controller.isRunning ? "닫기" : "열기") {
                    controller.isRunning ? controller.stop() : controller.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedAddress == nil && !controller.isRunning)
            }

            if case let .failed(message) = controller.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        if let accessURL = controller.accessURL {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    webHardLogo
                    Text(accessURL.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var webHardLogo: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "externaldrive.fill.badge.wifi")
                .font(.title3)
                .foregroundStyle(serviceColor)
                .frame(width: 34, height: 34)
            Text(ThemeServicePalette.badgeLetter(forServiceIdentifier: "webHard"))
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(
                    ThemeServicePalette.foregroundColor(
                        forServiceIdentifier: "webHard",
                        theme: .current
                    )
                )
                .frame(width: 13, height: 13)
                .background(serviceColor, in: Circle())
        }
        .accessibilityLabel("폰하드")
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
