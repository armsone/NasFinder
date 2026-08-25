import AppKit
import SwiftUI

@main
struct NasFinderSuperThumbnailMacApp: App {
    @StateObject private var model = SuperThumbnailMacModel()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        WindowGroup {
            SuperThumbnailMacView(model: model)
                .frame(minWidth: 760, minHeight: 610)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
        }
    }
}

@MainActor
final class SuperThumbnailMacModel: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var hasPendingResume = false
    @Published var totalCount = 0
    @Published var completedCount = 0
    @Published var generatedCount = 0
    @Published var cachedCount = 0
    @Published var failedCount = 0
    @Published var currentName = "Finder에서 NAS 또는 미디어 폴더를 선택하세요."
    @Published var status = ""
    @Published var totalSourceBytes: Int64 = 0
    @Published var checkedSourceBytes: Int64 = 0
    @Published var thumbnailBytes: Int64 = 0
    @Published var averageSecondsPerItem = 0.0

    private var task: Task<Void, Never>?
    private let workerID = "mac-\(UUID().uuidString)"
    private let defaults = UserDefaults.standard

    var progress: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    var estimatedRemainingText: String {
        guard isRunning, completedCount > 0, averageSecondsPerItem > 0 else { return "계산 중" }
        let seconds = Int(Double(max(totalCount - completedCount, 0)) * averageSecondsPerItem)
        if seconds >= 3_600 {
            return "약 \(seconds / 3_600)시간 \((seconds % 3_600) / 60)분"
        }
        if seconds >= 60 { return "약 \(seconds / 60)분" }
        return "약 \(seconds)초"
    }

    var checkedDataText: String { byteText(checkedSourceBytes) + " / " + byteText(totalSourceBytes) }
    var thumbnailDataText: String { byteText(thumbnailBytes) }

    init() {
        restoreLastFolder()
    }

    func restoreLastFolder() {
        guard let path = defaults.string(forKey: "lastSelectedFolder") else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        selectedFolder = url
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 다시 선택했습니다."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "수퍼썸네일을 만들 폴더 선택"
        panel.message = "Finder에 연결된 NAS 폴더나 Mac의 미디어 폴더를 선택하세요."
        panel.prompt = "이 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFolder = url
        defaults.set(url.path, forKey: "lastSelectedFolder")
        hasPendingResume = true
        currentName = "‘\(url.lastPathComponent)’ 폴더를 처리할 준비가 됐습니다."
        status = ""
    }

    func start() {
        guard let root = selectedFolder, !isRunning else { return }
        resetProgress()
        isRunning = true
        isPaused = false
        hasPendingResume = true
        status = "사진과 영상을 찾는 중…"
        let worker = workerID

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try VaultProcessor.discoverMedia(in: root)
                }.value
                try Task.checkCancellation()
                let folders = try await Task.detached(priority: .userInitiated) {
                    try VaultProcessor.discoverFolders(in: root)
                }.value
                try Task.checkCancellation()
                totalCount = files.count + folders.count
                totalSourceBytes = files.reduce(0) { $0 + $1.size }
                if files.isEmpty, folders.isEmpty {
                    status = "이 폴더에서 지원되는 사진이나 영상을 찾지 못했습니다."
                    currentName = ""
                    isRunning = false
                    hasPendingResume = false
                    return
                }
                _ = try await Task.detached(priority: .utility) {
                    try VaultProcessor.registerWorker(worker, root: root)
                }.value
                status = "파일 \(files.count)개와 폴더 \(folders.count)개의 수퍼썸네일을 확인합니다."

                let started = Date()
                for file in files {
                    try Task.checkCancellation()
                    while isPaused {
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                    }
                    currentName = file.url.lastPathComponent
                    do {
                        let result = try await VaultProcessor.process(file, workerID: worker)
                        generatedCount += result.generated ? 1 : 0
                        cachedCount += result.alreadyCached ? 1 : 0
                        thumbnailBytes += result.thumbnailBytes
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                    }
                    completedCount += 1
                    checkedSourceBytes += file.size
                    averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)
                }

                // Folders run after files and deepest-first so each parent
                // sheet can reuse child file thumbnails and child folder
                // sheets that already exist in the vault.
                var folderGeneratedCount = 0
                var folderEmptyCount = 0
                var folderFailedCount = 0
                for folder in folders {
                    try Task.checkCancellation()
                    while isPaused {
                        try await Task.sleep(for: .milliseconds(200))
                        try Task.checkCancellation()
                    }
                    currentName = "폴더 · \(folder.url.lastPathComponent)"
                    do {
                        let result = try await Task.detached(priority: .utility) {
                            try VaultProcessor.processFolder(folder, workerID: worker)
                        }.value
                        switch result.state {
                        case .generated:
                            generatedCount += 1
                            folderGeneratedCount += 1
                            thumbnailBytes += result.thumbnailBytes
                        case .emptyIndexed:
                            cachedCount += 1
                            folderEmptyCount += 1
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failedCount += 1
                        folderFailedCount += 1
                    }
                    completedCount += 1
                    averageSecondsPerItem = Date().timeIntervalSince(started) / Double(completedCount)
                }
                status = "완료: 새로 생성 \(generatedCount)개 · 기존/다른 기기 \(cachedCount)개 · 실패 \(failedCount)개"
                    + " · 폴더 생성 \(folderGeneratedCount)개 · 빈 폴더 \(folderEmptyCount)개"
                    + (folderFailedCount > 0 ? " · 폴더 실패 \(folderFailedCount)개" : "")
                currentName = "처리가 완료되었습니다."
                hasPendingResume = false
            } catch is CancellationError {
                status = "작업을 중단했습니다. 다음 실행에서 이어서 확인할 수 있습니다."
            } catch {
                status = "시작하지 못했습니다: \(error.localizedDescription)"
            }
            isRunning = false
            isPaused = false
            task = nil
        }
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        status = isPaused
            ? "일시정지했습니다. ‘계속’을 누르면 현재 위치부터 이어갑니다."
            : "작업을 계속합니다…"
    }

    func cancel() {
        guard isRunning else { return }
        status = "현재 파일을 정리한 뒤 중단합니다…"
        task?.cancel()
    }

    private func resetProgress() {
        totalCount = 0
        completedCount = 0
        generatedCount = 0
        cachedCount = 0
        failedCount = 0
        totalSourceBytes = 0
        checkedSourceBytes = 0
        thumbnailBytes = 0
        averageSecondsPerItem = 0
    }

    private func byteText(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

struct SuperThumbnailMacView: View {
    @ObservedObject var model: SuperThumbnailMacModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    folderCard
                    progressCard
                }
                .padding(28)
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("NasFinder").font(.title2.bold())
                Text("Super Thumbnail for Mac").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.bar)
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("작업 폴더", systemImage: "folder.fill").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedFolder?.path ?? "선택된 폴더 없음")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("Finder에 마운트된 NAS 폴더를 선택할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("폴더 선택", action: model.chooseFolder)
                    .disabled(model.isRunning)
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("생성 진행", systemImage: "photo.stack.fill").font(.headline)
                Spacer()
                Text("\(model.completedCount.formatted()) / \(model.totalCount.formatted())")
                    .font(.title3.monospacedDigit().bold())
            }
            ProgressView(value: model.progress)
            Text(model.currentName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 24) {
                metric("새로 생성", model.generatedCount)
                metric("기존", model.cachedCount)
                metric("실패", model.failedCount)
                Spacer()
                infoMetric("남은 예상시간", model.estimatedRemainingText)
                infoMetric("확인한 대상 용량", model.checkedDataText)
                infoMetric("썸네일 용량", model.thumbnailDataText)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func infoMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(value).font(.callout.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("각 미디어 폴더의 .NasFinder-Vault에 iPhone과 호환되는 JPEG를 저장합니다. 중단하거나 앱을 닫아도 같은 폴더에서 이어갈 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if model.isRunning {
                    Button(model.isPaused ? "계속" : "일시정지", action: model.togglePause)
                    Button("중단", role: .destructive, action: model.cancel)
                }
                Spacer()
                Button(model.hasPendingResume ? "이어하기" : "수퍼썸네일 만들기", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedFolder == nil || model.isRunning)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
    }
}
