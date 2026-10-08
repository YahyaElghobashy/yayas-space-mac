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

/// Where the green-button menu opens.
enum WindowGreenButtonMenuPlacement {
    /// The room the system's own green-button menu takes under the button,
    /// generously measured, so ours never covers it.
    static let systemMenuFootprint = CGSize(width: 272, height: 340)
    static let gap: CGFloat = 8

    /// The menu's frame in AppKit coordinates. Without the system's menu it
    /// drops down from the button. With it, the menu opens beside the
    /// system's footprint (to its right, or left of the window when there is
    /// no room), and only as a last resort anywhere that fits.
    static func frame(buttonFrame button: CGRect,
                      menuSize: CGSize,
                      visibleFrame screen: CGRect,
                      reservesSystemMenu: Bool) -> CGRect {
        func clamped(_ rect: CGRect) -> CGRect {
            var result = rect
            result.origin.x = min(max(result.minX, screen.minX), max(screen.minX, screen.maxX - result.width))
            result.origin.y = min(max(result.minY, screen.minY), max(screen.minY, screen.maxY - result.height))
            return result
        }
        let dropDown = CGRect(x: button.minX - 6, y: button.minY - gap - menuSize.height,
                              width: menuSize.width, height: menuSize.height)
        guard reservesSystemMenu else { return clamped(dropDown) }

        let reserved = CGRect(x: button.minX - 12, y: button.minY - systemMenuFootprint.height,
                              width: systemMenuFootprint.width, height: systemMenuFootprint.height)
        let beside = CGRect(x: reserved.maxX + gap, y: button.minY - 4 - menuSize.height,
                            width: menuSize.width, height: menuSize.height)
        if beside.maxX <= screen.maxX { return clamped(beside) }
        let leftOfWindow = CGRect(x: reserved.minX - gap - menuSize.width, y: button.maxY - menuSize.height,
                                  width: menuSize.width, height: menuSize.height)
        if leftOfWindow.minX >= screen.minX { return clamped(leftOfWindow) }
        let above = CGRect(x: button.minX - 6, y: button.maxY + gap,
                           width: menuSize.width, height: menuSize.height)
        if above.maxY <= screen.maxY { return clamped(above) }
        return clamped(beside)
    }

    /// The way from the button to the menu, which counts as inside for the
    /// leave timer: the button, the part of the menu nearest to it and the
    /// band between them. The pointer crosses it, sometimes over the
    /// system's own menu, on its way to ours; the rest of the system's
    /// menu stays outside, so resting there still closes ours.
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

/// The two layouts of the green-button menu.
enum WindowGreenButtonMenuLayout: String, CaseIterable, Identifiable {
    /// One row per command: glyph, name and shortcut.
    case list
    /// Glyphs only, in a grid.
    case grid

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

/// What the green-button menu accepts as the green button under the pointer,
/// from the Accessibility role and subrole of the element there. A window
/// that can go full screen, most of them, reports its green button as the
/// full-screen button; one that can only zoom, as the zoom button.
enum WindowGreenButtonIdentity {
    static func isGreenButton(role: String?, subrole: String?) -> Bool {
        role == "AXButton" && (subrole == "AXZoomButton" || subrole == "AXFullScreenButton")
    }
}
