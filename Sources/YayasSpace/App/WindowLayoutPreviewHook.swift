// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

#if YAYASSPACE_DEVELOPMENT
import AppKit

/// Developer builds only: `--window-layout-preview <general|commands|menu>`
/// opens the Window Layout tab or menu it names a moment after launch, so the
/// screens can be captured without driving the pointer. `commands` takes an
/// optional command name after a colon (`commands:Right`) to select it.
enum WindowLayoutPreviewHook {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--window-layout-preview"),
              arguments.indices.contains(index + 1) else { return }
        let request = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { perform(request) }
    }

    private static func perform(_ request: String) {
        let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "general":
            open(tab: .general)
        case "commands":
            let selection = WindowCommandSelection.shared
            selection.kind = .horizontal
            if parts.count > 1 {
                let wanted = parts[1]
                let match = WindowCommandStore.shared.commands(.horizontal).first {
                    WindowCommandStrings.displayName(of: $0, language: L10n.shared.language) == wanted
                }
                selection.select(match?.id, in: .horizontal)
            }
            open(tab: .commands)
        case "menu":
            WindowLayoutMenuBarController.shared.openMenu()
        case "green":
            // Beside the Settings window's own green button.
            open(tab: .general)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                      let zoom = window.standardWindowButton(.zoomButton) else { return }
                let frame = window.convertToScreen(zoom.convert(zoom.bounds, to: nil))
                WindowGreenButtonService.shared.previewMenu(beside: frame)
            }
        default:
            break
        }
    }

    private static func open(tab: WindowLayoutSettingsTabs.Tab) {
        WindowLayoutSettingsTabs.shared.tab = tab
        SettingsRouter.shared.page = .windowLayout
        appDelegate()?.openSettingsWindow()
        // Captured windows read best while active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
