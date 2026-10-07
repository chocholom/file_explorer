import SwiftUI

/// ⇧⌘G: type a path (`~`, relative or absolute) and go there.
struct GoToFolderSheet: View {
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @FocusState private var fieldFocused: Bool

    init(state: WindowState) {
        self.state = state
        _path = State(initialValue: PathInput.abbreviate(state.activeModel.currentDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder")
                .font(.headline)
            TextField("~/Documents or /Volumes/…", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(go)
            Group {
                if let url = resolvedURL, FileSystemHelpers.isDirectory(url) {
                    Label(url.path, systemImage: "folder")
                } else {
                    Label("No such folder", systemImage: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedURL.map { !FileSystemHelpers.isDirectory($0) } ?? true)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }

    private var resolvedURL: URL? {
        PathInput.resolve(path, relativeTo: state.activeModel.currentDirectory)
    }

    private func go() {
        guard let url = resolvedURL, FileSystemHelpers.isDirectory(url) else { return }
        state.activeModel.navigate(to: url)
        dismiss()
    }
}
