import SwiftUI
import AppKit

struct LegalAgreementView: View {
    @ObservedObject var viewModel: LegalAgreementViewModel

    var body: some View {
        VStack(spacing: 18) {
            header

            if let loadingError = viewModel.loadingError {
                errorBlock(loadingError)
            }

            legalDocumentsBlock

            footer
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 620)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DroneUAVDemo")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("EULA и Terms of Service")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Перед первым запуском необходимо принять лицензионное соглашение и условия использования.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legalDocumentsBlock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(viewModel.documents) { document in
                    documentBlock(document)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private func documentBlock(_ document: LegalDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let subtitle = document.subtitle {
                    Text(subtitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Text("Version: \(document.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(document.body, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func errorBlock(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Локальный файл принятия будет сохранён в Application Support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(viewModel.acceptanceDebugPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                Button("Выйти") {
                    NSApplication.shared.terminate(nil)
                }

                Button("Согласиться") {
                    viewModel.accept()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.documents.isEmpty)
            }
        }
    }
}
