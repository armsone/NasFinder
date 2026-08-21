import SwiftUI

/// Google 포토 접근을 시작하기 전에 NasFinder의 데이터 사용 방식을 알리는 사전 고지 화면.
struct GooglePhotosDisclosureView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    private static let privacyPolicyURL = URL(string: "https://nasfinder.com/privacy")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(alignment: .leading, spacing: 16) {
                        disclosureRow(
                            systemImage: "hand.tap",
                            title: "선택한 항목에만 접근",
                            detail: "NasFinder는 Google 포토에서 회원님이 직접 선택한 사진과 동영상에만 접근합니다. 전체 보관함은 볼 수 없습니다."
                        )
                        disclosureRow(
                            systemImage: "tray.and.arrow.down",
                            title: "이 기기의 받은 파일에 저장",
                            detail: "선택한 파일은 이 기기의 ‘받은 파일’에만 저장됩니다."
                        )
                        disclosureRow(
                            systemImage: "externaldrive",
                            title: "NAS 전송은 별도의 직접 동작으로만",
                            detail: "저장된 파일은 회원님이 ‘NAS로 보내기’를 직접 실행할 때만 NAS 또는 연결된 저장소로 전송됩니다."
                        )
                        disclosureRow(
                            systemImage: "eye.slash",
                            title: "광고·추적 없음",
                            detail: "사진을 광고, 추적, 얼굴 분류, AI 학습에 사용하지 않습니다."
                        )
                        disclosureRow(
                            systemImage: "gearshape",
                            title: "언제든 삭제·연결 해제 가능",
                            detail: "받은 파일에서 저장된 파일을 삭제할 수 있고, 설정에서 Google 포토 연결을 해제할 수 있습니다."
                        )
                    }

                    Link("개인정보 처리방침 보기", destination: Self.privacyPolicyURL)
                        .font(.footnote)
                        .accessibilityLabel("개인정보 처리방침 보기")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(SkyBreezeTheme.accent)
                .accessibilityHidden(true)

            Text("Google 포토에서 가져오기")
                .font(.title3.weight(.semibold))

            Text("가져오기를 시작하기 전에 NasFinder가 사진을 다루는 방식을 확인해 주세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(SkyBreezeTheme.accent)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button("계속") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Google 계정 로그인 화면이 열립니다.")

            Button("취소") {
                onCancel()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
