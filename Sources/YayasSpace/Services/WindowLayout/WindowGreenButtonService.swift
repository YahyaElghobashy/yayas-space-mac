// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import ApplicationServices

/// Opens a menu of commands when the pointer rests on a window's green
/// (zoom) button. Cheap by construction: the global monitor only records
/// that the pointer moved; one timer waits until it has been still for the
/// hover delay, and only then asks Accessibility what is under it, once per
/// resting spot and never faster than ~30 Hz. A pointer that keeps moving
/// never triggers a single Accessibility call.
final class WindowGreenButtonService {
    static let shared = WindowGreenButtonService()

    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var restTimer: Timer?
    private var lastMoveAt: TimeInterval = 0
    private var lastHitTestAt: TimeInterval = 0
    private var lastTestedPoint: CGPoint?
    private var menu: WindowGreenButtonMenuController?

    private init() {}

    var isRunning: Bool { moveMonitor != nil }

    func sync(enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pointerMoved()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.pointerPressedElsewhere()
        }
    }

    func stop() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        moveMonitor = nil
        clickMonitor = nil
        restTimer?.invalidate()
        restTimer = nil
        lastTestedPoint = nil
        closeMenu()
    }

    private var hoverDelay: TimeInterval {
        let milliseconds = WindowGreenButtonMenuLayout.sanitizedDelay(
            UserDefaults.standard.integer(forKey: DefaultsKey.windowLayoutGreenButtonDelay))
        return max(WindowGreenButtonMenuLayout.minimumRest, Double(milliseconds) / 1_000)
    }

    private func pointerMoved() {
        lastMoveAt = ProcessInfo.processInfo.systemUptime
        if let menu {
            menu.pointerMoved(to: NSEvent.mouseLocation)
            return
        }
        scheduleRestCheck(after: hoverDelay)
    }

    private func pointerPressedElsewhere() {
        restTimer?.invalidate()
        restTimer = nil
        // A click on the button itself is the system's zoom; let it happen
        // and step aside.
        closeMenu()
        lastTestedPoint = NSEvent.mouseLocation
    }

    /// One pending check at a time. If the pointer kept moving, the check
    /// just waits out the rest of the delay again.
    private func scheduleRestCheck(after interval: TimeInterval) {
        guard restTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restTimer = nil
            self.checkRest()
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    private func checkRest() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = hoverDelay
        let rested = now - lastMoveAt
        if rested < delay {
            scheduleRestCheck(after: delay - rested)
            return
        }
        let point = NSEvent.mouseLocation
        if let last = lastTestedPoint, hypot(last.x - point.x, last.y - point.y) < 1 { return }
        let sinceLast = now - lastHitTestAt
        if sinceLast < WindowGreenButtonMenuLayout.minimumRest {
            scheduleRestCheck(after: WindowGreenButtonMenuLayout.minimumRest - sinceLast)
            return
        }
        lastHitTestAt = now
        lastTestedPoint = point
        hitTest(at: point)
    }

    private func hitTest(at point: CGPoint) {
        guard AXIsProcessTrusted(),
              UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutGreenButtonMenuEnabled)
        else { return }
        let quartz = CGPoint(x: point.x, y: Self.primaryScreenTop - point.y)
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(quartz.x), Float(quartz.y), &raw) == .success,
              let button = raw
        else { return }
        AXUIElementSetMessagingTimeout(button, 0.25)
        guard Self.string(button, kAXRoleAttribute) == (kAXButtonRole as String),
              Self.string(button, kAXSubroleAttribute) == (kAXZoomButtonSubrole as String),
              let window = Self.element(button, kAXWindowAttribute)
        else { return }
        var pid = pid_t(0)
        guard AXUIElementGetPid(button, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              !WindowLayoutService.shared.isIgnored(bundleID: app.bundleIdentifier),
              !Self.bool(window, "AXFullScreen"),
              let buttonFrame = Self.frame(of: button)
        else { return }
        let appKitButton = CGRect(x: buttonFrame.minX,
                                  y: Self.primaryScreenTop - buttonFrame.maxY,
                                  width: buttonFrame.width,
                                  height: buttonFrame.height)
        openMenu(for: window, buttonFrame: appKitButton)
    }

    private func openMenu(for window: AXUIElement, buttonFrame: CGRect) {
        closeMenu()
        let context = WindowLayoutService.shared.menuContext(window: window)
        guard context.hasWindow else { return }
        let set = WindowCommandStore.shared.commands(context.setKind)
        let entries = WindowCommandMenuLayout.entries(of: set) { $0.showInGreenButtonMenu }
        guard entries.contains(where: { !$0.isSeparator }) else { return }
        let items = entries.map { command in
            WindowGreenButtonMenuItem(command: command,
                                      title: WindowCommandStrings.displayName(of: command,
                                                                              language: L10n.shared.language),
                                      isEnabled: command.isSeparator
                                          || WindowLayoutService.shared.isAvailable(command, in: context))
        }
        let layout = WindowGreenButtonMenuLayout.sanitized(
            UserDefaults.standard.string(forKey: DefaultsKey.windowLayoutGreenButtonLayout))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)) }
            ?? NSScreen.main
        let controller = WindowGreenButtonMenuController(items: items,
                                                         layout: layout,
                                                         grid: context.setKind.grid,
                                                         buttonFrame: buttonFrame,
                                                         visibleFrame: screen?.visibleFrame ?? buttonFrame)
        controller.onChoose = { [weak self] command in
            self?.closeMenu()
            WindowLayoutService.shared.apply(command, setKind: context.setKind, window: window)
        }
        controller.onClose = { [weak self] in
            self?.menu = nil
        }
        menu = controller
        controller.show()
    }

    private func closeMenu() {
        let current = menu
        menu = nil
        current?.close()
    }

    // MARK: Accessibility reads

    private static var primaryScreenTop: CGFloat {
        let primary = NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
        return (primary ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

struct WindowGreenButtonMenuItem {
    let command: WindowCommand
    let title: String
    let isEnabled: Bool
}

/// The open menu: a non-activating panel beside the green button. It closes
/// on a choice, on a click elsewhere, on Escape, or shortly after the
/// pointer leaves both the panel and the button.
final class WindowGreenButtonMenuController {
    var onChoose: ((WindowCommand) -> Void)?
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let buttonFrame: CGRect
    private var leaveTimer: Timer?
    private var keyMonitor: Any?
    private var closed = false

    init(items: [WindowGreenButtonMenuItem],
         layout: WindowGreenButtonMenuLayout,
         grid: WindowGrid,
         buttonFrame: CGRect,
         visibleFrame: CGRect) {
        self.buttonFrame = buttonFrame
        let content = WindowGreenButtonMenuView(items: items, layout: layout, grid: grid)
        let size = content.preferredSize
        let frame = WindowGreenButtonMenuPlacement.frame(buttonFrame: buttonFrame,
                                                         menuSize: size,
                                                         visibleFrame: visibleFrame,
                                                         reservesSystemMenu: true)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        background.autoresizingMask = [.width, .height]
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background

        content.onChoose = { [weak self] command in self?.onChoose?(command) }
        content.onHoverChange = { [weak self] inside in
            if inside { self?.cancelLeave() } else { self?.scheduleLeave() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close() } // Escape
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        leaveTimer?.invalidate()
        leaveTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
        onClose?()
    }

    /// Global pointer moves while open (the panel's own area reports through
    /// its tracking area instead).
    func pointerMoved(to point: CGPoint) {
        if panel.frame.insetBy(dx: -6, dy: -6).contains(point)
            || buttonFrame.insetBy(dx: -4, dy: -4).contains(point) {
            cancelLeave()
        } else {
            scheduleLeave()
        }
    }

    private func scheduleLeave() {
        guard leaveTimer == nil, !closed else { return }
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.leaveTimer = nil
            self?.close()
        }
        RunLoop.main.add(timer, forMode: .common)
        leaveTimer = timer
    }

    private func cancelLeave() {
        leaveTimer?.invalidate()
        leaveTimer = nil
    }
}

/// Draws the menu's items, list or grid, and reports hovering and choices.
private final class WindowGreenButtonMenuView: NSView {
    var onChoose: ((WindowCommand) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private let items: [WindowGreenButtonMenuItem]
    private let layout: WindowGreenButtonMenuLayout
    private let grid: WindowGrid
    private var slots: [(index: Int, rect: CGRect)] = []
    private var separators: [CGRect] = []
    private var hovered: Int?
    private(set) var preferredSize = CGSize(width: 200, height: 40)

    private static let padding: CGFloat = 6
    private static let rowHeight: CGFloat = 24
    private static let separatorHeight: CGFloat = 9
    private static let listWidth: CGFloat = 250
    private static let cell = CGSize(width: 40, height: 30)
    private static let gridColumns = 5
    private static let footerHeight: CGFloat = 22

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(items: [WindowGreenButtonMenuItem], layout: WindowGreenButtonMenuLayout, grid: WindowGrid) {
        self.items = items
        self.layout = layout
        self.grid = grid
        super.init(frame: .zero)
        buildLayout()
        setAccessibilityRole(.menu)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayout() {
        slots = []
        separators = []
        let pad = Self.padding
        switch layout {
        case .list:
            var y = pad
            for (index, item) in items.enumerated() {
                if item.command.isSeparator {
                    separators.append(CGRect(x: pad + 8, y: y + Self.separatorHeight / 2,
                                             width: Self.listWidth - pad * 2 - 16, height: 1))
                    y += Self.separatorHeight
                } else {
                    slots.append((index, CGRect(x: pad, y: y, width: Self.listWidth - pad * 2, height: Self.rowHeight)))
                    y += Self.rowHeight
                }
            }
            preferredSize = CGSize(width: Self.listWidth, height: y + pad)
        case .grid:
            // Each group of the list starts a row of its own.
            var x = pad
            var y = pad
            var column = 0
            var widest: CGFloat = 0
            for (index, item) in items.enumerated() {
                if item.command.isSeparator {
                    if column > 0 {
                        y += Self.cell.height + 4
                        x = pad
                        column = 0
                    }
                    continue
                }
                if column == Self.gridColumns {
                    y += Self.cell.height + 4
                    x = pad
                    column = 0
                }
                slots.append((index, CGRect(x: x, y: y, width: Self.cell.width, height: Self.cell.height)))
                x += Self.cell.width + 4
                widest = max(widest, x)
                column += 1
            }
            if column > 0 { y += Self.cell.height + 4 }
            preferredSize = CGSize(width: max(widest - 4 + pad, 150), height: y + Self.footerHeight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        onHoverChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(slots.first { $0.rect.contains(point) }?.index)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let slot = slots.first(where: { $0.rect.contains(point) }),
              items[slot.index].isEnabled else { return }
        onChoose?(items[slot.index].command)
    }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for line in separators {
            NSColor.separatorColor.setFill()
            line.fill()
        }
        let shortcutFont = NSFont.systemFont(ofSize: 12)
        let titleFont = NSFont.menuFont(ofSize: 13)
        for (index, rect) in slots {
            let item = items[index]
            let isHovered = hovered == index && item.isEnabled
            if isHovered {
                let highlight = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                highlight.fill()
            }
            let glyphStyle: WindowCommandGlyph.Style = item.isEnabled ? .accent : .dimmed
            switch layout {
            case .list:
                let glyphRect = CGRect(x: rect.minX + 8, y: rect.midY - 7, width: 22, height: 14)
                WindowCommandGlyph.draw(item.command.kind, grid: grid, in: glyphRect, context: context,
                                        style: isHovered ? .onAccent : glyphStyle)
                let color: NSColor = isHovered ? .white : (item.isEnabled ? .labelColor : .disabledControlTextColor)
                let title = NSAttributedString(string: item.title,
                                               attributes: [.font: titleFont, .foregroundColor: color])
                let titleSize = title.size()
                var shortcutWidth: CGFloat = 0
                if let shortcut = item.command.effectiveShortcut {
                    let text = NSAttributedString(
                        string: shortcut.displayString,
                        attributes: [.font: shortcutFont,
                                     .foregroundColor: isHovered ? NSColor.white.withAlphaComponent(0.85)
                                         : NSColor.secondaryLabelColor.withAlphaComponent(item.isEnabled ? 1 : 0.5)])
                    let size = text.size()
                    shortcutWidth = size.width + 12
                    text.draw(at: CGPoint(x: rect.maxX - 10 - size.width, y: rect.midY - size.height / 2))
                }
                let titleRect = CGRect(x: glyphRect.maxX + 10, y: rect.midY - titleSize.height / 2,
                                       width: rect.maxX - glyphRect.maxX - 20 - shortcutWidth,
                                       height: titleSize.height)
                title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            case .grid:
                let glyphRect = CGRect(x: rect.midX - 13, y: rect.midY - 8.5, width: 26, height: 17)
                WindowCommandGlyph.draw(item.command.kind, grid: grid, in: glyphRect, context: context,
                                        style: isHovered ? .onAccent : glyphStyle)
            }
        }
        if layout == .grid {
            let caption: String
            if let hovered {
                let item = items[hovered]
                caption = [item.title, item.command.effectiveShortcut?.displayString]
                    .compactMap { $0 }.joined(separator: "   ")
            } else {
                caption = ""
            }
            let text = NSAttributedString(string: caption,
                                          attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                       .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size()
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                  y: bounds.height - Self.footerHeight + (Self.footerHeight - size.height) / 2 - 2))
        }
    }
}
