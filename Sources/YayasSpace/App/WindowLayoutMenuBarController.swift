// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import Carbon.HIToolbox

/// Window Layout's own menu-bar item, separate from Yaya's Space's icon. Its
/// menu lists the commands marked for the menu bar, from the set of the
/// display the front window is on, greyed where they could not change that
/// window, followed by settings, the ignore switch for the front app, help,
/// About and Quit. The menu is rebuilt each time it opens and holds nothing
/// in between.
final class WindowLayoutMenuBarController: NSObject, NSMenuDelegate {
    static let shared = WindowLayoutMenuBarController()

    /// The README section the Help item opens in the browser.
    static let helpURL = URL(string: "https://github.com/YahyaElghobashy/yayas-space-mac#window-layout")!

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var context: WindowCommandMenuContext?

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func sync(visible: Bool) {
        visible ? install() : remove()
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "YayasSpaceWindowLayoutItem"
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            button.image = Self.statusImage()
            button.imagePosition = .imageOnly
            let title = WindowCommandStrings.localized(L10n.shared.language).statusItemTitle
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }
        item.menu = menu
        statusItem = item
    }

    private func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let text = WindowCommandStrings.localized(L10n.shared.language)
        let language = L10n.shared.language
        let service = WindowLayoutService.shared
        let context = service.menuContext()
        self.context = context
        let set = WindowCommandStore.shared.commands(context.setKind)
        let grid = context.setKind.grid
        for command in WindowCommandMenuLayout.entries(of: set, including: { $0.showInMenuBar }) {
            if command.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: WindowCommandStrings.displayName(of: command, language: language),
                                  action: #selector(runCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.id
            item.image = WindowCommandGlyph.image(for: command.kind, grid: grid,
                                                  size: NSSize(width: 21, height: 14))
            if let shortcut = command.effectiveShortcut,
               UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled),
               let equivalent = Self.keyEquivalent(for: shortcut) {
                item.keyEquivalent = equivalent
                item.keyEquivalentModifierMask = Self.modifierMask(for: shortcut.modifiers)
            }
            item.isEnabled = service.isAvailable(command, in: context)
            menu.addItem(item)
        }
        if menu.items.last.map({ !$0.isSeparatorItem }) ?? false { menu.addItem(.separator()) }

        let settings = NSMenuItem(title: text.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil)
        menu.addItem(settings)

        if let appName = context.appName, context.bundleID != nil {
            menu.addItem(.separator())
            let format = context.isIgnored ? text.menuStopIgnoringFormat : text.menuIgnoreFormat
            let ignore = NSMenuItem(title: String(format: format, appName),
                                    action: #selector(toggleIgnore),
                                    keyEquivalent: "")
            ignore.target = self
            ignore.image = NSImage(systemSymbolName: context.isIgnored ? "eye" : "eye.slash",
                                   accessibilityDescription: nil)
            menu.addItem(ignore)
        }

        menu.addItem(.separator())
        let help = NSMenuItem(title: text.menuHelp, action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(help)
        let about = NSMenuItem(title: String(format: text.menuAboutFormat, AppInfo.name),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(format: text.menuQuitFormat, AppInfo.name),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    func menuDidClose(_ menu: NSMenu) {
        context = nil
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let found = WindowCommandStore.shared.command(id: id) else { return }
        // After the menu is gone, so the app in front is the one acted on.
        DispatchQueue.main.async {
            if case .failure = WindowLayoutService.shared.apply(found.command, setKind: found.kind) {
                NSSound.beep()
            }
        }
    }

    @objc private func openSettings() {
        SettingsRouter.shared.page = .windowLayout
        appDelegate()?.openSettingsWindow()
    }

    @objc private func toggleIgnore() {
        guard let bundleID = context?.bundleID else { return }
        WindowLayoutService.shared.toggleIgnored(bundleID: bundleID)
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc private func showAbout() {
        appDelegate()?.showAbout()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Key equivalents

    /// The character a menu shows for a shortcut's key, so every command's
    /// combination appears on its row.
    static func keyEquivalent(for shortcut: GlobalShortcut) -> String? {
        func scalar(_ value: Int) -> String? { UnicodeScalar(value).map { String(Character($0)) } }
        switch Int(shortcut.keyCode) {
        case kVK_LeftArrow: return scalar(NSLeftArrowFunctionKey)
        case kVK_RightArrow: return scalar(NSRightArrowFunctionKey)
        case kVK_UpArrow: return scalar(NSUpArrowFunctionKey)
        case kVK_DownArrow: return scalar(NSDownArrowFunctionKey)
        case kVK_Return: return "\r"
        case kVK_ANSI_KeypadEnter: return scalar(NSEnterCharacter)
        case kVK_Delete: return scalar(NSBackspaceCharacter)
        case kVK_ForwardDelete: return scalar(NSDeleteFunctionKey)
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Escape: return "\u{1b}"
        case kVK_Home: return scalar(NSHomeFunctionKey)
        case kVK_End: return scalar(NSEndFunctionKey)
        case kVK_PageUp: return scalar(NSPageUpFunctionKey)
        case kVK_PageDown: return scalar(NSPageDownFunctionKey)
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            guard let label = shortcut.keyCaps.last, let number = Int(label.dropFirst()) else { return nil }
            return scalar(NSF1FunctionKey + number - 1)
        default:
            guard let label = shortcut.keyCaps.last, label.count == 1 else { return nil }
            return label.lowercased()
        }
    }

    static func modifierMask(for modifiers: GlobalShortcutModifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }

    // MARK: Icon

    /// A small tiled-display mark: one tall pane beside two stacked ones,
    /// drawn here as a template so it follows the menu bar's look.
    static func statusImage() -> NSImage {
        let size = NSSize(width: 20, height: 15)
        let image = NSImage(size: size, flipped: false) { _ in
            let outline = NSRect(x: 1.5, y: 1.5, width: 17, height: 12)
            let frame = NSBezierPath(roundedRect: outline, xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.4
            NSColor.black.setStroke()
            frame.stroke()
            let inner = outline.insetBy(dx: 2.2, dy: 2.2)
            let gap: CGFloat = 1.4
            let leftWidth = (inner.width - gap) * 0.52
            let left = NSRect(x: inner.minX, y: inner.minY, width: leftWidth, height: inner.height)
            let rightX = left.maxX + gap
            let rightWidth = inner.maxX - rightX
            let paneHeight = (inner.height - gap) / 2
            NSColor.black.setFill()
            NSBezierPath(roundedRect: left, xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: rightX, y: inner.minY, width: rightWidth, height: paneHeight),
                         xRadius: 1, yRadius: 1).fill()
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: rightX, y: inner.minY + paneHeight + gap,
                                             width: rightWidth, height: paneHeight),
                         xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
