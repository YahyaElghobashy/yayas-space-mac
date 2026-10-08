// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Foundation

/// Window Layout settings as one JSON file: what Export writes, Import reads
/// and the sync folder keeps up to date. Real iCloud sync needs an
/// Apple-issued profile this self-signed app does not have, so syncing is a
/// plain file in a folder the person picks (iCloud Drive, Dropbox, a network
/// share); the folder's own client moves it between Macs. Nothing here
/// touches the network.
enum WindowLayoutSyncSupport {
    static let format = "yayasspace.window-layout"
    static let version = 1

    /// The file's name in the sync folder, and the name Export suggests.
    /// Fixed and never translated: two Macs set to different languages must
    /// still read and write the same file.
    static let fileName = "Yayas Space Window Layout.json"

    enum ValueType {
        case bool
        case integer
        case string
        case strings
    }

    /// Every preference the file carries, with the type it must have to be
    /// accepted on import.
    static let syncedKeys: [(key: String, type: ValueType)] = [
        (DefaultsKey.windowLayoutShortcutsEnabled, .bool),
        (DefaultsKey.windowEdgeSnapEnabled, .bool),
        (DefaultsKey.windowLayoutRestoreSizeOnDrag, .bool),
        (DefaultsKey.windowLayoutHighlightAreas, .bool),
        (DefaultsKey.windowLayoutInteriorAreaScale, .integer),
        (DefaultsKey.windowLayoutEdgeAreaWidth, .integer),
        (DefaultsKey.windowLayoutPreviewStyle, .string),
        (DefaultsKey.windowLayoutPreviewBorderWidth, .integer),
        (DefaultsKey.windowLayoutGreenButtonMenuEnabled, .bool),
        (DefaultsKey.windowLayoutGreenButtonDelay, .integer),
        (DefaultsKey.windowLayoutGreenButtonLayout, .string),
        (DefaultsKey.windowLayoutWindowGap, .integer),
        (DefaultsKey.windowLayoutScreenGap, .integer),
        (DefaultsKey.windowLayoutFitTightly, .bool),
        (DefaultsKey.windowLayoutIgnoredApps, .strings),
        (DefaultsKey.windowLayoutShowMenuBarItem, .bool),
        (DefaultsKey.windowGestureEnabled, .bool),
        (DefaultsKey.windowGestureModifiers, .string),
        (DefaultsKey.windowGestureRaiseWindow, .bool),
        (DefaultsKey.windowDirectionalEnabled, .bool),
        (DefaultsKey.windowDirectionalShortcut, .string),
        (DefaultsKey.panelUtilityWindowLayout, .bool),
        (DefaultsKey.windowLayoutHiddenActions, .string),
    ]

    /// The preferences whose changes count as a settings change: every
    /// synced key plus the command sets. The sync clock and folder are left
    /// out on purpose, or stamping a change would itself look like one.
    static var observedKeys: [String] {
        syncedKeys.map(\.key) + [DefaultsKey.windowLayoutCommands]
    }

    struct Document: Equatable {
        var modifiedAt: TimeInterval
        var device: String
        var settings: [String: SyncValue]
        var commands: WindowCommandConfiguration?
    }

    /// A preference value in a form that compares cleanly.
    enum SyncValue: Equatable {
        case bool(Bool)
        case integer(Int)
        case string(String)
        case strings([String])

        var propertyListValue: Any {
            switch self {
            case .bool(let value): return value
            case .integer(let value): return value
            case .string(let value): return value
            case .strings(let value): return value
            }
        }

        init?(_ value: Any?, as type: ValueType) {
            switch type {
            case .bool:
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                self = .bool(number.boolValue)
            case .integer:
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                self = .integer(number.intValue)
            case .string:
                guard let string = value as? String else { return nil }
                self = .string(String(string.prefix(4_096)))
            case .strings:
                guard let strings = value as? [String] else { return nil }
                self = .strings(Array(strings.prefix(500)))
            }
        }
    }

    /// Reads the synced preferences from a defaults domain, registered
    /// defaults included, so the file always holds a complete setup.
    static func snapshot(of defaults: UserDefaults) -> [String: SyncValue] {
        var result: [String: SyncValue] = [:]
        for (key, type) in syncedKeys {
            if let value = SyncValue(defaults.object(forKey: key), as: type) {
                result[key] = value
            }
        }
        return result
    }

    /// Writes a snapshot back. Keys missing from it, or of the wrong type,
    /// are left as they are.
    static func apply(_ settings: [String: SyncValue], to defaults: UserDefaults) {
        for (key, _) in syncedKeys {
            guard let value = settings[key] else { continue }
            defaults.set(value.propertyListValue, forKey: key)
        }
    }

    static func encode(_ document: Document) -> Data? {
        var settings: [String: Any] = [:]
        for (key, value) in document.settings { settings[key] = value.propertyListValue }
        var object: [String: Any] = [
            "format": format,
            "version": version,
            "modifiedAt": document.modifiedAt,
            "device": document.device,
            "settings": settings,
        ]
        if let commands = document.commands {
            object["commands"] = WindowCommandPersistence.jsonObject(for: commands)
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Nil for anything that is not a window layout settings file.
    static func decode(_ data: Data) -> Document? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == format
        else { return nil }
        let rawSettings = object["settings"] as? [String: Any] ?? [:]
        var settings: [String: SyncValue] = [:]
        for (key, type) in syncedKeys {
            if let value = SyncValue(rawSettings[key], as: type) { settings[key] = value }
        }
        let commands = (object["commands"] as? [String: Any]).flatMap(WindowCommandPersistence.configuration(from:))
        guard !settings.isEmpty || commands != nil else { return nil }
        let modifiedAt = (object["modifiedAt"] as? NSNumber)?.doubleValue ?? 0
        let device = object["device"] as? String ?? ""
        return Document(modifiedAt: modifiedAt, device: device, settings: settings, commands: commands)
    }

    enum Decision: Equatable {
        /// Nothing to do: both sides hold the same change.
        case none
        /// The file is newer: take its settings.
        case adoptFile
        /// This Mac is newer, or there is no file yet: write it.
        case writeLocal
    }

    /// Last writer wins. `localModifiedAt` is the real time of this Mac's
    /// last change, 0 when nothing was ever changed here, so an untouched
    /// setup never outranks a file someone did change. A conflict is when
    /// both sides changed since a sync this Mac already made with the folder;
    /// the newer one still wins, and the caller leaves a note. A fresh Mac,
    /// or a folder just chosen, has no such sync yet and so no conflict.
    static func decide(localModifiedAt: TimeInterval,
                       fileModifiedAt: TimeInterval?,
                       lastSyncedAt: TimeInterval,
                       tolerance: TimeInterval = 0.5) -> (decision: Decision, conflict: Bool) {
        guard let fileModifiedAt else { return (.writeLocal, false) }
        if abs(fileModifiedAt - localModifiedAt) <= tolerance { return (.none, false) }
        let hasSyncedBefore = lastSyncedAt > 0
        let localChanged = localModifiedAt > lastSyncedAt + tolerance
        let fileChanged = fileModifiedAt > lastSyncedAt + tolerance
        let conflict = hasSyncedBefore && localChanged && fileChanged
        return (fileModifiedAt > localModifiedAt ? .adoptFile : .writeLocal, conflict)
    }

    /// Whether the folder's file can be read right now without waiting.
    enum FileReadiness: Equatable {
        case missing
        case ready
        /// A cloud placeholder, or a copy older than the cloud's: reading it
        /// would wait for the folder's own client to download it.
        case waitingForDownload
    }

    /// Decided from what the file system says without opening the file. A
    /// dataless file (any cloud provider's placeholder) or a ubiquitous item
    /// whose download status is not current is left alone until it is.
    static func readiness(exists: Bool,
                          isDataless: Bool,
                          isUbiquitous: Bool,
                          downloadStatus: URLUbiquitousItemDownloadingStatus?) -> FileReadiness {
        guard exists else { return .missing }
        if isDataless { return .waitingForDownload }
        if isUbiquitous, let downloadStatus, downloadStatus != .current { return .waitingForDownload }
        return .ready
    }
}
