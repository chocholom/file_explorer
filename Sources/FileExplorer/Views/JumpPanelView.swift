import SwiftUI

/// Fuzzy folder jump: type partial path fragments ("dowwall" → ~/Downloads/Wallpapers).
struct JumpPanelView: View {
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var jump: FolderJumpModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
                TextField("Jump to folder or file… (or type a path: ~/Dow)", text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) {
                        jump.selectedIndex = min(jump.selectedIndex + 1, jump.matches.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        jump.selectedIndex = max(jump.selectedIndex - 1, 0)
                        return .handled
                    }
                    .onSubmit(chooseSelected)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            if jump.isBuilding {
                Label("Indexing folders…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else if jump.matches.isEmpty && jump.query.count >= 2 {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(jump.matches.enumerated()), id: \.element) { index, match in
                    HStack(spacing: 6) {
                        Image(systemName: match.isDirectory ? "folder" : "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(jump.displayPath(for: match.url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == jump.selectedIndex ? Color.accentColor.opacity(0.25) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { choose(match) }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)  // Esc closes; no visible chrome needed
            }
            .frame(height: 0)
        }
        .padding(14)
        .frame(width: 480)
        .onAppear {
            jump.prepare()
            jump.query = ""
            fieldFocused = true
        }
    }

    private var queryBinding: Binding<String> {
        Binding(get: { jump.query }, set: { jump.query = $0 })
    }

    private func chooseSelected() {
        guard jump.matches.indices.contains(jump.selectedIndex) else { return }
        choose(jump.matches[jump.selectedIndex])
    }

    private func choose(_ match: FolderJumpModel.Match) {
        let model = state.activeModel
        if match.isDirectory {
            model.navigate(to: match.url)
        } else {
            // Jump to the file: open its folder and select it.
            model.navigate(to: match.url.deletingLastPathComponent())
            if let item = model.allItems.first(where: { $0.name == match.url.lastPathComponent }) {
                model.selection = [item.id]
            }
        }
        dismiss()
    }
}
