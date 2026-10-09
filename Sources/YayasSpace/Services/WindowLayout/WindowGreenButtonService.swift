// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import ApplicationServices

/// Opens a menu of commands when the pointer rests on a window's green
/// (zoom) button. While it runs, the system's own green-button menu waits
/// for a held key, and resting with that key held leaves the button to it.
/// Cheap by construction: the global monitor only records
/// that the pointer moved; one timer waits until it has been still for the
/// hover delay, then asks the window server, never faster than ~30 Hz,
/// which ordinary window is in front under the pointer. Only a pointer
/// resting in that window's traffic-light corner goes on to ask
/// Accessibility what is under it. A pointer that keeps moving, or rests
/// anywhere else, never triggers a single Accessibility call.
final class WindowGreenButtonService {
    static let shared = WindowGreenButtonService()

    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var restTimer: Timer?
    private var lastMoveAt: TimeInterval = 0
    private var lastHitTestAt: TimeInterval = 0
    private var lastTestedPoint: CGPoint?
    private var menu: WindowGreenButtonMenuController?
    /// The hover delay and the key that asks for the system's menu, read
    /// once and again only when their preferences change, never on a
    /// pointer move.
    private var hoverDelay = WindowGreenButtonService.storedHoverDelay()
    private var systemMenuKey = WindowGreenButtonService.storedSystemMenuKey()
    private var preferenceObserver: WindowLayoutDefaultsObserver?

    private init() {}

    var isRunning: Bool { moveMonitor != nil }

    func sync(enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard moveMonitor == nil else { return }
        hoverDelay = Self.storedHoverDelay()
        systemMenuKey = Self.storedSystemMenuKey()
        WindowSystemZoomMenu.takeOver(for: systemMenuKey)
        preferenceObserver = WindowLayoutDefaultsObserver(
            keys: [DefaultsKey.windowLayoutGreenButtonDelay, DefaultsKey.windowLayoutGreenButtonSystemMenuKey]
        ) { [weak self] in
            DispatchQueue.main.async { self?.preferencesChanged() }
        }
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
        preferenceObserver = nil
        restTimer?.invalidate()
        restTimer = nil
        lastTestedPoint = nil
        closeMenu()
        // The system's own menu comes back as it was whenever this one stops:
        // switched off, Accessibility revoked or the app quitting.
        WindowSystemZoomMenu.handBack()
    }

    private func preferencesChanged() {
        guard moveMonitor != nil else { return }
        hoverDelay = Self.storedHoverDelay()
        let key = Self.storedSystemMenuKey()
        guard key != systemMenuKey else { return }
        systemMenuKey = key
        WindowSystemZoomMenu.takeOver(for: key)
    }

    private static func storedSystemMenuKey() -> WindowSystemZoomMenuKey {
        WindowSystemZoomMenuKey.sanitized(
            UserDefaults.standard.string(forKey: DefaultsKey.windowLayoutGreenButtonSystemMenuKey))
    }

    private static func storedHoverDelay() -> TimeInterval {
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
        // Resting with the key held asks for the system's own menu instead.
        if NSEvent.modifierFlags.contains(systemMenuKey.modifierFlag) { return }
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
        guard AXIsProcessTrusted() else { return }
        let quartz = CGPoint(x: point.x, y: Self.primaryScreenTop - point.y)
        // The window server first: the front-most ordinary window under the
        // pointer, and only if the pointer rests in its traffic-light corner.
        // Ignored apps, Yaya's Space itself and agents end the search there.
        let ignored = WindowLayoutService.shared.ignoredBundleIDs
        guard let candidate = WindowServerTrafficLightHitTest.candidate(at: quartz, button: .zoom, pidIsEligible: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && app.activationPolicy == .regular
                && !WindowLayoutIgnoreList.contains(app.bundleIdentifier, in: ignored)
        }) else { return }
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(quartz.x), Float(quartz.y), &raw) == .success,
              let button = raw
        else { return }
        AXUIElementSetMessagingTimeout(button, 0.25)
        guard WindowGreenButtonIdentity.isGreenButton(role: Self.string(button, kAXRoleAttribute),
                                                      subrole: Self.string(button, kAXSubroleAttribute)),
              let window = Self.element(button, kAXWindowAttribute)
        else { return }
        var pid = pid_t(0)
        guard AXUIElementGetPid(button, &pid) == .success,
              pid == candidate.pid,
              AXWindowResolver.windowID(for: window).map({ $0 == candidate.windowID }) ?? true,
              !Self.bool(window, "AXFullScreen"),
              let buttonFrame = Self.frame(of: button)
        else { return }
        let appKitButton = CGRect(x: buttonFrame.minX,
                                  y: Self.primaryScreenTop - buttonFrame.maxY,
                                  width: buttonFrame.width,
                                  height: buttonFrame.height)
        openMenu(for: window, buttonFrame: appKitButton)
    }

#if YAYASSPACE_DEVELOPMENT
    /// Developer builds only: shows the menu for the current set beside a
    /// given button frame, with nothing to act on, so its look can be
    /// checked without Accessibility.
    func previewMenu(beside buttonFrame: CGRect) {
        closeMenu()
        let set = WindowCommandStore.shared.commands(.horizontal)
        let entries = WindowCommandMenuLayout.entries(of: set) { $0.showInGreenButtonMenu }
        let items = entries.map { command in
            WindowGreenButtonMenuItem(command: command,
                                      title: WindowCommandStrings.displayName(of: command,
                                                                              language: L10n.shared.language),
                                      isEnabled: command.kind != .restore && command.kind != .previousDisplay
                                          && command.kind != .nextDisplay)
        }
        let layout = WindowGreenButtonMenuLayout.sanitized(
            UserDefaults.standard.string(forKey: DefaultsKey.windowLayoutGreenButtonLayout))
        let screen = NSScreen.main
        let controller = WindowGreenButtonMenuController(items: items, layout: layout,
                                                         grid: WindowCommandSetKind.horizontal.grid,
                                                         buttonFrame: buttonFrame,
                                                         visibleFrame: screen?.visibleFrame ?? buttonFrame)
        controller.onClose = { [weak self] in self?.menu = nil }
        menu = controller
        controller.show()
    }
#endif

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

/// AppKit's own green-button menu, kept for a held key while the
/// green-button menu runs, through the global preference AppKit reads on
/// every hover (`WindowSystemZoomMenuPreference` holds the rules). What it
/// found is remembered in this app's preferences before anything is
/// written, so even a crash leaves the next start able to hand it back.
enum WindowSystemZoomMenu {
    private typealias Preference = WindowSystemZoomMenuPreference

    static func takeOver(for key: WindowSystemZoomMenuKey) {
        let next = Preference.takingOver(current, option: key.systemMenuOption)
        remember(next)
        writeSystem(next.system)
    }

    static func handBack() {
        let state = current
        guard state.saved != nil else { return }
        let next = Preference.handingBack(state)
        writeSystem(next.system)
        remember(next)
    }

    private static var current: Preference.State {
        let defaults = UserDefaults.standard
        let system = CFPreferencesCopyValue(Preference.key as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
        return Preference.State(system: system,
                                saved: defaults.object(forKey: DefaultsKey.windowLayoutSystemZoomMenuSaved) as? Int,
                                written: defaults.object(forKey: DefaultsKey.windowLayoutSystemZoomMenuWritten) as? Int)
    }

    private static func remember(_ state: Preference.State) {
        let defaults = UserDefaults.standard
        for (key, value) in [(DefaultsKey.windowLayoutSystemZoomMenuSaved, state.saved),
                             (DefaultsKey.windowLayoutSystemZoomMenuWritten, state.written)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private static func writeSystem(_ value: Int?) {
        CFPreferencesSetValue(Preference.key as CFString, value.map { NSNumber(value: $0) },
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

private extension WindowSystemZoomMenuKey {
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .command: return .command
        }
    }
}

/// The menu's outline: a rounded body with an arrow on the edge that faces
/// the button, its tip slightly rounded.
enum WindowGreenButtonMenuShape {
    static let cornerRadius: CGFloat = 10

    static func outline(body: CGRect, arrowX: CGFloat,
                        edge: WindowGreenButtonMenuPlacement.Edge) -> NSBezierPath {
        let r = cornerRadius
        let arrow = WindowGreenButtonMenuPlacement.arrowSize
        let half = arrow.width / 2
        let path = NSBezierPath()
        // Counter-clockwise from the bottom edge's left end.
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if edge == .above {
            path.line(to: CGPoint(x: arrowX - half, y: body.minY))
            path.appendArc(from: CGPoint(x: arrowX, y: body.minY - arrow.height),
                           to: CGPoint(x: arrowX + half, y: body.minY), radius: 2)
            path.line(to: CGPoint(x: arrowX + half, y: body.minY))
        }
        path.line(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.appendArc(withCenter: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r,
                       startAngle: 270, endAngle: 360)
        path.line(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.appendArc(withCenter: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                       startAngle: 0, endAngle: 90)
        if edge == .below {
            path.line(to: CGPoint(x: arrowX + half, y: body.maxY))
            path.appendArc(from: CGPoint(x: arrowX, y: body.maxY + arrow.height),
                           to: CGPoint(x: arrowX - half, y: body.maxY), radius: 2)
            path.line(to: CGPoint(x: arrowX - half, y: body.maxY))
        }
        path.line(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.appendArc(withCenter: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                       startAngle: 90, endAngle: 180)
        path.line(to: CGPoint(x: body.minX, y: body.minY + r))
        path.appendArc(withCenter: CGPoint(x: body.minX + r, y: body.minY + r), radius: r,
                       startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// The material's mask: opaque inside the outline only.
    static func mask(size: CGSize, outline: NSBezierPath) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            outline.fill()
            return true
        }
    }
}

/// The hairline around the menu and its arrow. It never takes the pointer.
private final class WindowGreenButtonMenuBorder: NSView {
    private let outline: NSBezierPath

    init(frame: CGRect, outline: NSBezierPath) {
        self.outline = outline
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        let line = outline.copy() as! NSBezierPath
        line.lineWidth = 1
        // Inside the mask, so the material's own edge never shows past it.
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct WindowGreenButtonMenuItem {
    let command: WindowCommand
    let title: String
    let isEnabled: Bool
}

/// The open menu: a non-activating panel hanging from the green button, its
/// arrow on the button. It closes on a choice, on a click elsewhere, on
/// Escape, or shortly after the pointer leaves the panel, the button and the
/// corridor between them.
///
/// The keyboard always stays with the app in front: the panel never becomes
/// the key window, not when it opens and not under the pointer, so typing
/// in that app is never taken. Escape closes the menu from a global monitor
/// that only watches; the key still reaches the app. The pointer picks a
/// command, and VoiceOver reaches each one as a button it can press, which
/// needs no keyboard focus.
final class WindowGreenButtonMenuController {
    var onChoose: ((WindowCommand) -> Void)?
    var onClose: (() -> Void)?

    private let panel: WindowGreenButtonMenuPanel
    private let content: WindowGreenButtonMenuView
    private let buttonFrame: CGRect
    private var leaveTimer: Timer?
    /// Watch for Escape, typed into the app in front or, when Yaya's Space
    /// is that app, into its own windows; neither ever consumes it.
    private var escapeMonitor: Any?
    private var ownEscapeMonitor: Any?
    private var closed = false

    init(items: [WindowGreenButtonMenuItem],
         layout: WindowGreenButtonMenuLayout,
         grid: WindowGrid,
         buttonFrame: CGRect,
         visibleFrame: CGRect) {
        self.buttonFrame = buttonFrame
        let content = WindowGreenButtonMenuView(items: items, layout: layout, grid: grid)
        self.content = content
        let size = content.preferredSize
        let placement = WindowGreenButtonMenuPlacement.layout(buttonFrame: buttonFrame,
                                                              contentSize: size,
                                                              visibleFrame: visibleFrame)
        panel = WindowGreenButtonMenuPanel(contentRect: placement.frame,
                                           styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered,
                                           defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow

        // One outline, the body and its arrow, shapes the material, the
        // border and so the shadow.
        let bounds = CGRect(origin: .zero, size: placement.frame.size)
        let outline = WindowGreenButtonMenuShape.outline(body: placement.body,
                                                         arrowX: placement.arrowX,
                                                         edge: placement.edge)
        let background = NSVisualEffectView(frame: bounds)
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = WindowGreenButtonMenuShape.mask(size: bounds.size, outline: outline)
        if placement.scrolls {
            // Too tall for the room beside the button: the commands scroll.
            let scroll = NSScrollView(frame: placement.body)
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            content.frame = CGRect(x: 0, y: 0, width: placement.body.width, height: size.height)
            scroll.documentView = content
            background.addSubview(scroll)
        } else {
            content.frame = placement.body
            background.addSubview(content)
        }
        background.addSubview(WindowGreenButtonMenuBorder(frame: bounds, outline: outline))
        panel.contentView = background

        content.onChoose = { [weak self] command in self?.onChoose?(command) }
        content.onHoverChange = { [weak self] inside in
            if inside {
                self?.cancelLeave()
            } else {
                self?.scheduleLeave()
            }
        }
    }

    /// Shown in front without becoming the key window or activating Yaya's
    /// Space: the app in front keeps the keyboard.
    func show() {
        panel.orderFrontRegardless()
        // The shadow follows the shaped content, arrow included.
        panel.display()
        panel.invalidateShadow()
        // Escape typed into the app in front closes the menu. The monitors
        // only watch, so the key still reaches that app.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close() } // Escape
        }
        ownEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.close() } // Escape
            return event
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        leaveTimer?.invalidate()
        leaveTimer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let ownEscapeMonitor { NSEvent.removeMonitor(ownEscapeMonitor) }
        escapeMonitor = nil
        ownEscapeMonitor = nil
        panel.orderOut(nil)
        onClose?()
    }

    /// Global pointer moves while open (the panel's own area reports through
    /// its tracking area instead). The corridor from the button to the menu
    /// counts as inside, so crossing it, even over the system's own
    /// green-button menu, never closes the menu on the way.
    func pointerMoved(to point: CGPoint) {
        if panel.frame.insetBy(dx: -6, dy: -6).contains(point)
            || buttonFrame.insetBy(dx: -4, dy: -4).contains(point)
            || WindowGreenButtonMenuPlacement.corridor(buttonFrame: buttonFrame,
                                                       menuFrame: panel.frame).contains(point) {
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

/// Never the key window, whatever asks: the keyboard stays with the app in
/// front. Clicks and VoiceOver presses reach the menu without it.
private final class WindowGreenButtonMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One command of the open menu as Accessibility sees it: a button that
/// VoiceOver can read and press.
private final class WindowGreenButtonMenuElement: NSAccessibilityElement {
    var onPress: (() -> Bool)?
    var frameOnScreen: (() -> CGRect)?

    override func accessibilityFrame() -> NSRect {
        frameOnScreen?() ?? .zero
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?() ?? false
    }
}

/// Draws the menu's items, list or grid, reports hovering and choices, and
/// answers Accessibility for them. It takes no keyboard input: the panel
/// never becomes the key window.
private final class WindowGreenButtonMenuView: NSView {
    var onChoose: ((WindowCommand) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private let items: [WindowGreenButtonMenuItem]
    private let layout: WindowGreenButtonMenuLayout
    private let grid: WindowGrid
    private var slots: [(index: Int, rect: CGRect)] = []
    private var separators: [CGRect] = []
    /// The item under the pointer.
    private var hovered: Int?
    private var accessibilityItems: [WindowGreenButtonMenuElement] = []
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

    /// Menus print the named keys as the caps on the keyboard.
    static func compactText(_ shortcut: GlobalShortcut) -> String {
        shortcut.displayString
            .replacingOccurrences(of: "Return", with: "↩")
            .replacingOccurrences(of: "Space", with: "␣")
            .replacingOccurrences(of: "Tab", with: "⇥")
            .replacingOccurrences(of: "Esc", with: "⎋")
    }

    init(items: [WindowGreenButtonMenuItem], layout: WindowGreenButtonMenuLayout, grid: WindowGrid) {
        self.items = items
        self.layout = layout
        self.grid = grid
        super.init(frame: .zero)
        buildLayout()
        buildAccessibility()
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

    // MARK: Accessibility

    /// A group of buttons, one per command, in list order; separators are
    /// left out. Each reads its name and shortcut and can be pressed.
    private func buildAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(WindowCommandStrings.localized(L10n.shared.language).statusItemTitle)
        accessibilityItems = slots.map { slot in
            let item = items[slot.index]
            let element = WindowGreenButtonMenuElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(item.title)
            if let shortcut = item.command.effectiveShortcut {
                element.setAccessibilityHelp(Self.compactText(shortcut))
            }
            element.setAccessibilityEnabled(item.isEnabled)
            element.setAccessibilityParent(self)
            element.frameOnScreen = { [weak self] in
                guard let self, let window = self.window else { return .zero }
                return window.convertToScreen(self.convert(slot.rect, to: nil))
            }
            element.onPress = { [weak self] in
                guard let self, item.isEnabled else { return false }
                self.onChoose?(item.command)
                return true
            }
            return element
        }
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityItems
    }

    // MARK: Pointer

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
                        string: Self.compactText(shortcut),
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
                caption = [item.title, item.command.effectiveShortcut.map(Self.compactText)]
                    .compactMap { $0 }.joined(separator: "   ")
            } else {
                caption = WindowCommandStrings.localized(L10n.shared.language).statusItemTitle
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
