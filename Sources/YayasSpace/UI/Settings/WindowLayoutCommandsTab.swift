// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Commands tab: the set switcher and + menu over a reorderable list on the
/// left, the selected command's editor on the right.
struct WindowLayoutCommandsTab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var store = WindowCommandStore.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var selectionModel = WindowCommandSelection.shared
    @AppStorage(DefaultsKey.windowLayoutShortcutsEnabled) private var shortcutsEnabled = false
    @AppStorage(DefaultsKey.windowEdgeSnapEnabled) private var snapEnabled = false
    @State private var dragging: UUID?
    @State private var hovered: UUID?
    @State private var confirmingReset = false
    @State private var shortcutError: String?
    @State private var isRecording = false

    private var text: WindowCommandStrings { .localized(l10n.language) }
    private var kind: WindowCommandSetKind { selectionModel.kind }
    private var commands: [WindowCommand] { store.commands(kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            listColumn
                .frame(width: 226)
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .onAppear(perform: ensureSelection)
        .onChange(of: selectionModel.kind) { _, _ in
            shortcutError = nil
            ensureSelection()
        }
        .onChange(of: store.configuration) { _, _ in ensureSelection() }
        .alert(String(format: text.resetSetTitleFormat, setName(kind)), isPresented: $confirmingReset) {
            Button(text.reset, role: .destructive) {
                store.resetToDefaults(kind)
                selectionModel.select(nil, in: kind)
                ensureSelection()
            }
            Button(text.cancel, role: .cancel) {}
        } message: {
            Text(text.resetSetMessage)
        }
    }

    // MARK: List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $selectionModel.kind) {
                    Text(text.setHorizontal).tag(WindowCommandSetKind.horizontal)
                    Text(text.setVertical).tag(WindowCommandSetKind.vertical)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                addMenu
            }
            Text(kind == .horizontal ? text.setHorizontalCaption : text.setVerticalCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(commands) { command in
                        row(command)
                    }
                }
                .padding(6)
            }
            .background(WindowLayoutCardStyle.background)
            .overlay(WindowLayoutCardStyle.border)
        }
    }

    private var addMenu: some View {
        Menu {
            Button(text.addCustom, action: addCustom)
            Button(text.addSeparator, action: addSeparator)
            Menu(text.addBuiltin) {
                ForEach(missingBuiltins, id: \.self) { action in
                    Button {
                        addBuiltin(action)
                    } label: {
                        Label {
                            Text(WindowCommandStrings.builtinName(action, language: l10n.language))
                        } icon: {
                            Image(nsImage: glyphImage(for: action))
                        }
                    }
                }
            }
            .disabled(missingBuiltins.isEmpty)
            Divider()
            Button(String(format: text.resetSetFormat, setName(kind))) { confirmingReset = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(text.add)
        .accessibilityLabel(text.add)
    }

    private func row(_ command: WindowCommand) -> some View {
        let selected = selectionModel.selected(in: kind) == command.id
        let showsControls = selected || hovered == command.id
        return HStack(spacing: 8) {
            if command.isSeparator {
                Rectangle()
                    .fill(Color.secondary.opacity(selected ? 0.9 : 0.35))
                    .frame(height: 1)
                    .padding(.leading, 4)
            } else {
                WindowCommandGlyphView(kind: command.kind, grid: kind.grid,
                                       size: CGSize(width: 26, height: 17),
                                       style: selected ? .onAccent : .accent)
                Text(WindowCommandStrings.displayName(of: command, language: l10n.language))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            Spacer(minLength: 4)
            if showsControls {
                rowControls(command, selected: selected)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: command.isSeparator ? 18 : 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor
                      : (hovered == command.id ? Color.primary.opacity(0.06) : Color.clear))
        )
        .opacity(dragging == command.id ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            shortcutError = nil
            selectionModel.select(command.id, in: kind)
        }
        .onHover { inside in
            if inside { hovered = command.id } else if hovered == command.id { hovered = nil }
        }
        .onDrag {
            dragging = command.id
            return NSItemProvider(object: command.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: WindowCommandDropDelegate(target: command.id,
                                                                       kind: kind,
                                                                       dragging: $dragging))
        .contextMenu {
            Button(text.moveUp) { store.move(command.id, by: -1, in: kind) }
            Button(text.moveDown) { store.move(command.id, by: 1, in: kind) }
            Divider()
            Button(text.delete, role: .destructive) { delete(command) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func rowControls(_ command: WindowCommand, selected: Bool) -> some View {
        HStack(spacing: 4) {
            if !command.isSeparator {
                rowToggle(isOn: command.showInGreenButtonMenu, selected: selected,
                          help: text.inGreenButtonMenu) {
                    Circle()
                        .fill(command.showInGreenButtonMenu ? Color.green : Color.clear)
                        .overlay(Circle().strokeBorder(Color.green.opacity(0.9), lineWidth: 1.2))
                        .frame(width: 9, height: 9)
                } action: {
                    var updated = command
                    updated.showInGreenButtonMenu.toggle()
                    store.update(updated, in: kind)
                }
                rowToggle(isOn: command.showInMenuBar, selected: selected, help: text.inMenuBar) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                } action: {
                    var updated = command
                    updated.showInMenuBar.toggle()
                    store.update(updated, in: kind)
                }
            }
            Button {
                delete(command)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(text.delete)
            .accessibilityLabel(text.delete)
        }
    }

    private func rowToggle<Icon: View>(isOn: Bool, selected: Bool, help: String,
                                       @ViewBuilder icon: () -> Icon,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(selected ? Color.white : (isOn ? Color.accentColor : Color.secondary))
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? (selected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.14))
                              : Color.clear)
                )
                .opacity(isOn ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "1" : "0")
    }

    // MARK: Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectionModel.selected(in: kind),
           let command = commands.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailHeader(command)
                    if command.isSeparator {
                        WindowLayoutCard {
                            HStack {
                                Text(text.separator)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(text.delete, role: .destructive) { delete(command) }
                            }
                        }
                    } else {
                        targetCard(command)
                        shortcutCard(command)
                        dragAreaCard(command)
                        showCard(command)
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            Text(text.selectCommand)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The glyph and the command's name, editable in place: an empty name
    /// goes back to the built-in's own.
    private func detailHeader(_ command: WindowCommand) -> some View {
        HStack(spacing: 10) {
            if command.isSeparator {
                Text(text.separator)
                    .font(.title3.weight(.semibold))
            } else {
                WindowCommandGlyphView(kind: command.kind, grid: kind.grid,
                                       size: CGSize(width: 36, height: 24))
                TextField(WindowCommandStrings.displayName(of: WindowCommand(kind: command.kind,
                                                                            builtinID: command.builtinID),
                                                           language: l10n.language),
                          text: Binding(get: { command.name ?? "" },
                                        set: { value in
                                            var updated = current(command)
                                            updated.name = value.isEmpty ? nil : String(value.prefix(80))
                                            store.update(updated, in: kind)
                                        }))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .help(text.name)
                    .accessibilityLabel(text.name)
                Button(text.tryIt) {
                    WindowLayoutService.shared.apply(command, setKind: kind)
                }
                .controlSize(.small)
                .disabled(!permissions.accessibility)
            }
        }
    }

    @ViewBuilder
    private func targetCard(_ command: WindowCommand) -> some View {
        WindowLayoutCard(title: text.targetTitle) {
            if case .area = command.kind {
                WindowTargetGridEditor(grid: kind.grid,
                                       rect: Binding(get: { current(command).kind.gridRect ?? GridRect(x: 0, y: 0,
                                                                                                      width: 1,
                                                                                                      height: 1) },
                                                     set: { rect in
                                                         var updated = current(command)
                                                         updated.kind = .area(rect)
                                                         store.update(updated, in: kind)
                                                     }),
                                       maxHeight: kind == .horizontal ? 200 : 260)
                Text(text.targetCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let caption = text.caption(for: command.kind) {
                HStack(spacing: 12) {
                    WindowCommandGlyphView(kind: command.kind, grid: kind.grid,
                                           size: CGSize(width: 54, height: 34))
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutCard(_ command: WindowCommand) -> some View {
        WindowLayoutCard {
            WindowLayoutCardSwitch(title: text.shortcutTitle,
                                   isOn: Binding(get: { command.shortcutEnabled },
                                                 set: { value in
                                                     var updated = current(command)
                                                     updated.shortcutEnabled = value && updated.shortcut != nil
                                                     store.update(updated, in: kind)
                                                 }))
                .disabled(command.shortcut == nil)
            ShortcutRecorderButton(shortcut: command.shortcut ?? WindowCommandDefaults.maximize,
                                   isEnabled: true,
                                   waitingTitle: l10n.s.shortcutPressKeys,
                                   emptyTitle: command.shortcut == nil ? l10n.s.shortcutNone : nil,
                                   clearAction: { clearShortcut(command) },
                                   notCapturedAction: { shortcutError = l10n.s.shortcutNotCaptured },
                                   recordingChanged: { recording in
                                       isRecording = recording
                                       if recording { shortcutError = nil }
                                   },
                                   invalidAction: { shortcutError = l10n.s.shortcutInvalid },
                                   captureAction: { saveShortcut($0, for: command) })
                .frame(maxWidth: .infinity)
            if let shortcutError {
                Text(shortcutError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if isRecording {
                Text(ShortcutRecordingCaption.text(l10n.s, canClear: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !shortcutsEnabled {
                Text(text.shortcutsOffNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dragAreaCard(_ command: WindowCommand) -> some View {
        WindowLayoutCard {
            WindowLayoutCardSwitch(title: text.dragAreaTitle,
                                   isOn: Binding(get: { command.activationEnabled },
                                                 set: { value in
                                                     var updated = current(command)
                                                     updated.activationEnabled = value && updated.activation != nil
                                                     store.update(updated, in: kind)
                                                 }))
                .disabled(command.activation == nil)
            WindowActivationEditor(grid: kind.grid,
                                   region: Binding(get: { current(command).activation },
                                                   set: { region in
                                                       var updated = current(command)
                                                       updated.activation = region
                                                       updated.activationEnabled = region != nil
                                                       store.update(updated, in: kind)
                                                   }),
                                   otherRegions: commands.filter { $0.id != command.id }
                                       .compactMap(\.effectiveActivation),
                                   maxHeight: kind == .horizontal ? 190 : 250)
            HStack(alignment: .top) {
                Text(command.activation == nil ? text.dragAreaNone : text.dragAreaCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(text.clearDragArea) {
                    var updated = current(command)
                    updated.activation = nil
                    updated.activationEnabled = false
                    store.update(updated, in: kind)
                }
                .controlSize(.small)
                .disabled(command.activation == nil)
            }
            if !snapEnabled {
                Text(text.draggingOffNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func showCard(_ command: WindowCommand) -> some View {
        WindowLayoutCard(title: text.showTitle) {
            WindowLayoutCardSwitch(title: text.showInMenuBar,
                                   isOn: Binding(get: { command.showInMenuBar },
                                                 set: { value in
                                                     var updated = current(command)
                                                     updated.showInMenuBar = value
                                                     store.update(updated, in: kind)
                                                 }),
                                   isHeading: false)
            Divider()
            WindowLayoutCardSwitch(title: text.showInGreenButtonMenu,
                                   isOn: Binding(get: { command.showInGreenButtonMenu },
                                                 set: { value in
                                                     var updated = current(command)
                                                     updated.showInGreenButtonMenu = value
                                                     store.update(updated, in: kind)
                                                 }),
                                   isHeading: false)
        }
    }

    // MARK: Actions

    /// The stored version of a command, so an edit never works on a copy
    /// the view captured before another edit landed.
    private func current(_ command: WindowCommand) -> WindowCommand {
        store.commands(kind).first { $0.id == command.id } ?? command
    }

    private func saveShortcut(_ shortcut: GlobalShortcut, for command: WindowCommand) {
        shortcutError = WindowCommandShortcutEditing.save(shortcut, for: command, in: kind)
    }

    private func clearShortcut(_ command: WindowCommand) {
        shortcutError = nil
        WindowCommandShortcutEditing.set(nil, for: command, in: kind)
    }

    private func delete(_ command: WindowCommand) {
        let set = commands
        if let index = set.firstIndex(where: { $0.id == command.id }) {
            // Select a neighbour so the editor never goes blank.
            let neighbour = set.indices.contains(index + 1) ? set[index + 1] : (index > 0 ? set[index - 1] : nil)
            selectionModel.select(neighbour?.id, in: kind)
        }
        store.remove(command.id, in: kind)
    }

    private func addCustom() {
        let grid = kind.grid
        let rect = GridRect(x: grid.columns / 4, y: grid.rows / 4, width: grid.columns / 2, height: grid.rows / 2)
        let command = WindowCommand(kind: .area(rect),
                                    name: WindowCommandStrings.newCustomName(existing: commands,
                                                                            language: l10n.language),
                                    shortcutEnabled: false,
                                    activationEnabled: false)
        insert(command)
    }

    private func addSeparator() {
        insert(.separator())
    }

    private func addBuiltin(_ action: WindowLayoutAction) {
        guard let command = WindowCommandDefaults.builtinCommand(action, in: kind) else { return }
        insert(command)
    }

    private func insert(_ command: WindowCommand) {
        store.insert(command, in: kind, after: selectionModel.selected(in: kind))
        selectionModel.select(command.id, in: kind)
    }

    private var missingBuiltins: [WindowLayoutAction] {
        let present = Set(commands.compactMap(\.builtinID))
        return WindowCommandDefaults.offeredBuiltins.filter { !present.contains($0) }
    }

    private func glyphImage(for action: WindowLayoutAction) -> NSImage {
        let kind = WindowCommandDefaults.builtinCommand(action, in: self.kind)?.kind ?? .maximize
        return WindowCommandGlyph.image(for: kind, grid: self.kind.grid, size: NSSize(width: 21, height: 14))
    }

    private func setName(_ kind: WindowCommandSetKind) -> String {
        kind == .horizontal ? text.setHorizontal : text.setVertical
    }

    private func ensureSelection() {
        let set = commands
        if let id = selectionModel.selected(in: kind), set.contains(where: { $0.id == id }) { return }
        selectionModel.select(set.first(where: { !$0.isSeparator })?.id, in: kind)
    }
}

/// Recording a command's shortcut, shared by the Commands tab and the
/// central Shortcuts page so both refuse the same clashes.
enum WindowCommandShortcutEditing {
    /// Saves the combination, or returns why it cannot be used: another
    /// command of the same set, another Yaya's Space shortcut (switched on
    /// or not), the shortcut + pointer layout, or macOS itself.
    static func save(_ shortcut: GlobalShortcut,
                     for command: WindowCommand,
                     in kind: WindowCommandSetKind) -> String? {
        let language = L10n.shared.language
        let strings = L10n.shared.s
        let siblings = WindowCommandStore.shared.commands(kind)
        if let clash = WindowCommandShortcuts.conflictingCommand(for: shortcut, in: siblings, excluding: command.id) {
            return String(format: WindowCommandStrings.localized(language).conflictInSetFormat,
                          WindowCommandStrings.displayName(of: clash, language: language))
        }
        if let role = GlobalShortcutRole.conflict(for: shortcut, excluding: nil, includeInactive: true) {
            return String(format: strings.shortcutConflictFormat, role.title(strings))
        }
        if UserDefaults.standard.bool(forKey: DefaultsKey.windowDirectionalEnabled),
           GlobalShortcut(storageValue: UserDefaults.standard.string(forKey: DefaultsKey.windowDirectionalShortcut)
                          ?? "") == shortcut {
            return String(format: strings.shortcutConflictFormat, WindowDirectionalStrings.localized(language).title)
        }
        if shortcut.conflictsWithSystemShortcut {
            return String(format: strings.shortcutConflictFormat, "macOS")
        }
        Self.set(shortcut, for: command, in: kind)
        return nil
    }

    static func set(_ shortcut: GlobalShortcut?, for command: WindowCommand, in kind: WindowCommandSetKind) {
        let store = WindowCommandStore.shared
        guard var updated = store.commands(kind).first(where: { $0.id == command.id }) else { return }
        updated.shortcut = shortcut
        updated.shortcutEnabled = shortcut != nil
        store.update(updated, in: kind)
    }

    /// The combination a built-in command ships with in this set, if any.
    static func defaultShortcut(for command: WindowCommand, in kind: WindowCommandSetKind) -> GlobalShortcut? {
        guard let builtin = command.builtinID else { return nil }
        return WindowCommandDefaults.commands(for: kind).first { $0.builtinID == builtin }?.effectiveShortcut
    }
}

/// The selected set and command, kept across page switches.
final class WindowCommandSelection: ObservableObject {
    static let shared = WindowCommandSelection()

    @Published var kind: WindowCommandSetKind = .horizontal
    @Published private var selectedIDs: [WindowCommandSetKind: UUID] = [:]

    private init() {}

    func selected(in kind: WindowCommandSetKind) -> UUID? { selectedIDs[kind] }

    func select(_ id: UUID?, in kind: WindowCommandSetKind) {
        selectedIDs[kind] = id
    }
}

/// A title with a switch on the right, the way the page's rows read.
struct WindowLayoutCardSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var isHeading = true

    var body: some View {
        HStack {
            Text(title)
                .font(isHeading ? .headline : .body)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// A rounded group in the page's own style.
struct WindowLayoutCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowLayoutCardStyle.background)
        .overlay(WindowLayoutCardStyle.border)
    }
}

enum WindowLayoutCardStyle {
    static var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.04))
    }

    static var border: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08))
    }
}

private struct WindowCommandDropDelegate: DropDelegate {
    let target: UUID
    let kind: WindowCommandSetKind
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            WindowCommandStore.shared.move(dragging, to: target, in: kind)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
