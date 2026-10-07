import SwiftUI

/// Create and manage custom file type filters ("3D Assets" → fbx, obj, blend).
struct ManageFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newExtensions = ""

    private var store: CustomFilterStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Type Filters")
                .font(.headline)
            Text("A filter matches files by extension and appears as a chip in the filter bar.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if store.filters.isEmpty {
                Text("No custom filters yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.filters) { filter in
                        HStack {
                            Image(systemName: "star")
                                .foregroundStyle(.secondary)
                            Text(filter.name)
                                .fontWeight(.medium)
                            Text(filter.extensions.map { ".\($0)" }.joined(separator: " "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                store.filters.removeAll { $0.id == filter.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Divider()

            HStack {
                TextField("Name (e.g. 3D Assets)", text: $newName)
                TextField("Extensions (fbx, obj, blend)", text: $newExtensions)
                Button("Add") { add() }
                    .disabled(!canAdd)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { if canAdd { add() } }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !CustomFilter.parseExtensions(newExtensions).isEmpty
    }

    private func add() {
        store.filters.append(
            CustomFilter(
                name: newName.trimmingCharacters(in: .whitespaces),
                extensions: CustomFilter.parseExtensions(newExtensions)))
        newName = ""
        newExtensions = ""
    }
}
