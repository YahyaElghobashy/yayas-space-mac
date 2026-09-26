// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The command sets a fresh install (or "Restore to defaults") starts from,
/// and the canonical rectangle of every built-in area.
enum WindowCommandDefaults {
    /// Default shortcuts of the command sets. Both sets share them, so the
    /// same keys do the same kind of thing on a landscape and a portrait
    /// display. Restore moved from ⌃⌥R to ⌃⌥⌫ so R can take Center Two
    /// Thirds, between E and T.
    static let leftHalf = GlobalShortcut(keyCode: Int64(kVK_LeftArrow), modifiers: [.control, .option])
    static let rightHalf = GlobalShortcut(keyCode: Int64(kVK_RightArrow), modifiers: [.control, .option])
    static let topHalf = GlobalShortcut(keyCode: Int64(kVK_UpArrow), modifiers: [.control, .option])
    static let bottomHalf = GlobalShortcut(keyCode: Int64(kVK_DownArrow), modifiers: [.control, .option])
    static let topLeft = GlobalShortcut(keyCode: Int64(kVK_ANSI_U), modifiers: [.control, .option])
    static let topRight = GlobalShortcut(keyCode: Int64(kVK_ANSI_I), modifiers: [.control, .option])
    static let bottomLeft = GlobalShortcut(keyCode: Int64(kVK_ANSI_J), modifiers: [.control, .option])
    static let bottomRight = GlobalShortcut(keyCode: Int64(kVK_ANSI_K), modifiers: [.control, .option])
    static let firstThird = GlobalShortcut(keyCode: Int64(kVK_ANSI_D), modifiers: [.control, .option])
    static let middleThird = GlobalShortcut(keyCode: Int64(kVK_ANSI_F), modifiers: [.control, .option])
    static let lastThird = GlobalShortcut(keyCode: Int64(kVK_ANSI_G), modifiers: [.control, .option])
    static let firstTwoThirds = GlobalShortcut(keyCode: Int64(kVK_ANSI_E), modifiers: [.control, .option])
    static let middleTwoThirds = GlobalShortcut(keyCode: Int64(kVK_ANSI_R), modifiers: [.control, .option])
    static let lastTwoThirds = GlobalShortcut(keyCode: Int64(kVK_ANSI_T), modifiers: [.control, .option])
    static let nextDisplay = GlobalShortcut(keyCode: Int64(kVK_RightArrow),
                                            modifiers: [.control, .option, .command])
    static let previousDisplay = GlobalShortcut(keyCode: Int64(kVK_LeftArrow),
                                                modifiers: [.control, .option, .command])
    static let maximize = GlobalShortcut(keyCode: Int64(kVK_Return), modifiers: [.control, .option])
    static let center = GlobalShortcut(keyCode: Int64(kVK_ANSI_C), modifiers: [.control, .option])
    static let restore = GlobalShortcut(keyCode: Int64(kVK_Delete), modifiers: [.control, .option])

    private struct Entry {
        let action: WindowLayoutAction?
        let shortcut: GlobalShortcut?
        let activation: WindowActivationRegion?

        static let separator = Entry(action: nil, shortcut: nil, activation: nil)
    }

    /// The horizontal set, in list order. The activation areas never
    /// overlap: the sides take halves, the top takes Maximize, the corners
    /// take quarters and the bottom edge is cut into five spans, so sliding
    /// along it walks through the thirds and two-thirds.
    private static let horizontalEntries: [Entry] = [
        Entry(action: .leftHalf, shortcut: leftHalf, activation: .edge(.left, start: 1, end: 11)),
        Entry(action: .rightHalf, shortcut: rightHalf, activation: .edge(.right, start: 1, end: 11)),
        Entry(action: .topHalf, shortcut: topHalf, activation: nil),
        Entry(action: .bottomHalf, shortcut: bottomHalf, activation: nil),
        .separator,
        Entry(action: .topLeft, shortcut: topLeft, activation: .corner(.topLeft)),
        Entry(action: .topRight, shortcut: topRight, activation: .corner(.topRight)),
        Entry(action: .bottomLeft, shortcut: bottomLeft, activation: .corner(.bottomLeft)),
        Entry(action: .bottomRight, shortcut: bottomRight, activation: .corner(.bottomRight)),
        .separator,
        Entry(action: .leftThird, shortcut: firstThird, activation: .edge(.bottom, start: 1, end: 5)),
        Entry(action: .centerThird, shortcut: middleThird, activation: .edge(.bottom, start: 9, end: 15)),
        Entry(action: .rightThird, shortcut: lastThird, activation: .edge(.bottom, start: 19, end: 23)),
        .separator,
        Entry(action: .leftTwoThirds, shortcut: firstTwoThirds, activation: .edge(.bottom, start: 5, end: 9)),
        Entry(action: .centerTwoThirds, shortcut: middleTwoThirds, activation: nil),
        Entry(action: .rightTwoThirds, shortcut: lastTwoThirds, activation: .edge(.bottom, start: 15, end: 19)),
        .separator,
        Entry(action: .nextDisplay, shortcut: nextDisplay, activation: nil),
        Entry(action: .previousDisplay, shortcut: previousDisplay, activation: nil),
        .separator,
        Entry(action: .maximize, shortcut: maximize, activation: .edge(.top, start: 1, end: 23)),
        Entry(action: .center, shortcut: center, activation: nil),
        Entry(action: .restore, shortcut: restore, activation: nil),
    ]

    /// The vertical set: the same groups turned on their side. The top and
    /// bottom edges take the halves, the left edge is cut into the five
    /// third and two-third spans, and Maximize moves to the right edge
    /// because the top now belongs to Top.
    private static let verticalEntries: [Entry] = [
        Entry(action: .leftHalf, shortcut: leftHalf, activation: nil),
        Entry(action: .rightHalf, shortcut: rightHalf, activation: nil),
        Entry(action: .topHalf, shortcut: topHalf, activation: .edge(.top, start: 1, end: 11)),
        Entry(action: .bottomHalf, shortcut: bottomHalf, activation: .edge(.bottom, start: 1, end: 11)),
        .separator,
        Entry(action: .topLeft, shortcut: topLeft, activation: .corner(.topLeft)),
        Entry(action: .topRight, shortcut: topRight, activation: .corner(.topRight)),
        Entry(action: .bottomLeft, shortcut: bottomLeft, activation: .corner(.bottomLeft)),
        Entry(action: .bottomRight, shortcut: bottomRight, activation: .corner(.bottomRight)),
        .separator,
        Entry(action: .topThird, shortcut: firstThird, activation: .edge(.left, start: 1, end: 5)),
        Entry(action: .middleThird, shortcut: middleThird, activation: .edge(.left, start: 9, end: 15)),
        Entry(action: .bottomThird, shortcut: lastThird, activation: .edge(.left, start: 19, end: 23)),
        .separator,
        Entry(action: .topTwoThirds, shortcut: firstTwoThirds, activation: .edge(.left, start: 5, end: 9)),
        Entry(action: .middleTwoThirds, shortcut: middleTwoThirds, activation: nil),
        Entry(action: .bottomTwoThirds, shortcut: lastTwoThirds, activation: .edge(.left, start: 15, end: 19)),
        .separator,
        Entry(action: .nextDisplay, shortcut: nextDisplay, activation: nil),
        Entry(action: .previousDisplay, shortcut: previousDisplay, activation: nil),
        .separator,
        Entry(action: .maximize, shortcut: maximize, activation: .edge(.right, start: 1, end: 23)),
        Entry(action: .center, shortcut: center, activation: nil),
        Entry(action: .restore, shortcut: restore, activation: nil),
    ]

    /// A fresh copy of a default set, with new ids.
    static func commands(for kind: WindowCommandSetKind) -> [WindowCommand] {
        let entries = kind == .horizontal ? horizontalEntries : verticalEntries
        return entries.compactMap { entry in
            guard let action = entry.action else { return WindowCommand.separator() }
            guard var command = builtinCommand(action, in: kind) else { return nil }
            command.shortcut = entry.shortcut
            command.shortcutEnabled = entry.shortcut != nil
            command.activation = entry.activation
            command.activationEnabled = entry.activation != nil
            return command
        }
    }

    /// The built-ins a default set contains, in order.
    static func defaultBuiltins(for kind: WindowCommandSetKind) -> [WindowLayoutAction] {
        (kind == .horizontal ? horizontalEntries : verticalEntries).compactMap(\.action)
    }

    /// A built-in as a new command of the given set: its canonical target,
    /// no shortcut and no drag area yet, visible everywhere.
    static func builtinCommand(_ action: WindowLayoutAction,
                               in kind: WindowCommandSetKind) -> WindowCommand? {
        let commandKind: WindowCommandKind
        if let fixed = WindowCommandKind(fixedAction: action) {
            commandKind = fixed
        } else if let rect = canonicalRect(for: action, in: kind.grid) {
            commandKind = .area(rect)
        } else {
            return nil
        }
        return WindowCommand(kind: commandKind,
                             builtinID: action,
                             shortcut: nil,
                             shortcutEnabled: false,
                             activation: nil,
                             activationEnabled: false)
    }

    /// The order built-ins are offered in the + menu: Yaya's Space's own
    /// extras first, then everything else a set may be missing.
    static let offeredBuiltins: [WindowLayoutAction] = [
        .topLeftSixth, .topCenterSixth, .topRightSixth,
        .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
        .centerHalf, .fullScreen, .marginMaximize,
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird,
        .leftTwoThirds, .centerTwoThirds, .rightTwoThirds,
        .topThird, .middleThird, .bottomThird,
        .topTwoThirds, .middleTwoThirds, .bottomTwoThirds,
        .nextDisplay, .previousDisplay, .maximize, .center, .restore,
    ]

    /// Each built-in area in twelfths of the display (x, y from the top-left,
    /// right, bottom). Twelve divides both grids' columns and rows, so every
    /// built-in lands on whole cells in either set.
    private static func twelfths(for action: WindowLayoutAction) -> (Int, Int, Int, Int)? {
        switch action {
        case .leftHalf: return (0, 0, 6, 12)
        case .rightHalf: return (6, 0, 12, 12)
        case .topHalf: return (0, 0, 12, 6)
        case .bottomHalf: return (0, 6, 12, 12)
        case .centerHalf: return (3, 0, 9, 12)
        case .leftThird: return (0, 0, 4, 12)
        case .centerThird: return (4, 0, 8, 12)
        case .rightThird: return (8, 0, 12, 12)
        case .leftTwoThirds: return (0, 0, 8, 12)
        case .centerTwoThirds: return (2, 0, 10, 12)
        case .rightTwoThirds: return (4, 0, 12, 12)
        case .topThird: return (0, 0, 12, 4)
        case .middleThird: return (0, 4, 12, 8)
        case .bottomThird: return (0, 8, 12, 12)
        case .topTwoThirds: return (0, 0, 12, 8)
        case .middleTwoThirds: return (0, 2, 12, 10)
        case .bottomTwoThirds: return (0, 4, 12, 12)
        case .topLeftSixth: return (0, 0, 4, 6)
        case .topCenterSixth: return (4, 0, 8, 6)
        case .topRightSixth: return (8, 0, 12, 6)
        case .bottomLeftSixth: return (0, 6, 4, 12)
        case .bottomCenterSixth: return (4, 6, 8, 12)
        case .bottomRightSixth: return (8, 6, 12, 12)
        case .topLeft: return (0, 0, 6, 6)
        case .topRight: return (6, 0, 12, 6)
        case .bottomLeft: return (0, 6, 6, 12)
        case .bottomRight: return (6, 6, 12, 12)
        case .maximize, .marginMaximize, .fullScreen, .center,
             .previousDisplay, .nextDisplay, .restore:
            return nil
        }
    }

    /// The grid rectangle of a built-in area in a given grid, or nil for the
    /// built-ins that are not a fixed area.
    static func canonicalRect(for action: WindowLayoutAction, in grid: WindowGrid) -> GridRect? {
        guard let (left, top, right, bottom) = twelfths(for: action) else { return nil }
        let columnsPerTwelfth = Double(grid.columns) / 12
        let rowsPerTwelfth = Double(grid.rows) / 12
        let x = Int((Double(left) * columnsPerTwelfth).rounded())
        let y = Int((Double(top) * rowsPerTwelfth).rounded())
        let maxX = Int((Double(right) * columnsPerTwelfth).rounded())
        let maxY = Int((Double(bottom) * rowsPerTwelfth).rounded())
        return GridRect(x: x, y: y, width: maxX - x, height: maxY - y).clamped(to: grid)
    }

    /// Whether a command still is exactly its built-in: an area that kept the
    /// built-in's rectangle, or a fixed kind. Only those run through the
    /// built-in path with its extra behaviours; an edited area is a custom
    /// placement from then on.
    static func isCanonical(_ command: WindowCommand, in grid: WindowGrid) -> Bool {
        guard let builtin = command.builtinID else { return false }
        switch command.kind {
        case .area(let rect):
            return canonicalRect(for: builtin, in: grid) == rect
        case .separator:
            return false
        default:
            return command.kind.fixedAction == builtin
        }
    }

    /// The built-in the vertical set uses where the horizontal set has the
    /// given one. Only the thirds turn on their side; everything else is the
    /// same built-in in both sets.
    static func verticalCounterpart(of action: WindowLayoutAction) -> WindowLayoutAction {
        switch action {
        case .leftThird: return .topThird
        case .centerThird: return .middleThird
        case .rightThird: return .bottomThird
        case .leftTwoThirds: return .topTwoThirds
        case .rightTwoThirds: return .bottomTwoThirds
        case .centerTwoThirds: return .middleTwoThirds
        default: return action
        }
    }
}

/// Carries a setup made with the earlier fixed actions into the command sets,
/// once, the first time the sets are created.
enum WindowCommandMigration {
    /// Legacy per-action shortcut keys a person could have changed, with the
    /// default each one shipped with. Anything stored that differs from that
    /// default was a deliberate choice and wins over the new defaults.
    static func customisedLegacyShortcuts(
        storedValue: (String) -> String?
    ) -> [WindowLayoutAction: GlobalShortcut?] {
        var result: [WindowLayoutAction: GlobalShortcut?] = [:]
        for action in WindowLayoutAction.shortcutActions {
            guard let stored = storedValue(action.shortcutKey) else { continue }
            let resolved = WindowLayoutAction.resolvedShortcut(storedValue: stored,
                                                               defaultShortcut: action.defaultShortcut)
            // A corrupt value resolves to the default, and an explicit reset
            // writes the default back: neither is a customisation.
            guard resolved != action.defaultShortcut else { continue }
            result[action] = .some(resolved)
        }
        return result
    }

    /// The default sets with every customised legacy shortcut carried into
    /// the matching command of both sets, and every visual edge-snap zone
    /// someone switched off carried into the commands that live there.
    static func configuration(legacyShortcut storedValue: (String) -> String?,
                              disabledZones: Set<WindowEdgeSnapZone>) -> WindowCommandConfiguration {
        var configuration = WindowCommandConfiguration.defaults
        let customised = customisedLegacyShortcuts(storedValue: storedValue)
        for kind in WindowCommandSetKind.allCases {
            configuration[kind] = migratedSet(configuration[kind],
                                              kind: kind,
                                              customised: customised,
                                              disabledZones: disabledZones)
        }
        return configuration
    }

    static func migratedSet(_ commands: [WindowCommand],
                            kind: WindowCommandSetKind,
                            customised: [WindowLayoutAction: GlobalShortcut?],
                            disabledZones: Set<WindowEdgeSnapZone>) -> [WindowCommand] {
        var set = commands
        var chosenIDs = Set<UUID>()
        // Stable order, so two runs over the same setup build the same set.
        let ordered = WindowLayoutAction.shortcutActions.filter { customised[$0] != nil }
        for action in ordered {
            guard let value = customised[action] else { continue }
            let target = kind == .vertical ? WindowCommandDefaults.verticalCounterpart(of: action) : action
            if let index = set.firstIndex(where: { $0.builtinID == target }) {
                set[index].shortcut = value
                set[index].shortcutEnabled = value != nil
                chosenIDs.insert(set[index].id)
            } else if let shortcut = value,
                      var extra = WindowCommandDefaults.builtinCommand(action, in: kind) {
                // A shortcut on one of Yaya's Space's extras (a sixth, the
                // centre half, full screen, almost maximize) keeps working:
                // the extra joins the set at the end.
                if set.last?.isSeparator == false { set.append(.separator()) }
                extra.shortcut = shortcut
                extra.shortcutEnabled = true
                set.append(extra)
                chosenIDs.insert(extra.id)
            }
        }
        set = WindowCommandShortcuts.resolvingConflicts(in: set, keeping: chosenIDs)
        if !disabledZones.isEmpty {
            for index in set.indices {
                if let zone = set[index].activation?.legacyZone, disabledZones.contains(zone) {
                    set[index].activationEnabled = false
                }
            }
        }
        return set
    }
}

/// Shortcut rules shared by the recorder, the registration and migration.
enum WindowCommandShortcuts {
    /// Another command of the same set that already uses this combination.
    /// A disabled shortcut still counts: switching it back on later would
    /// otherwise bring back a clash nobody was warned about.
    static func conflictingCommand(for shortcut: GlobalShortcut,
                                   in commands: [WindowCommand],
                                   excluding id: UUID?) -> WindowCommand? {
        commands.first { $0.id != id && !$0.isSeparator && $0.shortcut == shortcut }
    }

    /// Clears the shortcut of any command that collides with one the user
    /// chose. Among commands nobody chose, the first in the list keeps it.
    static func resolvingConflicts(in commands: [WindowCommand], keeping chosen: Set<UUID>) -> [WindowCommand] {
        var result = commands
        var owner: [GlobalShortcut: Int] = [:]
        // Chosen shortcuts claim their combination first.
        let order = result.indices.sorted { lhs, rhs in
            let lhsChosen = chosen.contains(result[lhs].id)
            let rhsChosen = chosen.contains(result[rhs].id)
            if lhsChosen != rhsChosen { return lhsChosen }
            return lhs < rhs
        }
        for index in order {
            guard let shortcut = result[index].shortcut, !result[index].isSeparator else { continue }
            if owner[shortcut] == nil {
                owner[shortcut] = index
            } else {
                result[index].shortcut = nil
                result[index].shortcutEnabled = false
            }
        }
        return result
    }

    /// Every combination either set has switched on, once each, in a stable
    /// order. One system-wide registration serves both sets; which command
    /// runs is decided when it fires, from the display under the window.
    static func registrations(for configuration: WindowCommandConfiguration) -> [GlobalShortcut] {
        var seen = Set<GlobalShortcut>()
        var result: [GlobalShortcut] = []
        for kind in WindowCommandSetKind.allCases {
            for command in configuration[kind] {
                guard let shortcut = command.effectiveShortcut, seen.insert(shortcut).inserted else { continue }
                result.append(shortcut)
            }
        }
        return result
    }

    /// The command a pressed combination runs for a window on a display of
    /// the given kind. Nil when that display's set does not use it.
    static func command(for shortcut: GlobalShortcut,
                        in configuration: WindowCommandConfiguration,
                        setKind: WindowCommandSetKind) -> WindowCommand? {
        configuration[setKind].first { $0.effectiveShortcut == shortcut }
    }
}
