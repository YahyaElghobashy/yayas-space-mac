// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit

/// The parts of Window Layout that live beside the engine: the green-button
/// menu, the menu-bar item and the sync folder. The engine's own sync brings
/// them up and takes them down with the feature, so an uninstalled feature
/// or a revoked permission leaves nothing running.
enum WindowLayoutCompanions {
    static func sync(available: Bool, trusted: Bool) {
        let defaults = UserDefaults.standard
        // The green-button menu reads other apps' windows, so it needs the
        // Accessibility grant and an active session, like every input hook.
        WindowGreenButtonService.shared.sync(
            enabled: available && trusted
                && defaults.bool(forKey: DefaultsKey.windowLayoutGreenButtonMenuEnabled))
        // The menu-bar item works without the grant too: its commands grey
        // out, and Settings is one click away.
        WindowLayoutMenuBarController.shared.sync(
            visible: available && defaults.bool(forKey: DefaultsKey.windowLayoutShowMenuBarItem))
        // The sync folder follows the feature, not the permission: settings
        // can travel even before Accessibility is granted.
        WindowLayoutSyncController.shared.sync(active: available)
    }

    static func suspend() {
        WindowGreenButtonService.shared.stop()
    }
}
