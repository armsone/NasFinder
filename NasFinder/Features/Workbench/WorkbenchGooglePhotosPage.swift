import SwiftUI

/// Google 포토 Picker로 고른 항목을 **내려받지 않고** 작업대 포켓의 참조로만 담는다.
/// 기존 OAuth 로그인·권한 범위를 그대로 쓰며(새 범위 요청 없음), 선택 결과는 영속 항목 ID·세션 참조·만료 시각만 기록한다.
/// 기록에 성공하면 포켓 참조가 계속 쓸 수 있도록 Picker 세션을 지우지 않는다(세션은 만료 시각에 스스로 끝난다).
@MainActor
private final class WorkbenchGoogleReferenceModel: ObservableObject {
    enum Target {
        case pocket(UUID)
        /// 선택이 끝난 뒤 사용자가 대상 포켓을 고른다.
        case chooser
    }

    let media = GooglePhotosImportedMedia()
    let target: Target
    let controller: GooglePhotosImportFlowController
    @Published var request: WorkbenchAddRequest?
    @Published var resultText: String?
    private var startEpoch = 0

    init(target: Target) {
        self.target = target
        let media = media
        // 컨트롤러가 만들어지기 전에 self를 캡처하지 않도록 임시 박스를 쓴다.
        let box = ReceiverBox()
        controller = GooglePhotosImportFlowController(
            dependencies: .live(
                referenceSink: { batch in try box.model?.receive(batch) },
                openPicker: { [weak media] url in
                    guard let media, !media.isPickerPresented else { return false }
                    media.pickerURL = url
                    media.isPickerPresented = true
                    return true
                },
                closePicker: { [weak media] in media?.isPickerPresented = false }
            )
        )
        box.model = self
        prepareForNewSelection()
    }

    @MainActor
    private final class ReceiverBox {
        weak var model: WorkbenchGoogleReferenceModel?
    }

    /// 새 선택을 시작하기 직전에 부른다. 그 사이 포켓이 비워졌다면 늦게 도착한 결과가 되살리지 못한다.
    func prepareForNewSelection() {
        resultText = nil
        if case .pocket(let id) = target { startEpoch = WorkbenchStore.shared.epoch(of: id) }
    }

    fileprivate func receive(_ batch: GooglePhotosReferenceBatch) throws {
        let entries = batch.items.map {
            WorkbenchEntryFactory.entry(google: $0, sessionID: batch.sessionID, sessionExpiresAt: batch.expiresAt)
        }
        switch target {
        case .pocket(let id):
            let outcome = WorkbenchStore.shared.add(entries, to: id, expectedEpoch: startEpoch)
            if let failure = outcome.failureMessage { throw GooglePhotosImportFlowError.referenceRejected(failure) }
            let name = WorkbenchStore.shared.pocket(id)?.name ?? "포켓"
            resultText = "'\(name)' 포켓: " + outcome.summary
        case .chooser:
            request = WorkbenchAddRequest(title: "Google 포토 \(entries.count)개", entries: entries)
            resultText = "담을 포켓을 고르면 \(entries.count)개가 참조로 담깁니다."
        }
    }
}

struct WorkbenchGooglePhotosPage: View {
    @StateObject private var model: WorkbenchGoogleReferenceModel

    /// `pocketID`가 있으면 그 포켓에 바로 담고, nil이면 선택이 끝난 뒤 포켓을 고른다.
    init(pocketID: UUID?) {
        let target: WorkbenchGoogleReferenceModel.Target = pocketID.map { WorkbenchGoogleReferenceModel.Target.pocket($0) } ?? .chooser
        _model = StateObject(wrappedValue: WorkbenchGoogleReferenceModel(target: target))
    }

    var body: some View {
        Content(model: model, controller: model.controller, media: model.media)
            .navigationTitle("Google 포토")
            .navigationBarTitleDisplayMode(.inline)
            .workbenchAddSheet($model.request)
    }

    private struct Content: View {
        @ObservedObject var model: WorkbenchGoogleReferenceModel
        @ObservedObject var controller: GooglePhotosImportFlowController
        @ObservedObject var media: GooglePhotosImportedMedia
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @AppStorage("googlePhotosDisclosureAccepted.v1") private var disclosureAccepted = false

        var body: some View {
            ZStack {
                if media.isPickerPresented, let url = media.pickerURL {
                    GooglePhotosPickerPage(url: url)
                } else {
                    phaseContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SkyBreezeBackground())
            .onAppear {
                controller.setScenePollingAllowed(scenePhase == .active)
                if controller.phase == .idle { begin() }
            }
            .onChange(of: scenePhase) { _, phase in controller.setScenePollingAllowed(phase == .active) }
            .onDisappear {
                // 화면을 떠나면 아직 선택 중인 세션만 닫는다. 이미 포켓 참조가 된 세션은 지우지 않는다.
                if controller.isRunning { controller.cancel() }
            }
        }

        private func begin() {
            model.prepareForNewSelection()
            controller.presentDisclosure()
            if disclosureAccepted || ((try? GooglePhotosKeychainCredentialStore().load()) ?? nil) != nil {
                disclosureAccepted = true
                controller.confirmDisclosure()
            }
        }

        @ViewBuilder
        private var phaseContent: some View {
            switch controller.phase {
            case .idle, .disclosure:
                GooglePhotosDisclosureView(
                    onContinue: {
                        disclosureAccepted = true
                        controller.confirmDisclosure()
                    },
                    onCancel: {
                        controller.declineDisclosure()
                        dismiss()
                    }
                )
            case .preparing:
                status("Google 계정을 확인하는 중", detail: "잠시만 기다려 주세요.", showsReopen: false)
            case .waitingForSelection:
                status("Google 포토에서 선택해 주세요",
                       detail: "선택을 마치면 내려받지 않고 위치만 작업대에 담습니다.", showsReopen: true)
            case let .importing(_, total):
                status("작업대에 참조를 담는 중", detail: total > 0 ? "\(total)개를 확인했습니다." : "선택한 항목을 확인하는 중입니다.",
                       showsReopen: false)
            case let .finished(imported, _, _):
                end("담기 완료", detail: model.resultText ?? "\(imported)개를 참조로 담았습니다.",
                    note: "원본은 내려받지 않았습니다. 영상 제작·미디어 전송을 시작할 때 현재 선택 목록에서 가져옵니다.")
            case .cancelled:
                end("취소했습니다", detail: "담은 항목이 없습니다.", note: nil)
            case let .failed(message):
                end("담지 못했습니다", detail: message, note: "포켓의 기존 항목은 그대로입니다.")
            }
        }

        private func status(_ title: String, detail: String, showsReopen: Bool) -> some View {
            VStack(spacing: ui(14)) {
                Text(title).font(.ui(.headline)).multilineTextAlignment(.center)
                Text(detail).font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.secondary)
                    .multilineTextAlignment(.center).monospacedDigit()
                ProgressView()
                if showsReopen {
                    Button("선택 화면 다시 열기") { controller.reopenPicker() }
                        .buttonStyle(PorcelainProminentButtonStyle())
                }
                Button("취소") { controller.cancel() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Google 포토 담기 취소")
            }
            .padding(ui(24))
            .frame(maxWidth: ui(480))
        }

        private func end(_ title: String, detail: String, note: String?) -> some View {
            ScrollView {
                VStack(spacing: ui(14)) {
                    Text(title).font(.ui(.headline))
                    Text(detail).font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.secondary)
                        .multilineTextAlignment(.center)
                    if let note {
                        Text(note).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("더 선택하기") { begin() }
                        .buttonStyle(PorcelainProminentButtonStyle())
                    Button("돌아가기") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .padding(ui(24))
                .frame(maxWidth: ui(480))
            }
        }
    }
}
