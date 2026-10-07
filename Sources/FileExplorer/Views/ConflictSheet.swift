import SwiftUI

/// "An item named X already exists": Replace / Keep Both / Skip / Merge / Cancel,
/// with "apply to all" for the rest of the operation. Resolving resumes the worker.
struct ConflictSheet: View {
    let conflict: FileConflict
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("An item named “\(conflict.destination.lastPathComponent)” already exists in “\(folderName)”.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(conflict.bothDirectories
                ? "Merge keeps the existing folder and adds the new items into it; Replace moves the existing folder to the Trash first."
                : "Replace moves the existing item to the Trash, so this stays undoable.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 24) {
                column("New", url: conflict.source, size: conflict.sourceSize,
                       modified: conflict.sourceModified, isNewer: sourceIsNewer == true)
                column("Existing", url: conflict.destination, size: conflict.destinationSize,
                       modified: conflict.destinationModified, isNewer: sourceIsNewer == false)
            }

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)

            HStack {
                Button("Cancel") { resolve(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { resolve(.skip) }
                if conflict.bothDirectories {
                    Button("Replace") { resolve(.replace) }
                    Button("Merge") { resolve(.merge) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Replace") { resolve(.replace) }
                    Button("Keep Both") { resolve(.keepBoth) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var folderName: String {
        let name = conflict.destination.deletingLastPathComponent().lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private var sourceIsNewer: Bool? {
        guard let a = conflict.sourceModified, let b = conflict.destinationModified else { return nil }
        if abs(a.timeIntervalSince(b)) < 2 { return nil }
        return a > b
    }

    private func column(_ title: String, url: URL, size: Int64?, modified: Date?, isNewer: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if isNewer {
                        Text("newer")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text(PathInput.abbreviate(url.deletingLastPathComponent()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let modified {
                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolve(_ resolution: ConflictResolution) {
        FileOperationQueue.shared.resolvePendingConflict(resolution, applyToAll: applyToAll)
    }
}
