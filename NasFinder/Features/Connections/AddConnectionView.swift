import SwiftUI

struct AddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ConnectionStore
    @StateObject private var oauthAuthorizer = CloudOAuthAuthorizer()
    @AppStorage("connections.lastKind.v1") private var lastKindRawValue = ConnectionKind.synology.rawValue

    @State private var kind: ConnectionKind = .synology
    @State private var name = ""
    @State private var host = ""
    @State private var port = ConnectionKind.synology.defaultPort
    @State private var username = ""
    @State private var password = ""
    @State private var rootPath = ConnectionKind.synology.defaultRootPath
    @State private var usesTLS = true
    @State private var webDAVPreset: WebDAVConnectionPreset = .generic
    @State private var trustedHostKey: String?
    @State private var pendingHostKey: SFTPHostKeyTrustRequired?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testMessage: String?
    @State private var errorMessage: String?
    @State private var testedConfiguration: ConnectionTestConfiguration?
    @State private var didLoadStoredCredential = false
    @State private var didApplyRememberedKind = false
    @State private var shouldSaveAfterHostKeyTrust = false

    private let editingConnection: RemoteConnection?

    init(connection: RemoteConnection? = nil) {
        editingConnection = connection
        if let connection {
            _kind = State(initialValue: connection.kind)
            _name = State(initialValue: connection.name)
            _host = State(initialValue: connection.host)
            _port = State(initialValue: connection.port)
            _username = State(initialValue: connection.username)
            _rootPath = State(initialValue: connection.rootPath)
            _usesTLS = State(initialValue: connection.usesTLS)
            _trustedHostKey = State(initialValue: connection.trustedHostKey)
        }
    }

    var body: some View {
        NavigationStack {
            connectionForm
            .tint(selectedServiceColor)
            .scrollContentBackground(.hidden)
            .background(SkyBreezeBackground())
            .navigationTitle(editingConnection == nil ? "연결 추가" : "연결 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !kind.isOAuthCloud {
                        Button {
                            Task { await connectAndSave() }
                        } label: {
                            if isTesting || isSaving {
                                ProgressView()
                            } else {
                                Text(editingConnection == nil ? "연결" : "저장")
                            }
                        }
                        .disabled(!isValid || isSaving || isTesting)
                    }
                }
            }
            .onChange(of: kind) { _, newKind in
                if editingConnection == nil {
                    lastKindRawValue = newKind.rawValue
                }
                port = newKind.defaultPort
                rootPath = newKind.defaultRootPath
                usesTLS = true
                webDAVPreset = .generic
                trustedHostKey = nil
                testMessage = nil
                synchronizeAddressComponents()
            }
            .onChange(of: host) { _, _ in
                synchronizeAddressComponents()
                serverIdentityChanged()
            }
            .onChange(of: port) { _, _ in serverIdentityChanged() }
            .onChange(of: username) { oldValue, newValue in
                synchronizeWebDAVRootPath(from: oldValue, to: newValue)
                resetTestStatus()
            }
            .onChange(of: password) { _, _ in resetTestStatus() }
            .onChange(of: rootPath) { _, _ in resetTestStatus() }
            .onChange(of: usesTLS) { oldValue, newValue in
                synchronizeStandardSynologyPort(fromTLS: oldValue, toTLS: newValue)
                resetTestStatus()
            }
            .onChange(of: webDAVPreset) { _, newValue in
                applyWebDAVPreset(newValue)
            }
            .task {
                applyRememberedKindIfNeeded()
                loadStoredCredentialIfNeeded()
            }
            .alert("연결 오류", isPresented: errorBinding) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(currentErrorMessage)
            }
            .alert("SSH 서버 키 확인", isPresented: hostKeyAlertBinding, presenting: pendingHostKey) { pending in
                Button("취소", role: .cancel) {
                    shouldSaveAfterHostKeyTrust = false
                    pendingHostKey = nil
                }
                Button(pending.isChangedKey ? "새 키 신뢰" : "이 키 신뢰") {
                    let saveAfterTrust = shouldSaveAfterHostKeyTrust
                    trustedHostKey = pending.hostKey
                    shouldSaveAfterHostKeyTrust = false
                    pendingHostKey = nil
                    Task {
                        await testConnection(saveOnSuccess: saveAfterTrust)
                    }
                }
            } message: { pending in
                Text("\(pending.errorDescription ?? "서버 키를 확인해 주세요.")\n\n\(pending.fingerprint)")
            }
        }
    }

    private var connectionForm: some View {
        Form {
            connectionKindSection
            if kind.isOAuthCloud {
                cloudAccountSection
            } else {
                serverSection
                passwordSection
                connectionTestSection
            }
        }
    }

    private var selectedServiceColor: Color {
        ThemeServicePalette.color(
            forServiceIdentifier: kind.rawValue,
            theme: .current
        )
    }

    private var connectionKindSection: some View {
        Section("연결 방식") {
            LazyVGrid(columns: connectionKindColumns, spacing: 8) {
                ForEach(ConnectionKind.allCases) { candidate in
                    connectionKindButton(candidate)
                }
            }
            .padding(.vertical, 2)

            Text(kind.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if kind == .webDAV {
                Picker("클라우드 서비스", selection: $webDAVPreset) {
                    ForEach(WebDAVConnectionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }
        }
    }

    private var connectionKindColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    }

    private var cloudAccountSection: some View {
        Section {
            Button {
                Task { await connectCloud() }
            } label: {
                HStack {
                    Label("\(kind.title)로 계속", systemImage: kind.systemImage)
                    Spacer()
                    if isSaving { ProgressView() }
                }
            }
            .disabled(isSaving)
        } header: {
            Text("계정")
        } footer: {
            Text("로그인 토큰은 이 iPhone의 키체인에만 저장됩니다. NasFinder는 계정 비밀번호를 보거나 저장하지 않습니다.")
        }
    }

    private var serverSection: some View {
        Section("서버") {
            TextField("표시 이름 (예: 우리집 NAS)", text: $name)
            TextField("호스트 (예: nas.example.com)", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if let addressValidationMessage {
                Label(addressValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            LabeledContent("포트") {
                TextField(String(kind.defaultPort), value: $port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .disabled(parsedServerAddress?.explicitPort != nil)
            }

            if parsedServerAddress?.explicitPort != nil {
                Text("서버 주소에 포트가 포함되어 있어 해당 포트를 사용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if kind == .synology {
                Text("DSM 기본 포트: HTTPS 5001 · HTTP 5000. SFTP 포트 22와는 다릅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if kind == .synology,
               (parsedServerAddress?.explicitPort ?? port) == ConnectionKind.sftp.defaultPort {
                Label(
                    "22번은 SFTP 포트입니다. Synology 연결에는 DSM HTTPS 5001, HTTP 5000 또는 DSM에서 지정한 웹 포트를 입력하세요.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if kind == .synology || kind == .webDAV {
                Toggle("HTTPS 사용", isOn: $usesTLS)
                    .disabled(parsedServerAddress?.inferredTLS != nil)
                if parsedServerAddress?.inferredTLS != nil {
                    Text("주소의 http:// 또는 https:// 표시에 맞춰 보안 연결 설정을 사용합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("시작 위치") {
                TextField(rootPathPlaceholder, text: $rootPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var passwordSection: some View {
        Section("로그인") {
            TextField("사용자 이름", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("비밀번호", text: $password)
                .textContentType(.password)
        }
    }

    private var connectionTestSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("연결만 확인")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(!isValid || isTesting || isSaving)

            if let testMessage {
                Label(testMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } footer: {
            Text(securityFootnote)
        }
    }

    private var currentErrorMessage: String {
        errorMessage ?? ""
    }

    private var isValid: Bool {
        if kind.isOAuthCloud { return true }
        return parsedServerAddress != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && (1...65_535).contains(port)
    }

    private var canSave: Bool {
        isValid
            && testMessage != nil
            && testedConfiguration == currentTestConfiguration
            && (kind != .sftp || trustedHostKey != nil)
    }

    private var securityFootnote: String {
        switch kind {
        case .synology:
            return usesTLS
                ? "공인 또는 기기에서 신뢰하는 TLS 인증서가 필요합니다. QuickConnect ID 대신 DDNS·도메인 또는 VPN 주소를 입력하세요."
                : "HTTP는 같은 로컬 네트워크에서만 사용하세요. 외부 접속에는 HTTPS 또는 VPN을 권장합니다."
        case .sftp:
            let hostKeyGuidance = trustedHostKey == nil
                ? "연결 테스트에서 표시되는 SSH 호스트 키 지문을 확인한 뒤 저장할 수 있습니다."
                : "SSH 호스트 키가 이 연결에 고정되었습니다. 키가 바뀌면 NasFinder가 연결을 차단합니다."
            return "\(hostKeyGuidance) 처음에는 시작 위치를 ‘.’으로 테스트하세요. 상대 경로는 SSH 로그인 홈을 기준으로 합니다."
        case .smb:
            return "ipTIME에서는 Windows 파일공유(SMB)를 켜세요. 시작 위치가 ‘/’이면 사용 가능한 공유 폴더를 먼저 보여줍니다. SMB 2.0 이상을 사용합니다."
        case .webDAV:
            if webDAVPreset != .generic {
                return webDAVPreset.credentialGuidance
            }
            return usesTLS
                ? "WebDAV 공유 폴더 권한을 지정하세요. \(webDAVPreset.credentialGuidance)"
                : "HTTP WebDAV는 같은 로컬 네트워크에서만 사용하세요."
        case .ftp:
            return "ipTIME 공유기 USB 저장장치와 ipDISK는 FTP를 사용합니다. FTP 암호화가 없으므로 로컬 네트워크나 VPN 안에서만 사용하세요."
        case .dropbox, .oneDrive, .googleDrive:
            return "로그인 토큰은 iPhone 키체인에 저장됩니다."
        }
    }

    private func connectionKindButton(_ candidate: ConnectionKind) -> some View {
        let isSelected = kind == candidate
        let serviceColor = ThemeServicePalette.color(
            forServiceIdentifier: candidate.rawValue,
            theme: .current
        )
        return Button {
            kind = candidate
        } label: {
            VStack(spacing: 5) {
                Image(systemName: candidate.systemImage)
                    .font(.body.weight(.medium))
                Text(candidate.compactTitle)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(serviceColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? serviceColor.opacity(0.14)
                            : Color(uiColor: .secondarySystemGroupedBackground)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isSelected ? serviceColor.opacity(0.55) : serviceColor.opacity(0.14),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.title) 연결 방식")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var draftConnection: RemoteConnection {
        RemoteConnection(
            id: editingConnection?.id ?? UUID(),
            name: name.isEmpty ? defaultName : name,
            kind: kind,
            host: normalizedHost,
            port: parsedServerAddress?.explicitPort ?? port,
            username: username,
            rootPath: rootPath,
            usesTLS: usesTLS,
            trustedHostKey: trustedHostKey,
            createdAt: editingConnection?.createdAt ?? .now
        )
    }

    private var normalizedHost: String {
        parsedServerAddress?.host ?? host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedServerAddress: ParsedServerAddress? {
        try? ServerAddressParser.parse(host, kind: kind)
    }

    private var addressValidationMessage: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try ServerAddressParser.parse(host, kind: kind)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var defaultName: String {
        kind.title
    }

    private var rootPathPlaceholder: String {
        switch kind {
        case .synology: "/photo"
        case .sftp: "예: ."
        case .smb: "/ 또는 /공유이름"
        case .webDAV, .ftp, .dropbox, .oneDrive, .googleDrive: "/"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func testConnection(saveOnSuccess: Bool = false) async {
        isTesting = true
        testMessage = nil
        testedConfiguration = nil
        defer { isTesting = false }

        let attemptedConfiguration = currentTestConfiguration
        let connection = draftConnection
        do {
            let service = RemoteFileServiceFactory.make(
                connection: connection,
                credential: RemoteCredential(password: password)
            )
            try await service.testConnection()
            guard attemptedConfiguration == currentTestConfiguration else { return }
            testMessage = "연결되었습니다."
            testedConfiguration = attemptedConfiguration
            shouldSaveAfterHostKeyTrust = false
            if kind == .sftp {
                SFTPConnectionDiagnostics.recordConnectionTestSucceeded()
            } else if kind == .synology {
                SynologyConnectionDiagnostics.recordConnectionTestSucceeded()
            }
            if saveOnSuccess {
                await save()
            }
        } catch let trust as SFTPHostKeyTrustRequired {
            guard attemptedConfiguration == currentTestConfiguration else { return }
            shouldSaveAfterHostKeyTrust = saveOnSuccess
            pendingHostKey = trust
        } catch {
            guard attemptedConfiguration == currentTestConfiguration else { return }
            shouldSaveAfterHostKeyTrust = false
            if kind == .sftp {
                let diagnostic = SFTPConnectionDiagnostics.diagnostic(
                    for: error,
                    rootPath: connection.normalizedRootPath
                )
                SFTPConnectionDiagnostics.record(diagnostic)
                errorMessage = diagnostic.userMessage
            } else if kind == .synology {
                let diagnostic = SynologyConnectionDiagnostics.diagnostic(
                    for: error,
                    connection: connection
                )
                SynologyConnectionDiagnostics.record(diagnostic)
                errorMessage = diagnostic.userMessage
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func connectAndSave() async {
        if AddConnectionFlowPolicy.requiresConnectionTest(
            testedConfiguration: testedConfiguration,
            currentConfiguration: currentTestConfiguration
        ) {
            await testConnection(saveOnSuccess: true)
        } else {
            await save()
        }
    }

    @MainActor
    private func connectCloud() async {
        guard let provider = kind.oauthProvider else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let credential = try await oauthAuthorizer.authorize(provider: provider)
            let connection = RemoteConnection(
                id: editingConnection?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.title : name,
                kind: kind,
                host: provider.rawValue,
                port: 443,
                username: kind.title,
                rootPath: "/",
                usesTLS: true,
                createdAt: editingConnection?.createdAt ?? .now
            )
            let service = CloudDriveFileService(
                connection: connection,
                credential: RemoteCredential(password: "", cloudCredential: .oauth(credential))
            )
            try await service.testConnection()
            if editingConnection == nil {
                try await store.add(connection, oauthCredential: credential)
            } else {
                try await store.update(connection, oauthCredential: credential)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard testedConfiguration == currentTestConfiguration else {
            errorMessage = "연결 정보가 바뀌었습니다. 연결 테스트를 다시 실행해 주세요."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if editingConnection == nil {
                try await store.add(draftConnection, password: password)
            } else {
                try await store.update(draftConnection, password: password)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadStoredCredentialIfNeeded() {
        guard !didLoadStoredCredential, let editingConnection else { return }
        didLoadStoredCredential = true
        guard !editingConnection.kind.isOAuthCloud else { return }
        do {
            password = try store.credential(for: editingConnection).password
        } catch {
            errorMessage = "저장된 비밀번호를 읽지 못했습니다. 비밀번호를 다시 입력해 주세요."
        }
    }

    private func applyRememberedKindIfNeeded() {
        guard !didApplyRememberedKind else { return }
        didApplyRememberedKind = true
        guard editingConnection == nil,
              let rememberedKind = ConnectionKind(rawValue: lastKindRawValue) else {
            return
        }
        kind = rememberedKind
    }

    private var hostKeyAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingHostKey != nil },
            set: { if !$0 { pendingHostKey = nil } }
        )
    }

    private func serverIdentityChanged() {
        if kind == .sftp {
            trustedHostKey = nil
        }
        resetTestStatus()
    }

    private func resetTestStatus() {
        testMessage = nil
        testedConfiguration = nil
        shouldSaveAfterHostKeyTrust = false
    }

    private func synchronizeAddressComponents() {
        guard let parsed = parsedServerAddress else { return }
        if kind == .synology {
            // A pasted URL without an explicit port follows DSM's standard
            // ports. Previously `http://nas.local` changed the scheme but left
            // port 5001 selected, which commonly ended in a timeout.
            let settings = parsed.synchronizedSynologySettings(
                currentPort: port,
                currentUsesTLS: usesTLS
            )
            if port != settings.port { port = settings.port }
            if usesTLS != settings.usesTLS { usesTLS = settings.usesTLS }
        } else {
            if kind == .webDAV, let inferredTLS = parsed.inferredTLS {
                usesTLS = inferredTLS
                if parsed.explicitPort == nil {
                    port = inferredTLS ? 443 : ConnectionKind.webDAV.defaultPort
                }
            }
            if let explicitPort = parsed.explicitPort, port != explicitPort {
                port = explicitPort
            }
        }
    }

    private func applyWebDAVPreset(_ preset: WebDAVConnectionPreset) {
        guard kind == .webDAV, preset != .generic else { return }
        if let defaultHost = preset.defaultHost {
            host = defaultHost
        }
        port = preset.defaultPort
        usesTLS = true
        rootPath = preset.rootPath(username: username)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = preset.title
        }
        resetTestStatus()
    }

    private func synchronizeWebDAVRootPath(from oldUsername: String, to newUsername: String) {
        guard kind == .webDAV,
              webDAVPreset == .nextcloud || webDAVPreset == .ownCloud,
              rootPath == webDAVPreset.rootPath(username: oldUsername) else { return }
        rootPath = webDAVPreset.rootPath(username: newUsername)
    }

    private func synchronizeStandardSynologyPort(fromTLS oldValue: Bool, toTLS newValue: Bool) {
        guard kind == .synology else { return }
        port = ConnectionKind.synologyPortAfterTLSToggle(
            currentPort: port,
            from: oldValue,
            to: newValue,
            hasExplicitPort: parsedServerAddress?.explicitPort != nil
        )
    }

    private var currentTestConfiguration: ConnectionTestConfiguration {
        ConnectionTestConfiguration(
            kind: kind,
            host: normalizedHost,
            port: parsedServerAddress?.explicitPort ?? port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            rootPath: draftConnection.normalizedRootPath,
            usesTLS: (kind == .synology || kind == .webDAV) && usesTLS,
            trustedHostKey: kind == .sftp ? trustedHostKey : nil
        )
    }
}

enum AddConnectionFlowPolicy {
    static func requiresConnectionTest(
        testedConfiguration: ConnectionTestConfiguration?,
        currentConfiguration: ConnectionTestConfiguration
    ) -> Bool {
        testedConfiguration != currentConfiguration
    }
}

struct ConnectionTestConfiguration: Equatable {
    let kind: ConnectionKind
    let host: String
    let port: Int
    let username: String
    let password: String
    let rootPath: String
    let usesTLS: Bool
    let trustedHostKey: String?
}

private extension ConnectionKind {
    var compactTitle: String {
        switch self {
        case .synology: "Synology"
        case .sftp: "SFTP"
        case .smb: "SMB"
        case .webDAV: "WebDAV"
        case .ftp: "FTP"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google"
        }
    }
}
