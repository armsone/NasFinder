import SwiftUI

/// '작업대에 담기'가 만든 담을 참조들. 모든 담기 경로가 이 값을 만들어 같은 대상 포켓 선택 화면을 연다.
struct WorkbenchAddRequest: Identifiable {
    let id = UUID()
    /// 사용자에게 보여 줄 짧은 설명(예: "NAS 항목 3개").
    let title: String
    let entries: [WorkbenchEntry]
    /// 참조를 만들지 못한 항목 사유처럼, 담기 전에 함께 알려야 할 안내.
    var notices: [String] = []
}

extension View {
    /// 선택한 항목을 담을 **포켓을 사용자가 직접 고르는**(또는 그 자리에서 새로 만드는) 시트를 붙인다.
    /// 기본 포켓으로 조용히 담지 않는다.
    func workbenchAddSheet(_ request: Binding<WorkbenchAddRequest?>) -> some View {
        sheet(item: request) { WorkbenchTargetSheet(request: $0) }
    }
}

/// 대상 포켓 선택 시트. 포켓을 고르면 그 포켓 끝에 순서대로 참조를 담고 결과를 그대로 보여 준다.
struct WorkbenchTargetSheet: View {
    let request: WorkbenchAddRequest
    @ObservedObject private var store = WorkbenchStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var result: String?
    @State private var errorText: String?
    private var themeRefresh = ThemeRefresh()

    init(request: WorkbenchAddRequest) { self.request = request }

    var body: some View {
        let _ = themeRefresh.theme
        NavigationStack {
            Group {
                if let result {
                    resultView(result)
                } else {
                    chooser
                }
            }
            .background(PorcelainMetrics.paper)
            .navigationTitle("작업대에 담기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "취소" : "닫기") { dismiss() }
                }
            }
        }
    }

    private var chooser: some View {
        List {
            Section {
                ForEach(request.notices, id: \.self) { notice in
                    Text(notice).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.warn)
                }
                Text("\(request.title)을(를) 담을 포켓을 고르세요. 원본은 복사되지 않고 위치만 기록됩니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                if store.isReadOnly, let message = store.persistenceError {
                    Text(message).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
                }
            }
            Section("포켓") {
                if store.pockets.isEmpty {
                    Text("아직 포켓이 없습니다. 아래에서 새로 만들어 담을 수 있습니다.")
                        .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                }
                ForEach(store.pockets) { pocket in
                    Button { add(to: pocket.id) } label: {
                        HStack {
                            InterfaceIcon(systemName: "nf.pocket", size: PorcelainMetrics.rowIconSize).frame(width: ui(30))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pocket.name).font(.ui(.body))
                                Text("항목 \(pocket.entries.count)개").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isReadOnly)
                    .accessibilityLabel("\(pocket.name) 포켓에 담기")
                }
            }
            Section("새 포켓") {
                TextField("포켓 이름", text: $newName)
                    .submitLabel(.done)
                Button("만들고 담기") { createAndAdd() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isReadOnly)
                if let errorText {
                    Text(errorText).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func resultView(_ text: String) -> some View {
        VStack(spacing: ui(14)) {
            Image(interfaceSystemName: "checkmark.circle.fill", pointSize: 34).font(.ui(.largeTitle)).foregroundStyle(PorcelainMetrics.accent)
                .accessibilityHidden(true)
            Text(text).font(.ui(.subheadline)).multilineTextAlignment(.center)
            Button("확인") { dismiss() }.buttonStyle(PorcelainProminentButtonStyle())
        }
        .padding(ui(24))
        .frame(maxWidth: ui(480), maxHeight: .infinity)
    }

    private func add(to pocketID: UUID) {
        let outcome = store.add(request.entries, to: pocketID)
        if let failure = outcome.failureMessage {
            errorText = failure
            return
        }
        let name = store.pocket(pocketID)?.name ?? "포켓"
        result = "'\(name)' 포켓: " + outcome.summary
    }

    private func createAndAdd() {
        switch store.createPocket(named: newName) {
        case .success(let id):
            newName = ""
            errorText = nil
            add(to: id)
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}
