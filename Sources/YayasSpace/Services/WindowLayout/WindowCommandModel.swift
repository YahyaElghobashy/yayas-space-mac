// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import CoreGraphics
import Foundation

// The editable window command model. Every placement the user can trigger by
// shortcut, by dragging, from the menu bar or from the green-button menu is a
// `WindowCommand` in one of two ordered sets. The fixed `WindowLayoutAction`
// enum stays the list of built-in ids, so the radial menu, the panel grid, the
// command bar and the gestures keep addressing the same placements.
//
// Pure value types only: the unit harness compiles this file.

/// Which command set a display uses. Landscape displays take the horizontal
/// set, portrait ones (taller than wide) the vertical set. Raw values persist.
enum WindowCommandSetKind: String, CaseIterable, Identifiable, Hashable {
    case horizontal
    case vertical

    var id: String { rawValue }

    /// Columns by rows of the grid that every target and activation area in
    /// the set snaps to. The vertical grid is the horizontal one on its side.
    var grid: WindowGrid {
        switch self {
        case .horizontal: return WindowGrid(columns: 24, rows: 12)
        case .vertical: return WindowGrid(columns: 12, rows: 24)
        }
    }

    /// A display is vertical when it is taller than it is wide. A square one
    /// counts as horizontal, the shape every set was designed on first.
    static func forDisplay(_ frame: CGRect) -> WindowCommandSetKind {
        frame.height > frame.width ? .vertical : .horizontal
    }
}

struct WindowGrid: Equatable, Hashable {
    let columns: Int
    let rows: Int

    /// Cells along one screen edge: columns across the top and bottom, rows
    /// down the sides.
    func units(along edge: WindowScreenEdge) -> Int {
        switch edge {
        case .top, .bottom: return columns
        case .left, .right: return rows
        }
    }
}

/// A reduced fraction of the display, as the editor's badges print it.
struct WindowGridFraction: Equatable {
    let numerator: Int
    let denominator: Int

    init(_ numerator: Int, of denominator: Int) {
        let divisor = Self.greatestCommonDivisor(max(0, numerator), max(1, denominator))
        self.numerator = max(0, numerator) / max(1, divisor)
        self.denominator = max(1, denominator) / max(1, divisor)
    }

    var text: String { "\(numerator)/\(denominator)" }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 { (a, b) = (b, a % b) }
        return max(1, a)
    }
}

/// A rectangle in whole grid cells, measured from the top-left corner of the
/// display's usable area. Stored in its set's own grid, so a target never
/// drifts when a display changes resolution.
struct GridRect: Equatable, Hashable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    /// The same area pulled inside the grid, at least one cell each way, so a
    /// hand-edited or imported value can never describe an empty or inverted
    /// placement.
    func clamped(to grid: WindowGrid) -> GridRect {
        let left = min(max(0, x), max(0, grid.columns - 1))
        let top = min(max(0, y), max(0, grid.rows - 1))
        let right = min(max(left + 1, maxX), grid.columns)
        let bottom = min(max(top + 1, maxY), grid.rows)
        return GridRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The rectangle covering two cells and everything between them,
    /// whichever direction the drag went.
    static func spanning(column firstColumn: Int, row firstRow: Int,
                         column secondColumn: Int, row secondRow: Int,
                         in grid: WindowGrid) -> GridRect {
        let left = min(firstColumn, secondColumn)
        let right = max(firstColumn, secondColumn)
        let top = min(firstRow, secondRow)
        let bottom = max(firstRow, secondRow)
        return GridRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            .clamped(to: grid)
    }

    func contains(column: Int, row: Int) -> Bool {
        column >= x && column < maxX && row >= y && row < maxY
    }

    /// The part of `bounds` (AppKit coordinates, y growing upward) this area
    /// covers. Each edge rounds on its own, so two areas that share a grid
    /// line also share the exact point: no seam and no one-point overlap.
    func frame(in bounds: CGRect, grid: WindowGrid) -> CGRect {
        let columns = CGFloat(max(1, grid.columns))
        let rows = CGFloat(max(1, grid.rows))
        let left = (bounds.minX + bounds.width * CGFloat(x) / columns).rounded()
        let right = (bounds.minX + bounds.width * CGFloat(maxX) / columns).rounded()
        let top = (bounds.maxY - bounds.height * CGFloat(y) / rows).rounded()
        let bottom = (bounds.maxY - bounds.height * CGFloat(maxY) / rows).rounded()
        return CGRect(x: left, y: bottom, width: max(1, right - left), height: max(1, top - bottom))
    }

    /// The area as fractions of a unit square with a top-left origin, for
    /// drawing glyphs and editors at any size.
    func unitRect(in grid: WindowGrid) -> CGRect {
        let columns = CGFloat(max(1, grid.columns))
        let rows = CGFloat(max(1, grid.rows))
        return CGRect(x: CGFloat(x) / columns, y: CGFloat(y) / rows,
                      width: CGFloat(width) / columns, height: CGFloat(height) / rows)
    }

    func widthFraction(in grid: WindowGrid) -> WindowGridFraction {
        WindowGridFraction(width, of: grid.columns)
    }

    func heightFraction(in grid: WindowGrid) -> WindowGridFraction {
        WindowGridFraction(height, of: grid.rows)
    }

    func covers(_ grid: WindowGrid) -> Bool {
        x == 0 && y == 0 && width == grid.columns && height == grid.rows
    }
}

/// What a command does to the window it acts on.
enum WindowCommandKind: Equatable, Hashable {
    /// Fill a rectangle of the display's grid.
    case area(GridRect)
    case maximize
    case marginMaximize
    case fullScreen
    case center
    case restore
    case nextDisplay
    case previousDisplay
    /// A divider between groups of commands in every list and menu.
    case separator

    var isSeparator: Bool { self == .separator }

    var gridRect: GridRect? {
        if case .area(let rect) = self { return rect }
        return nil
    }

    /// The built-in action a fixed kind always performs. Areas have no fixed
    /// action: their rectangle decides where the window goes.
    var fixedAction: WindowLayoutAction? {
        switch self {
        case .maximize: return .maximize
        case .marginMaximize: return .marginMaximize
        case .fullScreen: return .fullScreen
        case .center: return .center
        case .restore: return .restore
        case .nextDisplay: return .nextDisplay
        case .previousDisplay: return .previousDisplay
        case .area, .separator: return nil
        }
    }

    init?(fixedAction action: WindowLayoutAction) {
        switch action {
        case .maximize: self = .maximize
        case .marginMaximize: self = .marginMaximize
        case .fullScreen: self = .fullScreen
        case .center: self = .center
        case .restore: self = .restore
        case .nextDisplay: self = .nextDisplay
        case .previousDisplay: self = .previousDisplay
        default: return nil
        }
    }

    /// Persisted name of the kind. Stable: files written by this version are
    /// read back by every later one.
    var storageName: String {
        switch self {
        case .area: return "area"
        case .maximize: return "maximize"
        case .marginMaximize: return "marginMaximize"
        case .fullScreen: return "fullScreen"
        case .center: return "center"
        case .restore: return "restore"
        case .nextDisplay: return "nextDisplay"
        case .previousDisplay: return "previousDisplay"
        case .separator: return "separator"
        }
    }
}

enum WindowScreenEdge: String, CaseIterable, Hashable {
    case top, left, bottom, right
}

enum WindowScreenCorner: String, CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight

    var edges: (horizontal: WindowScreenEdge, vertical: WindowScreenEdge) {
        switch self {
        case .topLeft: return (.top, .left)
        case .topRight: return (.top, .right)
        case .bottomLeft: return (.bottom, .left)
        case .bottomRight: return (.bottom, .right)
        }
    }
}

/// Where the pointer has to be, while a window is dragged, for a command to
/// take the window. All three shapes use the set's grid.
enum WindowActivationRegion: Equatable, Hashable {
    /// A span of one screen edge, in grid units along that edge (columns for
    /// the top and bottom, rows for the sides), `end` exclusive. It fires
    /// within the configured edge width of that edge.
    case edge(WindowScreenEdge, start: Int, end: Int)
    /// A screen corner. It reaches one grid unit along both of its edges.
    case corner(WindowScreenCorner)
    /// A rectangle inside the display, scaled around its centre by the
    /// regular-area scale before it is hit-tested.
    case interior(GridRect)

    /// Corner beats edge beats interior when two regions both hold the
    /// pointer: the more specific gesture wins.
    var priorityClass: Int {
        switch self {
        case .corner: return 0
        case .edge: return 1
        case .interior: return 2
        }
    }

    /// The units of an edge an edge span may cover: all but the first and
    /// the last, which belong to the corners at either end (a corner reaches
    /// one grid unit along both of its edges and wins there anyway).
    static func edgeSpanUnits(along edge: WindowScreenEdge, in grid: WindowGrid) -> Range<Int> {
        let units = grid.units(along: edge)
        guard units > 2 else { return 0..<max(1, units) }
        return 1..<(units - 1)
    }

    /// The edge span the drag-area editor draws between two units, in either
    /// order, kept off the corner cells at both ends.
    static func edgeSpan(_ edge: WindowScreenEdge, from first: Int, to second: Int,
                         in grid: WindowGrid) -> WindowActivationRegion {
        let allowed = edgeSpanUnits(along: edge, in: grid)
        let lower = min(max(min(first, second), allowed.lowerBound), allowed.upperBound - 1)
        let upper = min(max(max(first, second), allowed.lowerBound), allowed.upperBound - 1)
        return .edge(edge, start: lower, end: upper + 1)
    }

    /// The region pulled into the grid, or nil when nothing usable is left.
    func sanitized(in grid: WindowGrid) -> WindowActivationRegion? {
        switch self {
        case .edge(let edge, let start, let end):
            let units = grid.units(along: edge)
            let lower = min(max(0, min(start, end)), units)
            let upper = min(max(0, max(start, end)), units)
            guard upper > lower else { return nil }
            return .edge(edge, start: lower, end: upper)
        case .corner:
            return self
        case .interior(let rect):
            return .interior(rect.clamped(to: grid))
        }
    }

    /// The visual zone of the earlier fixed edge-snap picker this region
    /// sits in. Used once, to carry zones someone switched off into the
    /// per-command switches.
    var legacyZone: WindowEdgeSnapZone? {
        switch self {
        case .corner(.topLeft): return .topLeft
        case .corner(.topRight): return .topRight
        case .corner(.bottomLeft): return .bottomLeft
        case .corner(.bottomRight): return .bottomRight
        case .edge(.top, _, _): return .top
        case .edge(.left, _, _): return .left
        case .edge(.right, _, _): return .right
        case .edge(.bottom, _, _): return .bottom
        case .interior: return nil
        }
    }
}

/// One entry of a command set: a placement, a separator, or a custom area.
struct WindowCommand: Identifiable, Equatable {
    var id: UUID
    var kind: WindowCommandKind
    /// The built-in placement this command started as. Kept for names,
    /// migration and the behaviours the built-ins already had (such as a
    /// repeated side crossing to the next display); nil for custom commands.
    var builtinID: WindowLayoutAction?
    /// The user's own name; nil means the built-in's localized name.
    var name: String?
    var shortcut: GlobalShortcut?
    var shortcutEnabled: Bool
    var activation: WindowActivationRegion?
    var activationEnabled: Bool
    var showInMenuBar: Bool
    var showInGreenButtonMenu: Bool

    init(id: UUID = UUID(),
         kind: WindowCommandKind,
         builtinID: WindowLayoutAction? = nil,
         name: String? = nil,
         shortcut: GlobalShortcut? = nil,
         shortcutEnabled: Bool = true,
         activation: WindowActivationRegion? = nil,
         activationEnabled: Bool = true,
         showInMenuBar: Bool = true,
         showInGreenButtonMenu: Bool = true) {
        self.id = id
        self.kind = kind
        self.builtinID = builtinID
        self.name = name
        self.shortcut = shortcut
        self.shortcutEnabled = shortcutEnabled
        self.activation = activation
        self.activationEnabled = activationEnabled
        self.showInMenuBar = showInMenuBar
        self.showInGreenButtonMenu = showInGreenButtonMenu
    }

    static func separator(id: UUID = UUID()) -> WindowCommand {
        WindowCommand(id: id, kind: .separator, shortcutEnabled: false, activationEnabled: false)
    }

    var isSeparator: Bool { kind.isSeparator }

    /// The shortcut that is actually live, if any.
    var effectiveShortcut: GlobalShortcut? {
        guard !isSeparator, shortcutEnabled else { return nil }
        return shortcut
    }

    /// The drag area that is actually live, if any.
    var effectiveActivation: WindowActivationRegion? {
        guard !isSeparator, activationEnabled else { return nil }
        return activation
    }

    /// The trimmed user name, or nil when the default name applies.
    var customName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Everything but the identity, for comparing sets built at different
    /// times (a fresh default set gets fresh ids).
    func isSameContent(as other: WindowCommand) -> Bool {
        var copy = other
        copy.id = id
        return copy == self
    }
}

/// Both command sets, as stored.
struct WindowCommandConfiguration: Equatable {
    static let currentVersion = 1

    var horizontal: [WindowCommand]
    var vertical: [WindowCommand]

    subscript(kind: WindowCommandSetKind) -> [WindowCommand] {
        get {
            switch kind {
            case .horizontal: return horizontal
            case .vertical: return vertical
            }
        }
        set {
            switch kind {
            case .horizontal: horizontal = newValue
            case .vertical: vertical = newValue
            }
        }
    }

    static var defaults: WindowCommandConfiguration {
        WindowCommandConfiguration(horizontal: WindowCommandDefaults.commands(for: .horizontal),
                                   vertical: WindowCommandDefaults.commands(for: .vertical))
    }

    /// Whether any command in either set has a live drag area. Drag snapping
    /// keeps no pointer listener at all while this is false.
    var hasEnabledActivation: Bool {
        (horizontal + vertical).contains { $0.effectiveActivation != nil }
    }

    func command(id: UUID) -> (kind: WindowCommandSetKind, command: WindowCommand)? {
        for kind in WindowCommandSetKind.allCases {
            if let command = self[kind].first(where: { $0.id == id }) { return (kind, command) }
        }
        return nil
    }
}
