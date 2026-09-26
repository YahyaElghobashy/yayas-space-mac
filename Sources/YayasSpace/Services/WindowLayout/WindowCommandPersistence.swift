// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Foundation

/// The command sets as versioned JSON, stored in one preference and carried
/// inside the sync file. Reading is lenient on purpose: a command of a kind a
/// later version added is skipped instead of losing the whole set, and
/// anything out of range is pulled back into the grid.
enum WindowCommandPersistence {
    /// Decodes a stored document. Nil when it is empty, unreadable, or holds
    /// no usable set at all.
    static func decode(_ string: String) -> WindowCommandConfiguration? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> WindowCommandConfiguration? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return configuration(from: object)
    }

    static func encode(_ configuration: WindowCommandConfiguration) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject(for: configuration),
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    // MARK: JSON objects

    static func jsonObject(for configuration: WindowCommandConfiguration) -> [String: Any] {
        [
            "version": WindowCommandConfiguration.currentVersion,
            "horizontal": configuration.horizontal.map(jsonObject(for:)),
            "vertical": configuration.vertical.map(jsonObject(for:)),
        ]
    }

    static func configuration(from object: [String: Any]) -> WindowCommandConfiguration? {
        guard object["horizontal"] != nil || object["vertical"] != nil else { return nil }
        func set(_ key: String, _ kind: WindowCommandSetKind) -> [WindowCommand] {
            let raw = object[key] as? [[String: Any]] ?? []
            return sanitized(raw.compactMap { command(from: $0, grid: kind.grid) })
        }
        // A set missing from the document falls back to its defaults, so a
        // file written by hand with one set still gives a working other one.
        let horizontal = object["horizontal"] != nil
            ? set("horizontal", .horizontal) : WindowCommandDefaults.commands(for: .horizontal)
        let vertical = object["vertical"] != nil
            ? set("vertical", .vertical) : WindowCommandDefaults.commands(for: .vertical)
        return WindowCommandConfiguration(horizontal: horizontal, vertical: vertical)
    }

    static func jsonObject(for command: WindowCommand) -> [String: Any] {
        var object: [String: Any] = [
            "id": command.id.uuidString,
            "type": command.kind.storageName,
        ]
        if command.isSeparator { return object }
        if case .area(let rect) = command.kind {
            object["rect"] = [rect.x, rect.y, rect.width, rect.height]
        }
        if let builtin = command.builtinID { object["builtin"] = builtin.rawValue }
        if let name = command.customName { object["name"] = name }
        if let shortcut = command.shortcut { object["shortcut"] = shortcut.storageValue }
        object["shortcutEnabled"] = command.shortcutEnabled
        if let activation = command.activation { object["activation"] = jsonObject(for: activation) }
        object["activationEnabled"] = command.activationEnabled
        object["menuBar"] = command.showInMenuBar
        object["greenButton"] = command.showInGreenButtonMenu
        return object
    }

    static func command(from object: [String: Any], grid: WindowGrid) -> WindowCommand? {
        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        guard let type = object["type"] as? String else { return nil }
        let kind: WindowCommandKind
        switch type {
        case "separator": return .separator(id: id)
        case "area":
            guard let rect = gridRect(from: object["rect"]) else { return nil }
            kind = .area(rect.clamped(to: grid))
        case "maximize": kind = .maximize
        case "marginMaximize": kind = .marginMaximize
        case "fullScreen": kind = .fullScreen
        case "center": kind = .center
        case "restore": kind = .restore
        case "nextDisplay": kind = .nextDisplay
        case "previousDisplay": kind = .previousDisplay
        default: return nil
        }
        let builtin = (object["builtin"] as? String).flatMap(WindowLayoutAction.init(rawValue:))
        let shortcut = (object["shortcut"] as? String).flatMap(GlobalShortcut.init(storageValue:))
        let activation = (object["activation"] as? [String: Any])
            .flatMap { activationRegion(from: $0) }?
            .sanitized(in: grid)
        let name = (object["name"] as? String).map { String($0.prefix(80)) }
        return WindowCommand(id: id,
                             kind: kind,
                             builtinID: builtin,
                             name: name,
                             shortcut: shortcut,
                             shortcutEnabled: (object["shortcutEnabled"] as? Bool ?? true) && shortcut != nil,
                             activation: activation,
                             activationEnabled: (object["activationEnabled"] as? Bool ?? true) && activation != nil,
                             showInMenuBar: object["menuBar"] as? Bool ?? true,
                             showInGreenButtonMenu: object["greenButton"] as? Bool ?? true)
    }

    static func jsonObject(for region: WindowActivationRegion) -> [String: Any] {
        switch region {
        case .edge(let edge, let start, let end):
            return ["edge": edge.rawValue, "start": start, "end": end]
        case .corner(let corner):
            return ["corner": corner.rawValue]
        case .interior(let rect):
            return ["rect": [rect.x, rect.y, rect.width, rect.height]]
        }
    }

    static func activationRegion(from object: [String: Any]) -> WindowActivationRegion? {
        if let raw = object["edge"] as? String, let edge = WindowScreenEdge(rawValue: raw),
           let start = integer(object["start"]), let end = integer(object["end"]) {
            return .edge(edge, start: start, end: end)
        }
        if let raw = object["corner"] as? String, let corner = WindowScreenCorner(rawValue: raw) {
            return .corner(corner)
        }
        if let rect = gridRect(from: object["rect"]) {
            return .interior(rect)
        }
        return nil
    }

    private static func gridRect(from value: Any?) -> GridRect? {
        guard let values = value as? [Any], values.count == 4 else { return nil }
        let numbers = values.compactMap(integer)
        guard numbers.count == 4 else { return nil }
        return GridRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }

    /// Unique ids and no doubled or dangling separators, whatever the source.
    static func sanitized(_ commands: [WindowCommand]) -> [WindowCommand] {
        var seen = Set<UUID>()
        var result: [WindowCommand] = []
        for var command in commands {
            if !seen.insert(command.id).inserted {
                command.id = UUID()
                seen.insert(command.id)
            }
            if command.isSeparator, result.last?.isSeparator ?? true { continue }
            result.append(command)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }

    // MARK: Preferences

    /// The stored sets, or nil when nothing usable is stored yet.
    static func load(from defaults: UserDefaults) -> WindowCommandConfiguration? {
        decode(defaults.string(forKey: DefaultsKey.windowLayoutCommands) ?? "")
    }

    static func save(_ configuration: WindowCommandConfiguration, to defaults: UserDefaults) {
        defaults.set(encode(configuration), forKey: DefaultsKey.windowLayoutCommands)
    }

    /// The stored sets, or the migrated defaults when this is the first run
    /// of the command model. `persistentValue` reads only what the person
    /// actually saved (never a registered default), which is what tells a
    /// deliberate legacy shortcut from one that was simply never touched.
    static func loadOrMigrate(from defaults: UserDefaults,
                              persistentValue: (String) -> Any?) -> (configuration: WindowCommandConfiguration,
                                                                     migrated: Bool) {
        if let stored = load(from: defaults) { return (stored, false) }
        let zones = WindowEdgeSnapZone.disabledZones(
            from: persistentValue(DefaultsKey.windowEdgeSnapDisabledZones) as? String)
        let configuration = WindowCommandMigration.configuration(
            legacyShortcut: { persistentValue($0) as? String },
            disabledZones: zones)
        return (configuration, true)
    }

    private static var dragAreaCache: (source: String, value: Bool)?
    private static let dragAreaCacheLock = NSLock()

    /// Whether drag snapping has anything to listen for, read straight from
    /// the preference so the energy and permission summaries can ask
    /// without the live store. Nothing stored yet means the default sets,
    /// which have drag areas. Cached per stored value: decoding is cheap but
    /// the summaries ask often.
    static func hasEnabledDragAreas(in defaults: UserDefaults) -> Bool {
        let stored = defaults.string(forKey: DefaultsKey.windowLayoutCommands) ?? ""
        if let cached = (dragAreaCacheLock.withLock { dragAreaCache }), cached.source == stored {
            return cached.value
        }
        let value = (decode(stored) ?? .defaults).hasEnabledActivation
        dragAreaCacheLock.withLock { dragAreaCache = (stored, value) }
        return value
    }
}
