import SwiftUI

/// 받은 파일 화면에서 시트로 표시되는 Google 포토 가져오기 흐름 컨테이너.
/// 사전 고지 → 인증/세션 준비 → 선택 대기 → 가져오기 진행 → 결과 순으로 단계를 보여준다.
struct GooglePhotosImportFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: GooglePhotosImportFlowController

    init(inboxStore: SharedInboxStore) {
        _controller = StateObject(
            wrappedValue: GooglePhotosImportFlowController(
                dependencies: .live(inboxStore: inboxStore)
            )
        )
    }

    /// 테스트·프리뷰용 주입 생성자.
    init(controller: @autoclosure @escaping () -> GooglePhotosImportFlowController) {
        _controller = StateObject(wrappedValue: controller())
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SkyBreezeBackground())
                .navigationTitle("Google 포토")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            controller.setScenePollingAllowed(scenePhase == .active)
            controller.presentDisclosure()
        }
        .onDisappear {
            controller.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setScenePollingAllowed(phase == .active)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .disclosure:
            GooglePhotosDisclosureView(
                onContinue: { controller.confirmDisclosure() },
                onCancel: {
                    controller.declineDisclosure()
                    dismiss()
                }
            )

        case .preparing:
            statusView(
                systemImage: "person.badge.key",
                title: "Google 계정을 확인하는 중",
                detail: "잠시만 기다려 주세요."
            )

        case .waitingForSelection:
            statusView(
                systemImage: "photo.on.rectangle.angled",
                title: "Google 포토에서 선택해 주세요",
                detail: "가져올 항목(최대 \(GooglePhotosImportFlowController.maxSelectionCount)개)을 선택한 뒤 NasFinder로 돌아오면 자동으로 가져옵니다."
            )

        case let .importing(completed, total):
            statusView(
                systemImage: "arrow.down.circle",
                title: "가져오는 중",
                detail: total > 0
                    ? "\(completed)/\(total)개 완료"
                    : "선택한 항목을 확인하는 중입니다."
            )

        case let .finished(imported, skipped, failed):
            resultView(imported: imported, skipped: skipped, failed: failed)

        case let .cancelled(imported):
            endView(
                systemImage: "xmark.circle",
                iconStyle: Color.secondary,
                title: "가져오기를 취소했습니다",
                detail: imported > 0
                    ? "이미 가져온 \(imported)개 파일은 받은 파일에 그대로 유지됩니다."
                    : "가져온 파일이 없습니다."
            )

        case let .failed(message):
            failureView(message: message)
        }
    }

    private func statusView(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(SkyBreezeTheme.accent)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            ProgressView()
                .padding(.top, 2)

            Button("취소") {
                controller.cancel()
            }
            .buttonStyle(.bordered)
            .padding(.top, 10)
            .accessibilityLabel("Google 포토 가져오기 취소")
        }
        .padding(24)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .contain)
    }

    private func resultView(imported: Int, skipped: Int, failed: Int) -> some View {
        endView(
            systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle",
            iconStyle: failed == 0 ? Color.green : Color.orange,
            title: "가져오기 완료",
            detail: "가져옴 \(imported)개 · 건너뜀 \(skipped)개 · 실패 \(failed)개"
        )
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("가져오지 못했습니다")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("다시 시도") {
                controller.presentDisclosure()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 10)

            Button("닫기") {
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: 480)
    }

    private func endView(systemImage: String, iconStyle: Color, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(iconStyle)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()

            Button("완료") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 10)
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}
