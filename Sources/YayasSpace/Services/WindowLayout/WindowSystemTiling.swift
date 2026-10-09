// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit

/// macOS's own drag tiling, switched off while drag snapping runs and put
/// back as it was found, the way Magnet does it (`WindowSystemTilingTakeover`
/// holds the rules). What snapping found, wrote and last handed back is
/// remembered on this Mac only, and remembered before anything is written,
/// so even a crash leaves the next start able to hand the switches back.
enum WindowSystemTiling {
    private typealias Takeover = WindowSystemTilingTakeover

    private static var asking = false

    /// Takes the switches over or hands them back as snapping starts or
    /// stops. When someone turned the system's tiling back on behind
    /// snapping's back, nothing is changed and the user is asked instead.
    static func sync(snappingWanted: Bool) {
        guard #available(macOS 15.0, *) else { return }
        let switches = current
        switch Takeover.action(snappingWanted: snappingWanted, switches: switches) {
        case .none:
            break
        case .takeOver:
            apply(switches.map(Takeover.takingOver), from: switches)
        case .handBack:
            apply(switches.map(Takeover.handingBack), from: switches)
        case .ask:
            askWhichTiling()
        }
    }

    /// Puts the switches back whatever snapping wants: the app is quitting
    /// or Window Layout is stopping for good.
    static func handBack() {
        guard #available(macOS 15.0, *) else { return }
        let switches = current
        apply(switches.map(Takeover.handingBack), from: switches)
    }

    // MARK: Asking

    /// Which of the two handles drops from now on, asked once per change.
    private static func askWhichTiling() {
        guard !asking else { return }
        asking = true
        DispatchQueue.main.async {
            let text = WindowCommandStrings.localized(L10n.shared.language)
            let alert = NSAlert()
            alert.messageText = text.tilingPromptTitle
            alert.informativeText = text.tilingPromptMessage
            alert.addButton(withTitle: text.tilingPromptKeep)
            alert.addButton(withTitle: text.tilingPromptSwitch)
            NSApp.activate(ignoringOtherApps: true)
            let keepSnapping = alert.runModal() == .alertFirstButtonReturn
            asking = false
            let switches = current
            if keepSnapping {
                // Off again; the user's latest choice is what comes back
                // when snapping stops.
                apply(switches.map { Takeover.takingOver(Takeover.handingBack($0)) }, from: switches)
            } else {
                // The system's tiling stays as the user left it and is what
                // snapping expects to find from now on; snapping goes off.
                apply(switches.map { state -> Takeover.Switch in
                    var next = Takeover.handingBack(state)
                    next.handedBack = next.system ?? Takeover.unset
                    return next
                }, from: switches)
                UserDefaults.standard.set(false, forKey: DefaultsKey.windowEdgeSnapEnabled)
            }
            WindowLayoutService.shared.syncWithPreferences()
        }
    }

    // MARK: Reading and writing

    private static var current: [Takeover.Switch] {
        let defaults = UserDefaults.standard
        func remembered(_ key: String) -> [String: Int] {
            (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        }
        let saved = remembered(DefaultsKey.windowLayoutSystemTilingSaved)
        let written = remembered(DefaultsKey.windowLayoutSystemTilingWritten)
        let handedBack = remembered(DefaultsKey.windowLayoutSystemTilingHandedBack)
        return Takeover.keys.map { key in
            Takeover.Switch(system: systemValue(key), saved: saved[key], written: written[key],
                            handedBack: handedBack[key])
        }
    }

    private static func systemValue(_ key: String) -> Int? {
        guard let value = CFPreferencesCopyValue(key as CFString, Takeover.domain as CFString,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let number = value as? NSNumber
        else { return nil }
        return number.boolValue ? 1 : Takeover.off
    }

    /// Taking over remembers first and writes second; handing back writes
    /// first and forgets second.
    private static func apply(_ next: [Takeover.Switch], from previous: [Takeover.Switch]) {
        let holds = next.contains(where: \.isHeld)
        if holds { remember(next) }
        var wrote = false
        for (key, change) in zip(Takeover.keys, zip(previous, next)) where change.0.system != change.1.system {
            // Written as booleans, the way the system writes them.
            let value = change.1.system.map { NSNumber(value: $0 != Takeover.off) }
            CFPreferencesSetValue(key as CFString, value, Takeover.domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            wrote = true
        }
        if wrote {
            CFPreferencesSynchronize(Takeover.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        if !holds { remember(next) }
    }

    private static func remember(_ switches: [Takeover.Switch]) {
        let defaults = UserDefaults.standard
        func store(_ key: String, _ value: (Takeover.Switch) -> Int?) {
            var entries: [String: Int] = [:]
            for (name, state) in zip(Takeover.keys, switches) { entries[name] = value(state) }
            if entries.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(entries, forKey: key) }
        }
        store(DefaultsKey.windowLayoutSystemTilingSaved) { $0.saved }
        store(DefaultsKey.windowLayoutSystemTilingWritten) { $0.written }
        store(DefaultsKey.windowLayoutSystemTilingHandedBack) { $0.handedBack }
    }
}
