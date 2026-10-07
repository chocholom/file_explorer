import SwiftUI

/// Progress strip for the running copy/move, with Cancel. Hidden when idle.
struct OperationStatusView: View {
    var body: some View {
        if let progress = FileOperationQueue.shared.progress {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(progress.title)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(detail(progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if progress.totalItems == 0 {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: progress.fraction)
                    }
                    if !progress.currentName.isEmpty {
                        Text(progress.currentName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button("Cancel") { FileOperationQueue.shared.cancel() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func detail(_ progress: OperationProgress) -> String {
        var parts: [String] = []
        if progress.totalItems > 0 {
            parts.append("\(progress.completedItems) of \(progress.totalItems)")
        }
        if progress.totalBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            parts.append("\(done) of \(total)")
        }
        return parts.joined(separator: " · ")
    }
}
