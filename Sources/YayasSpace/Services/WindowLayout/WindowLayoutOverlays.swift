// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit

/// While a window is dragged, optionally shows every drag area faintly, one
/// click-through panel per display, with the area under the pointer drawn
/// brighter. Built once per drag and redrawn only when the area under the
/// pointer changes, so a drag never pays for it per event.
final class WindowLayoutOverlays {
    static let shared = WindowLayoutOverlays()

    private var panels: [NSPanel] = []
    private var isShowing = false

    private init() {}

    func beginDrag(screens: [WindowActivationScreen],
                   commands: WindowCommandConfiguration,
                   settings: WindowActivationSettings) {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutHighlightAreas) else { return }
        if panels.count != screens.count {
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { _ in Self.makePanel() }
        }
        for (screen, panel) in zip(screens, panels) {
            panel.setFrame(screen.frame, display: false)
            guard let view = panel.contentView as? WindowActivationAreasView else { continue }
            view.configure(screen: screen,
                           commands: commands[screen.setKind],
                           grid: screen.setKind.grid,
                           settings: settings)
            panel.orderFrontRegardless()
        }
        isShowing = true
    }

    func highlight(commandID: UUID?) {
        guard isShowing else { return }
        for panel in panels {
            (panel.contentView as? WindowActivationAreasView)?.highlightedID = commandID
        }
    }

    func endDrag() {
        guard isShowing else { return }
        isShowing = false
        for panel in panels {
            (panel.contentView as? WindowActivationAreasView)?.highlightedID = nil
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Just under the drop preview, which sits at the status bar level,
        // and above every ordinary window.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = WindowActivationAreasView(frame: .zero)
        return panel
    }
}

/// Draws one display's drag areas. Everything is computed once per drag in
/// `configure`; a highlight change only repaints.
private final class WindowActivationAreasView: NSView {
    private struct Area {
        let id: UUID
        let rects: [CGRect]
        let isInterior: Bool
    }

    private var areas: [Area] = []

    var highlightedID: UUID? {
        didSet { if oldValue != highlightedID { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func configure(screen: WindowActivationScreen,
                   commands: [WindowCommand],
                   grid: WindowGrid,
                   settings: WindowActivationSettings) {
        let origin = screen.frame.origin
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        // Bands a few points thick at least, so an 8 pt reach still reads.
        let visual = WindowActivationSettings(edgeWidth: max(settings.edgeWidth, 5),
                                              interiorScale: settings.interiorScale)
        areas = commands.compactMap { command in
            guard let region = command.effectiveActivation else { return nil }
            let parts = WindowActivationHitTest.hitRects(for: region, grid: grid, screen: screen, settings: visual)
            let rects = parts.parts.map { part in
                part.rect.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
            }.filter { !$0.isNull && !$0.isEmpty }
            guard !rects.isEmpty else { return nil }
            if case .interior = region {
                return Area(id: command.id, rects: rects, isInterior: true)
            }
            return Area(id: command.id, rects: rects, isInterior: false)
        }
        highlightedID = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor
        for area in areas {
            let lit = area.id == highlightedID
            context.saveGState()
            for rect in area.rects {
                let inset = rect.insetBy(dx: 1, dy: 1)
                guard inset.width > 0, inset.height > 0 else { continue }
                let radius = max(0, min(area.isInterior ? 12 : .greatestFiniteMagnitude,
                                        inset.width / 2, inset.height / 2))
                let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius,
                                  transform: nil)
                context.addPath(path)
                context.setFillColor(accent.withAlphaComponent(lit ? 0.42 : 0.14).cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(accent.withAlphaComponent(lit ? 0.95 : 0.4).cgColor)
                context.setLineWidth(lit ? 2 : 1)
                context.strokePath()
            }
            context.restoreGState()
        }
    }
}
