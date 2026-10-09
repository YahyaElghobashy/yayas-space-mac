// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import CoreGraphics
import Foundation

// Pure rules behind the command engine: target geometry, drag activation
// hit-testing, greyed menu items, menu shaping, the green-button menu's
// placement and the restore-on-drag frame. Kept free of AppKit and
// Accessibility so the unit harness pins every one of them.

/// A display as the activation geometry sees it, in AppKit coordinates
/// (origin bottom-left of the main display, y growing upward).
struct WindowActivationScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    var setKind: WindowCommandSetKind { .forDisplay(frame) }
}

/// The two drag settings that shape every activation area.
struct WindowActivationSettings: Equatable {
    /// How far from a screen edge (points) an edge or corner area fires.
    var edgeWidth: CGFloat
    /// Interior areas are scaled around their centre by this factor.
    var interiorScale: CGFloat

    static let defaultEdgeWidth = 8
    static let defaultInteriorScalePercent = 80
    static let edgeWidthRange = 1...40
    static let interiorScaleRange = 10...100

    static let standard = WindowActivationSettings(edgeWidth: CGFloat(defaultEdgeWidth),
                                                   interiorScale: CGFloat(defaultInteriorScalePercent) / 100)

    static func sanitizedEdgeWidth(_ value: Int) -> Int {
        min(max(value, edgeWidthRange.lowerBound), edgeWidthRange.upperBound)
    }

    static func sanitizedInteriorScale(_ value: Int) -> Int {
        min(max(value, interiorScaleRange.lowerBound), interiorScaleRange.upperBound)
    }
}

enum WindowCommandGeometry {
    /// Where an area command puts a window: the grid rectangle inside the
    /// visible frame after the screen margin, with half the window margin
    /// taken off every edge it shares with a neighbouring area, exactly the
    /// rule the built-in placements follow.
    static func frame(for rect: GridRect,
                      grid: WindowGrid,
                      visibleFrame: CGRect,
                      windowGap: CGFloat = 0,
                      screenGap: CGFloat = 0) -> CGRect {
        let layout = WindowLayoutGeometry.screenGapFrame(visibleFrame, screenGap: screenGap)
        let raw = rect.frame(in: layout, grid: grid)
        return WindowLayoutGeometry.shavingSharedEdges(raw, in: layout, windowGap: windowGap)
    }

    /// The edges of the (margin-reduced) visible frame an area touches. A
    /// window that cannot take the exact size stays pinned to these.
    static func edgeContact(for rect: GridRect, grid: WindowGrid) -> WindowLayoutEdgeContact {
        var contact: WindowLayoutEdgeContact = []
        if rect.x == 0 { contact.insert(.left) }
        if rect.maxX >= grid.columns { contact.insert(.right) }
        if rect.y == 0 { contact.insert(.top) }
        if rect.maxY >= grid.rows { contact.insert(.bottom) }
        return contact
    }

    /// The margins as the two gap preferences store them: the window margin
    /// always, the screen margin only when windows are not fitted tightly to
    /// the screen edges.
    static func gaps(margin: Int, fitTightly: Bool) -> (windowGap: Int, screenGap: Int) {
        let clamped = min(max(0, margin), 128)
        return (clamped, fitTightly ? 0 : clamped)
    }

    /// The single margin and "fit tightly" switch an earlier pair of gap
    /// settings becomes, with the gap values that match them: the margin is
    /// the window gap when there is one, else the screen gap, and a zero
    /// screen gap beside a window gap means fitting tightly.
    static func normalizedLegacyGaps(windowGap: Int,
                                     screenGap: Int) -> (margin: Int, fitTightly: Bool,
                                                         windowGap: Int, screenGap: Int) {
        let margin = min(max(0, windowGap > 0 ? windowGap : screenGap), 128)
        let fitTightly = screenGap <= 0 && windowGap > 0
        let stored = Self.gaps(margin: margin, fitTightly: fitTightly)
        return (margin, fitTightly, stored.windowGap, stored.screenGap)
    }
}

/// Which command, if any, a dragged window's pointer is asking for.
enum WindowActivationHitTest {
    struct Match: Equatable {
        let screenIndex: Int
        let commandID: UUID
    }

    /// The command whose activation area holds the point. Corners beat
    /// edges and edges beat interior areas; between two of the same kind
    /// the smaller one wins, and the list order breaks a remaining tie.
    static func match(at point: CGPoint,
                      screens: [WindowActivationScreen],
                      commands: (WindowCommandSetKind) -> [WindowCommand],
                      settings: WindowActivationSettings) -> Match? {
        guard let screenIndex = screenIndex(for: point, screens: screens, slack: settings.edgeWidth) else {
            return nil
        }
        let screen = screens[screenIndex]
        let others = screens.enumerated().filter { $0.offset != screenIndex }.map(\.element.frame)
        let set = commands(screen.setKind)
        let grid = screen.setKind.grid
        var best: (rank: Int, size: CGFloat, order: Int, id: UUID)?
        for (order, command) in set.enumerated() {
            guard let region = command.effectiveActivation,
                  let size = hitSize(of: region, at: point, grid: grid, screen: screen,
                                     otherFrames: others, settings: settings)
            else { continue }
            let candidate = (rank: region.priorityClass, size: size, order: order, id: command.id)
            if let current = best {
                if (candidate.rank, candidate.size, candidate.order) < (current.rank, current.size, current.order) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best.map { Match(screenIndex: screenIndex, commandID: $0.id) }
    }

    /// The display a pointer belongs to: the one holding it, else the
    /// nearest within the edge slack.
    static func screenIndex(for point: CGPoint,
                            screens: [WindowActivationScreen],
                            slack: CGFloat) -> Int? {
        if let inside = screens.firstIndex(where: { inclusiveContains($0.frame, point) }) {
            return inside
        }
        let nearest = screens.enumerated().min { lhs, rhs in
            distanceSquared(point, lhs.element.frame) < distanceSquared(point, rhs.element.frame)
        }
        guard let nearest, distanceSquared(point, nearest.element.frame) <= slack * slack else { return nil }
        return nearest.offset
    }

    /// The size used to rank a hit (span length or area), or nil when the
    /// point is outside the region.
    static func hitSize(of region: WindowActivationRegion,
                        at point: CGPoint,
                        grid: WindowGrid,
                        screen: WindowActivationScreen,
                        otherFrames: [CGRect],
                        settings: WindowActivationSettings) -> CGFloat? {
        let rects = hitRects(for: region, grid: grid, screen: screen, settings: settings)
        for rect in rects.parts where inclusiveContains(rect.rect, point) {
            // An edge shared with another display is a doorway, not an edge.
            if let edge = rect.edge, isSeam(edge, at: point, screen: screen,
                                            otherFrames: otherFrames, width: settings.edgeWidth) {
                continue
            }
            return rects.size
        }
        return nil
    }

    struct HitPart: Equatable {
        let rect: CGRect
        let edge: WindowScreenEdge?
    }

    /// The rectangles a region answers to on one display, plus the size it
    /// ranks with. Edges run along the physical screen; the top edge also
    /// covers the menu bar, where a dragged title bar's pointer ends up.
    /// Interior areas live in the visible frame, where windows go.
    static func hitRects(for region: WindowActivationRegion,
                         grid: WindowGrid,
                         screen: WindowActivationScreen,
                         settings: WindowActivationSettings) -> (parts: [HitPart], size: CGFloat) {
        let frame = screen.frame
        let width = max(1, settings.edgeWidth)
        switch region {
        case .edge(let edge, let start, let end):
            let span = edgeSpan(edge, start: start, end: end, grid: grid, frame: frame)
            let rect = band(edge, along: span, screen: screen, width: width)
            return ([HitPart(rect: rect, edge: edge)], span.upperBound - span.lowerBound)
        case .corner(let corner):
            let (horizontal, vertical) = corner.edges
            let columnReach = frame.width / CGFloat(max(1, grid.columns))
            let rowReach = frame.height / CGFloat(max(1, grid.rows))
            let horizontalSpan: ClosedRange<CGFloat> = vertical == .left
                ? frame.minX - width...frame.minX + columnReach
                : frame.maxX - columnReach...frame.maxX + width
            let verticalSpan: ClosedRange<CGFloat> = horizontal == .top
                ? frame.maxY - rowReach...frame.maxY + width
                : frame.minY - width...frame.minY + rowReach
            return ([
                HitPart(rect: band(horizontal, along: horizontalSpan, screen: screen, width: width),
                        edge: horizontal),
                HitPart(rect: band(vertical, along: verticalSpan, screen: screen, width: width),
                        edge: vertical),
            ], 0)
        case .interior(let rect):
            let full = rect.frame(in: screen.visibleFrame, grid: grid)
            let scale = min(max(settings.interiorScale, 0.05), 1)
            let scaled = full.insetBy(dx: full.width * (1 - scale) / 2, dy: full.height * (1 - scale) / 2)
            return ([HitPart(rect: scaled, edge: nil)], scaled.width * scaled.height)
        }
    }

    /// The span of an edge in points, along the physical frame.
    static func edgeSpan(_ edge: WindowScreenEdge, start: Int, end: Int,
                         grid: WindowGrid, frame: CGRect) -> ClosedRange<CGFloat> {
        let units = CGFloat(max(1, grid.units(along: edge)))
        let lower = CGFloat(min(start, end))
        let upper = CGFloat(max(start, end))
        switch edge {
        case .top, .bottom:
            return (frame.minX + frame.width * lower / units)...(frame.minX + frame.width * upper / units)
        case .left, .right:
            // Grid rows count down from the top; AppKit y counts up.
            return (frame.maxY - frame.height * upper / units)...(frame.maxY - frame.height * lower / units)
        }
    }

    /// The band along one edge that fires, covering `span` along it.
    static func band(_ edge: WindowScreenEdge,
                     along span: ClosedRange<CGFloat>,
                     screen: WindowActivationScreen,
                     width: CGFloat) -> CGRect {
        let frame = screen.frame
        switch edge {
        case .top:
            // From just under the menu bar up to (and past) the physical top.
            let visibleTop = min(max(screen.visibleFrame.maxY, frame.minY), frame.maxY)
            let bottom = visibleTop - width
            return CGRect(x: span.lowerBound, y: bottom,
                          width: span.upperBound - span.lowerBound, height: frame.maxY + width - bottom)
        case .bottom:
            return CGRect(x: span.lowerBound, y: frame.minY - width,
                          width: span.upperBound - span.lowerBound, height: width * 2)
        case .left:
            return CGRect(x: frame.minX - width, y: span.lowerBound,
                          width: width * 2, height: span.upperBound - span.lowerBound)
        case .right:
            return CGRect(x: frame.maxX - width, y: span.lowerBound,
                          width: width * 2, height: span.upperBound - span.lowerBound)
        }
    }

    static func isSeam(_ edge: WindowScreenEdge,
                       at point: CGPoint,
                       screen: WindowActivationScreen,
                       otherFrames: [CGRect],
                       width: CGFloat) -> Bool {
        var probe = point
        switch edge {
        case .left: probe.x = screen.frame.minX - width - 1
        case .right: probe.x = screen.frame.maxX + width + 1
        case .top: probe.y = screen.frame.maxY + width + 1
        case .bottom: probe.y = screen.frame.minY - width - 1
        }
        return otherFrames.contains { inclusiveContains($0, probe) }
    }

    private static func inclusiveContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func distanceSquared(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// The visual zones of the earlier fixed picker that some live region of
    /// either set covers. The drag keeps the pointer off the physical top
    /// edge only where a region would catch it, so macOS still gets its own
    /// top-edge gesture everywhere else.
    static func coveredLegacyZones(_ configuration: WindowCommandConfiguration) -> Set<WindowEdgeSnapZone> {
        var zones = Set<WindowEdgeSnapZone>()
        for kind in WindowCommandSetKind.allCases {
            for command in configuration[kind] {
                if let zone = command.effectiveActivation?.legacyZone { zones.insert(zone) }
            }
        }
        return zones
    }
}

/// What a window lets Accessibility change about it.
struct WindowCommandCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let move = WindowCommandCapabilities(rawValue: 1 << 0)
    static let resize = WindowCommandCapabilities(rawValue: 1 << 1)
    static let fullScreen = WindowCommandCapabilities(rawValue: 1 << 2)

    static let all: WindowCommandCapabilities = [.move, .resize, .fullScreen]
}

/// Whether a command can change the focused window, which decides greyed
/// items in the menu-bar and green-button menus.
enum WindowCommandAvailability {
    struct Context: Equatable {
        var hasWindow: Bool
        var appIsIgnored: Bool
        var displayCount: Int
        var canRestore: Bool
        /// The window's current frame and where the command would put it;
        /// nil when the target cannot be computed ahead of time.
        var currentFrame: CGRect?
        var targetFrame: CGRect?
        /// What the window lets Accessibility change.
        var capabilities: WindowCommandCapabilities = .all

        static let noWindow = Context(hasWindow: false, appIsIgnored: false, displayCount: 1,
                                      canRestore: false, currentFrame: nil, targetFrame: nil,
                                      capabilities: [])
    }

    /// Frames closer than this count as the same placement.
    static let sameFrameTolerance: CGFloat = 2

    /// What a command has to change to do its work: an area, a maximize or a
    /// display move sets the whole frame, so it needs the window to resize
    /// as well as move; centring and restoring only need it to move.
    static func requiredCapabilities(for kind: WindowCommandKind) -> WindowCommandCapabilities {
        switch kind {
        case .area, .maximize, .marginMaximize, .nextDisplay, .previousDisplay:
            return [.move, .resize]
        case .center, .restore:
            return .move
        case .fullScreen:
            return .fullScreen
        case .separator:
            return []
        }
    }

    static func isEnabled(_ kind: WindowCommandKind, context: Context) -> Bool {
        if kind.isSeparator { return false }
        guard context.hasWindow, !context.appIsIgnored,
              context.capabilities.isSuperset(of: requiredCapabilities(for: kind))
        else { return false }
        switch kind {
        case .nextDisplay, .previousDisplay:
            return context.displayCount > 1
        case .restore:
            return context.canRestore
        case .fullScreen:
            return true
        case .area, .maximize, .marginMaximize, .center:
            guard let current = context.currentFrame, let target = context.targetFrame else { return true }
            return !isSameFrame(current, target)
        case .separator:
            return false
        }
    }

    static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= sameFrameTolerance
            && abs(lhs.minY - rhs.minY) <= sameFrameTolerance
            && abs(lhs.width - rhs.width) <= sameFrameTolerance
            && abs(lhs.height - rhs.height) <= sameFrameTolerance
    }
}

/// Where a command was chosen. Only the keyboard and the built-in pickers
/// (the main-panel grid, the radial menu, the command bar) keep the repeat
/// rules: the same side twice crosses to the display beside it, Top twice
/// maximizes. A command picked from the menu-bar or green-button menu, or
/// tried from Settings, does exactly what it says every time, and a drop
/// lands where it was dropped.
enum WindowCommandOrigin: Equatable {
    case shortcut
    case builtinPicker
    case menu
    case drop

    var appliesRepeatRules: Bool {
        switch self {
        case .shortcut, .builtinPicker: return true
        case .menu, .drop: return false
        }
    }

    /// The earlier placement the repeat rules compare with, or nil when
    /// they do not apply to this origin.
    func previousAction(_ stored: WindowLayoutAction?) -> WindowLayoutAction? {
        appliesRepeatRules ? stored : nil
    }
}

/// How the surfaces that list built-ins (the main-panel grid, the radial
/// menu, the command bar) reach the user's commands.
enum WindowCommandRouting {
    /// The user's command for a built-in in one set: the first command that
    /// started as it, whatever its area or name became. Nil when the set has
    /// none, and the built-in then runs as shipped.
    static func command(for action: WindowLayoutAction, in set: [WindowCommand]) -> WindowCommand? {
        set.first { !$0.isSeparator && $0.builtinID == action }
    }

    /// The shortcut a picker prints next to a built-in. It is the shortcut
    /// of the command the pick runs, so it is shown only when every kind of
    /// display connected agrees on it; otherwise nothing is promised.
    static func labelShortcut(for action: WindowLayoutAction,
                              in configuration: WindowCommandConfiguration,
                              displayKinds: Set<WindowCommandSetKind>) -> GlobalShortcut? {
        let shortcuts = WindowCommandSetKind.allCases.filter(displayKinds.contains).map {
            command(for: action, in: configuration[$0])?.effectiveShortcut
        }
        guard let first = shortcuts.first, shortcuts.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// Editing rules of the Commands list.
enum WindowCommandListEditing {
    /// Where a new separator goes beside the selected command: right after
    /// it, or right before it when after would put the separator at an end
    /// of the list or next to another one. Nil when neither divides two
    /// groups.
    static func separatorInsertionIndex(in set: [WindowCommand], near id: UUID?) -> Int? {
        func divides(at index: Int) -> Bool {
            guard index > 0, index < set.count else { return false }
            return !set[index - 1].isSeparator && !set[index].isSeparator
        }
        guard let id, let selected = set.firstIndex(where: { $0.id == id }) else { return nil }
        if divides(at: selected + 1) { return selected + 1 }
        if divides(at: selected) { return selected }
        return nil
    }
}

/// Shapes a set into what one menu shows.
enum WindowCommandMenuLayout {
    /// The commands a menu shows, in list order, with the separators the
    /// list has between them. Filtering can leave separators next to each
    /// other or at an end; those collapse away.
    static func entries(of commands: [WindowCommand],
                        including include: (WindowCommand) -> Bool) -> [WindowCommand] {
        var result: [WindowCommand] = []
        for command in commands {
            if command.isSeparator {
                if let last = result.last, !last.isSeparator { result.append(command) }
            } else if include(command) {
                result.append(command)
            }
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}

/// Where the green-button menu opens: it hangs from the button the way the
/// system's own menu does, its arrow on the button. While this menu runs,
/// the system's own one waits for a held key (`WindowSystemZoomMenuKey`), so
/// the spot under the button is this menu's alone.
enum WindowGreenButtonMenuPlacement {
    /// The arrow that points at the button: base by height.
    static let arrowSize = CGSize(width: 20, height: 9)
    /// How far left of the button's middle the menu starts, as the system's
    /// own menu does, so the arrow sits near its top-left corner.
    static let arrowInset: CGFloat = 26
    /// The arrow keeps this much menu on either side of its middle, so it
    /// never runs into a rounded corner.
    static let arrowMargin: CGFloat = 20
    /// Room kept between the menu and the screen's edges.
    static let screenMargin: CGFloat = 4
    /// Between the button's edge and the arrow's tip.
    static let gap: CGFloat = 1
    /// A menu squeezed between the button and a screen edge still shows
    /// this much before it scrolls.
    static let minimumBodyHeight: CGFloat = 80

    enum Edge: Equatable {
        /// Under the button, the arrow on the menu's top edge.
        case below
        /// Over the button, the arrow on the menu's bottom edge, when there
        /// is more room above than below for a menu that does not fit below.
        case above
    }

    struct Layout: Equatable {
        /// The panel, arrow included, in AppKit coordinates.
        var frame: CGRect
        /// The menu's body inside the panel (origin bottom-left).
        var body: CGRect
        /// Where the arrow's tip sits along the panel's width.
        var arrowX: CGFloat
        var edge: Edge
        /// The body is shorter or narrower than the commands, which then
        /// scroll.
        var scrolls: Bool
    }

    /// The menu under the button when it fits there, over it when only that
    /// fits, else on the roomier side, scrolling. Kept on screen; the arrow
    /// follows the button as far as the menu's corners allow.
    static func layout(buttonFrame button: CGRect,
                       contentSize: CGSize,
                       visibleFrame screen: CGRect) -> Layout {
        let room = screen.insetBy(dx: screenMargin, dy: screenMargin)
        let reach = gap + arrowSize.height
        let roomBelow = button.minY - reach - room.minY
        let roomAbove = room.maxY - (button.maxY + reach)
        let edge: Edge = contentSize.height <= roomBelow || roomBelow >= roomAbove ? .below : .above
        let bodyHeight = max(min(contentSize.height, edge == .below ? roomBelow : roomAbove),
                             min(contentSize.height, minimumBodyHeight)).rounded(.down)
        let width = min(contentSize.width, room.width).rounded(.down)
        let x = min(max((button.midX - arrowInset).rounded(), room.minX), max(room.minX, room.maxX - width))
        let arrowX = min(max(button.midX - x, arrowMargin), width - arrowMargin)
        let height = bodyHeight + arrowSize.height
        let frame: CGRect
        let body: CGRect
        switch edge {
        case .below:
            frame = CGRect(x: x, y: (button.minY - gap - height).rounded(), width: width, height: height)
            body = CGRect(x: 0, y: 0, width: width, height: bodyHeight)
        case .above:
            frame = CGRect(x: x, y: (button.maxY + gap).rounded(), width: width, height: height)
            body = CGRect(x: 0, y: arrowSize.height, width: width, height: bodyHeight)
        }
        return Layout(frame: frame, body: body, arrowX: arrowX, edge: edge,
                      scrolls: bodyHeight < contentSize.height || width < contentSize.width)
    }

    /// The way from the button to the menu, which counts as inside for the
    /// leave timer: the button, the part of the menu nearest to it and the
    /// band between them, which the pointer crosses on its way down.
    static func corridor(buttonFrame button: CGRect, menuFrame menu: CGRect, reach: CGFloat = 24) -> CGRect {
        let center = CGPoint(x: button.midX, y: button.midY)
        let nearest = CGPoint(x: min(max(center.x, menu.minX), menu.maxX),
                              y: min(max(center.y, menu.minY), menu.maxY))
        let landing = CGRect(x: nearest.x - reach, y: nearest.y - reach, width: reach * 2, height: reach * 2)
        return button.union(landing)
    }
}

/// How window drags are followed, when at all.
enum WindowDragListener: Equatable {
    case none
    /// A global event monitor: it watches left-button events on their way
    /// to other apps and can never hold, change or delay one. Enough for
    /// giving a placed window its size back, which never places anything.
    case passive
    /// An event tap in the input path: only drops need it, to keep a
    /// confirmed window drag off the edge that opens the system's overview.
    case active
}

/// Which parts of window dragging run. Drag snapping previews and places a
/// window dropped on a drag area. Restoring gives a window Window Layout
/// placed, by any route (a shortcut, a menu, a picker or a drag), its
/// earlier size back as soon as a drag takes it away; it works with drag
/// snapping off, and with the system's own tiling on, because it never
/// places anything. The drag listener runs while either has work: the
/// active tap only while drops place, a passive monitor while only
/// restoring has work.
struct WindowDragTracking: Equatable {
    var placesOnDrop: Bool
    var restoresSize: Bool

    static let off = WindowDragTracking(placesOnDrop: false, restoresSize: false)

    var listener: WindowDragListener {
        if placesOnDrop { return .active }
        return restoresSize ? .passive : .none
    }

    static func resolve(featureAvailable: Bool,
                        trusted: Bool,
                        snappingEnabled: Bool,
                        hasLiveDragAreas: Bool,
                        systemTilingEnabled: Bool,
                        restoreSizeEnabled: Bool,
                        hasPlacedWindows: Bool) -> WindowDragTracking {
        guard featureAvailable, trusted else { return .off }
        return WindowDragTracking(placesOnDrop: snappingEnabled && hasLiveDragAreas && !systemTilingEnabled,
                                  restoresSize: restoreSizeEnabled && hasPlacedWindows)
    }

    /// Whether a press on a window starts following the drag: any window
    /// while drops place, otherwise only one Window Layout placed.
    func tracksPress(onPlacedWindow: Bool) -> Bool {
        placesOnDrop || (restoresSize && onPlacedWindow)
    }
}

extension WindowCommandKind {
    /// Whether where this command puts a window depends on the window's
    /// current frame: its size for Center, its history for Restore, its
    /// position for the display moves. Only those make a drag preview read
    /// the dragged window's frame again while it moves.
    var previewFollowsWindow: Bool {
        switch self {
        case .center, .restore, .nextDisplay, .previousDisplay:
            return true
        case .area, .maximize, .marginMaximize, .fullScreen, .separator:
            return false
        }
    }
}

/// Restoring a snapped window to its earlier size once it is dragged away.
/// Frames here are Accessibility frames (origin top-left, y growing down),
/// the space the pointer events arrive in.
enum WindowRestoreOnDrag {
    /// A drag only restores a window that still sits where it was snapped;
    /// one resized by hand since then keeps its size.
    static func isStillSnapped(current: CGRect, placed: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(current.minX - placed.minX) <= tolerance
            && abs(current.minY - placed.minY) <= tolerance
            && abs(current.width - placed.width) <= tolerance
            && abs(current.height - placed.height) <= tolerance
    }

    /// The window at its earlier size, placed so the pointer keeps the same
    /// relative point across the title bar and the same distance from the
    /// top edge it was grabbed at.
    static func restoredFrame(snapped: CGRect,
                              originalSize: CGSize,
                              pointerStart: CGPoint,
                              pointerNow: CGPoint) -> CGRect {
        let width = max(1, originalSize.width)
        let height = max(1, originalSize.height)
        let relativeX = snapped.width > 0
            ? min(max((pointerStart.x - snapped.minX) / snapped.width, 0), 1) : 0.5
        let grabDepth = min(max(pointerStart.y - snapped.minY, 0), height - 1)
        return CGRect(x: (pointerNow.x - relativeX * width).rounded(),
                      y: (pointerNow.y - grabDepth).rounded(),
                      width: width,
                      height: height)
    }
}

/// The windows Window Layout placed and still remembers, each with the size
/// it had before, so a drag can give that size back. Drags are followed for
/// restoring only while this holds a window, so a window leaves it as soon
/// as it is no longer where it was placed: when a drag takes it away
/// (restored or not), when the window server shows it moved, resized or
/// gone, or when its size was given back some other way. Frames are
/// Accessibility frames, the window server's space (origin top-left).
struct WindowPlacements {
    struct Record: Equatable {
        var placed: CGRect
        var originalSize: CGSize
    }

    /// How far a window may sit from its placed frame and still count as
    /// placed; the restore applies the same slack.
    static let tolerance: CGFloat = 24

    private(set) var records: [WindowLayoutWindowKey: Record] = [:]

    var isEmpty: Bool { records.isEmpty }

    subscript(key: WindowLayoutWindowKey) -> Record? { records[key] }

    var windowIDs: [CGWindowID] { records.keys.map(\.windowID) }

    /// Remembers a placement. Placing a window again straight from where it
    /// was placed keeps the size it had before the first placement, so a
    /// drag away always goes back to the window's own size.
    mutating func note(_ key: WindowLayoutWindowKey, placed: CGRect, before: CGRect) {
        if let existing = records[key],
           WindowRestoreOnDrag.isStillSnapped(current: before, placed: existing.placed,
                                              tolerance: Self.tolerance) {
            records[key] = Record(placed: placed, originalSize: existing.originalSize)
        } else {
            records[key] = Record(placed: placed, originalSize: before.size)
        }
    }

    /// Forgets one window, as a drag that takes it away does. True when it
    /// was remembered.
    @discardableResult
    mutating func forget(_ key: WindowLayoutWindowKey) -> Bool {
        records.removeValue(forKey: key) != nil
    }

    /// Keeps only the windows that still exist. True when any was forgotten.
    @discardableResult
    mutating func keep(only live: Set<WindowLayoutWindowKey>) -> Bool {
        let before = records.count
        records = records.filter { live.contains($0.key) }
        return records.count != before
    }

    /// Forgets every window the window server no longer shows where it was
    /// placed: gone (`current` answers nil), owned by another process, or
    /// moved or resized beyond the slack. True when any was forgotten.
    @discardableResult
    mutating func forgetLeft(current: (CGWindowID) -> (pid: pid_t, bounds: CGRect)?) -> Bool {
        let before = records.count
        records = records.filter { key, record in
            guard let now = current(key.windowID), now.pid == key.processID else { return false }
            return WindowRestoreOnDrag.isStillSnapped(current: now.bounds, placed: record.placed,
                                                      tolerance: Self.tolerance)
        }
        return records.count != before
    }

    func contains(processID: pid_t, windowID: CGWindowID) -> Bool {
        records.keys.contains { $0.processID == processID && $0.windowID == windowID }
    }

    /// Whether a press can be on a placed window at all: inside a frame one
    /// was placed in, with the same slack. Every other press is left alone
    /// before the window server is asked anything.
    func mayHold(_ point: CGPoint) -> Bool {
        records.values.contains {
            $0.placed.insetBy(dx: -Self.tolerance, dy: -Self.tolerance).contains(point)
        }
    }
}

/// Apps whose windows Window Layout leaves alone.
enum WindowLayoutIgnoreList {
    static func sanitized(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        return bundleIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { return nil }
            return id
        }
    }

    static func contains(_ bundleID: String?, in list: [String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return list.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    static func toggled(_ bundleID: String, in list: [String]) -> [String] {
        if contains(bundleID, in: list) {
            return list.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        }
        return sanitized(list + [bundleID])
    }
}

/// How the drag preview (the destination frame shown while dragging) looks.
enum WindowLayoutPreviewStyle: String, CaseIterable, Identifiable {
    /// A translucent material that follows the system's light or dark look.
    case system
    case light
    case dark
    /// The accent-tinted fill and outline Window Layout has always drawn.
    case accent

    var id: String { rawValue }

    static let defaultBorderWidth = 2
    static let borderWidthRange = 0...8

    static func sanitized(_ rawValue: String?) -> WindowLayoutPreviewStyle {
        rawValue.flatMap(WindowLayoutPreviewStyle.init(rawValue:)) ?? .system
    }

    static func sanitizedBorderWidth(_ value: Int) -> Int {
        min(max(value, borderWidthRange.lowerBound), borderWidthRange.upperBound)
    }
}

/// The three layouts of the green-button menu.
enum WindowGreenButtonMenuLayout: String, CaseIterable, Identifiable {
    /// One row per command: glyph, name and shortcut.
    case list
    /// Glyphs only, in a grid: each group of the list starts a row.
    case grid
    /// Glyphs only, every command in one row, the groups set apart by thin
    /// dividers.
    case horizontal

    var id: String { rawValue }

    static let defaultDelayMilliseconds = 100
    static let delayRange = 0...2_000

    static func sanitized(_ rawValue: String?) -> WindowGreenButtonMenuLayout {
        rawValue.flatMap(WindowGreenButtonMenuLayout.init(rawValue:)) ?? .list
    }

    static func sanitizedDelay(_ milliseconds: Int) -> Int {
        min(max(milliseconds, delayRange.lowerBound), delayRange.upperBound)
    }

    /// Hit-testing never runs faster than this, however short the delay:
    /// the pointer has to rest this long before anything is asked.
    static let minimumRest: TimeInterval = 1.0 / 30.0
}

/// Where each command and separator of the green-button menu sits, in the
/// menu's own space (origin top-left, y growing down), and the size the menu
/// asks for. Commands are given by their place in the menu's entries.
enum WindowGreenButtonMenuGeometry {
    static let padding: CGFloat = 6
    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 9
    static let listWidth: CGFloat = 250
    static let cell = CGSize(width: 40, height: 30)
    static let cellGap: CGFloat = 4
    static let gridColumns = 5
    /// The caption under the glyph layouts: the command under the pointer.
    static let footerHeight: CGFloat = 22
    /// The room on either side of a divider in the single row.
    static let dividerGap: CGFloat = 6
    /// The narrowest a glyph layout gets, so its caption still fits.
    static let minimumGlyphWidth: CGFloat = 150

    struct Slot: Equatable {
        var index: Int
        var rect: CGRect
    }

    struct Placement: Equatable {
        var commands: [Slot]
        var separators: [CGRect]
        var size: CGSize
    }

    /// `isSeparator` holds one flag per menu entry, in order.
    static func placement(isSeparator: [Bool], layout: WindowGreenButtonMenuLayout) -> Placement {
        var commands: [Slot] = []
        var separators: [CGRect] = []
        let pad = padding
        switch layout {
        case .list:
            var y = pad
            for (index, separator) in isSeparator.enumerated() {
                if separator {
                    separators.append(CGRect(x: pad + 8, y: y + separatorHeight / 2,
                                             width: listWidth - pad * 2 - 16, height: 1))
                    y += separatorHeight
                } else {
                    commands.append(Slot(index: index, rect: CGRect(x: pad, y: y, width: listWidth - pad * 2,
                                                                    height: rowHeight)))
                    y += rowHeight
                }
            }
            return Placement(commands: commands, separators: separators,
                             size: CGSize(width: listWidth, height: y + pad))
        case .grid:
            // Each group of the list starts a row of its own.
            var x = pad
            var y = pad
            var column = 0
            var widest: CGFloat = 0
            for (index, separator) in isSeparator.enumerated() {
                if separator {
                    if column > 0 {
                        y += cell.height + cellGap
                        x = pad
                        column = 0
                    }
                    continue
                }
                if column == gridColumns {
                    y += cell.height + cellGap
                    x = pad
                    column = 0
                }
                commands.append(Slot(index: index, rect: CGRect(origin: CGPoint(x: x, y: y), size: cell)))
                x += cell.width + cellGap
                widest = max(widest, x)
                column += 1
            }
            if column > 0 { y += cell.height + cellGap }
            return Placement(commands: commands, separators: separators,
                             size: CGSize(width: max(widest - cellGap + pad, minimumGlyphWidth),
                                          height: y + footerHeight))
        case .horizontal:
            // One row in list order; a group break between two commands is
            // an upright hairline with the same room on both sides.
            var x = pad
            var pendingBreak = false
            for (index, separator) in isSeparator.enumerated() {
                if separator {
                    pendingBreak = !commands.isEmpty
                    continue
                }
                if pendingBreak {
                    let line = x - cellGap + dividerGap
                    separators.append(CGRect(x: line, y: pad + 5, width: 1, height: cell.height - 10))
                    x = line + 1 + dividerGap
                    pendingBreak = false
                }
                commands.append(Slot(index: index, rect: CGRect(origin: CGPoint(x: x, y: pad), size: cell)))
                x += cell.width + cellGap
            }
            return Placement(commands: commands, separators: separators,
                             size: CGSize(width: max(x - cellGap + pad, minimumGlyphWidth),
                                          height: pad + cell.height + cellGap + footerHeight))
        }
    }
}

/// Which key, held while the pointer rests on the green button, shows the
/// system's own green-button menu instead of this one. While the
/// green-button menu runs, macOS keeps its own menu for that key, so the two
/// never open together.
enum WindowSystemZoomMenuKey: String, CaseIterable, Identifiable {
    case control
    case command

    var id: String { rawValue }

    static func sanitized(_ rawValue: String?) -> WindowSystemZoomMenuKey {
        rawValue.flatMap(WindowSystemZoomMenuKey.init(rawValue:)) ?? .control
    }

    /// The value of AppKit's own `NSZoomButtonMenuOption` preference that
    /// shows the system's menu only while this key is held. AppKit reads it
    /// on every hover: 0 shows the menu as usual, 1 never, 2 only with
    /// Command, 3 only with Control.
    var systemMenuOption: Int {
        switch self {
        case .control: return 3
        case .command: return 2
        }
    }
}

/// Taking AppKit's global `NSZoomButtonMenuOption` preference over while the
/// green-button menu runs, and handing it back as it was found.
enum WindowSystemZoomMenuPreference {
    /// The global preference every app's green button reads.
    static let key = "NSZoomButtonMenuOption"
    /// Remembered in place of a preference that was not set at all.
    static let unset = -1

    struct State: Equatable {
        /// The global preference; nil when it is not set.
        var system: Int?
        /// The value found before the menu took the preference over (`unset`
        /// when there was none); nil while the menu does not hold it.
        var saved: Int?
        /// What the menu wrote, to tell it from a later change by anyone else.
        var written: Int?
    }

    /// Writes the option for the chosen key. The value found the first time
    /// is kept through later writes: a change of key, or a start after the
    /// app stopped without handing the preference back.
    static func takingOver(_ state: State, option: Int) -> State {
        State(system: option, saved: state.saved ?? state.system ?? unset, written: option)
    }

    /// Puts back the value found, unless something else changed the
    /// preference since; that change then stands. A preference the menu
    /// never took over is left alone.
    static func handingBack(_ state: State) -> State {
        guard let saved = state.saved else { return state }
        let system = state.system == state.written ? (saved == unset ? nil : saved) : state.system
        return State(system: system, saved: nil, written: nil)
    }
}

/// What the green-button menu accepts as the green button under the pointer,
/// from the Accessibility role and subrole of the element there. A window
/// that can go full screen, most of them, reports its green button as the
/// full-screen button; one that can only zoom, as the zoom button.
enum WindowGreenButtonIdentity {
    static func isGreenButton(role: String?, subrole: String?) -> Bool {
        role == "AXButton" && (subrole == "AXZoomButton" || subrole == "AXFullScreenButton")
    }
}
