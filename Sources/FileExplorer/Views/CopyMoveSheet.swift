import SwiftUI

/// F5 / F6 confirmation, Commander style: destination path prefilled with the other
/// pane, editable, with a conflict policy. Return confirms immediately.
struct CopyMoveSheet: View {
    let state: WindowState
    let request: TransferRequest
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var policy: PolicyChoice = .ask
    @FocusState private var fieldFocused: Bool

    enum PolicyChoice: String, CaseIterable, Identifiable {
        case ask = "Ask"
        case replace = "Replace"
        case skip = "Skip"
        case keepBoth = "Keep Both"

        var id: String { rawValue }

        var conflictPolicy: ConflictPolicy {
            switch self {
            case .ask: return .ask
            case .replace: return .always(.replace)
            case .skip: return .always(.skip)
            case .keepBoth: return .always(.keepBoth)
            }
        }
    }

    init(state: WindowState, request: TransferRequest) {
        self.state = state
        self.request = request
        _path = State(initialValue: PathInput.abbreviate(request.suggestedDestination))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                TextField("Destination folder", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(confirm)
                Button("Choose…", action: choose)
            }

            Group {
                if let url = resolvedURL {
                    if FileSystemHelpers.isDirectory(url) {
                        Label(url.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if FileSystemHelpers.exists(url) {
                        Label("That path is a file, not a folder.", systemImage: "exclamationmark.triangle")
                    } else {
                        Label("Folder doesn't exist yet — it will be created.", systemImage: "info.circle")
                    }
                } else {
                    Label("Enter a destination folder.", systemImage: "info.circle")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Picker("If an item already exists:", selection: $policy) {
                ForEach(PolicyChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .copy ? "Copy" : "Move", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { fieldFocused = true }
    }

    private var title: String {
        let verb = request.kind == .copy ? "Copy" : "Move"
        let what = request.items.count == 1
            ? "“\(request.items[0].name)”" : "\(request.items.count) items"
        return "\(verb) \(what) to:"
    }

    private var resolvedURL: URL? {
        PathInput.resolve(path, relativeTo: request.source.currentDirectory)
    }

    private var canConfirm: Bool {
        guard let url = resolvedURL else { return false }
        return !FileSystemHelpers.exists(url) || FileSystemHelpers.isDirectory(url)
    }

    private func confirm() {
        guard canConfirm, let url = resolvedURL else { return }
        if !FileSystemHelpers.exists(url) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                request.source.operationError = error.localizedDescription
                dismiss()
                return
            }
        }
        state.perform(request, to: url, policy: policy.conflictPolicy)
        dismiss()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = request.kind == .copy ? "Copy Here" : "Move Here"
        if let url = resolvedURL, FileSystemHelpers.isDirectory(url) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = PathInput.abbreviate(url)
        }
    }
}
