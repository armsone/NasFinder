import SwiftUI

struct RemoteFileInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let item: RemoteFileItem
    let connection: RemoteConnection
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: ui(12)) {
                        Image(interfaceSystemName: item.systemImage, pointSize: ui(46))
                            .font(.system(size: ui(46)))
                            .foregroundStyle(item.isDirectory ? PorcelainMetrics.graphite : PorcelainMetrics.accent)
                            .accessibilityHidden(true)

                        Text(item.name)
                            .font(.ui(.body))
                            .foregroundStyle(PorcelainMetrics.graphite)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ui(8))
                }

                Section {
                    LabeledContent("종류", value: kindDescription)
                    if !item.isDirectory {
                        LabeledContent("크기", value: sizeDescription)
                    }
                    if let modifiedAt = item.modifiedAt {
                        LabeledContent("수정일") {
                            Text(
                                modifiedAt,
                                format: .dateTime
                                    .year()
                                    .month()
                                    .day()
                                    .hour()
                                    .minute()
                                    .second()
                            )
                        }
                    }
                } header: {
                    Text("일반").font(MacUIScale.sectionNoteFont)
                }

                Section {
                    LabeledContent("연결", value: connection.name)
                    LabeledContent("방식", value: connection.kind.title)
                    LabeledContent("서버", value: connection.endpointDescription)
                    VStack(alignment: .leading, spacing: ui(6)) {
                        Text("전체 경로")
                            .font(.ui(.caption))
                            .foregroundStyle(PorcelainMetrics.secondary)
                        Text(item.path)
                            .font(.ui(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("위치").font(MacUIScale.sectionNoteFont)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyBreezeBackground())
            .navigationTitle("정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Group {
                        Button("완료") { dismiss() }
                    }
                    .uiBarFont()
                }
            }
        }
    }

    private var kindDescription: String {
        if item.isDirectory { return "폴더" }
        if item.isImage { return "사진" }
        if item.isVideo { return "비디오" }

        let filenameExtension = (item.name as NSString).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !filenameExtension.isEmpty {
            return "\(filenameExtension.uppercased()) 파일"
        }
        return item.contentType.localizedDescription ?? "파일"
    }

    private var sizeDescription: String {
        guard let size = item.size else { return "알 수 없음" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
