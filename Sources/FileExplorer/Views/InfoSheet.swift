import CryptoKit
import SwiftUI

struct InfoSheet: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var checksum: String?
    @State private var checksumRunning = false
    @State private var created: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(item.kindText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Size") {
                    if item.isDirectory {
                        FolderTotalText(url: item.url)
                    } else {
                        Text(item.sizeText)
                    }
                }
                row("Where") {
                    Text(whereText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let created {
                    row("Created") { Text(created.formatted(date: .abbreviated, time: .shortened)) }
                }
                row("Modified") { Text(item.dateText) }
                if !item.isDirectory {
                    row("SHA-256") {
                        if let checksum {
                            Text(checksum)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                        } else if checksumRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Computing…").foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Calculate") { computeChecksum() }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if !item.isArchiveEntry {
                created = try? item.url.resourceValues(forKeys: [.creationDateKey]).creationDate
            }
            if !item.isDirectory, item.size < 50_000_000 {
                computeChecksum()  // auto for small files; large ones on demand
            }
        }
    }

    private var whereText: String {
        if let entry = item.archiveEntry {
            let inner = (entry.path as NSString).deletingLastPathComponent
            return inner.isEmpty
                ? "\(entry.archiveURL.path) (archive)" : "\(entry.archiveURL.path) ▸ \(inner)"
        }
        return item.url.deletingLastPathComponent().path
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }

    private func computeChecksum() {
        checksumRunning = true
        let url = item.url
        let entry = item.archiveEntry
        Task.detached(priority: .userInitiated) {
            // Archive entries are hashed from an extracted copy.
            let real = entry.flatMap { try? ArchiveCache.shared.materialize($0) } ?? url
            let result = Self.sha256(of: real)
            await MainActor.run {
                checksum = result ?? "unreadable"
                checksumRunning = false
            }
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 4_194_304), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Folder total via the shared async size store.
private struct FolderTotalText: View {
    let url: URL

    var body: some View {
        if let total = FolderSizeStore.shared.size(for: url) {
            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        } else {
            Text("Calculating…")
                .foregroundStyle(.secondary)
                .onAppear { FolderSizeStore.shared.request(url) }
        }
    }
}
