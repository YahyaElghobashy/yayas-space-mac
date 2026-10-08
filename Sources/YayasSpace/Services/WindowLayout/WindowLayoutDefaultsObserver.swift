// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Foundation

/// Watches a fixed list of preference keys through key-value observing and
/// reports a change to any of them, and only to them: a write to some other
/// preference anywhere in the app never wakes it. The callback runs on the
/// thread that made the change; callers hop to the main queue themselves.
final class WindowLayoutDefaultsObserver: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: () -> Void

    /// Identifies this class's registrations, so a callback meant for a
    /// superclass is never mistaken for one of ours.
    private static let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    init(defaults: UserDefaults = .standard, keys: [String], onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.keys = Array(Set(keys))
        self.onChange = onChange
        super.init()
        for key in self.keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: Self.context)
        }
    }

    deinit {
        for key in keys {
            defaults.removeObserver(self, forKeyPath: key, context: Self.context)
        }
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == Self.context else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        onChange()
    }
}
