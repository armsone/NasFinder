import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 포켓에 직접 담는 세 출처 — 미디어(사진 보관함) / Google 포토 / 파일. 미디어 전송의 세 소스와 포켓 화면이 함께 쓴다.
/// 어느 출처든 원본을 복사하지 않고 참조(PhotoKit 식별자·Google 항목 ID·파일 북마크)만 `pocketID` 포켓에 담는다.
struct WorkbenchAddSourceControls: View {
    enum Layout { case rows, menu }

    let pocketID: UUID?
    let layout: Layout
    /// Google 포토 참조 화면은 호출한 화면이 자기 탐색 경로에 올린다(화면을 떠날 때의 정리를 호출한 쪽이 알기 때문).
    let openGoogle: () -> Void
    /// 파인더의 모든 내용 출처(연결·폰하드·기기 파일·즐겨찾기 등)를 여는 길. 포켓 화면의 +에서만 지정하고, 미디어 전송의 세 소스는 그대로 둔다.
    var openFinder: (() -> Void)?

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isPhotosPresented = false
    @State private var isFilesPresented = false
    @State private var message: String?

    var body: some View {
        controls
            .disabled(pocketID == nil)
            .photosPicker(
                isPresented: $isPhotosPresented, selection: $pickerItems,
                matching: .any(of: [.images, .livePhotos, .videos]),
                preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                addPickerItems(items)
                pickerItems = []
            }
            .fileImporter(
                isPresented: $isFilesPresented, allowedContentTypes: [.image, .movie, .folder],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): addFiles(urls)
                case .failure(let error):
                    let cocoa = error as NSError
                    guard !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.Code.userCancelled.rawValue) else { return }
                    message = UserErrorText.message("파일을 열지 못했습니다", error, recovery: "파일이 있는 위치를 확인한 뒤 다시 골라 주세요.")
                }
            }
            .alert("작업대 알림", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }

    @ViewBuilder
    private var controls: some View {
        switch layout {
        case .rows:
            Button { isPhotosPresented = true } label: { rowLabel("미디어", "photo.on.rectangle") }
                .accessibilityHint("사진 보관함에서 사진·영상·Live Photo를 골라 위치만 포켓에 담습니다.")
            Button(action: openGoogle) { rowLabel("Google 포토", "cloud") }
                .accessibilityHint("Google 포토 선택기에서 고른 항목을 내려받지 않고 포켓에 담습니다.")
            Button { isFilesPresented = true } label: { rowLabel("파일", "folder") }
                .accessibilityHint("파일 앱의 사진·영상 파일이나 폴더를 복사하지 않고 포켓에 담습니다.")
        case .menu:
            Menu {
                Button("미디어", interfaceSystemImage: "photo.on.rectangle") { isPhotosPresented = true }
                Button("Google 포토", interfaceSystemImage: "cloud", action: openGoogle)
                Button("파일·폴더", interfaceSystemImage: "folder") { isFilesPresented = true }
                if let openFinder {
                    Divider()
                    Button("파인더에서 담기 (NAS·폰하드 등)", interfaceSystemImage: "externaldrive.connected.to.line.below", action: openFinder)
                }
            } label: {
                InterfaceToolbarIcon(systemName: "plus")
            }
            .accessibilityLabel("포켓에 담기")
        }
    }

    private func rowLabel(_ title: String, _ systemImage: String) -> some View {
        Label(title, interfaceSystemImage: systemImage).font(.ui(.subheadline))
    }

    // MARK: 담기

    private func addPickerItems(_ items: [PhotosPickerItem]) {
        guard let pocketID else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let canResolve = status == .authorized || status == .limited
        var entries: [WorkbenchEntry] = []
        var unresolved = 0
        for (offset, item) in items.enumerated() {
            guard let identifier = item.itemIdentifier else { unresolved += 1; continue }
            if canResolve, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                entries.append(WorkbenchEntryFactory.entry(asset: asset))
            } else {
                let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                entries.append(WorkbenchEntryFactory.entry(
                    assetIdentifier: identifier, name: "\(isVideo ? "영상" : "사진") \(offset + 1)", isVideo: isVideo))
            }
        }
        var parts: [String] = []
        if !entries.isEmpty { parts.append(WorkbenchStore.shared.add(entries, to: pocketID).summary) }
        if unresolved > 0 {
            parts.append("\(unresolved)개는 사진 접근이 허용되지 않아 위치를 기록할 수 없었습니다. 설정에서 사진 접근을 허용한 뒤 다시 골라 주세요. (몰래 복사하지 않습니다)")
        }
        message = parts.joined(separator: "\n")
    }

    private func addFiles(_ urls: [URL]) {
        guard let pocketID else { return }
        var entries: [WorkbenchEntry] = []
        var failures: [String] = []
        for url in urls {
            switch WorkbenchEntryFactory.entry(fileURL: url) {
            case .success(let entry): entries.append(entry)
            case .failure(let error): failures.append(error.localizedDescription)
            }
        }
        var parts: [String] = []
        if !entries.isEmpty { parts.append(WorkbenchStore.shared.add(entries, to: pocketID).summary) }
        parts.append(contentsOf: failures)
        message = parts.joined(separator: "\n")
    }
}
