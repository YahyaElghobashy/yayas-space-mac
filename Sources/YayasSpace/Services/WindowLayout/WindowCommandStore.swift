// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Combine
import Foundation

/// The live command sets. One instance serves the whole app; every edit goes
/// through here, is saved at once as versioned JSON and announced to the
/// engine so shortcuts and drag areas follow without a relaunch.
final class WindowCommandStore: ObservableObject {
    static let shared = WindowCommandStore(defaults: .standard) { key in
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: domain)?[key]
    }

    @Published private(set) var configuration: WindowCommandConfiguration

    private let defaults: UserDefaults

    /// `persistentValue` answers what the person saved for a key, never a
    /// registered default: migration needs to tell the two apart.
    init(defaults: UserDefaults, persistentValue: (String) -> Any?) {
        self.defaults = defaults
        let loaded = WindowCommandPersistence.loadOrMigrate(from: defaults,
                                                            persistentValue: persistentValue)
        configuration = loaded.configuration
        if loaded.migrated {
            WindowCommandPersistence.save(configuration, to: defaults)
            Self.migrateMargins(in: defaults)
        }
        foldLegacyZonesIfNeeded()
    }

    // MARK: Reading

    func commands(_ kind: WindowCommandSetKind) -> [WindowCommand] {
        configuration[kind]
    }

    func command(id: UUID) -> (kind: WindowCommandSetKind, command: WindowCommand)? {
        configuration.command(id: id)
    }

    /// The shortcut the surfaces that list built-ins (the panel grid, the
    /// command bar) print next to one: the shortcut of the user's command
    /// that picking it runs, when every connected kind of display agrees.
    func shortcut(for action: WindowLayoutAction,
                  displayKinds: Set<WindowCommandSetKind>) -> GlobalShortcut? {
        WindowCommandRouting.labelShortcut(for: action, in: configuration, displayKinds: displayKinds)
    }

    // MARK: Editing

    func update(_ command: WindowCommand, in kind: WindowCommandSetKind) {
        var set = configuration[kind]
        guard let index = set.firstIndex(where: { $0.id == command.id }) else { return }
        guard set[index] != command else { return }
        set[index] = command
        commit(set, in: kind)
    }

    /// Adds a separator beside a command where it divides two groups:
    /// after it, or before it when after would leave the separator at the
    /// end or next to another one. Returns its id, or nil when there is no
    /// such place (an empty set, or one command).
    @discardableResult
    func insertSeparator(in kind: WindowCommandSetKind, near id: UUID?) -> UUID? {
        var set = configuration[kind]
        guard let index = WindowCommandListEditing.separatorInsertionIndex(in: set, near: id) else { return nil }
        let separator = WindowCommand.separator()
        set.insert(separator, at: index)
        commit(set, in: kind)
        return separator.id
    }

    /// Inserts after the given command, or at the end.
    func insert(_ command: WindowCommand, in kind: WindowCommandSetKind, after id: UUID?) {
        var set = configuration[kind]
        if let id, let index = set.firstIndex(where: { $0.id == id }) {
            set.insert(command, at: index + 1)
        } else {
            set.append(command)
        }
        commit(set, in: kind)
    }

    func remove(_ id: UUID, in kind: WindowCommandSetKind) {
        var set = configuration[kind]
        set.removeAll { $0.id == id }
        commit(set, in: kind)
    }

    /// Moves a command to the slot another one occupies, the way the list's
    /// drag and drop reorders.
    func move(_ id: UUID, to targetID: UUID, in kind: WindowCommandSetKind) {
        var set = configuration[kind]
        guard id != targetID,
              let from = set.firstIndex(where: { $0.id == id }),
              let to = set.firstIndex(where: { $0.id == targetID }) else { return }
        // Removing first shifts everything after it up by one, so inserting at
        // the target's old index lands after it when moving down and before
        // it when moving up: either way the command takes the target's slot.
        let command = set.remove(at: from)
        set.insert(command, at: to)
        commitMove(of: command, in: set, kind: kind)
    }

    func move(_ id: UUID, by offset: Int, in kind: WindowCommandSetKind) {
        var set = configuration[kind]
        guard let from = set.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), set.count - 1)
        guard to != from else { return }
        let command = set.remove(at: from)
        set.insert(command, at: to)
        commitMove(of: command, in: set, kind: kind)
    }

    /// A separator never moves to a place where it would divide nothing
    /// (an end of the list, or beside another separator): the move is
    /// refused rather than the separator dropped. A command that leaves its
    /// group empty takes the group's spare separator with it.
    private func commitMove(of command: WindowCommand, in set: [WindowCommand], kind: WindowCommandSetKind) {
        if command.isSeparator,
           !WindowCommandPersistence.sanitized(set).contains(where: { $0.id == command.id }) {
            return
        }
        commit(set, in: kind)
    }

    func resetToDefaults(_ kind: WindowCommandSetKind) {
        commit(WindowCommandDefaults.commands(for: kind), in: kind)
    }

    func replaceConfiguration(_ configuration: WindowCommandConfiguration) {
        let cleaned = WindowCommandConfiguration(
            horizontal: WindowCommandPersistence.sanitized(configuration.horizontal),
            vertical: WindowCommandPersistence.sanitized(configuration.vertical))
        guard cleaned != self.configuration else { return }
        self.configuration = cleaned
        persist()
    }

    /// Visual zones switched off in the earlier fixed picker, arriving with an
    /// old settings backup, become switched-off drag areas; the old
    /// preference is then cleared so it can never block snapping for good.
    func foldLegacyZonesIfNeeded() {
        let raw = defaults.string(forKey: DefaultsKey.windowEdgeSnapDisabledZones) ?? ""
        guard !raw.isEmpty else { return }
        let zones = WindowEdgeSnapZone.disabledZones(from: raw)
        var updated = configuration
        for kind in WindowCommandSetKind.allCases {
            updated[kind] = updated[kind].map { command in
                var command = command
                if let zone = command.activation?.legacyZone, zones.contains(zone) {
                    command.activationEnabled = false
                }
                return command
            }
        }
        defaults.set("", forKey: DefaultsKey.windowEdgeSnapDisabledZones)
        if updated != configuration {
            configuration = updated
            persist()
        }
    }

    /// Every edit leaves the list exactly as a later launch reads it back:
    /// unique ids, and no doubled, leading or trailing separators. What the
    /// list shows after an edit is what it shows after a relaunch.
    private func commit(_ set: [WindowCommand], in kind: WindowCommandSetKind) {
        var updated = configuration
        updated[kind] = WindowCommandPersistence.sanitized(set)
        guard updated != configuration else { return }
        configuration = updated
        persist()
    }

    private func persist() {
        WindowCommandPersistence.save(configuration, to: defaults)
    }

    /// The earlier gap pickers kept a window gap and a screen gap that could
    /// differ, while the command model has one margin and a "fit tightly"
    /// switch. The margin becomes the window gap when there is one, else the
    /// screen gap; a zero screen gap beside a window gap is fitting tightly.
    /// Both gaps are then stored to match, so the margin Settings shows is
    /// the one windows get.
    static func migrateMargins(in defaults: UserDefaults) {
        let legacy = WindowCommandGeometry.normalizedLegacyGaps(
            windowGap: defaults.integer(forKey: DefaultsKey.windowLayoutWindowGap),
            screenGap: defaults.integer(forKey: DefaultsKey.windowLayoutScreenGap))
        if legacy.fitTightly {
            defaults.set(true, forKey: DefaultsKey.windowLayoutFitTightly)
        }
        if defaults.integer(forKey: DefaultsKey.windowLayoutWindowGap) != legacy.windowGap {
            defaults.set(legacy.windowGap, forKey: DefaultsKey.windowLayoutWindowGap)
        }
        if defaults.integer(forKey: DefaultsKey.windowLayoutScreenGap) != legacy.screenGap {
            defaults.set(legacy.screenGap, forKey: DefaultsKey.windowLayoutScreenGap)
        }
    }
}
