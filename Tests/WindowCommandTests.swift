// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The window command sets: grid geometry, set selection, activation areas,
/// greyed menu items, shortcuts, persistence, migration and sync.
enum WindowCommandTests {
    static func run(expect: (Bool, String) -> Void) {
        defaultSets(expect)
        gridGeometry(expect)
        builtinGeometry(expect)
        setSelectionAndShortcuts(expect)
        multiDisplay(expect)
        activationHitTesting(expect)
        availability(expect)
        routingAndRepeatRules(expect)
        menusAndPlacement(expect)
        restoreOnDrag(expect)
        persistence(expect)
        migration(expect)
        sync(expect)
    }

    private static let landscapeFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let landscapeVisible = CGRect(x: 0, y: 40, width: 1440, height: 860)

    private static func shortcut(_ keyCode: Int, _ modifiers: GlobalShortcutModifiers) -> GlobalShortcut {
        GlobalShortcut(keyCode: Int64(keyCode), modifiers: modifiers)
    }

    // MARK: Default sets

    private static func defaultSets(_ expect: (Bool, String) -> Void) {
        let horizontal = WindowCommandDefaults.commands(for: .horizontal)
        let vertical = WindowCommandDefaults.commands(for: .vertical)
        func names(_ set: [WindowCommand]) -> [String] {
            set.map { WindowCommandStrings.displayName(of: $0, language: .enUS) }
        }
        expect(names(horizontal) == [
            "Left", "Right", "Top", "Bottom", "Separator",
            "Top Left", "Top Right", "Bottom Left", "Bottom Right", "Separator",
            "Left Third", "Center Third", "Right Third", "Separator",
            "Left Two Thirds", "Center Two Thirds", "Right Two Thirds", "Separator",
            "Next Display", "Previous Display", "Separator",
            "Maximize", "Center", "Restore",
        ], "the horizontal set lists every default command in order, with separators")
        expect(names(vertical) == [
            "Left", "Right", "Top", "Bottom", "Separator",
            "Top Left", "Top Right", "Bottom Left", "Bottom Right", "Separator",
            "Top Third", "Center Third", "Bottom Third", "Separator",
            "Top Two Thirds", "Center Two Thirds", "Bottom Two Thirds", "Separator",
            "Next Display", "Previous Display", "Separator",
            "Maximize", "Center", "Restore",
        ], "the vertical set turns the thirds and two-thirds on their side")

        let expectedShortcuts: [WindowLayoutAction: GlobalShortcut] = [
            .leftHalf: shortcut(kVK_LeftArrow, [.control, .option]),
            .rightHalf: shortcut(kVK_RightArrow, [.control, .option]),
            .topHalf: shortcut(kVK_UpArrow, [.control, .option]),
            .bottomHalf: shortcut(kVK_DownArrow, [.control, .option]),
            .topLeft: shortcut(kVK_ANSI_U, [.control, .option]),
            .topRight: shortcut(kVK_ANSI_I, [.control, .option]),
            .bottomLeft: shortcut(kVK_ANSI_J, [.control, .option]),
            .bottomRight: shortcut(kVK_ANSI_K, [.control, .option]),
            .leftThird: shortcut(kVK_ANSI_D, [.control, .option]),
            .centerThird: shortcut(kVK_ANSI_F, [.control, .option]),
            .rightThird: shortcut(kVK_ANSI_G, [.control, .option]),
            .leftTwoThirds: shortcut(kVK_ANSI_E, [.control, .option]),
            .centerTwoThirds: shortcut(kVK_ANSI_R, [.control, .option]),
            .rightTwoThirds: shortcut(kVK_ANSI_T, [.control, .option]),
            .nextDisplay: shortcut(kVK_RightArrow, [.control, .option, .command]),
            .previousDisplay: shortcut(kVK_LeftArrow, [.control, .option, .command]),
            .maximize: shortcut(kVK_Return, [.control, .option]),
            .center: shortcut(kVK_ANSI_C, [.control, .option]),
            .restore: shortcut(kVK_Delete, [.control, .option]),
        ]
        for command in horizontal where !command.isSeparator {
            guard let builtin = command.builtinID else { continue }
            expect(command.effectiveShortcut == expectedShortcuts[builtin],
                   "\(builtin.rawValue) ships with its documented shortcut")
        }
        for command in vertical where !command.isSeparator {
            guard let builtin = command.builtinID else { continue }
            let horizontalTwin = expectedShortcuts.first {
                WindowCommandDefaults.verticalCounterpart(of: $0.key) == builtin
            }?.value
            expect(command.effectiveShortcut == horizontalTwin,
                   "vertical \(builtin.rawValue) shares the shortcut of its horizontal twin")
        }
        for set in [horizontal, vertical] {
            let live = set.compactMap(\.effectiveShortcut)
            expect(Set(live).count == live.count, "a default set never uses one combination twice")
            expect(set.filter { !$0.isSeparator }.allSatisfy { $0.showInMenuBar && $0.showInGreenButtonMenu },
                   "every default command shows in the menu bar and the green-button menu")
        }
        let roleDefaults = Set(GlobalShortcutRole.allCases.map(\.defaultShortcut))
        let commandDefaults = Set(horizontal.compactMap(\.effectiveShortcut))
        expect(roleDefaults.isDisjoint(with: commandDefaults)
                && !commandDefaults.contains(GlobalShortcut.windowDirectionalDefault),
               "the default command shortcuts stay clear of every other Yaya's Space default")

        let horizontalAreas = horizontal.compactMap { command -> (WindowLayoutAction, WindowActivationRegion)? in
            guard let builtin = command.builtinID, let region = command.effectiveActivation else { return nil }
            return (builtin, region)
        }
        let areaByAction = Dictionary(uniqueKeysWithValues: horizontalAreas)
        expect(areaByAction[.leftHalf] == .edge(.left, start: 1, end: 11)
                && areaByAction[.rightHalf] == .edge(.right, start: 1, end: 11)
                && areaByAction[.maximize] == .edge(.top, start: 1, end: 23)
                && areaByAction[.topLeft] == .corner(.topLeft)
                && areaByAction[.bottomRight] == .corner(.bottomRight)
                && areaByAction[.topHalf] == nil && areaByAction[.bottomHalf] == nil
                && areaByAction[.centerTwoThirds] == nil && areaByAction[.center] == nil
                && areaByAction[.restore] == nil && areaByAction[.nextDisplay] == nil,
               "horizontal drag areas: sides halves, top maximize, corners quarters, the rest none")
        let bottomSpans = horizontalAreas.compactMap { action, region -> (Int, WindowLayoutAction)? in
            if case .edge(.bottom, let start, _) = region { return (start, action) }
            return nil
        }.sorted { $0.0 < $1.0 }.map(\.1)
        expect(bottomSpans == [.leftThird, .leftTwoThirds, .centerThird, .rightTwoThirds, .rightThird],
               "sliding along the bottom edge walks through thirds and two-thirds")
        let verticalAreas = Dictionary(uniqueKeysWithValues: vertical.compactMap { command -> (WindowLayoutAction, WindowActivationRegion)? in
            guard let builtin = command.builtinID, let region = command.effectiveActivation else { return nil }
            return (builtin, region)
        })
        expect(verticalAreas[.topHalf] == .edge(.top, start: 1, end: 11)
                && verticalAreas[.bottomHalf] == .edge(.bottom, start: 1, end: 11)
                && verticalAreas[.topThird] == .edge(.left, start: 1, end: 5)
                && verticalAreas[.bottomThird] == .edge(.left, start: 19, end: 23)
                && verticalAreas[.leftHalf] == nil,
               "vertical drag areas: top and bottom halves, the left edge cut into thirds")
        for (kind, set) in [(WindowCommandSetKind.horizontal, horizontal), (.vertical, vertical)] {
            var covered: [WindowScreenEdge: Set<Int>] = [:]
            var overlap = false
            for region in set.compactMap(\.effectiveActivation) {
                switch region {
                case .edge(let edge, let start, let end):
                    for unit in start..<end where !(covered[edge, default: []].insert(unit).inserted) {
                        overlap = true
                    }
                    let units = kind.grid.units(along: edge)
                    if start == 0 || end == units { overlap = true }
                case .corner, .interior:
                    break
                }
            }
            expect(!overlap, "\(kind.rawValue) default drag areas never overlap each other or a corner")
        }
        expect(WindowCommandDefaults.offeredBuiltins.contains(.topLeftSixth)
                && WindowCommandDefaults.offeredBuiltins.contains(.centerHalf)
                && WindowCommandDefaults.offeredBuiltins.contains(.fullScreen)
                && WindowCommandDefaults.offeredBuiltins.contains(.marginMaximize)
                && !WindowCommandDefaults.defaultBuiltins(for: .horizontal).contains(.topLeftSixth),
               "Yaya's Space's extras stay one click away in the + menu without crowding the defaults")
        expect(Set(WindowCommandDefaults.offeredBuiltins) == Set(WindowLayoutAction.allCases),
               "every built-in can be added back to a set")
    }

    // MARK: Grid geometry

    private static func gridGeometry(_ expect: (Bool, String) -> Void) {
        let grid = WindowCommandSetKind.horizontal.grid
        expect(grid == WindowGrid(columns: 24, rows: 12)
                && WindowCommandSetKind.vertical.grid == WindowGrid(columns: 12, rows: 24),
               "horizontal sets use 24 by 12 cells, vertical sets 12 by 24")
        let left = GridRect(x: 0, y: 0, width: 12, height: 12)
        expect(left.frame(in: landscapeVisible, grid: grid) == CGRect(x: 0, y: 40, width: 720, height: 860),
               "a grid half fills the left side of the visible frame")
        expect(GridRect(x: 12, y: 0, width: 12, height: 6).frame(in: landscapeVisible, grid: grid)
                == CGRect(x: 720, y: 470, width: 720, height: 430),
               "grid rows count from the top of the display")
        expect(GridRect(x: 12, y: 0, width: 12, height: 12).widthFraction(in: grid).text == "1/2"
                && GridRect(x: 12, y: 0, width: 12, height: 12).heightFraction(in: grid).text == "1/1"
                && GridRect(x: 0, y: 0, width: 8, height: 4).widthFraction(in: grid).text == "1/3"
                && GridRect(x: 0, y: 0, width: 16, height: 3).heightFraction(in: grid).text == "1/4"
                && GridRect(x: 0, y: 0, width: 16, height: 3).widthFraction(in: grid).text == "2/3",
               "fraction badges print reduced fractions of the display")
        expect(GridRect(x: -3, y: 20, width: 40, height: 0).clamped(to: grid)
                == GridRect(x: 0, y: 11, width: 24, height: 1),
               "an out-of-range area is pulled back inside the grid, at least one cell")
        expect(GridRect.spanning(column: 20, row: 9, column: 4, row: 2, in: grid)
                == GridRect(x: 4, y: 2, width: 17, height: 8),
               "dragging across the grid in any direction spans both cells")
        let thirds = [GridRect(x: 0, y: 0, width: 8, height: 12),
                      GridRect(x: 8, y: 0, width: 8, height: 12),
                      GridRect(x: 16, y: 0, width: 8, height: 12)]
        let oddFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let thirdFrames = thirds.map { $0.frame(in: oddFrame, grid: grid) }
        expect(thirdFrames[0].maxX == thirdFrames[1].minX && thirdFrames[1].maxX == thirdFrames[2].minX
                && thirdFrames[2].maxX == 1000,
               "neighbouring grid areas share an exact edge on sizes that do not divide evenly")

        // Margins: the window margin between areas, the screen margin unless
        // windows fit tightly to the screen edges.
        expect(WindowCommandGeometry.gaps(margin: 16, fitTightly: false) == (16, 16)
                && WindowCommandGeometry.gaps(margin: 16, fitTightly: true) == (16, 0)
                && WindowCommandGeometry.gaps(margin: 400, fitTightly: false) == (128, 128),
               "margins map onto the window and screen gaps, clamped to the largest preset")
        let margined = WindowCommandGeometry.frame(for: left, grid: grid, visibleFrame: landscapeVisible,
                                                   windowGap: 16, screenGap: 16)
        expect(margined == CGRect(x: 16, y: 56, width: 696, height: 828)
                && margined == WindowLayoutGeometry.rect(for: .leftHalf, current: .zero,
                                                         visibleFrame: landscapeVisible,
                                                         windowGap: 16, screenGap: 16),
               "a margined grid half keeps the screen margin outside and half the margin inside")
        let tight = WindowCommandGeometry.frame(for: left, grid: grid, visibleFrame: landscapeVisible,
                                                windowGap: 16, screenGap: 0)
        expect(tight == CGRect(x: 0, y: 40, width: 712, height: 860),
               "fitting tightly leaves no margin at the screen edges but keeps it between windows")
        let fullGrid = GridRect(x: 0, y: 0, width: 24, height: 12)
        expect(WindowCommandGeometry.frame(for: fullGrid, grid: grid, visibleFrame: landscapeVisible,
                                           windowGap: 16, screenGap: 16)
                == CGRect(x: 16, y: 56, width: 1408, height: 828),
               "a full-screen area takes only the screen margin")
        expect(WindowCommandGeometry.edgeContact(for: GridRect(x: 8, y: 0, width: 8, height: 12), grid: grid)
                == [.top, .bottom]
                && WindowCommandGeometry.edgeContact(for: fullGrid, grid: grid) == .all
                && WindowCommandGeometry.edgeContact(for: GridRect(x: 20, y: 9, width: 4, height: 3), grid: grid)
                    == [.right, .bottom],
               "an area reports the screen edges a smaller window stays pinned to")
    }

    // MARK: Built-in geometry

    private static func builtinGeometry(_ expect: (Bool, String) -> Void) {
        for kind in WindowCommandSetKind.allCases {
            let visible = kind == .horizontal ? landscapeVisible : CGRect(x: 1440, y: 0, width: 1080, height: 1896)
            for action in WindowLayoutAction.allCases {
                guard let rect = WindowCommandDefaults.canonicalRect(for: action, in: kind.grid) else { continue }
                let grid = WindowCommandGeometry.frame(for: rect, grid: kind.grid, visibleFrame: visible)
                let legacy = WindowLayoutGeometry.rect(for: action, current: .zero, visibleFrame: visible)
                let close = abs(grid.minX - legacy.minX) <= 1 && abs(grid.minY - legacy.minY) <= 1
                    && abs(grid.maxX - legacy.maxX) <= 1 && abs(grid.maxY - legacy.maxY) <= 1
                expect(close, "\(kind.rawValue) grid area of \(action.rawValue) lands where the built-in does")
            }
        }
        let visible = landscapeVisible
        expect(WindowLayoutGeometry.rect(for: .centerTwoThirds, current: .zero, visibleFrame: visible)
                == CGRect(x: 240, y: 40, width: 960, height: 860),
               "center two thirds sits two thirds wide in the middle")
        expect(WindowLayoutGeometry.rect(for: .topThird, current: .zero, visibleFrame: visible).maxY == 900
                && WindowLayoutGeometry.rect(for: .bottomThird, current: .zero, visibleFrame: visible).minY == 40
                && WindowLayoutGeometry.rect(for: .topTwoThirds, current: .zero, visibleFrame: visible).width == 1440,
               "the row thirds run across the whole width from the top or the bottom")
        let middle = WindowLayoutGeometry.rect(for: .middleThird, current: .zero, visibleFrame: visible)
        expect(abs(middle.midY - visible.midY) <= 1 && middle.width == 1440,
               "the middle row third is centred vertically")
        let centerTarget = WindowLayoutGeometry.rect(for: .centerTwoThirds, current: .zero, visibleFrame: visible)
        expect(WindowLayoutGeometry.anchoredRect(for: .centerTwoThirds, targetRect: centerTarget,
                                                 actualSize: CGSize(width: 1100, height: 860),
                                                 visibleFrame: visible)
                == CGRect(x: 170, y: 40, width: 1100, height: 860),
               "a wider window stays centred on a center two thirds target")
        expect(WindowLayoutGeometry.accepts(actualRect: CGRect(x: 170, y: 40, width: 1100, height: 860),
                                            targetRect: centerTarget, action: .centerTwoThirds,
                                            anchorTolerance: 36)
                && !WindowLayoutGeometry.accepts(actualRect: CGRect(x: 0, y: 40, width: 960, height: 860),
                                                 targetRect: centerTarget, action: .centerTwoThirds,
                                                 anchorTolerance: 36),
               "center two thirds accepts a centred window and rejects one pushed to a side")
        let topThird = WindowLayoutGeometry.rect(for: .topThird, current: .zero, visibleFrame: visible)
        expect(WindowLayoutGeometry.anchoredRect(contact: [.left, .right, .top], targetRect: topThird,
                                                 actualSize: CGSize(width: 1440, height: 400),
                                                 visibleFrame: visible).maxY == visible.maxY,
               "a top area keeps a taller window pinned to the top")
        expect(WindowLayoutGeometry.usesMaximizeFallback(.edges([.left, .top, .bottom]))
                && !WindowLayoutGeometry.usesMaximizeFallback(.edges(.all))
                && WindowLayoutGeometry.usesMaximizeFallback(.action(.middleThird))
                && !WindowLayoutGeometry.usesMaximizeFallback(.action(.center)),
               "only placements that tile part of the screen may use the maximize fallback")
        expect(WindowLayoutGeometry.shavingSharedEdges(CGRect(x: 480, y: 40, width: 480, height: 860),
                                                       in: visible, windowGap: 16)
                == CGRect(x: 488, y: 40, width: 464, height: 860),
               "the shared-edge rule shaves half the margin off both inner edges")
        let newActions: [WindowLayoutAction] = [.centerTwoThirds, .topThird, .middleThird, .bottomThird,
                                               .topTwoThirds, .middleTwoThirds, .bottomTwoThirds]
        expect(newActions.allSatisfy { WindowLayoutAction(shortcutID: $0.shortcutID) == $0
                    && $0.defaultShortcut == nil && !$0.symbolName.isEmpty
                    && !$0.title(FeatureStrings.windowLayout(.de)).isEmpty },
               "the new built-ins have their own ids, symbols and names and claim no legacy shortcut")

        var history = WindowLayoutHistory()
        let key = WindowLayoutWindowKey(processID: 7, processLaunchTime: 1, windowID: 9)
        let first = WindowLayoutFrame(origin: .zero, size: CGSize(width: 500, height: 400))
        let second = WindowLayoutFrame(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 600, height: 400))
        history.record(first, for: key)
        history.record(second, for: key)
        expect(history.peekPrevious(for: key, current: second) == first
                && history.peekPrevious(for: key, current: second) == first
                && history.popPrevious(for: key, current: second) == first,
               "peeking at the restore frame never uses it up")
    }

    // MARK: Set selection and shortcuts

    private static func setSelectionAndShortcuts(_ expect: (Bool, String) -> Void) {
        expect(WindowCommandSetKind.forDisplay(CGRect(x: 0, y: 0, width: 1080, height: 1920)) == .vertical
                && WindowCommandSetKind.forDisplay(CGRect(x: 0, y: 0, width: 1920, height: 1080)) == .horizontal
                && WindowCommandSetKind.forDisplay(CGRect(x: 0, y: 0, width: 1200, height: 1200)) == .horizontal,
               "portrait displays use the vertical set, landscape and square ones the horizontal set")
        let configuration = WindowCommandConfiguration.defaults
        let thirdKey = shortcut(kVK_ANSI_D, [.control, .option])
        expect(WindowCommandShortcuts.command(for: thirdKey, in: configuration, setKind: .horizontal)?.builtinID
                == .leftThird
                && WindowCommandShortcuts.command(for: thirdKey, in: configuration, setKind: .vertical)?.builtinID
                == .topThird,
               "one combination runs the command of the set that matches the window's display")
        let registrations = WindowCommandShortcuts.registrations(for: configuration)
        expect(registrations.count == Set(registrations).count && registrations.count == 19,
               "both sets share one system-wide registration per combination")
        var custom = configuration
        let onlyVertical = shortcut(kVK_ANSI_X, [.control, .option])
        custom.vertical[0].shortcut = onlyVertical
        expect(WindowCommandShortcuts.command(for: onlyVertical, in: custom, setKind: .horizontal) == nil
                && WindowCommandShortcuts.command(for: onlyVertical, in: custom, setKind: .vertical) != nil,
               "a combination used only by the vertical set does nothing for a landscape window")
        custom.vertical[0].shortcutEnabled = false
        expect(!WindowCommandShortcuts.registrations(for: custom).contains(onlyVertical),
               "a switched-off shortcut is not registered")

        let set = configuration.horizontal
        let maximizeKey = shortcut(kVK_Return, [.control, .option])
        let maximize = set.first { $0.builtinID == .maximize }!
        expect(WindowCommandShortcuts.conflictingCommand(for: maximizeKey, in: set, excluding: nil)?.id == maximize.id
                && WindowCommandShortcuts.conflictingCommand(for: maximizeKey, in: set, excluding: maximize.id) == nil
                && WindowCommandShortcuts.conflictingCommand(for: shortcut(kVK_ANSI_Z, [.control, .option]),
                                                             in: set, excluding: nil) == nil,
               "the recorder finds a clash inside the same set, never with the command itself")
        var disabled = set
        let index = disabled.firstIndex { $0.builtinID == .center }!
        disabled[index].shortcutEnabled = false
        expect(WindowCommandShortcuts.conflictingCommand(for: shortcut(kVK_ANSI_C, [.control, .option]),
                                                         in: disabled, excluding: nil) != nil,
               "a switched-off shortcut still reserves its combination inside the set")
        var clash = set
        let leftIndex = clash.firstIndex { $0.builtinID == .leftHalf }!
        let rightIndex = clash.firstIndex { $0.builtinID == .rightHalf }!
        clash[rightIndex].shortcut = clash[leftIndex].shortcut
        let resolved = WindowCommandShortcuts.resolvingConflicts(in: clash, keeping: [clash[rightIndex].id])
        expect(resolved[rightIndex].shortcut != nil && resolved[leftIndex].shortcut == nil,
               "a chosen shortcut wins a clash and the other command gives it up")
    }

    // MARK: Multiple displays

    private static func multiDisplay(_ expect: (Bool, String) -> Void) {
        // A laptop in the middle, a landscape display to its left and a
        // portrait one to its right.
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let portrait = CGRect(x: 1440, y: -300, width: 1080, height: 1920)
        let frames = [laptop, portrait, left]
        expect(WindowLayoutGeometry.adjacentDisplayIndex(currentIndex: 0, frames: frames, movingForward: true) == 1
                && WindowLayoutGeometry.adjacentDisplayIndex(currentIndex: 0, frames: frames, movingForward: false) == 2
                && WindowLayoutGeometry.adjacentDisplayIndex(currentIndex: 1, frames: frames, movingForward: true) == 2
                && WindowLayoutGeometry.adjacentDisplayIndex(currentIndex: 2, frames: frames, movingForward: false) == 1,
               "next and previous display walk left to right across mixed displays and wrap")
        expect(frames.map(WindowCommandSetKind.forDisplay) == [.horizontal, .vertical, .horizontal],
               "each display picks its own set: the portrait one the vertical set")
        let laptopVisible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let portraitVisible = CGRect(x: 1440, y: -300, width: 1080, height: 1895)
        let leftHalf = CGRect(x: 0, y: 0, width: 720, height: 875)
        let moved = WindowLayoutGeometry.rectForDisplay(current: leftHalf,
                                                        sourceVisibleFrame: laptopVisible,
                                                        destinationVisibleFrame: portraitVisible)
        expect(moved.minX == portraitVisible.minX && moved.width == 720 && portraitVisible.contains(moved),
               "a window moved to the portrait display keeps its size and its left edge")
        let wide = CGRect(x: 100, y: 100, width: 1300, height: 600)
        let squeezed = WindowLayoutGeometry.rectForDisplay(current: wide,
                                                           sourceVisibleFrame: laptopVisible,
                                                           destinationVisibleFrame: portraitVisible)
        expect(squeezed.width == 1080 && portraitVisible.contains(squeezed),
               "a window wider than the portrait display shrinks to fit it")
        var context = WindowCommandAvailability.Context(hasWindow: true, appIsIgnored: false, displayCount: 3,
                                                        canRestore: false, currentFrame: nil, targetFrame: nil)
        expect(WindowCommandAvailability.isEnabled(.nextDisplay, context: context)
                && WindowCommandAvailability.isEnabled(.previousDisplay, context: context),
               "display moves are offered with more than one display")
        context.displayCount = 1
        expect(!WindowCommandAvailability.isEnabled(.previousDisplay, context: context),
               "and greyed with one")
    }

    // MARK: Activation hit-testing

    private static func activationHitTesting(_ expect: (Bool, String) -> Void) {
        let screen = WindowActivationScreen(frame: landscapeFrame,
                                            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let configuration = WindowCommandConfiguration.defaults
        let settings = WindowActivationSettings.standard
        func hit(_ point: CGPoint,
                 screens: [WindowActivationScreen] = [screen],
                 configuration: WindowCommandConfiguration = configuration,
                 settings: WindowActivationSettings = settings) -> WindowLayoutAction? {
            guard let match = WindowActivationHitTest.match(at: point, screens: screens,
                                                            commands: { configuration[$0] },
                                                            settings: settings)
            else { return nil }
            return configuration.command(id: match.commandID)?.command.builtinID
        }
        expect(hit(CGPoint(x: 0, y: 450)) == .leftHalf && hit(CGPoint(x: 1440, y: 450)) == .rightHalf,
               "the middle of each side edge snaps to that half")
        expect(hit(CGPoint(x: 720, y: 899)) == .maximize && hit(CGPoint(x: 720, y: 868)) == .maximize,
               "the top edge, menu bar included, maximizes")
        expect(hit(CGPoint(x: 720, y: 860)) == nil,
               "the top area stops one edge width under the menu bar")
        expect(hit(CGPoint(x: 0, y: 899)) == .topLeft && hit(CGPoint(x: 30, y: 899)) == .topLeft
                && hit(CGPoint(x: 1440, y: 0)) == .bottomRight && hit(CGPoint(x: 0, y: 860)) == .topLeft,
               "each corner reaches one grid cell along both of its edges")
        expect(hit(CGPoint(x: 100, y: 0)) == .leftThird && hit(CGPoint(x: 400, y: 0)) == .leftTwoThirds
                && hit(CGPoint(x: 720, y: 0)) == .centerThird && hit(CGPoint(x: 1000, y: 0)) == .rightTwoThirds
                && hit(CGPoint(x: 1300, y: 0)) == .rightThird,
               "sliding along the bottom edge moves between thirds and two-thirds")
        expect(hit(CGPoint(x: 720, y: 450)) == nil && hit(CGPoint(x: 20, y: 450)) == nil,
               "the middle of the display and anything beyond the edge width never snap")
        let wide = WindowActivationSettings(edgeWidth: 30, interiorScale: 0.8)
        expect(hit(CGPoint(x: 20, y: 450), settings: wide) == .leftHalf,
               "a wider edge setting reaches further in")

        // Priority: corner beats edge beats interior; the smaller region wins
        // between two of the same kind.
        var custom = configuration
        let leftIndex = custom.horizontal.firstIndex { $0.builtinID == .leftHalf }!
        custom.horizontal[leftIndex].activation = .edge(.left, start: 0, end: 12)
        expect(hit(CGPoint(x: 0, y: 895), configuration: custom) == .topLeft
                && hit(CGPoint(x: 0, y: 450), configuration: custom) == .leftHalf,
               "a corner wins where a full-length edge area runs into it")
        let topIndex = custom.horizontal.firstIndex { $0.builtinID == .topHalf }!
        let centerIndex = custom.horizontal.firstIndex { $0.builtinID == .center }!
        custom.horizontal[topIndex].activation = .interior(GridRect(x: 0, y: 0, width: 24, height: 12))
        custom.horizontal[topIndex].activationEnabled = true
        custom.horizontal[centerIndex].activation = .interior(GridRect(x: 8, y: 4, width: 8, height: 4))
        custom.horizontal[centerIndex].activationEnabled = true
        expect(hit(CGPoint(x: 720, y: 437), configuration: custom) == .center
                && hit(CGPoint(x: 200, y: 437), configuration: custom) == .topHalf,
               "between two interior areas the smaller one wins, the larger keeps the rest")
        expect(hit(CGPoint(x: 0, y: 450), configuration: custom) == .leftHalf,
               "an edge area beats an interior area under it")
        // Interior scale: the area shrinks around its centre.
        let inset = CGPoint(x: 8 * 60 + 10, y: 437)
        expect(hit(inset, configuration: custom) == .topHalf,
               "the edge of an interior area outside its scaled rectangle falls through")
        let full = WindowActivationSettings(edgeWidth: 8, interiorScale: 1)
        expect(hit(inset, configuration: custom, settings: full) == .center,
               "at full scale the interior area answers all the way to its grid edge")

        // Displays side by side: the shared seam is a doorway, not an edge.
        let right = WindowActivationScreen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                           visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        expect(hit(CGPoint(x: 1440, y: 450), screens: [screen, right]) == nil
                && hit(CGPoint(x: 1439, y: 450), screens: [screen, right]) == nil
                && hit(CGPoint(x: 0, y: 450), screens: [screen, right]) == .leftHalf,
               "a window crosses a shared display edge without snapping")
        // A portrait display answers with the vertical set.
        let portrait = WindowActivationScreen(frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
                                              visibleFrame: CGRect(x: -1080, y: 0, width: 1080, height: 1895))
        expect(hit(CGPoint(x: -540, y: 1919), screens: [portrait]) == .topHalf
                && hit(CGPoint(x: -1080, y: 1700), screens: [portrait]) == .topThird
                && hit(CGPoint(x: -1080, y: 960), screens: [portrait]) == .middleThird
                && hit(CGPoint(x: 0, y: 960), screens: [portrait]) == .maximize,
               "a portrait display uses the vertical set's drag areas")
        var switchedOff = configuration
        for index in switchedOff.horizontal.indices { switchedOff.horizontal[index].activationEnabled = false }
        expect(hit(CGPoint(x: 0, y: 450), configuration: switchedOff) == nil
                && switchedOff.hasEnabledActivation,
               "a switched-off drag area never answers, and the other set still counts")
        expect(WindowActivationHitTest.coveredLegacyZones(configuration).isSuperset(of: [.top, .topLeft, .topRight]),
               "the default areas keep the top edge protected from the system's top-edge gesture")
    }

    // MARK: Greyed items

    private static func availability(_ expect: (Bool, String) -> Void) {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        var context = WindowCommandAvailability.Context(hasWindow: true, appIsIgnored: false, displayCount: 1,
                                                        canRestore: false, currentFrame: window,
                                                        targetFrame: CGRect(x: 0, y: 40, width: 720, height: 860))
        let area = WindowCommandKind.area(GridRect(x: 0, y: 0, width: 12, height: 12))
        expect(WindowCommandAvailability.isEnabled(area, context: context),
               "a placement that moves the window is available")
        expect(!WindowCommandAvailability.isEnabled(.nextDisplay, context: context)
                && !WindowCommandAvailability.isEnabled(.previousDisplay, context: context),
               "display moves grey out with a single display")
        expect(!WindowCommandAvailability.isEnabled(.restore, context: context),
               "restore greys out with nothing to go back to")
        context.displayCount = 2
        context.canRestore = true
        expect(WindowCommandAvailability.isEnabled(.nextDisplay, context: context)
                && WindowCommandAvailability.isEnabled(.restore, context: context),
               "display moves and restore come back when they can act")
        context.targetFrame = CGRect(x: 101, y: 99, width: 801, height: 600)
        expect(!WindowCommandAvailability.isEnabled(.center, context: context)
                && WindowCommandAvailability.isEnabled(.fullScreen, context: context),
               "a command whose result equals the current frame greys out")
        context.appIsIgnored = true
        expect(!WindowCommandAvailability.isEnabled(.maximize, context: context)
                && !WindowCommandAvailability.isEnabled(.nextDisplay, context: context),
               "an ignored app greys out every command")
        expect(!WindowCommandAvailability.isEnabled(.maximize, context: .noWindow)
                && !WindowCommandAvailability.isEnabled(.separator, context: context),
               "without a movable window nothing is available")
        let list = ["com.apple.Safari", " com.apple.safari ", "", "com.example.Tool"]
        expect(WindowLayoutIgnoreList.sanitized(list) == ["com.apple.Safari", "com.example.Tool"]
                && WindowLayoutIgnoreList.contains("COM.APPLE.SAFARI", in: list)
                && WindowLayoutIgnoreList.toggled("com.apple.Safari", in: ["com.apple.Safari"]).isEmpty,
               "the ignore list keeps one entry per app and matches regardless of case")
    }

    // MARK: Routing and repeat rules

    private static func routingAndRepeatRules(_ expect: (Bool, String) -> Void) {
        // What a menu greys out depends on what its window lets change.
        typealias Availability = WindowCommandAvailability
        let area = WindowCommandKind.area(GridRect(x: 0, y: 0, width: 12, height: 12))
        expect(Availability.requiredCapabilities(for: area) == [.move, .resize]
                && Availability.requiredCapabilities(for: .maximize) == [.move, .resize]
                && Availability.requiredCapabilities(for: .nextDisplay) == [.move, .resize]
                && Availability.requiredCapabilities(for: .center) == .move
                && Availability.requiredCapabilities(for: .restore) == .move
                && Availability.requiredCapabilities(for: .fullScreen) == .fullScreen,
               "an area or a maximize needs the window to resize; centring and restoring only to move")
        var context = Availability.Context(hasWindow: true, appIsIgnored: false, displayCount: 2,
                                           canRestore: true,
                                           currentFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
                                           targetFrame: nil, capabilities: .move)
        expect(!Availability.isEnabled(area, context: context)
                && !Availability.isEnabled(.maximize, context: context)
                && !Availability.isEnabled(.marginMaximize, context: context)
                && !Availability.isEnabled(.previousDisplay, context: context)
                && !Availability.isEnabled(.fullScreen, context: context),
               "a window that moves but cannot resize greys out every command that sets its size")
        expect(Availability.isEnabled(.center, context: context)
                && Availability.isEnabled(.restore, context: context),
               "centring and restoring stay available for a window that only moves")
        context.capabilities = .fullScreen
        expect(Availability.isEnabled(.fullScreen, context: context)
                && !Availability.isEnabled(.center, context: context),
               "a window in full screen offers only Full Screen")
        context.capabilities = .all
        expect(Availability.isEnabled(area, context: context),
               "a window that moves and resizes takes an area")

        // Only the keyboard and the built-in pickers repeat.
        expect(WindowCommandOrigin.shortcut.appliesRepeatRules
                && WindowCommandOrigin.builtinPicker.appliesRepeatRules
                && !WindowCommandOrigin.menu.appliesRepeatRules
                && !WindowCommandOrigin.drop.appliesRepeatRules,
               "menu choices and drops never take the keyboard's repeat rules")
        expect(WindowLayoutGeometry.displayCrossing(
                    for: .leftHalf, previousAction: WindowCommandOrigin.shortcut.previousAction(.leftHalf)) != nil
                && WindowLayoutGeometry.displayCrossing(
                    for: .leftHalf, previousAction: WindowCommandOrigin.menu.previousAction(.leftHalf)) == nil
                && WindowLayoutGeometry.displayCrossing(
                    for: .rightHalf, previousAction: WindowCommandOrigin.menu.previousAction(.rightHalf)) == nil,
               "Left or Right twice crosses to the next display from a shortcut, never from a menu")
        expect(WindowLayoutGeometry.effectiveAction(
                    for: .topHalf, current: .zero, visibleFrame: landscapeVisible,
                    previousAction: WindowCommandOrigin.shortcut.previousAction(.topHalf)) == .maximize
                && WindowLayoutGeometry.effectiveAction(
                    for: .topHalf, current: .zero, visibleFrame: landscapeVisible,
                    previousAction: WindowCommandOrigin.menu.previousAction(.topHalf)) == .topHalf,
               "Top twice maximizes from a shortcut; chosen from a menu, Top stays Top")

        // The pickers run the user's command for a built-in.
        var configuration = WindowCommandConfiguration.defaults
        let leftIndex = configuration.horizontal.firstIndex { $0.builtinID == .leftHalf }!
        let edited = GridRect(x: 0, y: 0, width: 10, height: 12)
        configuration.horizontal[leftIndex].kind = .area(edited)
        expect(WindowCommandRouting.command(for: .leftHalf, in: configuration.horizontal)?.kind == .area(edited),
               "picking a built-in runs the user's edited command, not the shipped placement")
        expect(WindowCommandRouting.command(for: .leftThird, in: configuration.vertical) == nil
                && WindowCommandRouting.command(for: .topThird, in: configuration.vertical) != nil,
               "a set without the built-in leaves the pick to the built-in as shipped")
        let leftKey = shortcut(kVK_LeftArrow, [.control, .option])
        let thirdKey = shortcut(kVK_ANSI_D, [.control, .option])
        expect(WindowCommandRouting.labelShortcut(for: .leftThird, in: configuration, displayKinds: [.horizontal])
                == thirdKey
                && WindowCommandRouting.labelShortcut(for: .leftThird, in: configuration,
                                                      displayKinds: [.vertical]) == nil
                && WindowCommandRouting.labelShortcut(for: .leftThird, in: configuration,
                                                      displayKinds: [.horizontal, .vertical]) == nil
                && WindowCommandRouting.labelShortcut(for: .leftHalf, in: configuration,
                                                      displayKinds: [.horizontal, .vertical]) == leftKey,
               "a picker prints the shortcut of the command it runs, only where every display agrees")
        let custom = shortcut(kVK_ANSI_L, [.control, .option, .command])
        configuration.horizontal[leftIndex].shortcut = custom
        expect(WindowCommandRouting.labelShortcut(for: .leftHalf, in: configuration, displayKinds: [.horizontal])
                == custom
                && WindowCommandRouting.labelShortcut(for: .leftHalf, in: configuration,
                                                      displayKinds: [.horizontal, .vertical]) == nil,
               "a changed shortcut shows next to the built-in whose command now answers to it")
        configuration.horizontal[leftIndex].shortcutEnabled = false
        expect(WindowCommandRouting.labelShortcut(for: .leftHalf, in: configuration,
                                                  displayKinds: [.horizontal]) == nil,
               "a switched-off shortcut is not printed")
    }

    // MARK: Menus and placement

    private static func menusAndPlacement(_ expect: (Bool, String) -> Void) {
        let set = WindowCommandDefaults.commands(for: .horizontal)
        let onlyHalves = WindowCommandMenuLayout.entries(of: set) {
            [.leftHalf, .rightHalf, .maximize].contains($0.builtinID)
        }
        expect(onlyHalves.map(\.isSeparator) == [false, false, true, false],
               "hidden commands take their doubled and dangling separators with them")
        expect(WindowCommandMenuLayout.entries(of: set) { _ in false }.isEmpty,
               "a menu with no visible command is empty, not a pile of separators")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let button = CGRect(x: 208, y: 830, width: 14, height: 16)
        let size = CGSize(width: 240, height: 300)
        let plain = WindowGreenButtonMenuPlacement.frame(buttonFrame: button, menuSize: size,
                                                         visibleFrame: screen, reservesSystemMenu: false)
        expect(plain.maxY <= button.minY && abs(plain.minX - (button.minX - 6)) < 0.5,
               "without the system menu the green-button menu drops down from the button")
        let beside = WindowGreenButtonMenuPlacement.frame(buttonFrame: button, menuSize: size,
                                                          visibleFrame: screen, reservesSystemMenu: true)
        let footprint = CGRect(x: button.minX - 12,
                               y: button.minY - WindowGreenButtonMenuPlacement.systemMenuFootprint.height,
                               width: WindowGreenButtonMenuPlacement.systemMenuFootprint.width,
                               height: WindowGreenButtonMenuPlacement.systemMenuFootprint.height)
        expect(!beside.intersects(footprint) && screen.contains(beside),
               "the menu opens beside the system's own green-button menu, never over it")
        let nearRight = CGRect(x: 1300, y: 830, width: 14, height: 16)
        let flipped = WindowGreenButtonMenuPlacement.frame(buttonFrame: nearRight, menuSize: size,
                                                           visibleFrame: screen, reservesSystemMenu: true)
        let flippedFootprint = footprint.offsetBy(dx: nearRight.minX - button.minX, dy: 0)
        expect(!flipped.intersects(flippedFootprint) && flipped.maxX <= nearRight.minX,
               "without room on the right it opens to the left of the window")

        // The corridor from the button to the menu counts as inside.
        let corridor = WindowGreenButtonMenuPlacement.corridor(buttonFrame: button, menuFrame: beside)
        let start = CGPoint(x: button.midX, y: button.midY)
        let landing = CGPoint(x: beside.minX + 4, y: beside.maxY - 4)
        let onTheWay = (1...9).map { step -> CGPoint in
            let t = CGFloat(step) / 10
            return CGPoint(x: start.x + (landing.x - start.x) * t, y: start.y + (landing.y - start.y) * t)
        }
        expect(onTheWay.allSatisfy(corridor.contains),
               "the way from the green button to the menu beside the system's menu keeps it open")
        expect(!corridor.contains(CGPoint(x: button.minX + 100, y: button.minY - 200)),
               "resting deep inside the system's own menu still lets the menu close")
        let below = WindowGreenButtonMenuPlacement.corridor(buttonFrame: button, menuFrame: plain)
        expect(below.contains(CGPoint(x: button.midX, y: button.minY - 4)),
               "a menu dropping down from the button keeps the gap between them inside")
    }

    // MARK: Restore on drag

    private static func restoreOnDrag(_ expect: (Bool, String) -> Void) {
        let snapped = CGRect(x: 0, y: 25, width: 720, height: 875)
        let restored = WindowRestoreOnDrag.restoredFrame(snapped: snapped,
                                                         originalSize: CGSize(width: 800, height: 600),
                                                         pointerStart: CGPoint(x: 360, y: 35),
                                                         pointerNow: CGPoint(x: 500, y: 200))
        expect(restored == CGRect(x: 100, y: 190, width: 800, height: 600),
               "a restored window keeps the pointer at the same point of its title bar")
        let edge = WindowRestoreOnDrag.restoredFrame(snapped: snapped,
                                                     originalSize: CGSize(width: 400, height: 300),
                                                     pointerStart: CGPoint(x: 710, y: 30),
                                                     pointerNow: CGPoint(x: 900, y: 40))
        expect(abs(edge.maxX - 900) < 12 && edge.minY == 35,
               "a grab near the right end stays near the right end of the smaller window")
        expect(WindowRestoreOnDrag.isStillSnapped(current: snapped.offsetBy(dx: 3, dy: 0), placed: snapped)
                && !WindowRestoreOnDrag.isStillSnapped(current: CGRect(x: 0, y: 25, width: 900, height: 875),
                                                       placed: snapped),
               "only a window still in its snapped frame is restored; a hand-resized one keeps its size")

        // The drag listener: drops need snapping, restoring needs only a
        // placed window, whichever route placed it.
        func gate(available: Bool = true, trusted: Bool = true, snapping: Bool = false, areas: Bool = true,
                  tiling: Bool = false, restore: Bool = true, placed: Bool = true) -> WindowDragTracking {
            WindowDragTracking.resolve(featureAvailable: available, trusted: trusted, snappingEnabled: snapping,
                                       hasLiveDragAreas: areas, systemTilingEnabled: tiling,
                                       restoreSizeEnabled: restore, hasPlacedWindows: placed)
        }
        expect(gate().listens && gate().restoresSize && !gate().placesOnDrop,
               "with drag snapping off the listener still runs to give a placed window its size back")
        expect(!gate(placed: false).listens && !gate(restore: false).listens,
               "with snapping off it runs only while restoring is on and a placed window is remembered")
        expect(gate(snapping: true, restore: false).placesOnDrop
                && gate(snapping: true, placed: false).listens
                && !gate(snapping: true, areas: false, restore: false).listens,
               "snapping listens whenever some command has a live drag area")
        expect(!gate(snapping: true, tiling: true).placesOnDrop && gate(snapping: true, tiling: true).restoresSize,
               "the system's own tiling takes the drops but never the restoring")
        expect(gate(available: false) == .off && gate(trusted: false) == .off,
               "nothing listens without the feature or its permission")
        expect(gate().tracksPress(onPlacedWindow: true) && !gate().tracksPress(onPlacedWindow: false)
                && gate(snapping: true, placed: false).tracksPress(onPlacedWindow: false),
               "with only restoring to do, a press is followed only on a window Window Layout placed")
        let settingsSource = (try? String(contentsOfFile: "Sources/YayasSpace/UI/Settings/WindowLayoutSettings.swift",
                                          encoding: .utf8)) ?? ""
        let restoreToggle = settingsSource.components(separatedBy: "Toggle(text.restoreOnDrag").dropFirst().first?
            .components(separatedBy: "Text(text.restoreOnDragCaption").first ?? ".disabled("
        expect(!settingsSource.isEmpty && !restoreToggle.contains(".disabled("),
               "the restore switch can be turned on and off with snapping off")

        // Previews that move with the window are the only ones that read it.
        expect(WindowCommandKind.center.previewFollowsWindow
                && WindowCommandKind.restore.previewFollowsWindow
                && WindowCommandKind.nextDisplay.previewFollowsWindow
                && WindowCommandKind.previousDisplay.previewFollowsWindow
                && !WindowCommandKind.area(GridRect(x: 0, y: 0, width: 12, height: 12)).previewFollowsWindow
                && !WindowCommandKind.maximize.previewFollowsWindow
                && !WindowCommandKind.fullScreen.previewFollowsWindow,
               "a drag reads the window's frame only for a preview that depends on it")
    }

    // MARK: Persistence

    private static func persistence(_ expect: (Bool, String) -> Void) {
        var configuration = WindowCommandConfiguration.defaults
        configuration.horizontal.append(WindowCommand(kind: .area(GridRect(x: 2, y: 1, width: 5, height: 7)),
                                                      name: "Notes column",
                                                      shortcut: shortcut(kVK_ANSI_N, [.control, .option, .shift]),
                                                      activation: .interior(GridRect(x: 1, y: 1, width: 3, height: 3)),
                                                      showInMenuBar: false,
                                                      showInGreenButtonMenu: true))
        let encoded = WindowCommandPersistence.encode(configuration)
        expect(encoded.contains("\"version\":1") && WindowCommandPersistence.decode(encoded) == configuration,
               "the command sets survive a round trip through their versioned JSON")
        expect(WindowCommandPersistence.encode(configuration) == encoded,
               "encoding is stable, so an unchanged set writes the same text")
        let future = """
        {"version":9,"horizontal":[{"id":"\(UUID().uuidString)","type":"hologram"},
        {"id":"\(UUID().uuidString)","type":"area","rect":[30,-2,99,4],"menuBar":false},
        {"type":"separator"},{"type":"separator"}],"vertical":[]}
        """
        let lenient = WindowCommandPersistence.decode(future)
        expect(lenient?.horizontal.count == 1
                && lenient?.horizontal.first?.kind == .area(GridRect(x: 23, y: 0, width: 1, height: 2))
                && lenient?.horizontal.first?.showInMenuBar == false
                && lenient?.vertical.isEmpty == true,
               "an unknown kind is skipped, a bad area is clamped and dangling separators drop")
        expect(WindowCommandPersistence.decode("not json") == nil && WindowCommandPersistence.decode("") == nil,
               "an unreadable preference gives no sets, so the defaults take over")

        let suite = "yayasspace.tests.windowCommands.store"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = WindowCommandStore(defaults: defaults) { _ in nil }
        expect(store.configuration.horizontal.count == WindowCommandDefaults.commands(for: .horizontal).count
                && WindowCommandPersistence.load(from: defaults) == store.configuration,
               "a first run creates and saves the default sets")
        var changed = store.commands(.horizontal)[0]
        changed.name = "Left side"
        changed.showInGreenButtonMenu = false
        store.update(changed, in: .horizontal)
        let second = store.commands(.horizontal)[1]
        store.move(second.id, to: changed.id, in: .horizontal)
        store.insert(.separator(), in: .vertical, after: store.commands(.vertical)[0].id)
        let reloaded = WindowCommandStore(defaults: defaults) { _ in nil }
        expect(reloaded.configuration == store.configuration
                && reloaded.commands(.horizontal)[1].customName == "Left side"
                && reloaded.commands(.horizontal)[0].id == second.id
                && reloaded.commands(.vertical)[1].isSeparator,
               "edits, reordering and inserted separators persist across launches")
        store.remove(second.id, in: .horizontal)
        store.resetToDefaults(.vertical)
        let afterReset = WindowCommandStore(defaults: defaults) { _ in nil }
        expect(!afterReset.commands(.horizontal).contains { $0.id == second.id }
                && afterReset.commands(.vertical).count == WindowCommandDefaults.commands(for: .vertical).count,
               "deleting any row and restoring one set's defaults both persist")
        defaults.set("top,bottomLeft", forKey: DefaultsKey.windowEdgeSnapDisabledZones)
        afterReset.foldLegacyZonesIfNeeded()
        let maximize = afterReset.commands(.horizontal).first { $0.builtinID == .maximize }
        expect(maximize?.activationEnabled == false
                && defaults.string(forKey: DefaultsKey.windowEdgeSnapDisabledZones) == "",
               "zones switched off in an old backup become switched-off drag areas, once")
        defaults.set(WindowCommandPersistence.encode(WindowCommandConfiguration(horizontal: [], vertical: [])),
                     forKey: DefaultsKey.windowLayoutCommands)
        expect(!WindowCommandPersistence.hasEnabledDragAreas(in: defaults),
               "empty sets leave drag snapping nothing to listen for")
        defaults.removeObject(forKey: DefaultsKey.windowLayoutCommands)
        expect(WindowCommandPersistence.hasEnabledDragAreas(in: defaults),
               "no stored sets means the defaults, which have drag areas")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Migration

    private static func migration(_ expect: (Bool, String) -> Void) {
        let custom = shortcut(kVK_ANSI_L, [.control, .option, .command])
        let sixth = shortcut(kVK_ANSI_1, [.control, .option])
        let restoreKey = shortcut(kVK_Delete, [.control, .option])
        let stored: [String: String] = [
            DefaultsKey.windowLayoutShortcutLeft: custom.storageValue,
            DefaultsKey.windowLayoutShortcutCenter: WindowLayoutAction.clearedShortcutStorageValue,
            DefaultsKey.windowLayoutShortcutCenterThird: GlobalShortcut.windowLayoutCenterThirdDefault.storageValue,
            DefaultsKey.windowLayoutShortcutTopLeftSixth: sixth.storageValue,
            DefaultsKey.windowLayoutShortcutLeftThird: shortcut(kVK_ANSI_Q, [.control, .option]).storageValue,
            DefaultsKey.windowLayoutShortcutMaximize: restoreKey.storageValue,
            DefaultsKey.windowLayoutShortcutTopRightSixth: WindowLayoutAction.clearedShortcutStorageValue,
        ]
        let migrated = WindowCommandMigration.configuration(legacyShortcut: { stored[$0] },
                                                            disabledZones: [.top, .bottomLeft])
        func command(_ action: WindowLayoutAction, _ kind: WindowCommandSetKind) -> WindowCommand? {
            migrated[kind].first { $0.builtinID == action }
        }
        expect(command(.leftHalf, .horizontal)?.effectiveShortcut == custom
                && command(.leftHalf, .vertical)?.effectiveShortcut == custom,
               "a customised legacy shortcut moves into the matching command of both sets")
        expect(command(.center, .horizontal)?.effectiveShortcut == nil
                && command(.center, .vertical)?.effectiveShortcut == nil,
               "a cleared legacy shortcut stays cleared")
        expect(command(.centerThird, .horizontal)?.effectiveShortcut == shortcut(kVK_ANSI_F, [.control, .option]),
               "a legacy shortcut reset to its default is not a customisation")
        expect(command(.topThird, .vertical)?.effectiveShortcut == shortcut(kVK_ANSI_Q, [.control, .option]),
               "the vertical set's top third takes over a customised left third")
        expect(command(.topLeftSixth, .horizontal)?.effectiveShortcut == sixth
                && command(.topRightSixth, .horizontal) == nil
                && migrated.horizontal.dropLast().last?.isSeparator == true,
               "an extra with its own shortcut joins the set after a separator; a cleared one does not")
        expect(command(.maximize, .horizontal)?.effectiveShortcut == restoreKey
                && command(.restore, .horizontal)?.effectiveShortcut == nil
                && command(.restore, .vertical)?.effectiveShortcut == nil,
               "a legacy choice wins over a new default that uses the same combination")
        expect(command(.centerTwoThirds, .horizontal)?.effectiveShortcut == shortcut(kVK_ANSI_R, [.control, .option]),
               "untouched setups get the new defaults, center two thirds on R")
        expect(command(.maximize, .horizontal)?.activationEnabled == false
                && command(.bottomLeft, .horizontal)?.activationEnabled == false
                && command(.topHalf, .vertical)?.activationEnabled == false
                && command(.leftHalf, .horizontal)?.activationEnabled == true,
               "edge-snap zones switched off before become switched-off drag areas")
        let untouched = WindowCommandMigration.configuration(legacyShortcut: { _ in nil }, disabledZones: [])
        expect(zip(untouched.horizontal, WindowCommandDefaults.commands(for: .horizontal))
                .allSatisfy { $0.isSameContent(as: $1) },
               "a setup that never changed a shortcut gets exactly the default sets")

        let suite = "yayasspace.tests.windowCommands.migration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(16, forKey: DefaultsKey.windowLayoutWindowGap)
        defaults.set(0, forKey: DefaultsKey.windowLayoutScreenGap)
        let store = WindowCommandStore(defaults: defaults) { key in
            key == DefaultsKey.windowLayoutShortcutLeft ? custom.storageValue : nil
        }
        expect(store.commands(.horizontal).first?.effectiveShortcut == custom
                && defaults.bool(forKey: DefaultsKey.windowLayoutFitTightly),
               "the first launch migrates shortcuts and reads a zero screen gap as fitting tightly")
        let again = WindowCommandStore(defaults: defaults) { key in
            key == DefaultsKey.windowLayoutShortcutLeft ? shortcut(kVK_ANSI_P, [.control]).storageValue : nil
        }
        expect(again.commands(.horizontal).first?.effectiveShortcut == custom,
               "migration runs once: later launches keep the saved sets")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Sync

    private static func sync(_ expect: (Bool, String) -> Void) {
        let settings: [String: WindowLayoutSyncSupport.SyncValue] = [
            DefaultsKey.windowEdgeSnapEnabled: .bool(true),
            DefaultsKey.windowLayoutWindowGap: .integer(12),
            DefaultsKey.windowLayoutPreviewStyle: .string("dark"),
            DefaultsKey.windowLayoutIgnoredApps: .strings(["com.example.Tool"]),
        ]
        let document = WindowLayoutSyncSupport.Document(modifiedAt: 1_000, device: "Studio",
                                                        settings: settings,
                                                        commands: .defaults)
        let data = WindowLayoutSyncSupport.encode(document)
        let decoded = data.flatMap(WindowLayoutSyncSupport.decode)
        expect(decoded?.settings == settings && decoded?.device == "Studio" && decoded?.modifiedAt == 1_000
                && decoded?.commands == document.commands,
               "a settings file carries every value and both command sets")
        let wrongTypes = """
        {"format":"yayasspace.window-layout","version":1,"modifiedAt":5,
        "settings":{"windowEdgeSnapEnabled":3,"windowLayoutWindowGap":true,"windowLayoutPreviewStyle":"light"}}
        """
        let filtered = WindowLayoutSyncSupport.decode(Data(wrongTypes.utf8))
        expect(filtered?.settings == [DefaultsKey.windowLayoutPreviewStyle: .string("light")],
               "values of the wrong type are dropped on import")
        expect(WindowLayoutSyncSupport.decode(Data("{\"format\":\"other\"}".utf8)) == nil,
               "a file that is not a window layout settings file is refused")

        let suite = "yayasspace.tests.windowCommands.sync"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        WindowLayoutSyncSupport.apply(settings, to: defaults)
        let snapshot = WindowLayoutSyncSupport.snapshot(of: defaults)
        expect(settings.allSatisfy { snapshot[$0.key] == $0.value },
               "applying a file and reading it back gives the same settings")
        defaults.removePersistentDomain(forName: suite)

        typealias Sync = WindowLayoutSyncSupport
        expect(Sync.decide(localModifiedAt: 10, fileModifiedAt: nil, lastSyncedAt: 0) == (.writeLocal, false)
                && Sync.decide(localModifiedAt: 10, fileModifiedAt: 10.2, lastSyncedAt: 0) == (.none, false),
               "no file means write one; the same change on both sides means nothing to do")
        expect(Sync.decide(localModifiedAt: 10, fileModifiedAt: 20, lastSyncedAt: 10) == (.adoptFile, false)
                && Sync.decide(localModifiedAt: 30, fileModifiedAt: 20, lastSyncedAt: 20) == (.writeLocal, false),
               "the newer side wins")
        expect(Sync.decide(localModifiedAt: 30, fileModifiedAt: 25, lastSyncedAt: 10) == (.writeLocal, true)
                && Sync.decide(localModifiedAt: 25, fileModifiedAt: 30, lastSyncedAt: 10) == (.adoptFile, true),
               "when both changed since the last sync the newer still wins and a conflict is noted")

        // The real last change, 0 when this Mac never changed anything.
        expect(Sync.decide(localModifiedAt: 0, fileModifiedAt: 20, lastSyncedAt: 0) == (.adoptFile, false),
               "a fresh Mac takes the folder's file without a conflict note")
        expect(Sync.decide(localModifiedAt: 0, fileModifiedAt: nil, lastSyncedAt: 0) == (.writeLocal, false)
                && Sync.decide(localModifiedAt: 0, fileModifiedAt: 0, lastSyncedAt: 0) == (.none, false)
                && Sync.decide(localModifiedAt: 12, fileModifiedAt: 0, lastSyncedAt: 0) == (.writeLocal, false),
               "an untouched setup is dated never-changed, so any real change on another Mac outranks it")
        expect(Sync.decide(localModifiedAt: 30, fileModifiedAt: 25, lastSyncedAt: 0) == (.writeLocal, false)
                && Sync.decide(localModifiedAt: 25, fileModifiedAt: 30, lastSyncedAt: 0) == (.adoptFile, false),
               "a folder just chosen starts a new history: the newer side wins without a conflict note")

        expect(Sync.fileName == "Yayas Space Window Layout.json",
               "the sync file has one fixed name")
        let controllerSource = (try? String(
            contentsOfFile: "Sources/YayasSpace/Services/WindowLayout/WindowLayoutSyncController.swift",
            encoding: .utf8)) ?? ""
        expect(controllerSource.contains("appendingPathComponent(WindowLayoutSyncSupport.fileName)")
                && controllerSource.contains("nameFieldStringValue = WindowLayoutSyncSupport.fileName"),
               "the sync folder and Export both use the fixed file name, never a translated one")

        let observed = Set(Sync.observedKeys)
        expect(observed.isSuperset(of: Sync.syncedKeys.map(\.key))
                && observed.contains(DefaultsKey.windowLayoutCommands)
                && observed.isDisjoint(with: [DefaultsKey.windowLayoutSettingsModifiedAt,
                                              DefaultsKey.windowLayoutSyncedAt,
                                              DefaultsKey.windowLayoutSyncFolder,
                                              DefaultsKey.windowLayoutSyncNote]),
               "the change check watches the synced keys and the command sets, never the sync clock it stamps")
        let observerSuite = "yayasspace.tests.windowCommands.observer"
        let observerDefaults = UserDefaults(suiteName: observerSuite)!
        observerDefaults.removePersistentDomain(forName: observerSuite)
        var reported = 0
        var observer: WindowLayoutDefaultsObserver? = WindowLayoutDefaultsObserver(
            defaults: observerDefaults, keys: [DefaultsKey.windowLayoutWindowGap]) { reported += 1 }
        observerDefaults.set(true, forKey: DefaultsKey.dockClickCycleWindows)
        let afterOtherKey = reported
        observerDefaults.set(24, forKey: DefaultsKey.windowLayoutWindowGap)
        expect(observer != nil && afterOtherKey == 0 && reported == 1,
               "a write to another preference never wakes the change check; a synced key does")
        observer = nil
        observerDefaults.set(8, forKey: DefaultsKey.windowLayoutWindowGap)
        expect(reported == 1, "a stopped observer reports nothing")
        observerDefaults.removePersistentDomain(forName: observerSuite)

        expect(Sync.readiness(exists: false, isDataless: false, isUbiquitous: false, downloadStatus: nil) == .missing
                && Sync.readiness(exists: true, isDataless: false, isUbiquitous: false, downloadStatus: nil) == .ready
                && Sync.readiness(exists: true, isDataless: false, isUbiquitous: true,
                                  downloadStatus: .current) == .ready,
               "a local file, or a cloud file that is fully downloaded, is read")
        expect(Sync.readiness(exists: true, isDataless: true, isUbiquitous: false, downloadStatus: nil)
                == .waitingForDownload
                && Sync.readiness(exists: true, isDataless: false, isUbiquitous: true,
                                  downloadStatus: .notDownloaded) == .waitingForDownload
                && Sync.readiness(exists: true, isDataless: false, isUbiquitous: true,
                                  downloadStatus: .downloaded) == .waitingForDownload,
               "a placeholder or a stale cloud copy is skipped until it is downloaded, never waited on")
    }
}
