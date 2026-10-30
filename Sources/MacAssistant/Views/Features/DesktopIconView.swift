import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

struct DesktopIconView: View {
    private enum BrowserSource: String, CaseIterable, Identifiable {
        case desktop
        case applications
        case folder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .desktop: return L("desktopicon.browser.desktop")
            case .applications: return L("desktopicon.browser.applications")
            case .folder: return L("desktopicon.browser.folder")
            }
        }
    }

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all, file, folder, application

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L("desktopicon.filter.all")
            case .file: return L("desktopicon.filter.file")
            case .folder: return L("desktopicon.filter.folder")
            case .application: return L("desktopicon.filter.application")
            }
        }
    }

    @State private var target: URL?
    @State private var iconImage: NSImage?
    @State private var iconSourceURL: URL?
    @State private var iconCopiedFromFile = false
    @State private var selectedPresetID: String?
    @State private var customColors: [DesktopIconCustomColor] = []
    @State private var editingCustomID: UUID?
    @State private var pickerRed = 0.31
    @State private var pickerGreen = 0.56
    @State private var pickerBlue = 0.83
    @State private var items: [DesktopIconItem] = []
    @State private var history: [DesktopIconHistoryRecord] = []
    @State private var browser: BrowserSource = .desktop
    @State private var folderRoot: URL?
    @State private var kindFilter: KindFilter = .all
    @State private var query = ""
    @State private var listingDenied = false
    @State private var listingError = ""
    @State private var statusText = ""
    @State private var statusOK: Bool?
    @State private var busy = false
    @State private var targetDropTargeted = false
    @State private var iconDropTargeted = false
    @State private var refreshTick = 0

    private var selectedItem: DesktopIconItem? {
        target.map(DesktopIconService.inspect)
    }

    private var filteredItems: [DesktopIconItem] {
        items.filter { item in
            switch kindFilter {
            case .all: break
            case .file: if item.kind != .file { return false }
            case .folder: if item.kind != .folder { return false }
            case .application: if item.kind != .application { return false }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return TextSearch.matches(item.name, needle: query)
                || TextSearch.matches(item.url.path, needle: query)
        }
    }

    private var canApply: Bool {
        guard !busy, iconImage != nil, let item = selectedItem else { return false }
        return item.canApplyInPlace
    }

    private var canRestore: Bool {
        guard !busy, let item = selectedItem else { return false }
        return item.canApplyInPlace
    }

    private var canMakeAlias: Bool {
        guard !busy, iconImage != nil, let item = selectedItem else { return false }
        return !item.isBlocked
    }

    var body: some View {
        FeatureScaffold(title: L("desktopicon.title"), subtitle: L("desktopicon.subtitle")) {
            PermissionGuideCard(needs: PermissionGuide.desktopIcons)
            statusCard
            editorCard
            presetCard
            browserCard
            if !history.isEmpty {
                historyCard
            }
            footnote
        } trailing: {
            Button {
                reloadBrowser()
                reloadHistory()
            } label: {
                Label(L("desktopicon.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(busy)
        }
        .task {
            reloadBrowser()
            reloadHistory()
            reloadCustomColors()
        }
        .onChange(of: browser) { _ in
            reloadBrowser()
        }
        .onDisappear {
            DesktopIconColorPanel.shared.handler = nil
        }
    }

    private var statusCard: some View {
        Group {
            if !statusText.isEmpty {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        if busy { ProgressView().controlSize(.small) }
                        StatusBadge(ok: statusOK)
                        Text(statusText)
                            .font(.footnote)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            statusText = ""
                            statusOK = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .accessibilityIdentifier("desktopicon.status")
            }
        }
    }

    private var editorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("desktopicon.editor.title")).font(.headline)

                HStack(alignment: .top, spacing: 14) {
                    targetWell
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .padding(.top, 36)
                    iconWell
                }

                if let item = selectedItem {
                    HStack(spacing: 8) {
                        Label(item.kind.label, systemImage: item.kind.systemImage)
                        if item.hasCustomIcon {
                            Label(L("desktopicon.badge.custom"), systemImage: "paintpalette")
                                .foregroundStyle(.orange)
                        }
                        if item.isBlocked {
                            Label(L("desktopicon.badge.protected"), systemImage: "lock.fill")
                                .foregroundStyle(.red)
                        } else if !item.isWritable {
                            Label(L("desktopicon.badge.readOnly"), systemImage: "pencil.slash")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if item.kind == .application {
                        Text(L("desktopicon.app.warning"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !item.isWritable && !item.isBlocked {
                        Text(L("desktopicon.readonly.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        applyInPlace()
                    } label: {
                        Label(L("desktopicon.apply"), systemImage: "paintbrush.pointed")
                    }
                    .disabled(!canApply)
                    .accessibilityIdentifier("desktopicon.apply")

                    Button {
                        makeDesktopAlias()
                    } label: {
                        Label(L("desktopicon.alias"), systemImage: "arrow.up.doc")
                    }
                    .disabled(!canMakeAlias)
                    .help(L("desktopicon.alias.help"))

                    Button {
                        restoreDefault()
                    } label: {
                        Label(L("desktopicon.restore"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!canRestore)

                    Button {
                        refreshDock()
                    } label: {
                        Label(L("desktopicon.refreshDock"), systemImage: "macwindow")
                    }
                    .disabled(busy)
                    .help(L("desktopicon.refreshDock.help"))

                    if let target {
                        Button {
                            revealInFinder(target)
                        } label: {
                            Label(L("desktopicon.reveal"), systemImage: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var targetWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("desktopicon.target.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            dropWell(
                targeted: targetDropTargeted,
                hasPreview: target != nil,
                systemImage: "shippingbox",
                title: L("desktopicon.target.drop"),
                detail: L("desktopicon.target.drop.hint")
            ) {
                if let target {
                    Image(nsImage: DesktopIconService.currentIcon(for: target))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    PathBadge(url: target, isDropTargeted: targetDropTargeted, showsDropChrome: false)
                }
            }
            .fileURLDropTarget(isTargeted: $targetDropTargeted, onDrop: selectTarget)
            .onTapGesture { pickTarget() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("desktopicon.target.title"))
            .accessibilityIdentifier("desktopicon.target")

            HStack {
                Button(L("desktopicon.chooseTarget")) { pickTarget() }
                    .filePickerDrop { urls in
                        if let url = urls.first { selectTarget(url) }
                    }
                if target != nil {
                    Button(L("desktopicon.clear")) {
                        target = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("desktopicon.icon.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            dropWell(
                targeted: iconDropTargeted,
                hasPreview: iconImage != nil,
                systemImage: "photo",
                title: L("desktopicon.icon.drop"),
                detail: L("desktopicon.icon.drop.hint")
            ) {
                if let iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                    if let iconSourceURL {
                        PathBadge(url: iconSourceURL, isDropTargeted: iconDropTargeted, showsDropChrome: false)
                    } else if let selectedPresetID,
                              let preset = DesktopIconPresets.preset(id: selectedPresetID, customs: customColors) {
                        Text(L("desktopicon.preset.selected", preset.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(iconCopiedFromFile ? L("desktopicon.icon.copied") : L("desktopicon.icon.clipboard"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fileURLDropTarget(isTargeted: $iconDropTargeted, onDrop: selectIconSource)
            .onTapGesture { pickIcon() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("desktopicon.icon.title"))
            .accessibilityIdentifier("desktopicon.icon")

            HStack {
                FilePickerButton(
                    title: L("desktopicon.chooseImage"),
                    systemImage: "photo",
                    types: [.image, .png, .jpeg, .tiff, .gif, UTType(filenameExtension: "icns") ?? .data]
                ) { url in
                    selectIconSource(url)
                }
                Button(L("desktopicon.paste")) { pasteIcon() }
                if iconImage != nil {
                    Button(L("desktopicon.clear")) {
                        clearIcon()
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let iconImage {
                let size = DesktopIconService.pixelSize(of: iconImage)
                let longest = max(size.width, size.height)
                Text(
                    longest < CGFloat(DesktopIconService.recommendedPixelSize)
                        ? L("desktopicon.icon.small", Int(size.width), Int(size.height))
                        : L("desktopicon.icon.size", Int(size.width), Int(size.height))
                )
                .font(.caption2)
                .foregroundStyle(longest < CGFloat(DesktopIconService.recommendedPixelSize) ? .orange : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("desktopicon.preset.title")).font(.headline)
                    Text(L("desktopicon.preset.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(L("desktopicon.preset.ai"))
                    .font(.subheadline.weight(.semibold))
                Text(L("desktopicon.preset.ai.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Self.presetColumns, spacing: 10) {
                    ForEach(DesktopIconPresets.ai) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                }

                Text(L("desktopicon.preset.costume"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                Text(L("desktopicon.preset.costume.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(ProductLinks.moonvyFolderDressing)
                } label: {
                    HStack(spacing: 4) {
                        Text(L("desktopicon.preset.costume.credit"))
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("desktopicon.preset.costume.credit")
                LazyVGrid(columns: Self.presetColumns, spacing: 10) {
                    ForEach(DesktopIconPresets.costumes) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                }

                Text(L("desktopicon.preset.cute"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                Text(L("desktopicon.preset.cute.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Self.presetColumns, spacing: 10) {
                    ForEach(DesktopIconPresets.cute) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                }

                Text(L("desktopicon.preset.colors"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                LazyVGrid(columns: Self.presetColumns, spacing: 8) {
                    ForEach(DesktopIconPresets.colors) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                    ForEach(customColors) { color in
                        presetButton(color.preset, showsTitle: false, reservesTitle: true)
                    }
                    customColorButton
                }

                Text(L("desktopicon.preset.types"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                LazyVGrid(columns: Self.presetColumns, spacing: 10) {
                    ForEach(DesktopIconPresets.types) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                }

                Text(L("desktopicon.preset.software"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                Text(L("desktopicon.preset.software.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Self.presetColumns, spacing: 10) {
                    ForEach(DesktopIconPresets.software) { preset in
                        presetButton(preset, showsTitle: true)
                    }
                }
            }
        }
    }

    private static let presetFolderSize: CGFloat = 48
    private static let presetColumns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    private func presetButton(_ preset: DesktopIconPreset, showsTitle: Bool, reservesTitle: Bool = false) -> some View {
        let selected = selectedPresetID == preset.id
        return Button {
            editingCustomID = nil
            selectPreset(preset)
        } label: {
            presetLabel(
                preset,
                title: showsTitle ? preset.title : nil,
                reservesTitle: reservesTitle,
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .help(preset.title)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("desktopicon.preset.\(preset.id)")
    }

    private var customColorButton: some View {
        let preset = DesktopIconPresets.customPicker(red: pickerRed, green: pickerGreen, blue: pickerBlue)
        let selected = editingCustomID != nil || selectedPresetID == preset.id
        return Button {
            openCustomColorPicker()
        } label: {
            presetLabel(preset, title: L("desktopicon.preset.color.custom"), reservesTitle: true, selected: selected)
        }
        .buttonStyle(.plain)
        .help(L("desktopicon.preset.color.custom.help"))
        .accessibilityLabel(L("desktopicon.preset.color.custom"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("desktopicon.preset.color.custom")
    }

    private func presetLabel(_ preset: DesktopIconPreset, title: String?, reservesTitle: Bool, selected: Bool) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: DesktopIconPresets.image(for: preset, pixelSize: 128))
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .frame(width: Self.presetFolderSize, height: Self.presetFolderSize)
            if let title {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.appAccent : .secondary)
                    .lineLimit(1)
            } else if reservesTitle {
                Text(" ")
                    .font(.caption2)
                    .hidden()
            }
        }
        .frame(minWidth: 68, maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.appAccent.opacity(0.12) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.appAccent.opacity(0.35) : Color.clear, lineWidth: 1)
        }
    }

    private var browserCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("desktopicon.browser.title")).font(.headline)
                    Spacer()
                    Picker("", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }

                HStack {
                    ForEach(BrowserSource.allCases) { source in
                        Button {
                            if source == .folder {
                                pickBrowserFolder()
                            } else {
                                browser = source
                            }
                        } label: {
                            Text(source.title)
                        }
                        .buttonStyle(.bordered)
                        .tint(browser == source ? Color.appAccent : Color.secondary)
                    }
                    if browser == .folder, let folderRoot {
                        PathBadge(url: folderRoot)
                    }
                }

                TextField(L("desktopicon.search"), text: $query)
                    .textFieldStyle(.soft)

                if listingDenied {
                    Text(L("desktopicon.listing.denied"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("desktopicon.listing.grant")) {
                        pickBrowserFolder(startingAtDesktop: true)
                    }
                } else if !listingError.isEmpty {
                    Text(listingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if filteredItems.isEmpty {
                    Text(L("desktopicon.browser.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredItems) { item in
                                browserRow(item)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    Text(L("desktopicon.browser.count", filteredItems.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("desktopicon.history.title")).font(.headline)
                Text(L("desktopicon.history.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(history) { record in
                    HStack(spacing: 10) {
                        if let name = record.imageFileName,
                           let image = DesktopIconService.historyImage(named: name) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: record.kind.systemImage)
                                .frame(width: 28, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).font(.callout.weight(.medium))
                            Text(record.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button(L("desktopicon.history.reapply")) {
                            reapply(record)
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy || DesktopIconService.historyImage(named: record.imageFileName ?? "") == nil)
                        Button(L("desktopicon.restore")) {
                            restoreHistory(record)
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text(L("desktopicon.footnote"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func dropWell<Preview: View>(
        targeted: Bool,
        hasPreview: Bool,
        systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        VStack(spacing: 8) {
            if hasPreview {
                preview()
            } else {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 148)
        .foregroundStyle(targeted ? Color.accentColor : .primary)
        .contentShape(Rectangle())
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 12),
            legacyFill: Color.primary.opacity(targeted ? 0.10 : 0.04)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7])
                )
        }
    }

    private func browserRow(_ item: DesktopIconItem) -> some View {
        let selected = target?.standardizedFileURL == item.url
        return Button {
            target = item.url
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: DesktopIconService.currentIcon(for: item.url))
                    .resizable()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(item.kind.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if item.hasCustomIcon {
                    Image(systemName: "paintpalette.fill")
                        .foregroundStyle(.orange)
                        .help(L("desktopicon.badge.custom"))
                }
                if item.isBlocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.appAccent.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
        .id("\(item.id)-\(refreshTick)")
    }

    private func pickTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L("desktopicon.pickTarget.message")
        if panel.runModal() == .OK, let url = panel.url {
            selectTarget(url)
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif, UTType(filenameExtension: "icns") ?? .data]
        panel.message = L("desktopicon.pickImage.message")
        if panel.runModal() == .OK, let url = panel.url {
            selectIconSource(url)
        }
    }

    private func pickBrowserFolder(startingAtDesktop: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if startingAtDesktop, let desktop = try? DesktopIconService.desktopDirectory() {
            panel.directoryURL = desktop
        }
        panel.message = L("desktopicon.pickFolder.message")
        if panel.runModal() == .OK, let url = panel.url {
            folderRoot = url
            browser = .folder
            reloadBrowser()
        }
    }

    private func selectTarget(_ url: URL) {
        target = url.standardizedFileURL
        listingError = ""
        do {
            try DesktopIconService.validateTarget(url)
        } catch {
            report(error, ok: false)
        }
    }

    private func selectIconSource(_ url: URL) {
        do {
            let copied = !DesktopIconService.isSupportedIconImage(url)
            iconImage = try DesktopIconService.iconArtwork(from: url)
            iconSourceURL = url.standardizedFileURL
            iconCopiedFromFile = copied
            selectedPresetID = nil
            editingCustomID = nil
            statusText = ""
            statusOK = nil
        } catch {
            report(error, ok: false)
        }
    }

    private func selectPreset(_ preset: DesktopIconPreset) {
        iconImage = DesktopIconPresets.image(for: preset, pixelSize: 1024)
        iconSourceURL = nil
        iconCopiedFromFile = false
        selectedPresetID = preset.id
        statusText = ""
        statusOK = nil
    }

    private func openCustomColorPicker() {
        if editingCustomID == nil {
            editingCustomID = UUID()
        }
        let initial = NSColor(srgbRed: pickerRed, green: pickerGreen, blue: pickerBlue, alpha: 1)
        DesktopIconColorPanel.shared.present(color: initial) { color in
            applyPickedColor(color)
        }
    }

    private func applyPickedColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        pickerRed = Double(rgb.redComponent)
        pickerGreen = Double(rgb.greenComponent)
        pickerBlue = Double(rgb.blueComponent)
        let custom = DesktopIconCustomColor(
            id: editingCustomID ?? UUID(),
            red: pickerRed,
            green: pickerGreen,
            blue: pickerBlue
        )
        editingCustomID = custom.id
        if let saved = try? DesktopIconCustomColorStore.upsert(custom) {
            editingCustomID = saved.id
            reloadCustomColors()
            selectPreset(saved.preset)
        } else {
            selectPreset(custom.preset)
        }
    }

    private func reloadCustomColors() {
        customColors = DesktopIconCustomColorStore.load()
    }

    private func clearIcon() {
        iconImage = nil
        iconSourceURL = nil
        iconCopiedFromFile = false
        selectedPresetID = nil
        editingCustomID = nil
    }

    private func pasteIcon() {
        guard let image = DesktopIconService.imageFromPasteboard() else {
            report(DesktopIconError.missingImage, ok: false)
            return
        }
        let size = DesktopIconService.pixelSize(of: image)
        if max(size.width, size.height) < CGFloat(DesktopIconService.hardMinimumPixelSize) {
            report(DesktopIconError.imageTooSmall, ok: false)
            return
        }
        iconImage = image
        iconSourceURL = nil
        iconCopiedFromFile = false
        selectedPresetID = nil
        editingCustomID = nil
        statusText = ""
        statusOK = nil
    }

    private func applyInPlace() {
        guard let target, let iconImage else { return }
        run(L("desktopicon.status.applying")) {
            try DesktopIconService.applyIcon(iconImage, to: target)
            try remember(target, image: iconImage)
            return (L("desktopicon.status.applied", target.lastPathComponent), target)
        }
    }

    private func makeDesktopAlias() {
        guard let target, let iconImage else { return }
        run(L("desktopicon.status.aliasing")) {
            let alias = try DesktopIconService.createDesktopAlias(to: target)
            try DesktopIconService.applyIcon(iconImage, to: alias)
            try remember(alias, image: iconImage)
            return (L("desktopicon.status.aliased", alias.lastPathComponent), alias)
        }
    }

    private func restoreDefault() {
        guard let target else { return }
        run(L("desktopicon.status.restoring")) {
            try DesktopIconService.restoreDefaultIcon(at: target)
            return (L("desktopicon.status.restored", target.lastPathComponent), target)
        }
    }

    private func restoreHistory(_ record: DesktopIconHistoryRecord) {
        run(L("desktopicon.status.restoring")) {
            try DesktopIconService.restoreDefaultIcon(at: record.url)
            try DesktopIconService.removeHistory(id: record.id)
            return (L("desktopicon.status.restored", record.name), record.url)
        }
    }

    private func reapply(_ record: DesktopIconHistoryRecord) {
        guard let name = record.imageFileName,
              let image = DesktopIconService.historyImage(named: name)
        else { return }
        iconImage = image
        iconSourceURL = nil
        iconCopiedFromFile = false
        selectedPresetID = nil
        editingCustomID = nil
        target = record.url
        applyInPlace()
    }

    private func refreshDock() {
        DesktopIconService.refreshDock()
        statusOK = true
        statusText = L("desktopicon.status.dock")
    }

    private func remember(_ url: URL, image: NSImage) throws {
        let item = DesktopIconService.inspect(url)
        let id = UUID()
        let fileName = try? DesktopIconService.saveHistoryImage(image, id: id)
        try DesktopIconService.recordHistory(item: item, id: id, imageFileName: fileName)
    }

    private func run(_ pending: String, _ work: @escaping () throws -> (String, URL?)) {
        busy = true
        statusOK = nil
        statusText = pending
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                await MainActor.run {
                    statusOK = true
                    statusText = result.0
                    if let next = result.1 {
                        target = next
                    }
                    busy = false
                    refreshTick += 1
                    reloadBrowser()
                    reloadHistory()
                }
            } catch {
                await MainActor.run {
                    report(error, ok: false)
                    busy = false
                }
            }
        }
    }

    private func reloadBrowser() {
        listingDenied = false
        listingError = ""
        do {
            switch browser {
            case .desktop:
                items = try DesktopIconService.listDesktopItems()
            case .applications:
                items = DesktopIconService.listApplications()
            case .folder:
                guard let folderRoot else {
                    items = []
                    return
                }
                items = try DesktopIconService.listItems(in: folderRoot)
            }
        } catch DesktopIconError.listingDenied {
            items = []
            listingDenied = true
        } catch {
            items = []
            listingError = error.localizedDescription
        }
    }

    private func reloadHistory() {
        history = DesktopIconService.loadHistory()
    }

    private func report(_ error: Error, ok: Bool?) {
        statusOK = ok
        if FileSystemHelper.isAccessPermissionError(error), let target {
            statusText = FileSystemHelper.userFacingAccessError(error, paths: [target])
        } else {
            statusText = error.localizedDescription
        }
    }
}

private final class DesktopIconColorPanel: NSObject {
    static let shared = DesktopIconColorPanel()
    var handler: ((NSColor) -> Void)?

    func present(color: NSColor, handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        handler?(sender.color)
    }
}
