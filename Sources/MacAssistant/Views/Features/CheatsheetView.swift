import SwiftUI
import MacAssistantKit

struct CheatsheetView: View {
    @State private var query = ""
    @State private var selectedCategory: String?
    @State private var selectedRisk: RiskLevel?
    @State private var selectedCommandID: String?

    private var results: [CommandEntry] {
        CommandLibrary.search(query, risk: selectedRisk, category: selectedCategory)
    }

    private var grouped: [(String, [CommandEntry])] {
        let groups = Dictionary(grouping: results, by: \.category)
        return CommandLibrary.categories.compactMap { category in
            groups[category].map { (category, $0) }
        }
    }

    private var selectedCommand: CommandEntry? {
        results.first { $0.id == selectedCommandID }
    }

    private var hasFilters: Bool {
        !query.isEmpty || selectedCategory != nil || selectedRisk != nil
    }

    private var selectedCategoryName: String {
        selectedCategory.map(CommandLibrary.localizedCategory) ?? L("cheatsheet.all")
    }

    private var selectedRiskName: String {
        selectedRisk?.label ?? L("cheatsheet.all")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        .featureSurfaceBackground()
        .navigationTitle(L("cheatsheet.title"))
        .searchable(
            text: $query,
            placement: .toolbar,
            prompt: L("cheatsheet.searchPrompt")
        )
        .onSubmit(of: .search) {
            selectedCommandID = results.first?.id
        }
        .toolbar {
            ToolbarItemGroup {
                categoryMenu
                riskMenu
                Button {
                    if let selectedCommand {
                        copyToClipboard(selectedCommand.command)
                    }
                } label: {
                    Label(L("cheatsheet.copySelected"), systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(selectedCommand == nil)
                .help(L("cheatsheet.copySelected.help"))
                .accessibilityIdentifier("cheatsheet.copySelected")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("cheatsheet.title"))
                    .font(.headline)
                Text(L("cheatsheet.totalCount", CommandLibrary.all.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Text(L("cheatsheet.resultCount", results.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel(L("cheatsheet.resultCount.accessibility", results.count))
                .accessibilityIdentifier("cheatsheet.resultsCount")

            if hasFilters {
                Button(L("cheatsheet.clearFilters")) {
                    clearFilters()
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityHint(L("cheatsheet.clearFilters.hint"))
                .accessibilityIdentifier("cheatsheet.resetFilters")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var commandList: some View {
        List(selection: $selectedCommandID) {
            ForEach(grouped, id: \.0) { category, commands in
                Section {
                    ForEach(commands) { command in
                        CommandRow(command: command)
                            .tag(command.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(CommandLibrary.localizedCategory(category))
                        Text("\(commands.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L(
                        "cheatsheet.section.accessibility",
                        CommandLibrary.localizedCategory(category),
                        commands.count
                    ))
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("cheatsheet.results")
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                filterLabel(L("cheatsheet.allCategories"), selected: selectedCategory == nil)
            }
            Divider()
            ForEach(CommandLibrary.categories, id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    filterLabel(
                        CommandLibrary.localizedCategory(category),
                        selected: selectedCategory == category
                    )
                }
            }
        } label: {
            Label(
                selectedCategory.map(CommandLibrary.localizedCategory) ?? L("cheatsheet.category"),
                systemImage: "folder"
            )
        }
        .help(L("cheatsheet.category.help", selectedCategoryName))
        .accessibilityLabel(L("cheatsheet.category.accessibility", selectedCategoryName))
        .accessibilityIdentifier("cheatsheet.categoryFilter")
    }

    private var riskMenu: some View {
        Menu {
            Button {
                selectedRisk = nil
            } label: {
                filterLabel(L("cheatsheet.allRisks"), selected: selectedRisk == nil)
            }
            Divider()
            ForEach(RiskLevel.allCases, id: \.self) { risk in
                Button {
                    selectedRisk = risk
                } label: {
                    filterLabel(risk.label, selected: selectedRisk == risk)
                }
            }
        } label: {
            Label(selectedRisk?.label ?? L("cheatsheet.risk"), systemImage: "shield")
        }
        .help(L("cheatsheet.risk.help", selectedRiskName))
        .accessibilityLabel(L("cheatsheet.risk.accessibility", selectedRiskName))
        .accessibilityIdentifier("cheatsheet.riskFilter")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L("cheatsheet.empty.title"))
                .font(.headline)
            Text(L("cheatsheet.empty.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("cheatsheet.empty.reset")) {
                clearFilters()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheatsheet.emptyState")
    }

    @ViewBuilder
    private func filterLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func clearFilters() {
        query = ""
        selectedCategory = nil
        selectedRisk = nil
        selectedCommandID = nil
    }
}

private struct CommandRow: View {
    let command: CommandEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(command.title)
                    .font(.callout.weight(.medium))
                CommandRiskLabel(risk: command.risk)
                Spacer(minLength: 8)
                CopyButton(text: command.command, label: L("theme.copy"))
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(L("cheatsheet.copy.accessibility", command.title))
                    .accessibilityHint(L("cheatsheet.copy.hint"))
                    .help(L("cheatsheet.copy.help"))
            }

            Text(command.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(command.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurfaceBackground(
                    RoundedRectangle(cornerRadius: 5),
                    legacyFill: Color(nsColor: .textBackgroundColor).opacity(0.7)
                )
                .accessibilityLabel(L("cheatsheet.command.accessibility", command.command))

            if let note = command.versionNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L("cheatsheet.versionNote.accessibility", note))
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheatsheet.row.\(command.id)")
    }
}

private struct CommandRiskLabel: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(risk.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(risk.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("cheatsheet.risk.help", risk.label))
    }
}
