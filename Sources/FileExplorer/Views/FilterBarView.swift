import SwiftUI

struct FilterBarView: View {
    let model: DirectoryViewModel
    @State private var showingFilterManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.categoryCounts, id: \.category) { entry in
                            FilterChip(
                                label: entry.category.rawValue,
                                systemImage: entry.category.symbolName,
                                count: entry.count,
                                isSelected: model.selectedCategories.contains(entry.category)
                            ) {
                                model.toggleCategory(entry.category)
                            }
                        }
                        ForEach(CustomFilterStore.shared.filters) { filter in
                            let count = model.customFilterCount(filter)
                            if count > 0 {
                                FilterChip(
                                    label: filter.name,
                                    systemImage: "star",
                                    count: count,
                                    isSelected: model.selectedCustomFilterIDs.contains(filter.id)
                                ) {
                                    model.toggleCustomFilter(filter.id)
                                }
                            }
                        }
                        Button {
                            showingFilterManager = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Manage custom type filters")
                        if model.hasActiveFilters {
                            Button("Clear", systemImage: "xmark.circle.fill") {
                                model.clearFilters()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        }
                    }
                    .padding(.leading, 10)
                }

                MenuChip(
                    icon: "calendar",
                    label: model.dateFilter == .any ? "Date" : model.dateFilter.rawValue,
                    isActive: model.dateFilter != .any
                ) {
                    Picker("Date", selection: dateFilterBinding) {
                        ForEach(DateFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                }

                MenuChip(
                    icon: "scalemass",
                    label: model.sizeFilter == .any ? "Size" : model.sizeFilter.rawValue,
                    isActive: model.sizeFilter != .any
                ) {
                    Picker("Size", selection: sizeFilterBinding) {
                        ForEach(SizeFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        model.searchRecursively ? "Search subfolders" : "Filter",
                        text: searchBinding
                    )
                    .textFieldStyle(.plain)
                    .font(.callout)
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        model.searchRecursively.toggle()
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption)
                            .foregroundStyle(model.searchRecursively ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search subfolders recursively")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .frame(width: 200)
                .padding(.trailing, 10)
            }

            if !model.extensionCounts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.extensionCounts, id: \.ext) { entry in
                            FilterChip(
                                label: ".\(entry.ext)",
                                systemImage: nil,
                                count: entry.count,
                                isSelected: model.selectedExtensions.contains(entry.ext)
                            ) {
                                model.toggleExtension(entry.ext)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showingFilterManager) {
            ManageFiltersSheet()
        }
    }

    private var dateFilterBinding: Binding<DateFilter> {
        Binding(get: { model.dateFilter }, set: { model.dateFilter = $0 })
    }

    private var sizeFilterBinding: Binding<SizeFilter> {
        Binding(get: { model.sizeFilter }, set: { model.sizeFilter = $0 })
    }

    private var searchBinding: Binding<String> {
        Binding(get: { model.searchText }, set: { model.searchText = $0 })
    }
}

private struct MenuChip<Content: View>: View {
    let icon: String
    let label: String
    let isActive: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(isActive ? Color.white : .primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

private struct FilterChip: View {
    let label: String
    let systemImage: String?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(label)
                    .font(.callout)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(isSelected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }
}
