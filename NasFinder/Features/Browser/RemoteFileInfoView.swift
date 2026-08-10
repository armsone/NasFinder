import SwiftUI

struct RemoteFileInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let item: RemoteFileItem
    let connection: RemoteConnection

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 46))
                            .foregroundStyle(item.isDirectory ? Color.blue : Color.accentColor)
                            .accessibilityHidden(true)

                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("일반") {
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
                }

                Section("위치") {
                    LabeledContent("연결", value: connection.name)
                    LabeledContent("방식", value: connection.kind.title)
                    LabeledContent("서버", value: connection.endpointDescription)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("전체 경로")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
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
