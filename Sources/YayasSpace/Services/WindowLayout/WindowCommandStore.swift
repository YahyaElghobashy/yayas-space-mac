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

    /// Called after every change, on the thread that made it (main).
    var onChange: (() -> Void)?

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
            Self.migrateFitTightly(in: defaults)
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
        commit(set, in: kind)
    }

    func move(_ id: UUID, by offset: Int, in kind: WindowCommandSetKind) {
        var set = configuration[kind]
        guard let from = set.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), set.count - 1)
        guard to != from else { return }
        let command = set.remove(at: from)
        set.insert(command, at: to)
        commit(set, in: kind)
    }

    func resetToDefaults(_ kind: WindowCommandSetKind) {
        commit(WindowCommandDefaults.commands(for: kind), in: kind)
    }

    func replaceConfiguration(_ configuration: WindowCommandConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        persist()
    }

    /// Re-reads the stored sets after something else wrote them (an import
    /// through the settings backup).
    func reloadFromDefaults() {
        guard let stored = WindowCommandPersistence.load(from: defaults), stored != configuration else { return }
        configuration = stored
        onChange?()
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

    private func commit(_ set: [WindowCommand], in kind: WindowCommandSetKind) {
        var updated = configuration
        updated[kind] = set
        guard updated != configuration else { return }
        configuration = updated
        persist()
    }

    private func persist() {
        WindowCommandPersistence.save(configuration, to: defaults)
        onChange?()
    }

    /// The earlier gap pickers could leave the screen gap at zero with a
    /// window gap set, which is exactly "no space at screen edges".
    static func migrateFitTightly(in defaults: UserDefaults) {
        let windowGap = defaults.integer(forKey: DefaultsKey.windowLayoutWindowGap)
        let screenGap = defaults.integer(forKey: DefaultsKey.windowLayoutScreenGap)
        if windowGap > 0, screenGap == 0 {
            defaults.set(true, forKey: DefaultsKey.windowLayoutFitTightly)
        }
    }
}
