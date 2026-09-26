// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit

/// While a window is dragged, optionally shows every drag area of the
/// display faintly, with the one under the pointer brighter.
final class WindowLayoutOverlays {
    static let shared = WindowLayoutOverlays()

    private init() {}

    func beginDrag(screens: [WindowActivationScreen],
                   commands: WindowCommandConfiguration,
                   settings: WindowActivationSettings) {}

    func highlight(commandID: UUID?) {}

    func endDrag() {}
}
