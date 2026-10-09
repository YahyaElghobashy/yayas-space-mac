// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Foundation

/// Strings for the window command sets, their settings tabs, the menu-bar
/// item and the green-button menu. Added in Yaya's Space 1.1.0 in English;
/// the other twelve languages fall back to English until they are
/// translated, while the built-in placement names below keep using each
/// language's existing translations.
struct WindowCommandStrings {
    // Tabs and banner
    let tabGeneral: String
    let tabCommands: String
    let otherManagerTitle: String
    let otherManagerMessage: String
    let otherManagerQuitFormat: String

    // Sync
    let syncSection: String
    let syncCaption: String
    let exportSettings: String
    let importSettings: String
    let syncFolder: String
    let syncFolderOff: String
    let chooseSyncFolder: String
    let stopSyncing: String
    let syncNow: String
    let lastSyncedFormat: String
    let neverSynced: String
    let syncConflictFormat: String
    let dismiss: String
    let exported: String
    let imported: String
    let importFailed: String
    let exportFailed: String
    let syncFolderUnavailable: String
    let syncWaitingForDownload: String
    let syncDownloadStopped: String

    // General
    let generalSection: String
    let showMenuBarItem: String
    let showMenuBarItemCaption: String
    let openAtLogin: String
    let openAtLoginCaption: String
    let keyboardSection: String

    // Dragging
    let draggingSection: String
    let snapByDragging: String
    let snapByDraggingCaption: String
    let snapSystemTilingCaption: String
    let snapOptionTilingHint: String
    let tilingPromptTitle: String
    let tilingPromptMessage: String
    let tilingPromptKeep: String
    let tilingPromptSwitch: String
    let restoreOnDrag: String
    let restoreOnDragCaption: String
    let areasSection: String
    let highlightAreas: String
    let interiorScale: String
    let edgeWidth: String
    let previewSection: String
    let previewStyle: String
    let styleSystem: String
    let styleLight: String
    let styleDark: String
    let styleAccent: String
    let previewBorder: String

    // Green button
    let greenButtonSection: String
    let greenButtonMenu: String
    let greenButtonCaption: String
    let greenButtonDelay: String
    let greenButtonLayout: String
    let layoutList: String
    let layoutGrid: String
    let layoutHorizontal: String
    let greenButtonSystemMenuKey: String
    let systemMenuKeyControl: String
    let systemMenuKeyCommand: String
    let greenButtonSystemNote: String

    // Margins
    let marginsSection: String
    let margins: String
    let fitTightly: String
    let fitTightlyCaption: String

    // Ignored apps
    let ignoredSection: String
    let ignoredCaption: String
    let addApp: String
    let noIgnoredApps: String
    let remove: String

    // Reset
    let resetSection: String
    let resetAll: String
    let resetAllTitle: String
    let resetAllMessage: String
    let reset: String
    let cancel: String

    // Units
    let pointsFormat: String
    let percentFormat: String
    let millisecondsFormat: String

    // Commands tab
    let setHorizontal: String
    let setVertical: String
    let setHorizontalCaption: String
    let setVerticalCaption: String
    let add: String
    let addCustom: String
    let addSeparator: String
    let addBuiltin: String
    let resetSetFormat: String
    let resetSetTitleFormat: String
    let resetSetMessage: String
    let customCommand: String
    let separator: String
    let inMenuBar: String
    let inGreenButtonMenu: String
    let delete: String
    let moveUp: String
    let moveDown: String
    let selectCommand: String
    let name: String
    let targetTitle: String
    let targetCaption: String
    let shortcutTitle: String
    let shortcutsOffNote: String
    let conflictInSetFormat: String
    let dragAreaTitle: String
    let dragAreaCaption: String
    let dragAreaNone: String
    let regionTopEdge: String
    let regionLeftEdge: String
    let regionBottomEdge: String
    let regionRightEdge: String
    let regionEdgeSpanFormat: String
    let regionTopLeftCorner: String
    let regionTopRightCorner: String
    let regionBottomLeftCorner: String
    let regionBottomRightCorner: String
    let regionInteriorFormat: String
    let clearDragArea: String
    let draggingOffNote: String
    let showTitle: String
    let showInMenuBar: String
    let showInGreenButtonMenu: String
    let maximizeCaption: String
    let marginMaximizeCaption: String
    let fullScreenCaption: String
    let centerCaption: String
    let restoreCaption: String
    let nextDisplayCaption: String
    let previousDisplayCaption: String
    let tryIt: String

    // Menu bar item
    let statusItemTitle: String
    let menuSettings: String
    let menuIgnoreFormat: String
    let menuStopIgnoringFormat: String
    let menuHelp: String
    let menuAboutFormat: String
    let menuQuitFormat: String
    let menuNoWindow: String

    static func localized(_ language: AppLanguage) -> WindowCommandStrings {
        switch language {
        case .enUS:
            return .enUS
        // New in 1.1.0: English until these are translated.
        case .ptBR, .tr, .ru, .es, .de, .fr, .it, .ja, .ko, .zhHans, .zhTW, .zhHK:
            return .enUS
        }
    }

    static let enUS = WindowCommandStrings(
        tabGeneral: "General",
        tabCommands: "Commands",
        otherManagerTitle: "Magnet is running",
        otherManagerMessage: "Two window managers would fight over the same shortcuts and drags. Keep snapping, shortcuts and the green-button menu off here until Magnet is gone.",
        otherManagerQuitFormat: "Quit %@",
        syncSection: "Sync",
        syncCaption: "Move these settings between Macs as a file. A sync folder, such as one in iCloud Drive or Dropbox, keeps Macs in step: the file is read at launch and written after every change. Yaya's Space itself never goes online.",
        exportSettings: "Export…",
        importSettings: "Import…",
        syncFolder: "Sync folder",
        syncFolderOff: "Not syncing",
        chooseSyncFolder: "Choose…",
        stopSyncing: "Stop Syncing",
        syncNow: "Sync Now",
        lastSyncedFormat: "Last synced %@",
        neverSynced: "Not synced yet",
        syncConflictFormat: "Both this Mac and %@ changed these settings since the last sync. The newer copy, from %@, was kept.",
        dismiss: "Dismiss",
        exported: "Settings exported.",
        imported: "Settings imported.",
        importFailed: "That file holds no window layout settings.",
        exportFailed: "The file could not be written.",
        syncFolderUnavailable: "The sync folder cannot be read. Choose it again.",
        syncWaitingForDownload: "Waiting for the sync file to download to this Mac.",
        syncDownloadStopped: "The sync file still has not downloaded to this Mac, so syncing stopped trying. Click Sync Now to try again.",
        generalSection: "General",
        showMenuBarItem: "Show the Window Layout menu bar icon",
        showMenuBarItemCaption: "A second icon, next to the main Yaya's Space icon, lists every command for the window in front.",
        openAtLogin: "Open Yaya's Space at login",
        openAtLoginCaption: "Window Layout lives inside Yaya's Space, so this switch starts the whole app at login.",
        keyboardSection: "Keyboard",
        draggingSection: "Dragging",
        snapByDragging: "Snap dragged windows into place",
        snapByDraggingCaption: "Drag a window by its title bar into a command’s drag area, watch the preview, then let go.",
        snapSystemTilingCaption: "While this is on, macOS tiling by dropping a window on a screen edge or the menu bar is switched off. It comes back as it was when snapping is off or Yaya's Space quits.",
        snapOptionTilingHint: "Hold Option while dragging to tile with macOS instead.",
        tilingPromptTitle: "macOS tiling is on again",
        tilingPromptMessage: "Dropping a window on a screen edge would now be tiled by macOS and snapped by Window Layout at once. Keep snapping with Window Layout, or switch to macOS tiling?",
        tilingPromptKeep: "Keep Window Layout Snapping",
        tilingPromptSwitch: "Switch to macOS Tiling",
        restoreOnDrag: "Give snapped windows back their size",
        restoreOnDragCaption: "A window placed by Window Layout returns to the size it had before, as soon as you drag it away.",
        areasSection: "Drag Areas",
        highlightAreas: "Show every drag area while dragging",
        interiorScale: "Size of areas inside the screen",
        edgeWidth: "Reach of screen-edge areas",
        previewSection: "Preview",
        previewStyle: "Preview style",
        styleSystem: "Match system",
        styleLight: "Light",
        styleDark: "Dark",
        styleAccent: "Accent color",
        previewBorder: "Preview border",
        greenButtonSection: "Green-Button Menu",
        greenButtonMenu: "Open a command menu from the green button",
        greenButtonCaption: "Rest the pointer on a window’s green button to pick a command for that window.",
        greenButtonDelay: "Wait before opening",
        greenButtonLayout: "Menu layout",
        layoutList: "Full list",
        layoutGrid: "Compact grid",
        layoutHorizontal: "Horizontal row",
        greenButtonSystemMenuKey: "Show the macOS menu while holding",
        systemMenuKeyControl: "Control (⌃)",
        systemMenuKeyCommand: "Command (⌘)",
        greenButtonSystemNote: "While this menu is on, the macOS menu under the green button waits for that key, so the two never open together. It comes back as before when this menu is off or Yaya's Space quits.",
        marginsSection: "Margins",
        margins: "Space around windows",
        fitTightly: "No space at screen edges",
        fitTightlyCaption: "Windows still keep the space between each other.",
        ignoredSection: "Ignored Apps",
        ignoredCaption: "Shortcuts, dragging and both menus leave these apps’ windows alone.",
        addApp: "Add App…",
        noIgnoredApps: "No ignored apps.",
        remove: "Remove",
        resetSection: "Reset",
        resetAll: "Reset Window Layout…",
        resetAllTitle: "Reset Window Layout?",
        resetAllMessage: "Every command, shortcut, drag area and setting on these two tabs returns to how it shipped. Snapping, shortcuts and the green-button menu stay off.",
        reset: "Reset",
        cancel: "Cancel",
        pointsFormat: "%d pt",
        percentFormat: "%d%%",
        millisecondsFormat: "%d ms",
        setHorizontal: "Horizontal",
        setVertical: "Vertical",
        setHorizontalCaption: "Used for windows on landscape displays.",
        setVerticalCaption: "Used for windows on portrait displays.",
        add: "Add",
        addCustom: "New Command",
        addSeparator: "Separator",
        addBuiltin: "Built-in",
        resetSetFormat: "Reset %@ Commands…",
        resetSetTitleFormat: "Reset the %@ commands?",
        resetSetMessage: "This set returns to its default commands, shortcuts and drag areas.",
        customCommand: "Custom Command",
        separator: "Separator",
        inMenuBar: "Menu bar menu",
        inGreenButtonMenu: "Green-button menu",
        delete: "Delete",
        moveUp: "Move Up",
        moveDown: "Move Down",
        selectCommand: "Choose a command on the left to edit it.",
        name: "Name",
        targetTitle: "Where the window goes",
        targetCaption: "Drag across the grid to choose the window’s size and position.",
        shortcutTitle: "Shortcut",
        shortcutsOffNote: "Shortcuts are off. Turn them on in General.",
        conflictInSetFormat: "“%@” in this set already uses that combination.",
        dragAreaTitle: "Drag area",
        dragAreaCaption: "Drag along an edge, click a corner, or drag a rectangle inside the screen. Faint marks belong to other commands.",
        dragAreaNone: "No drag area yet.",
        regionTopEdge: "Top edge",
        regionLeftEdge: "Left edge",
        regionBottomEdge: "Bottom edge",
        regionRightEdge: "Right edge",
        regionEdgeSpanFormat: "%@, cells %d to %d of %d",
        regionTopLeftCorner: "Top left corner",
        regionTopRightCorner: "Top right corner",
        regionBottomLeftCorner: "Bottom left corner",
        regionBottomRightCorner: "Bottom right corner",
        regionInteriorFormat: "Area inside the screen, %@ of its width and %@ of its height",
        clearDragArea: "Clear",
        draggingOffNote: "Snapping by dragging is off. Turn it on in General.",
        showTitle: "Show in",
        showInMenuBar: "The menu bar menu",
        showInGreenButtonMenu: "The green-button menu",
        maximizeCaption: "Fills the screen, inside the margins.",
        marginMaximizeCaption: "Fills the screen but leaves a small border all around.",
        fullScreenCaption: "Switches the window in or out of full screen.",
        centerCaption: "Moves the window to the middle of the screen at its current size.",
        restoreCaption: "Puts the window back where it was before its last placement.",
        nextDisplayCaption: "Moves the window to the next display, keeping its size.",
        previousDisplayCaption: "Moves the window to the previous display, keeping its size.",
        tryIt: "Try It",
        statusItemTitle: "Window Layout",
        menuSettings: "Settings…",
        menuIgnoreFormat: "Ignore “%@” Windows",
        menuStopIgnoringFormat: "Stop Ignoring “%@” Windows",
        menuHelp: "Window Layout Help",
        menuAboutFormat: "About %@",
        menuQuitFormat: "Quit %@",
        menuNoWindow: "No window to arrange"
    )

    /// The name a built-in command shows until someone renames it. English
    /// uses whole words; the other languages keep their existing
    /// translations of the same placements.
    static func builtinName(_ action: WindowLayoutAction, language: AppLanguage) -> String {
        guard language == .enUS else {
            return action.title(FeatureStrings.windowLayout(language))
        }
        switch action {
        case .leftHalf: return "Left"
        case .rightHalf: return "Right"
        case .topHalf: return "Top"
        case .bottomHalf: return "Bottom"
        case .centerHalf: return "Center Half"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .topThird: return "Top Third"
        case .middleThird: return "Center Third"
        case .bottomThird: return "Bottom Third"
        case .topTwoThirds: return "Top Two Thirds"
        case .middleTwoThirds: return "Center Two Thirds"
        case .bottomTwoThirds: return "Bottom Two Thirds"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .maximize: return "Maximize"
        case .marginMaximize: return "Almost Maximize"
        case .fullScreen: return "Full Screen"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    /// The name a command shows: the user's own, the built-in's, or the
    /// generic name of a custom area.
    static func displayName(of command: WindowCommand, language: AppLanguage) -> String {
        if let custom = command.customName { return custom }
        if command.isSeparator { return localized(language).separator }
        if let builtin = command.builtinID { return builtinName(builtin, language: language) }
        if let fixed = command.kind.fixedAction { return builtinName(fixed, language: language) }
        return localized(language).customCommand
    }

    /// A name for a new custom command that no other command of the set
    /// already shows: "Custom Command", then "Custom Command 2", and so on.
    static func newCustomName(existing: [WindowCommand], language: AppLanguage) -> String {
        let base = localized(language).customCommand
        let taken = Set(existing.map { displayName(of: $0, language: language) })
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// The built-ins only the vertical set uses by default.
    private static let verticalBuiltins: Set<WindowLayoutAction> = [
        .topThird, .middleThird, .bottomThird, .topTwoThirds, .middleTwoThirds, .bottomTwoThirds,
    ]

    /// The name a built-in shows in lists that hold every built-in at once
    /// (the radial menu, the command bar): its command name, with the set
    /// added only where two built-ins would otherwise read the same, such as
    /// the Center Third of a landscape display and of a portrait one.
    static func listName(_ action: WindowLayoutAction, language: AppLanguage) -> String {
        let name = builtinName(action, language: language)
        guard verticalBuiltins.contains(action),
              WindowLayoutAction.allCases.contains(where: {
                  $0 != action && builtinName($0, language: language) == name
              })
        else { return name }
        return "\(name) (\(localized(language).setVertical))"
    }

    /// What VoiceOver reads for a drag area in the editor.
    func describe(_ region: WindowActivationRegion?, grid: WindowGrid) -> String {
        guard let region else { return dragAreaNone }
        switch region {
        case .edge(let edge, let start, let end):
            let name: String
            switch edge {
            case .top: name = regionTopEdge
            case .left: name = regionLeftEdge
            case .bottom: name = regionBottomEdge
            case .right: name = regionRightEdge
            }
            return String(format: regionEdgeSpanFormat, name, start + 1, end, grid.units(along: edge))
        case .corner(let corner):
            switch corner {
            case .topLeft: return regionTopLeftCorner
            case .topRight: return regionTopRightCorner
            case .bottomLeft: return regionBottomLeftCorner
            case .bottomRight: return regionBottomRightCorner
            }
        case .interior(let rect):
            return String(format: regionInteriorFormat,
                          rect.widthFraction(in: grid).text, rect.heightFraction(in: grid).text)
        }
    }

    /// Explains what a fixed (non-area) command does, in place of the grid.
    func caption(for kind: WindowCommandKind) -> String? {
        switch kind {
        case .maximize: return maximizeCaption
        case .marginMaximize: return marginMaximizeCaption
        case .fullScreen: return fullScreenCaption
        case .center: return centerCaption
        case .restore: return restoreCaption
        case .nextDisplay: return nextDisplayCaption
        case .previousDisplay: return previousDisplayCaption
        case .area, .separator: return nil
        }
    }
}

// The names of the built-ins added in 1.1.0 wherever the earlier placement
// titles are read: the same words as their commands (the portrait set calls
// its middle row Center Third, as the landscape set calls its middle column).
// English until translated: every language reads the same value, the way the
// project falls back for new strings.
extension WindowLayoutFeatureStrings {
    var centerTwoThirds: String { "Center Two Thirds" }
    var topThird: String { "Top Third" }
    var middleThird: String { "Center Third" }
    var bottomThird: String { "Bottom Third" }
    var topTwoThirds: String { "Top Two Thirds" }
    var middleTwoThirds: String { "Center Two Thirds" }
    var bottomTwoThirds: String { "Bottom Two Thirds" }
    var rows: String { "Rows" }
}
