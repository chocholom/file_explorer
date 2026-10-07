import SwiftUI

/// Total Commander's bottom row: F2…F8 act on the active pane; the real function
/// keys are handled by `WindowState` so this doubles as a legend.
struct FunctionKeyBar: View {
    let state: WindowState

    var body: some View {
        let model = state.activeModel
        let hasSelection = !model.selection.isEmpty
        HStack(spacing: 6) {
            key("F2", "Rename", enabled: hasSelection) { model.beginRenamingSelection() }
            key("F3", "View", enabled: hasSelection) { state.toggleQuickLook() }
            key("F4", "Edit", enabled: hasSelection) { model.edit(model.selectedItems) }
            key("F5", "Copy", enabled: hasSelection) { state.requestTransfer(.copy) }
            key("F6", "Move", enabled: hasSelection) { state.requestTransfer(.move) }
            key("F7", "New Folder", enabled: model.canModifyHere) { model.newFolder() }
            key("F8", "Delete", enabled: hasSelection) { model.trashSelection() }
            Spacer(minLength: 8)
            if let message = state.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func key(_ key: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.caption2.weight(.semibold).monospaced())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
                Text(title)
                    .font(.callout)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help("\(title) (\(key))")
    }
}
