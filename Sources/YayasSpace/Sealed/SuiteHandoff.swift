// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Foundation
import ServiceManagement

/// Hooks for the Yaya Suite installer. Local files only; nothing leaves the Mac.
///   --onboarding         show the first-run flow even if it was completed before
///   --login-item on|off  register / unregister the login item, then continue
/// When onboarding finishes, a marker file tells the installer to move on.
enum SuiteHandoff {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YayaSuite/handoff", isDirectory: true)
    }

    static func markDone() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("done \(Date())\n".utf8).write(to: directory.appendingPathComponent("yayasspace.done"))
    }

    static func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--login-item"), i + 1 < args.count else { return }
        let on = args[i + 1].lowercased() == "on"
        if #available(macOS 13.0, *) {
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        }
    }
}
