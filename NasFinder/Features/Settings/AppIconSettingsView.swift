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
    var body: some View {
        List {
            AppIconPickerSection()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("앱 아이콘")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppIconPickerSection: View {
    var compact = false

    @State private var selectedIcon = AppIconChoice.blueNAS
    @State private var isChangingIcon = false
    @State private var pendingIcon: AppIconChoice?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(AppIconChoice.allCases) { icon in
                        VStack(spacing: 10) {
                            Image(icon.previewAssetName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: iconSide, height: iconSide)
                                .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                            Button {
                                select(icon)
                            } label: {
                                Group {
                                    if pendingIcon == icon {
                                        ProgressView()
                                    } else {
                                        Text(selectedIcon == icon ? "선택됨" : "선택")
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isChangingIcon || selectedIcon == icon)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(icon.title) 아이콘")
                        .accessibilityValue(selectedIcon == icon ? "선택됨" : "선택되지 않음")
                    }
                }
                .padding(.vertical, 6)
            } header: {
                SettingsSectionHeader(title: "앱 아이콘", systemImage: "app.badge")
            } footer: {
                Text("선택한 아이콘은 홈 화면과 앱 보관함에 적용됩니다.")
            }
        }
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

    private var iconSide: CGFloat { compact ? 72 : 96 }
    private var iconCornerRadius: CGFloat { compact ? 16 : 21 }

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

struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
