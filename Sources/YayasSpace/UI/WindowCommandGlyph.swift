// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import SwiftUI

/// The small picture of a command: a miniature display with the command's
/// target filled in. Area commands draw their own rectangle, so every glyph
/// comes from the command itself; the fixed kinds get simple marks of their
/// own. Used by the settings list, the menu-bar menu and the green-button
/// menu.
enum WindowCommandGlyph {
    enum Style {
        /// Black on clear, for menus that tint template images themselves.
        case template
        /// Accent fill on a soft display, for our own views.
        case accent
        /// Accent fill, dimmed: a command that cannot act right now.
        case dimmed
        /// White, for a glyph drawn on a selected (accent) row.
        case onAccent
    }

    static func image(for kind: WindowCommandKind,
                      grid: WindowGrid,
                      size: NSSize,
                      style: Style = .template) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(kind, grid: grid, in: rect, context: context, style: style)
            return true
        }
        image.isTemplate = { if case .template = style { return true } else { return false } }()
        return image
    }

    /// Draws into a flipped (y down) rectangle.
    static func draw(_ kind: WindowCommandKind,
                     grid: WindowGrid,
                     in bounds: CGRect,
                     context: CGContext,
                     style: Style) {
        let colors = palette(style)
        let screen = bounds.insetBy(dx: 0.75, dy: 0.75)
        let radius = min(3, screen.height * 0.18)
        let screenPath = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(screenPath)
        context.setFillColor(colors.screen)
        context.fillPath()
        context.addPath(screenPath)
        context.setStrokeColor(colors.outline)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        let inner = screen.insetBy(dx: 1.75, dy: 1.75)
        context.saveGState()
        context.setFillColor(colors.fill)
        context.setStrokeColor(colors.fill)
        switch kind {
        case .area(let rect):
            let unit = rect.unitRect(in: grid)
            let target = CGRect(x: inner.minX + inner.width * unit.minX,
                                y: inner.minY + inner.height * unit.minY,
                                width: inner.width * unit.width,
                                height: inner.height * unit.height)
            fill(target.insetBy(dx: 0.35, dy: 0.35), context: context)
        case .maximize:
            fill(inner, context: context)
        case .marginMaximize:
            let margin = min(inner.width, inner.height) * 0.2
            fill(inner.insetBy(dx: margin, dy: margin), context: context)
        case .fullScreen:
            fill(inner, context: context)
            // A clear inner frame marks "the whole screen, chrome and all".
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.stroke(inner.insetBy(dx: 2.2, dy: 2.2))
        case .center:
            let box = CGRect(x: inner.midX - inner.width * 0.24, y: inner.midY - inner.height * 0.26,
                             width: inner.width * 0.48, height: inner.height * 0.52)
            fill(box, context: context)
            context.setLineWidth(1)
            context.setLineCap(.round)
            let reach = max(1, (inner.width - box.width) / 2 - 1.2)
            context.move(to: CGPoint(x: inner.minX, y: inner.midY))
            context.addLine(to: CGPoint(x: inner.minX + reach, y: inner.midY))
            context.move(to: CGPoint(x: inner.maxX, y: inner.midY))
            context.addLine(to: CGPoint(x: inner.maxX - reach, y: inner.midY))
            context.strokePath()
        case .restore:
            let center = CGPoint(x: inner.midX, y: inner.midY)
            let r = min(inner.width, inner.height) * 0.36
            context.setLineWidth(1.3)
            context.setLineCap(.round)
            context.addArc(center: center, radius: r, startAngle: .pi * 0.15, endAngle: .pi * 1.55, clockwise: false)
            context.strokePath()
            // Arrow head at the arc's open end, pointing back the way it came.
            let tip = CGPoint(x: center.x + r * cos(.pi * 0.15), y: center.y + r * sin(.pi * 0.15))
            context.move(to: CGPoint(x: tip.x + r * 0.55, y: tip.y - r * 0.1))
            context.addLine(to: tip)
            context.addLine(to: CGPoint(x: tip.x - r * 0.05, y: tip.y - r * 0.6))
            context.strokePath()
        case .nextDisplay, .previousDisplay:
            let forward = kind == .nextDisplay
            let h = inner.height * 0.62
            let w = h * 0.8
            let x = forward ? inner.midX - w * 0.35 : inner.midX + w * 0.35
            let tipX = forward ? x + w : x - w
            context.move(to: CGPoint(x: x, y: inner.midY - h / 2))
            context.addLine(to: CGPoint(x: tipX, y: inner.midY))
            context.addLine(to: CGPoint(x: x, y: inner.midY + h / 2))
            context.closePath()
            context.fillPath()
            let barX = forward ? x - w * 0.55 : x + w * 0.35
            fill(CGRect(x: barX, y: inner.midY - h * 0.18, width: w * 0.2, height: h * 0.36), context: context)
        case .separator:
            break
        }
        context.restoreGState()
    }

    private static func fill(_ rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let r = min(1.6, rect.width / 2, rect.height / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
    }

    private static func palette(_ style: Style) -> (screen: CGColor, outline: CGColor, fill: CGColor) {
        switch style {
        case .template:
            return (NSColor.black.withAlphaComponent(0.14).cgColor,
                    NSColor.black.withAlphaComponent(0.55).cgColor,
                    NSColor.black.cgColor)
        case .accent:
            return (NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor,
                    NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor,
                    NSColor.controlAccentColor.cgColor)
        case .dimmed:
            return (NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor,
                    NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor,
                    NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor)
        case .onAccent:
            return (NSColor.white.withAlphaComponent(0.18).cgColor,
                    NSColor.white.withAlphaComponent(0.7).cgColor,
                    NSColor.white.cgColor)
        }
    }
}

/// The glyph as a SwiftUI view, redrawn in the current appearance.
struct WindowCommandGlyphView: View {
    @Environment(\.colorScheme) private var colorScheme
    let kind: WindowCommandKind
    let grid: WindowGrid
    var size = CGSize(width: 26, height: 17)
    var style: WindowCommandGlyph.Style = .accent

    var body: some View {
        // Dynamic system colours resolve against the drawing appearance, which
        // a Canvas does not set by itself.
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                let draw = {
                    WindowCommandGlyph.draw(kind, grid: grid,
                                            in: CGRect(origin: .zero, size: canvasSize),
                                            context: cg, style: style)
                }
                if let appearance {
                    appearance.performAsCurrentDrawingAppearance(draw)
                } else {
                    draw()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
