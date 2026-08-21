import SwiftUI

/// 설정 화면의 `Google 포토 연결 해제` 상태 모델. 원격 revoke 성공 여부와 무관하게
/// 이 기기의 Photos 자격 증명은 항상 삭제한다. Drive 자격 증명에는 손대지 않는다.
@MainActor
final class GooglePhotosConnectionSettingsModel: ObservableObject {
    struct Dependencies: Sendable {
        var loadCredential: @Sendable () throws -> GooglePhotosCredential?
        var removeCredential: @Sendable () throws -> Void
        var revoke: @Sendable (GooglePhotosCredential) async throws -> Void

        static func live() -> Dependencies {
            let credentialStore = GooglePhotosKeychainCredentialStore()
            return Dependencies(
                loadCredential: { try credentialStore.load() },
                removeCredential: { try credentialStore.remove() },
                revoke: { credential in
                    let configuration = try GooglePhotosOAuthConfiguration.loadFromMainBundle()
                    try await GooglePhotosTokenClient(configuration: configuration).revoke(credential)
                }
            )
        }
    }

    @Published private(set) var isConnected = false
    @Published private(set) var isDisconnecting = false
    @Published var resultMessage: String?

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        refreshConnectionState()
    }

    func refreshConnectionState() {
        isConnected = ((try? dependencies.loadCredential()) ?? nil) != nil
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        defer { isDisconnecting = false }

        let credential = (try? dependencies.loadCredential()) ?? nil
        var revokeSucceeded = true
        if let credential {
            do {
                try await dependencies.revoke(credential)
            } catch {
                revokeSucceeded = false
            }
        }

        do {
            try dependencies.removeCredential()
            isConnected = false
            resultMessage = revokeSucceeded
                ? "Google 포토 연결을 해제했습니다. 받은 파일에 저장된 항목은 그대로 유지됩니다."
                : "이 기기의 Google 포토 연결 정보를 삭제했습니다. Google 계정 쪽 권한 해제 요청은 실패했으므로 "
                    + "필요하면 Google 계정 설정에서 직접 해제해 주세요. 받은 파일에 저장된 항목은 그대로 유지됩니다."
        } catch {
            refreshConnectionState()
            resultMessage = "Google 포토 연결 정보를 삭제하지 못했습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}

/// 설정 화면에 표시되는 Google 포토 섹션. Photos 자격 증명이 있을 때만 나타난다.
struct GooglePhotosSettingsSection: View {
    @StateObject private var model: GooglePhotosConnectionSettingsModel
    @State private var isConfirmingDisconnect = false

    init(
        model: @autoclosure @escaping () -> GooglePhotosConnectionSettingsModel =
            GooglePhotosConnectionSettingsModel(dependencies: .live())
    ) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        // 연결 해제 직후에도 결과 안내가 표시될 수 있도록 메시지가 남아 있는 동안은 유지한다.
        if model.isConnected || model.isDisconnecting || model.resultMessage != nil {
            Section {
                Button(role: .destructive) {
                    isConfirmingDisconnect = true
                } label: {
                    HStack {
                        Text("Google 포토 연결 해제")
                        Spacer(minLength: 0)
                        if model.isDisconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(model.isDisconnecting)
                .accessibilityLabel("Google 포토 연결 해제")
                .confirmationDialog(
                    "Google 포토 연결을 해제할까요?",
                    isPresented: $isConfirmingDisconnect,
                    titleVisibility: .visible
                ) {
                    Button("연결 해제", role: .destructive) {
                        Task { await model.disconnect() }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("이 기기에 저장된 Google 포토 인증 정보만 삭제됩니다. 이미 받은 파일에 저장된 항목과 Google Drive 연결은 그대로 유지됩니다.")
                }
                .alert("Google 포토", isPresented: resultMessageBinding) {
                    Button("확인", role: .cancel) {
                        model.resultMessage = nil
                    }
                } message: {
                    Text(model.resultMessage ?? "")
                }

                SettingsPanelDescription(
                    "연결을 해제해도 받은 파일에 저장된 사진·동영상은 삭제되지 않습니다."
                )
            } header: {
                SettingsSectionHeader(title: "Google 포토", systemImage: "photo.on.rectangle")
            }
            .onAppear {
                model.refreshConnectionState()
            }
        }
    }

    private var resultMessageBinding: Binding<Bool> {
        Binding(
            get: { model.resultMessage != nil },
            set: { if !$0 { model.resultMessage = nil } }
        )
    }
}
