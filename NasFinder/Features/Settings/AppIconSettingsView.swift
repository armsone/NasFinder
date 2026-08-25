import SwiftUI
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable {
    case blueNAS
    case purpleNAS
    case vibeCoder
    case cyberVault
    case networkNAS
    case enamelNAS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blueNAS: "블루 NAS"
        case .purpleNAS: "퍼플 NAS"
        case .vibeCoder: "Vibe Coder"
        case .cyberVault: "사이버 볼트"
        case .networkNAS: "네트워크 NAS"
        case .enamelNAS: "BK Style"
        }
    }

    var previewAssetName: String {
        switch self {
        case .blueNAS: "AppIconDefaultPreview"
        case .purpleNAS: "AppIconAlternatePreview"
        case .vibeCoder: "AppIconVibeCoderPreview"
        case .cyberVault: "AppIconCyberVaultPreview"
        case .networkNAS: "AppIconNetworkNASPreview"
        case .enamelNAS: "AppIconEnamelPreview"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .blueNAS: nil
        case .purpleNAS: "AppIconAlternate"
        case .vibeCoder: "AppIconVibeCoder"
        case .cyberVault: "AppIconCyberVault"
        case .networkNAS: "AppIconNetworkNAS"
        case .enamelNAS: "AppIconEnamel"
        }
    }

    static func current(alternateIconName: String?) -> AppIconChoice {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .blueNAS
    }

    @MainActor
    static func apply(
        _ icon: AppIconChoice,
        completion: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        // Designed-for-iPad on Mac: the alternate-icon API is unsupported and
        // the Mac keeps one fixed icon, so finish silently without touching
        // UIApplication and without reporting an error.
        guard !AppIconAvailabilityPolicy.isIOSAppOnMac else {
            completion(nil)
            return
        }
        guard UIApplication.shared.supportsAlternateIcons else {
            completion(AppIconChangeError.unsupported.localizedDescription)
            return
        }
        guard current(alternateIconName: UIApplication.shared.alternateIconName) != icon else {
            completion(nil)
            return
        }
        UIApplication.shared.setAlternateIconName(icon.alternateIconName) { error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(message) }
        }
    }
}

private enum AppIconChangeError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "이 기기에서는 대체 앱 아이콘을 지원하지 않습니다."
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

    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

    @State private var selectedIcon = AppIconChoice.blueNAS
    @State private var isChangingIcon = false
    @State private var pendingIcon: AppIconChoice?
    @State private var errorMessage: String?

    private var isEnamelTheme: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    private var showsIconPicker: Bool {
        AppIconAvailabilityPolicy.showsIconPicker(
            isIOSAppOnMac: AppIconAvailabilityPolicy.isIOSAppOnMac
        )
    }

    var body: some View {
        if showsIconPicker {
            pickerSection
        }
    }

    private var pickerSection: some View {
        Group {
            Section {
                VStack(spacing: 10) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8, alignment: .top),
                            GridItem(.flexible(), spacing: 8, alignment: .top),
                            GridItem(.flexible(), spacing: 8, alignment: .top),
                        ],
                        alignment: .center,
                        spacing: 8
                    ) {
                        ForEach(AppIconChoice.allCases) { icon in
                            Button {
                                select(icon)
                            } label: {
                                VStack(spacing: 8) {
                                    Image(icon.previewAssetName)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: iconSide, height: iconSide)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: iconCornerRadius,
                                                style: .continuous
                                            )
                                        )
                                        .overlay {
                                            RoundedRectangle(
                                                cornerRadius: iconCornerRadius,
                                                style: .continuous
                                            )
                                            .stroke(.primary.opacity(0.08), lineWidth: 1)
                                        }
                                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                                    HStack(spacing: 4) {
                                        Text(icon.title)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                        if pendingIcon == icon {
                                            ProgressView().controlSize(.mini)
                                        } else if selectedIcon == icon {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .font(.caption.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 104)
                                .background {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            selectedIcon == icon
                                                ? Color.accentColor.opacity(0.75)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: selectedIcon == icon ? 1.5 : 1
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isChangingIcon || selectedIcon == icon || isEnamelTheme)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .accessibilityLabel("\(icon.title) 아이콘")
                            .accessibilityValue(selectedIcon == icon ? "선택됨" : "선택되지 않음")
                        }
                    }

                    Divider()
                    SettingsPanelDescription(
                        isEnamelTheme
                            ? "BK Style에서는 같은 이름의 앱 아이콘을 사용합니다."
                            : "선택한 아이콘은 홈 화면과 앱 보관함에 적용됩니다."
                    )
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            } header: {
                SettingsSectionHeader(title: "앱 아이콘", systemImage: "app.badge")
            }
        }
        .task {
            selectedIcon = isEnamelTheme
                ? .enamelNAS
                : AppIconChoice.current(alternateIconName: UIApplication.shared.alternateIconName)
        }
        .alert("아이콘을 변경할 수 없습니다", isPresented: errorBinding) {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "잠시 후 다시 시도해 주세요.")
        }
    }

    private var iconSide: CGFloat { compact ? 54 : 60 }
    private var iconCornerRadius: CGFloat { compact ? 12 : 13 }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func select(_ icon: AppIconChoice) {
        guard AppIconAvailabilityPolicy.canChangeIcon(
            isIOSAppOnMac: AppIconAvailabilityPolicy.isIOSAppOnMac,
            supportsAlternateIcons: UIApplication.shared.supportsAlternateIcons
        ) else {
            // The picker is not shown on the Mac; on iPhone/iPad this only
            // fires when the system itself reports no alternate-icon support.
            if !AppIconAvailabilityPolicy.isIOSAppOnMac {
                errorMessage = "이 기기에서는 대체 앱 아이콘을 지원하지 않습니다."
            }
            return
        }

        isChangingIcon = true
        pendingIcon = icon
        AppIconChoice.apply(icon) { message in
            isChangingIcon = false
            pendingIcon = nil
            if let message {
                errorMessage = message
            } else {
                selectedIcon = icon
            }
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    var body: some View {
        HStack(spacing: selectedTheme == .skeuomorphism ? 7 : 3) {
            ThemedSymbol(systemName: systemImage)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPanelDescription: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
