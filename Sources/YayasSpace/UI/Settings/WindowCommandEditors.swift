// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import SwiftUI

/// The target editor: the set's grid as small cells, the command's area
/// filled in, and badges with the fractions of the display it covers. Drag
/// across the cells to choose a new area.
struct WindowTargetGridEditor: View {
    let grid: WindowGrid
    @Binding var rect: GridRect
    /// The tallest the grid may get, so a portrait grid stays on screen.
    var maxHeight: CGFloat = 240

    @State private var dragStart: (column: Int, row: Int)?
    @State private var preview: GridRect?

    private let gap: CGFloat = 2

    var body: some View {
        let shown = preview ?? rect
        let aspect = CGFloat(grid.columns) / CGFloat(max(1, grid.rows))
        Canvas { context, size in
            let pitchX = size.width / CGFloat(grid.columns)
            let pitchY = size.height / CGFloat(grid.rows)
            let radius = min(3, min(pitchX, pitchY) / 4)
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let cell = CGRect(x: CGFloat(column) * pitchX + gap / 2,
                                      y: CGFloat(row) * pitchY + gap / 2,
                                      width: pitchX - gap, height: pitchY - gap)
                    let selected = shown.contains(column: column, row: row)
                    context.fill(Path(roundedRect: cell, cornerRadius: radius),
                                 with: .color(selected ? Color.accentColor : Color.primary.opacity(0.09)))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: maxHeight * aspect, maxHeight: maxHeight)
        // Badges sit just outside the grid: the width fraction above the
        // area, the height fraction to its right.
        .overlay {
            GeometryReader { proxy in
                let pitchX = proxy.size.width / CGFloat(grid.columns)
                let pitchY = proxy.size.height / CGFloat(grid.rows)
                fractionBadge(shown.widthFraction(in: grid).text)
                    .position(x: (CGFloat(shown.x) + CGFloat(shown.width) / 2) * pitchX, y: -13)
                fractionBadge(shown.heightFraction(in: grid).text)
                    .position(x: proxy.size.width + 19,
                              y: (CGFloat(shown.y) + CGFloat(shown.height) / 2) * pitchY)
            }
        }
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let current = cell(at: value.location, size: proxy.size)
                            let start = dragStart ?? current
                            dragStart = start
                            preview = GridRect.spanning(column: start.column, row: start.row,
                                                        column: current.column, row: current.row, in: grid)
                        }
                        .onEnded { _ in
                            if let preview { rect = preview }
                            preview = nil
                            dragStart = nil
                        })
            }
        }
        .padding(.top, 26)
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rect.widthFraction(in: grid).text) × \(rect.heightFraction(in: grid).text)")
    }

    private func cell(at point: CGPoint, size: CGSize) -> (column: Int, row: Int) {
        let column = Int(floor(point.x / max(1, size.width / CGFloat(grid.columns))))
        let row = Int(floor(point.y / max(1, size.height / CGFloat(grid.rows))))
        return (min(max(column, 0), grid.columns - 1), min(max(row, 0), grid.rows - 1))
    }

    private func fractionBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .fixedSize()
    }
}

/// The drag-area editor: the display as a dot grid. Edge spans run along the
/// border, corners are the four caps, and a rectangle inside is an interior
/// area. Other commands' areas show faintly so the free parts are easy to
/// see. A corner owns the first cell along both of its edges, so an edge
/// span can never be drawn over those cells, and a corner is drawn with
/// them.
struct WindowActivationEditor: View {
    let grid: WindowGrid
    @Binding var region: WindowActivationRegion?
    let otherRegions: [WindowActivationRegion]
    var maxHeight: CGFloat = 230
    var strings: WindowCommandStrings = .localized(L10n.shared.language)

    @State private var drag: DragMode?
    @State private var preview: WindowActivationRegion?

    private enum DragMode {
        case edge(WindowScreenEdge, start: Int)
        case interior(column: Int, row: Int)
        case corner(WindowScreenCorner)
    }

    private let margin: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let layout = layout(in: geometry.size)
            Canvas { context, _ in
                draw(in: &context, layout: layout)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in changed(value, layout: layout) }
                .onEnded { _ in
                    if let preview { region = preview }
                    preview = nil
                    drag = nil
                })
        }
        .aspectRatio(CGFloat(grid.columns) / CGFloat(max(1, grid.rows)), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.dragAreaTitle)
        .accessibilityValue(strings.describe(region, grid: grid))
        .accessibilityHint(strings.dragAreaCaption)
    }

    // MARK: Layout

    private struct Layout {
        let outer: CGRect
        let inner: CGRect
        let columnWidth: CGFloat
        let rowHeight: CGFloat
    }

    private func layout(in size: CGSize) -> Layout {
        let aspect = CGFloat(grid.columns) / CGFloat(max(1, grid.rows))
        var height = size.height
        var width = height * aspect
        if width > size.width - 8 {
            width = size.width - 8
            height = width / aspect
        }
        let outer = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        let inner = outer.insetBy(dx: margin, dy: margin)
        return Layout(outer: outer, inner: inner,
                      columnWidth: inner.width / CGFloat(grid.columns),
                      rowHeight: inner.height / CGFloat(grid.rows))
    }

    private func cornerPoint(_ corner: WindowScreenCorner, _ layout: Layout) -> CGPoint {
        let half = margin / 2
        switch corner {
        case .topLeft: return CGPoint(x: layout.outer.minX + half, y: layout.outer.minY + half)
        case .topRight: return CGPoint(x: layout.outer.maxX - half, y: layout.outer.minY + half)
        case .bottomLeft: return CGPoint(x: layout.outer.minX + half, y: layout.outer.maxY - half)
        case .bottomRight: return CGPoint(x: layout.outer.maxX - half, y: layout.outer.maxY - half)
        }
    }

    /// The short line that stands for one unit of an edge.
    private func segment(_ edge: WindowScreenEdge, unit: Int, _ layout: Layout) -> (CGPoint, CGPoint) {
        let half = margin / 2
        let inset: CGFloat = 2.5
        switch edge {
        case .top, .bottom:
            let y = edge == .top ? layout.outer.minY + half : layout.outer.maxY - half
            let x0 = layout.inner.minX + CGFloat(unit) * layout.columnWidth
            return (CGPoint(x: x0 + inset, y: y), CGPoint(x: x0 + layout.columnWidth - inset, y: y))
        case .left, .right:
            let x = edge == .left ? layout.outer.minX + half : layout.outer.maxX - half
            let y0 = layout.inner.minY + CGFloat(unit) * layout.rowHeight
            return (CGPoint(x: x, y: y0 + inset), CGPoint(x: x, y: y0 + layout.rowHeight - inset))
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, layout: Layout) {
        let frame = Path(roundedRect: layout.outer, cornerRadius: 10)
        context.fill(frame, with: .color(Color.primary.opacity(0.035)))
        context.stroke(frame, with: .color(Color.primary.opacity(0.14)), lineWidth: 1)

        // Interior dots, one per cell.
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let center = CGPoint(x: layout.inner.minX + (CGFloat(column) + 0.5) * layout.columnWidth,
                                     y: layout.inner.minY + (CGFloat(row) + 0.5) * layout.rowHeight)
                let dot = CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)
                context.fill(Path(ellipseIn: dot), with: .color(Color.primary.opacity(0.22)))
            }
        }
        // Idle edge units and corner caps; the first and last unit of each
        // edge belong to its corners.
        for edge in WindowScreenEdge.allCases {
            for unit in WindowActivationRegion.edgeSpanUnits(along: edge, in: grid) {
                strokeSegment(edge, from: unit, to: unit + 1, layout: layout, in: &context,
                              color: Color.primary.opacity(0.12), width: 3)
            }
        }
        for corner in WindowScreenCorner.allCases {
            drawCorner(corner, layout: layout, in: &context, color: Color.primary.opacity(0.12),
                       capSize: 7, width: 3)
        }
        for other in otherRegions {
            draw(other, layout: layout, in: &context, color: Color.primary.opacity(0.42))
        }
        if let current = preview ?? region {
            draw(current, layout: layout, in: &context, color: Color.accentColor)
        }
    }

    private func draw(_ region: WindowActivationRegion, layout: Layout, in context: inout GraphicsContext,
                      color: Color) {
        switch region {
        case .edge(let edge, let start, let end):
            strokeSegment(edge, from: start, to: end, layout: layout, in: &context, color: color, width: 6)
        case .corner(let corner):
            drawCorner(corner, layout: layout, in: &context, color: color, capSize: 10, width: 6)
        case .interior(let rect):
            let box = CGRect(x: layout.inner.minX + CGFloat(rect.x) * layout.columnWidth,
                             y: layout.inner.minY + CGFloat(rect.y) * layout.rowHeight,
                             width: CGFloat(rect.width) * layout.columnWidth,
                             height: CGFloat(rect.height) * layout.rowHeight).insetBy(dx: 1, dy: 1)
            let path = Path(roundedRect: box, cornerRadius: 4)
            context.fill(path, with: .color(color.opacity(0.3)))
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }

    private func strokeSegment(_ edge: WindowScreenEdge, from start: Int, to end: Int, layout: Layout,
                               in context: inout GraphicsContext, color: Color, width: CGFloat) {
        let first = segment(edge, unit: start, layout).0
        let last = segment(edge, unit: max(start, end - 1), layout).1
        var path = Path()
        path.move(to: first)
        path.addLine(to: last)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// A corner: its cap, and the first cell along each of its two edges,
    /// which it reaches at run time.
    private func drawCorner(_ corner: WindowScreenCorner, layout: Layout, in context: inout GraphicsContext,
                            color: Color, capSize: CGFloat, width: CGFloat) {
        let (horizontal, vertical) = corner.edges
        let alongTop = vertical == .left ? 0 : grid.units(along: horizontal) - 1
        let alongSide = horizontal == .top ? 0 : grid.units(along: vertical) - 1
        strokeSegment(horizontal, from: alongTop, to: alongTop + 1, layout: layout, in: &context,
                      color: color, width: width)
        strokeSegment(vertical, from: alongSide, to: alongSide + 1, layout: layout, in: &context,
                      color: color, width: width)
        let point = cornerPoint(corner, layout)
        let cap = CGRect(x: point.x - capSize / 2, y: point.y - capSize / 2, width: capSize, height: capSize)
        context.fill(Path(ellipseIn: cap), with: .color(color))
    }

    // MARK: Editing

    private func changed(_ value: DragGesture.Value, layout: Layout) {
        let mode = drag ?? startMode(at: value.startLocation, layout: layout)
        drag = mode
        switch mode {
        case .corner(let corner):
            preview = .corner(corner)
        case .edge(let edge, let start):
            let current = unit(along: edge, at: value.location, layout: layout)
            preview = WindowActivationRegion.edgeSpan(edge, from: start, to: current, in: grid)
        case .interior(let column, let row):
            let current = cell(at: value.location, layout: layout)
            preview = .interior(GridRect.spanning(column: column, row: row,
                                                  column: current.column, row: current.row, in: grid))
        }
    }

    private func startMode(at point: CGPoint, layout: Layout) -> DragMode {
        for corner in WindowScreenCorner.allCases {
            let center = cornerPoint(corner, layout)
            if hypot(point.x - center.x, point.y - center.y) <= 11 { return .corner(corner) }
        }
        let edge: WindowScreenEdge?
        if point.y < layout.inner.minY {
            edge = .top
        } else if point.y > layout.inner.maxY {
            edge = .bottom
        } else if point.x < layout.inner.minX {
            edge = .left
        } else if point.x > layout.inner.maxX {
            edge = .right
        } else {
            edge = nil
        }
        if let edge {
            return .edge(edge, start: unit(along: edge, at: point, layout: layout))
        }
        let start = cell(at: point, layout: layout)
        return .interior(column: start.column, row: start.row)
    }

    /// The edge unit under the pointer, kept off the corner cells at both
    /// ends.
    private func unit(along edge: WindowScreenEdge, at point: CGPoint, layout: Layout) -> Int {
        let raw: CGFloat
        switch edge {
        case .top, .bottom: raw = (point.x - layout.inner.minX) / layout.columnWidth
        case .left, .right: raw = (point.y - layout.inner.minY) / layout.rowHeight
        }
        let allowed = WindowActivationRegion.edgeSpanUnits(along: edge, in: grid)
        return min(max(Int(floor(raw)), allowed.lowerBound), allowed.upperBound - 1)
    }

    private func cell(at point: CGPoint, layout: Layout) -> (column: Int, row: Int) {
        let column = Int(floor((point.x - layout.inner.minX) / layout.columnWidth))
        let row = Int(floor((point.y - layout.inner.minY) / layout.rowHeight))
        return (min(max(column, 0), grid.columns - 1), min(max(row, 0), grid.rows - 1))
    }
}
