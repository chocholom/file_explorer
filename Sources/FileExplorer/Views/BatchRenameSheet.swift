import SwiftUI

struct BatchRenameSheet: View {
    let model: DirectoryViewModel
    let items: [FileItem]
    @Environment(\.dismiss) private var dismiss

    private enum ModeKind: String, CaseIterable {
        case findReplace = "Find & Replace"
        case numbering = "Numbering"
        case caseChange = "Change Case"
    }

    @State private var modeKind: ModeKind = .findReplace
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var numberingBase = ""
    @State private var numberingStart = 1
    @State private var numberingDigits = 3
    @State private var caseMode: BatchRenamer.CaseMode = .lowercase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(items.count) Items")
                .font(.headline)

            Picker("Mode", selection: $modeKind) {
                ForEach(ModeKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch modeKind {
            case .findReplace:
                HStack {
                    TextField("Find", text: $findText)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replace with", text: $replaceText)
                }
                .textFieldStyle(.roundedBorder)
            case .numbering:
                HStack {
                    TextField("Base name (e.g. Holiday)", text: $numberingBase)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Start: \(numberingStart)", value: $numberingStart, in: 0...9999)
                    Stepper("Digits: \(numberingDigits)", value: $numberingDigits, in: 1...6)
                }
            case .caseChange:
                Picker("Case", selection: $caseMode) {
                    ForEach(BatchRenamer.CaseMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(Array(zip(items, previewNames).prefix(50)), id: \.0.id) { item, newName in
                        GridRow {
                            Text(item.name)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(newName)
                                .fontWeight(newName != item.name ? .medium : .regular)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .font(.callout)
            }
            .frame(maxHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.batchRename(items, mode: mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var mode: BatchRenamer.Mode {
        switch modeKind {
        case .findReplace: return .findReplace(find: findText, replace: replaceText)
        case .numbering:
            return .numbering(base: numberingBase, start: numberingStart, digits: numberingDigits)
        case .caseChange: return .caseChange(caseMode)
        }
    }

    private var previewNames: [String] {
        BatchRenamer.apply(mode, to: items.map(\.name))
    }

    private var hasChanges: Bool {
        zip(items, previewNames).contains { $0.name != $1 && !$1.isEmpty }
    }
}
