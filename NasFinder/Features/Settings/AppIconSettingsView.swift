import SwiftUI
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable {
    case blueNAS
    case purpleNAS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blueNAS: "블루 NAS"
        case .purpleNAS: "퍼플 NAS"
        }
    }

    var previewAssetName: String {
        switch self {
        case .blueNAS: "AppIconDefaultPreview"
        case .purpleNAS: "AppIconAlternatePreview"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .blueNAS: nil
        case .purpleNAS: "AppIconAlternate"
        }
    }

    static func current(alternateIconName: String?) -> AppIconChoice {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .blueNAS
    }
}

struct AppIconSettingsView: View {
    @State private var selectedIcon = AppIconChoice.blueNAS
    @State private var isChangingIcon = false
    @State private var pendingIcon: AppIconChoice?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        select(icon)
                    } label: {
                        HStack(spacing: 16) {
                            Image(icon.previewAssetName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                            Text(icon.title)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            if pendingIcon == icon {
                                ProgressView()
                            } else if selectedIcon == icon {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isChangingIcon || selectedIcon == icon)
                    .accessibilityLabel("\(icon.title) 아이콘")
                    .accessibilityValue(selectedIcon == icon ? "선택됨" : "선택되지 않음")
                    .accessibilityHint(selectedIcon == icon ? "현재 앱 아이콘입니다." : "이 아이콘으로 변경합니다.")
                }
            } header: {
                Text("아이콘 선택")
            } footer: {
                Text("선택한 아이콘은 홈 화면과 앱 보관함에 적용됩니다.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("앱 아이콘")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            selectedIcon = AppIconChoice.current(
                alternateIconName: UIApplication.shared.alternateIconName
            )
        }
        .alert("아이콘을 변경할 수 없습니다", isPresented: errorBinding) {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "잠시 후 다시 시도해 주세요.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func select(_ icon: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "이 기기에서는 대체 앱 아이콘을 지원하지 않습니다."
            return
        }

        isChangingIcon = true
        pendingIcon = icon
        UIApplication.shared.setAlternateIconName(icon.alternateIconName) { error in
            Task { @MainActor in
                isChangingIcon = false
                pendingIcon = nil
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    selectedIcon = icon
                }
            }
        }
    }
}
