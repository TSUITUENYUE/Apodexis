import SwiftUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String

    init(markdown: String) {
        _markdown = State(initialValue: markdown)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $markdown)
                    .font(.system(.body, design: .monospaced))
                    .padding()

                Divider()

                HStack {
                    Text("\(markdown.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        PlatformClipboard.copy(markdown)
                    } label: {
                        Label("Copy Markdown", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
