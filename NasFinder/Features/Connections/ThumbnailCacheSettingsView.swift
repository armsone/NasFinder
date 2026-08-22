import SwiftUI

struct ThumbnailCacheSettingsLink: View {
    @State private var statistics = RemoteThumbnailCacheStatistics.empty

    var body: some View {
        NavigationLink {
            ThumbnailCacheSettingsView { updatedStatistics in
                statistics = updatedStatistics
            }
        } label: {
            LabeledContent {
                Text(Self.formattedByteCount(statistics.totalBytes))
                    .foregroundStyle(.secondary)
            } label: {
                HStack(spacing: 7) {
                    ThemedSymbol(systemName: "photo.stack", size: 32, symbolSize: 17)
                    Text("썸네일 캐시")
                }
            }
        }
        .task {
            statistics = await RemoteThumbnailDiskCache.shared.statistics()
        }
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(byteCount, 0),
            countStyle: .file
        )
    }
}

private struct ThumbnailCacheSettingsView: View {
    @State private var statistics = RemoteThumbnailCacheStatistics.empty
    @State private var isConfirmingRemoval = false

    let onStatisticsChange: @MainActor (RemoteThumbnailCacheStatistics) -> Void

    var body: some View {
        List {
            Section("현재 캐시") {
                LabeledContent("사용량") {
                    Text(formattedByteCount(statistics.totalBytes))
                }
                LabeledContent("파일") {
                    Text("\(statistics.fileCount)개")
                }
            }

            Section {
                Picker(
                    "자동 정리 기준",
                    selection: automaticLimitBinding
                ) {
                    ForEach(RemoteThumbnailDiskCache.automaticLimitOptions, id: \.self) {
                        Text(formattedAutomaticLimit($0)).tag($0)
                    }
                }
            } header: {
                Text("자동 정리")
            } footer: {
                Text(
                    "용량을 넘거나 30일이 지나면 오래된 캐시부터 정리합니다.\n"
                        + "최대 5,000개를 보관합니다."
                )
            }

            Section {
                Button("지금 캐시 비우기", systemImage: "trash", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(statistics.fileCount == 0)
            } footer: {
                Text("원본 영상과 받은 파일은 삭제하지 않습니다.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("썸네일 캐시")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStatistics()
        }
        .alert("썸네일 캐시를 비울까요?", isPresented: $isConfirmingRemoval) {
            Button("캐시 비우기", role: .destructive) {
                Task {
                    await RemoteThumbnailDiskCache.shared.removeAll()
                    await refreshStatistics()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 \(formattedByteCount(statistics.totalBytes)) · 원본 파일은 삭제되지 않습니다.")
        }
    }

    private var automaticLimitBinding: Binding<Int64> {
        Binding(
            get: { statistics.automaticLimitBytes },
            set: { newValue in
                Task {
                    await RemoteThumbnailDiskCache.shared.setAutomaticLimitBytes(newValue)
                    await refreshStatistics()
                }
            }
        )
    }

    @MainActor
    private func refreshStatistics() async {
        let updatedStatistics = await RemoteThumbnailDiskCache.shared.statistics()
        statistics = updatedStatistics
        onStatisticsChange(updatedStatistics)
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(byteCount, 0),
            countStyle: .file
        )
    }

    private func formattedAutomaticLimit(_ byteCount: Int64) -> String {
        "\(max(byteCount, 0) / (1_024 * 1_024))MB"
    }
}
