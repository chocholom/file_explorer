import SwiftUI

/// Num+ / Num− in Total Commander: select or unselect files by wildcard.
struct SelectPatternSheet: View {
    let model: DirectoryViewModel
    let select: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: String
    @FocusState private var fieldFocused: Bool

    init(model: DirectoryViewModel, select: Bool) {
        self.model = model
        self.select = select
        // Default to the focused file's extension, the most common use.
        if let item = model.focusedItem, !item.isDirectory, !item.ext.isEmpty {
            _pattern = State(initialValue: "*.\(item.ext)")
        } else {
            _pattern = State(initialValue: "*")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(select ? "Select Files Matching" : "Unselect Files Matching")
                .font(.headline)
            TextField("*.jpg; IMG_*", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(apply)
            Text("Wildcards * and ?; separate several patterns with “;”. Plain text matches anywhere in the name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(matchCount) of \(model.filteredItems.count) items match")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(select ? "Select" : "Unselect", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(NamePattern.parse(pattern).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }

    private var matchCount: Int {
        let patterns = NamePattern.parse(pattern)
        guard !patterns.isEmpty else { return 0 }
        return model.filteredItems.filter { NamePattern.matches($0.name, patterns: patterns) }.count
    }

    private func apply() {
        model.select(matching: pattern, select: select)
        dismiss()
    }
}
