import PhotosUI
import SwiftUI

/// 시스템 사진 선택기에서 사진·영상을 함께 골라 QR로 연결한 기기로 보낸다.
@MainActor
struct PhotoTransferView: View {
    private struct ClassifiedItem: Identifiable {
        let id = UUID()
        let index: Int
        var kind: PhotoTransferMediaKind
        var thumbnail: UIImage?
        var duration: TimeInterval?
        var previewLoaded = false
    }

    private enum PairingRole: String, Identifiable {
        case receiver
        case sender

        var id: String { rawValue }
    }

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var classifiedItems: [ClassifiedItem] = []
    @State private var pairingRole: PairingRole?
    @State private var isSendingFlowSelected = false
    @StateObject private var receiverSession = PhotoTransferReceiverSession()
    @StateObject private var senderSession = PhotoTransferSenderSession()
    @State private var previewGeneration = UUID()
    private let previewLoader = PhotoTransferSelectionPreviewLoader()

    private var isRunningOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    private var summary: PhotoTransferSelectionSummary {
        PhotoTransferSelectionSummary(kinds: classifiedItems.map(\.kind))
    }

    var body: some View {
        List {
            roleSection
            if isSendingFlowSelected {
                selectionSection
                if !classifiedItems.isEmpty {
                    itemListSection
                }
                pairingSection
            }
        }
        .frame(maxWidth: isRunningOnMac ? 680 : nil)
        .environment(\.defaultMinListRowHeight, isRunningOnMac ? 36 : 44)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("Live Photos & Motion Photos")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedItems) { _, items in
            classify(items)
        }
        .sheet(item: $pairingRole) { role in
            switch role {
            case .receiver:
                PhotoTransferReceiverSheet(session: receiverSession)
            case .sender:
                PhotoTransferSenderSheet(
                    session: senderSession,
                    selectedItems: selectedItems,
                    mediaKinds: classifiedItems.map(\.kind)
                )
            }
        }
        .onDisappear {
            receiverSession.stop()
            senderSession.cancel()
        }
    }

    private var roleSection: some View {
        Section {
            Button {
                isSendingFlowSelected = true
            } label: {
                Label("보내기", systemImage: "paperplane")
                    .font(.subheadline)
            }
            Button {
                pairingRole = .receiver
            } label: {
                Label("받기", systemImage: "qrcode")
                    .font(.subheadline)
            }
            .accessibilityHint("수신을 시작하고 QR 코드를 표시합니다.")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                pairingRole = .sender
            } label: {
                Label("QR 스캔해서 연결", systemImage: "qrcode.viewfinder")
                    .font(.subheadline)
            }
            .accessibilityHint("받는 기기에 표시된 QR 코드를 스캔해 연결합니다.")
            .disabled(selectedItems.isEmpty)
        } header: {
            sectionHeader("3 다른 폰 연결", systemImage: "wifi")
        } footer: {
            Text("두 기기가 같은 Wi-Fi에 있어야 합니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var selectionSection: some View {
        let hasSelection = !classifiedItems.isEmpty

        return Section {
            PhotosPicker(
                selection: $selectedItems,
                matching: .any(of: [.images, .livePhotos, .videos]),
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
                Label(
                    hasSelection ? "다시 선택" : "사진 보관함에서 선택",
                    systemImage: "photo.badge.plus"
                )
                .font(.subheadline)
            }
            .accessibilityHint("사진, 영상, Live Photo를 한 번에 여러 개 선택할 수 있습니다.")
        } header: {
            sectionHeader("1 미디어 선택", systemImage: "checkmark.circle")
        } footer: {
            Text(
                hasSelection
                    ? "선택한 항목은 QR 연결 후 한 번에 보낼 수 있습니다."
                    : "사진, 영상, Live Photo를 한 번에 여러 개 선택할 수 있습니다."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var itemListSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 10)], spacing: 10) {
                ForEach(classifiedItems) { item in
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.quaternary)
                                if item.previewLoaded {
                                    Image(systemName: item.kind.systemImage)
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            }

                            if item.kind == .video {
                                Image(systemName: "play.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        .frame(height: 112)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 4) {
                                Text(item.kind.title)
                                if let duration = item.duration, item.kind == .video {
                                    Text(Self.durationText(duration))
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(6)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Self.selectionAccessibilityLabel(
                                index: item.index,
                                kindTitle: item.kind.title,
                                duration: item.kind == .video ? item.duration : nil
                            )
                        )

                        Button {
                            removeSelection(id: item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .accessibilityLabel("항목 \(item.index) 삭제")
                        .accessibilityHint("선택 목록에서 이 항목을 제거합니다.")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            sectionHeader("2 선택 검토 · \(summary.totalCount)개", systemImage: "photo.on.rectangle")
        }
    }

    private func classify(_ items: [PhotosPickerItem]) {
        let generation = UUID()
        previewGeneration = generation
        classifiedItems = items.enumerated().map { offset, item in
            ClassifiedItem(
                index: offset + 1,
                kind: PhotoTransferMediaClassifier.classify(
                    supportedContentTypes: item.supportedContentTypes
                ),
                thumbnail: nil,
                duration: nil
            )
        }
        let requests = Array(zip(classifiedItems.map(\.id), items))
        for (id, pickerItem) in requests {
            Task { @MainActor in
                guard previewGeneration == generation else { return }
                let scale = UIScreen.main.scale
                let preview = await previewLoader.load(
                    for: pickerItem,
                    targetSize: CGSize(width: 180 * scale, height: 180 * scale)
                )
                guard previewGeneration == generation,
                      let index = classifiedItems.firstIndex(where: { $0.id == id })
                else { return }
                classifiedItems[index].thumbnail = preview.image
                classifiedItems[index].duration = preview.duration
                classifiedItems[index].kind = PhotoTransferMediaClassifier.refinedKind(
                    classifiedItems[index].kind,
                    assetIsLivePhoto: preview.isLivePhotoAsset
                )
                classifiedItems[index].previewLoaded = true
            }
        }
    }

    private func removeSelection(id: UUID) {
        guard let index = classifiedItems.firstIndex(where: { $0.id == id }),
              selectedItems.indices.contains(index)
        else { return }
        selectedItems.remove(at: index)
    }

    nonisolated private static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    nonisolated static func selectionAccessibilityLabel(
        index: Int,
        kindTitle: String,
        duration: TimeInterval?
    ) -> String {
        guard let duration else { return "항목 \(index), \(kindTitle)" }
        return "항목 \(index), \(kindTitle), 재생 시간 \(durationText(duration))"
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
