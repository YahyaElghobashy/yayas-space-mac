// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit

/// The parts of Window Layout that live beside the engine: the menu-bar
/// item, the green-button menu and the sync folder. The engine's own sync
/// brings them up and takes them down with the feature, so an uninstalled
/// feature or a revoked permission leaves nothing running.
enum WindowLayoutCompanions {
    static func sync(available: Bool, trusted: Bool) {}

    static func suspend() {}
}
