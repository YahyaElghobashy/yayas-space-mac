// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import QuartzCore

enum WindowLayoutError: Equatable {
    case missingAccessibility
    case noWindow
    case noRestore
    case failed
}

enum WindowLayoutResult: Equatable {
    case success(restored: Bool)
    case failure(WindowLayoutError)
}

/// Window placement through explicit panel actions, global shortcuts and an
/// optional pointer gesture. The active taps only perform Accessibility work
/// after a deliberate gesture. Edge snapping changes an event only after the
/// same window has visibly followed the pointer to the top of a screen.
final class WindowLayoutService: ObservableObject {
    static let shared = WindowLayoutService()

    @Published private(set) var lastResult: WindowLayoutResult?
    /// Bumped on every published result, so a late settle failure can tell
    /// whether it still owns the feedback slot.
    private var resultGeneration = 0
    /// Command shortcuts the system refused to register (another app holds
    /// the combination).
    @Published private(set) var failedShortcuts: Set<GlobalShortcut> = []
    @Published private(set) var directionalShortcutRegistrationFailed = false
    @Published private(set) var isGestureRunning = false

    private var frameHistory = WindowLayoutHistory()
    private var lastActions: [WindowLayoutWindowKey: WindowLayoutAction] = [:]
    private var hotKeyRefs: [Int: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// One registration per combination any command set uses; the slot is
    /// the hotkey id, and which command runs is decided when it fires.
    private var registeredShortcuts: [GlobalShortcut] = []
    /// Windows a placement snapped, with the size they had before, so a
    /// drag can give that size back.
    private var snapRecords: [WindowLayoutWindowKey: WindowSnapRecord] = [:]
    /// What dragging does, as last resolved; the tap reads it on each press.
    private var dragTracking = WindowDragTracking.off
    private var commandStoreObservation: AnyCancellable?
    private var directionalHotKeyRef: EventHotKeyRef?
    private var registeredDirectionalShortcut: GlobalShortcut?
    private var directionalSession: WindowDirectionalSession?
    private var directionalTimer: Timer?
    private var directionalIndicatorPanel: NSPanel?
    private var directionalTap: CFMachPort?
    private var directionalTapSource: CFRunLoopSource?
    private var gestureTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private var edgeSnapTap: CFMachPort?
    private var edgeSnapRunLoopSource: CFRunLoopSource?
    private var activeGesture: WindowPointerGesture?
    private var pendingGesture: PendingWindowGesture?
    private var edgeSnapPressOrigin: CGPoint?
    private var edgeSnapPressCandidate: WindowServerWindowCandidate?
    /// Whether the press being followed may end in a drop placement, or is
    /// only followed to give a placed window its size back.
    private var edgeSnapPressPlaces = false
    private var edgeSnapSequenceSuppressed = false
    private var edgeSnapResolveAttempts = 0
    private var edgeSnapLastResolveAt: TimeInterval = 0
    private var edgeSnapDrag: WindowEdgeSnapDrag?
    private var edgeSnapSequenceGeneration = 0
    private var edgeSnapPreviewPanel: NSPanel?
    private var edgeSnapPreviewGeneration = 0
    private var assistiveModeSuspensions: [CGWindowID: EnhancedUserInterfaceSuspension] = [:]
    private var settleTimers: [CGWindowID: Timer] = [:]
    private var gestureAssistiveMode: EnhancedUserInterfaceSuspension?
    /// Stamped on the press this service gives back to the system so none of
    /// our own taps mistake it for a fresh one.
    private static let syntheticEventMarker: Int64 = 0x564F5253
    /// Read on every pointer event, so it is resolved once instead of per
    /// click.
    private static let ownProcessID = Int64(getpid())
    private let frameTolerance = WindowLayoutGeometry.frameTolerance
    private let anchorTolerance: CGFloat = 36
    private let moveGestureUpdateInterval: TimeInterval = 1.0 / 120.0
    // AX frame mutations are not atomic. Complex windows can visibly render
    // the intermediate size and position when they receive resize writes at
    // pointer-reporting speed, so resize is deliberately coalesced to 60 Hz.
    private let resizeGestureUpdateInterval: TimeInterval = 1.0 / 60.0
    private let edgeSnapSampleInterval: TimeInterval = 1.0 / 30.0

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in self?.syncWithPreferences() }
        // Edited commands take effect at once: shortcuts re-register and the
        // drag listener starts or stops with the drag areas.
        commandStoreObservation = WindowCommandStore.shared.$configuration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWithPreferences() }
    }

    private var commands: WindowCommandConfiguration { WindowCommandStore.shared.configuration }

    func syncWithPreferences() {
        let available = AppFeature.windowLayout.isAvailable
        let trusted = SessionActivitySupport.tapShouldRun(
            featureWanted: available,
            accessibilityGranted: AXIsProcessTrusted(),
            sessionIsActive: SessionActivity.shared.isActive)
        let wantsShortcuts = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled)
            && trusted
        wantsShortcuts ? registerHotkeys() : unregisterHotkeys()

        let wantsDirectional = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowDirectionalEnabled)
            && trusted
        wantsDirectional ? registerDirectionalHotkey() : unregisterDirectionalHotkey()

        let wantsGesture = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureEnabled)
            && trusted
        wantsGesture ? startGestureTap() : stopGestureTap()

        syncDragTracking(available: available, trusted: trusted)
        WindowLayoutCompanions.sync(available: available, trusted: trusted)
    }

    /// What dragging has to do right now, from the switches, the system's
    /// own tiling and whether any placed window is remembered.
    private func resolveDragTracking(available: Bool, trusted: Bool) -> WindowDragTracking {
        let defaults = UserDefaults.standard
        return WindowDragTracking.resolve(
            featureAvailable: available,
            trusted: trusted,
            snappingEnabled: defaults.bool(forKey: DefaultsKey.windowEdgeSnapEnabled),
            hasLiveDragAreas: commands.hasEnabledActivation,
            systemTilingEnabled: WindowEdgeSnapSupport.isSystemTilingEnabled,
            restoreSizeEnabled: defaults.bool(forKey: DefaultsKey.windowLayoutRestoreSizeOnDrag),
            hasPlacedWindows: !snapRecords.isEmpty)
    }

    private func resolveDragTracking() -> WindowDragTracking {
        let available = AppFeature.windowLayout.isAvailable
        let trusted = SessionActivitySupport.tapShouldRun(
            featureWanted: available,
            accessibilityGranted: AXIsProcessTrusted(),
            sessionIsActive: SessionActivity.shared.isActive)
        return resolveDragTracking(available: available, trusted: trusted)
    }

    /// Runs the drag listener while drag snapping or restoring a placed
    /// window's size has work, and only then. A drag already under way
    /// finishes first, unless the feature or its permission went away.
    private func syncDragTracking(available: Bool? = nil, trusted: Bool? = nil) {
        let tracking: WindowDragTracking
        if let available, let trusted {
            tracking = resolveDragTracking(available: available, trusted: trusted)
        } else {
            tracking = resolveDragTracking()
        }
        dragTracking = tracking
        if tracking.listens {
            startEdgeSnapTap()
        } else if available == false || trusted == false
                    || (edgeSnapPressOrigin == nil && edgeSnapDrag == nil) {
            stopEdgeSnapTap()
        }
    }

    /// Stops every Window Layout input hook before Accessibility is revoked or
    /// the process terminates. Idempotent so permission and feature changes can
    /// call it freely.
    func suspend() {
        unregisterHotkeys()
        unregisterDirectionalHotkey()
        stopGestureTap()
        stopEdgeSnapTap()
        WindowLayoutCompanions.suspend()
        for timer in settleTimers.values { timer.invalidate() }
        settleTimers.removeAll()
        let suspensions = assistiveModeSuspensions.values
        assistiveModeSuspensions.removeAll()
        // With the grant already revoked there is no safe way to touch the
        // apps again; the flag comes back when the assistive client sets it.
        guard AXIsProcessTrusted() else { return }
        for suspension in suspensions { suspension.resume() }
    }

    /// The command that answers to a combination, for other features'
    /// shortcut fields. Silent while window layout shortcuts are off, since
    /// nothing is registered then.
    func shortcutConflictTitle(_ shortcut: GlobalShortcut) -> String? {
        guard AppFeature.windowLayout.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled) else { return nil }
        for kind in WindowCommandSetKind.allCases {
            if let command = commands[kind].first(where: { $0.effectiveShortcut == shortcut }) {
                return WindowCommandStrings.displayName(of: command, language: L10n.shared.language)
            }
        }
        return nil
    }

    func directionalShortcutConflictTitle(_ shortcut: GlobalShortcut) -> String? {
        if let role = GlobalShortcutRole.conflict(for: shortcut, excluding: nil) {
            return role.title(L10n.shared.s)
        }
        return shortcutConflictTitle(shortcut)
    }

    /// A built-in picked on the main-panel grid, the radial menu or the
    /// command bar. It runs the user's command for that built-in from the
    /// set of the display the window is on, so the shortcut printed next to
    /// it and what happens always agree; only a set without that built-in
    /// runs it as shipped. Ignored apps are left alone.
    @discardableResult
    func apply(_ action: WindowLayoutAction) -> WindowLayoutResult {
        guard AXIsProcessTrusted() else {
            return finish(.failure(.missingAccessibility))
        }
        let configuration = commands
        let screens = NSScreen.screens
        var route: (command: WindowCommand?, kind: WindowCommandSetKind)?
        let resolved = focusedTarget(frontAppOnly: false) { candidate in
            // The set, the command and the check all come from this window.
            let kind = setKind(for: candidate.frame, screens: screens)
            let command = WindowCommandRouting.command(for: action, in: configuration[kind])
            let capability = command.map { capability(for: $0, setKind: kind) } ?? action.targetCapability
            guard supports(capability, candidate) else { return .skip }
            route = (command, kind)
            return .accept
        }
        guard let target = resolved, let route else {
            return finish(.failure(.noWindow))
        }
        guard !isIgnored(processID: target.key.processID) else { return .failure(.noWindow) }
        if let command = route.command {
            return apply(command, setKind: route.kind, to: target, dropVisibleFrame: nil, historyFrame: nil,
                         origin: .builtinPicker)
        }
        return apply(action, to: target, origin: .builtinPicker)
    }

    private func apply(_ action: WindowLayoutAction,
                       to target: WindowLayoutTarget,
                       dropVisibleFrame: NSRect? = nil,
                       historyFrame: WindowLayoutFrame? = nil,
                       origin: WindowCommandOrigin) -> WindowLayoutResult {
        pruneWindowState(keeping: target.key)

        if action == .restore {
            guard let previous = frameHistory.popPrevious(for: target.key,
                                                          current: target.frame) else {
                return finish(.failure(.noRestore))
            }
            if setFrame(previous, on: target.window, windowKey: target.key) {
                lastActions.removeValue(forKey: target.key)
                if snapRecords.removeValue(forKey: target.key) != nil { syncDragTracking() }
                return finish(.success(restored: true))
            }
            frameHistory.record(previous, for: target.key)
            return finish(.failure(.failed))
        }

        if action == .fullScreen {
            // A placement still settling must never write its old frame over
            // the native full-screen transition that replaces it.
            cancelSettle(for: target.windowID)
            assistiveModeSuspensions.removeValue(forKey: target.windowID)?.resume()
            // The native full screen the green button gives, toggled through
            // the same attribute the button writes. The system owns the frame
            // from here, so nothing is remembered for restore.
            var raw: CFTypeRef?
            AXUIElementCopyAttributeValue(target.window, "AXFullScreen" as CFString, &raw)
            let isFullScreen = (raw as? NSNumber)?.boolValue ?? false
            let flipped = (isFullScreen ? kCFBooleanFalse : kCFBooleanTrue) as CFTypeRef
            let applied = AXUIElementSetAttributeValue(target.window,
                                                       "AXFullScreen" as CFString,
                                                       flipped) == .success
            // Remembered like any other placement, or the "same half twice
            // means maximize" rule would still be looking at whatever the
            // window did before it went full screen.
            if applied {
                if isFullScreen {
                    lastActions.removeValue(forKey: target.key)
                } else {
                    lastActions[target.key] = .fullScreen
                }
            }
            return applied ? finish(.success(restored: false)) : finish(.failure(.failed))
        }
        let screens = NSScreen.screens
        guard let screen = bestScreen(for: target.frame, screens: screens) else {
            return finish(.failure(.failed))
        }
        let currentRect = appKitFrame(fromAX: target.frame)
        if action == .previousDisplay || action == .nextDisplay {
            guard let destination = adjacentScreen(to: screen,
                                                   screens: screens,
                                                   movingForward: action == .nextDisplay) else {
                return finish(.failure(.failed))
            }
            let rect = WindowLayoutGeometry.rectForDisplay(current: currentRect,
                                                           sourceVisibleFrame: screen.visibleFrame,
                                                           destinationVisibleFrame: destination.visibleFrame)
            frameHistory.record(target.frame, for: target.key)
            if setFrame(axFrame(fromAppKit: rect),
                        targetRect: rect,
                        screenVisibleFrame: destination.visibleFrame,
                        action: action,
                        anchor: .action(action),
                        on: target.window,
                        windowKey: target.key) {
                lastActions[target.key] = action
                return finish(.success(restored: false))
            }
            frameHistory.discardLatest(for: target.key)
            return finish(.failure(.failed))
        }
        // Only the keyboard and the built-in pickers repeat: a menu choice
        // or a drop does what it names every time.
        let previousAction = origin.previousAction(lastActions[target.key])
        if dropVisibleFrame == nil,
           let crossing = WindowLayoutGeometry.displayCrossing(for: action,
                                                               previousAction: previousAction),
           accepted(actual: target.frame,
                    targetRect: placement(for: action,
                                          current: target.frame,
                                          visibleFrame: screen.visibleFrame).rect,
                    anchor: .action(action)),
           let destination = sidewaysScreen(to: screen,
                                            screens: screens,
                                            movingRight: crossing.movingRight) {
            // The window is already parked on that side, so the same shortcut
            // keeps pushing in the same direction: over to the display beside
            // it, snapped against the edge it came in through. Without a
            // display on that side the placement below simply leaves it where
            // it is.
            return applyPlacement(crossing.action,
                                  to: target,
                                  visibleFrame: destination.visibleFrame,
                                  cyclesRepeatedAction: false)
        }
        if let dropVisibleFrame {
            // A drop picks its display with the pointer, and never cycles.
            return applyPlacement(action,
                                  to: target,
                                  visibleFrame: dropVisibleFrame,
                                  historyFrame: historyFrame,
                                  cyclesRepeatedAction: false)
        }
        return applyPlacement(action,
                              to: target,
                              visibleFrame: screen.visibleFrame,
                              cyclesRepeatedAction: origin.appliesRepeatRules)
    }

    /// Applies a pointer-selected snap target to one exact external window.
    /// Dock Preview resolves the target from the drop location; the frame still
    /// goes through the same settling and recovery path as every Window Layout
    /// placement instead of maintaining a second AX mutation algorithm.
    @discardableResult
    private func finish(_ result: WindowLayoutResult) -> WindowLayoutResult {
        resultGeneration += 1
        lastResult = result
        return result
    }

    private func applyPlacement(_ action: WindowLayoutAction,
                                to target: WindowLayoutTarget,
                                visibleFrame: NSRect,
                                historyFrame: WindowLayoutFrame? = nil,
                                cyclesRepeatedAction: Bool = true) -> WindowLayoutResult {
        let currentRect = appKitFrame(fromAX: target.frame)
        let previousAction = cyclesRepeatedAction ? lastActions[target.key] : nil
        let effectiveAction = WindowLayoutGeometry.effectiveAction(for: action,
                                                                   current: currentRect,
                                                                   visibleFrame: visibleFrame,
                                                                   previousAction: previousAction)
        let placement = placement(for: effectiveAction,
                                  current: target.frame,
                                  visibleFrame: visibleFrame)
        if placement.frame == target.frame {
            lastActions[target.key] = effectiveAction
            return finish(.success(restored: false))
        }
        frameHistory.record(historyFrame ?? target.frame, for: target.key)
        if setFrame(placement.frame,
                    targetRect: placement.rect,
                    screenVisibleFrame: visibleFrame,
                    action: effectiveAction,
                    anchor: .action(effectiveAction),
                    on: target.window,
                    windowKey: target.key) {
            lastActions[target.key] = effectiveAction
            if effectiveAction != .center {
                noteSnapped(target.key, placed: placement.frame, before: historyFrame ?? target.frame)
            }
            return finish(.success(restored: false))
        }
        frameHistory.discardLatest(for: target.key)
        return finish(.failure(.failed))
    }

    private func focusedTarget(for action: WindowLayoutAction) -> WindowLayoutTarget? {
        focusedTarget(capability: action.targetCapability)
    }

    private func focusedTarget(capability: WindowLayoutTargetCapability) -> WindowLayoutTarget? {
        focusedTarget(frontAppOnly: false) { supports(capability, $0) ? .accept : .skip }
    }

    /// The window a keyboard or menu command acts on, looked up once: the
    /// front app's focused window, then its main window, then its other
    /// windows, and, unless `frontAppOnly`, the same for the recently used
    /// apps after it. `judge` sees every candidate once and decides: take
    /// it, look further, or stop with nothing. Whatever it decides about a
    /// window (its set, its command, the capability needed) is decided from
    /// that same window, so nothing is resolved twice.
    private func focusedTarget(frontAppOnly: Bool,
                               judge: (WindowLayoutCandidate) -> WindowCandidateVerdict) -> WindowLayoutTarget? {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownKeyWindow = NSApp.keyWindow
        let hasFocusedResizableOwnWindow = NSApp.isActive
            && ownKeyWindow?.styleMask.contains(.resizable) == true
            && !(ownKeyWindow is NSPanel)
        let frontmost = hasFocusedResizableOwnWindow
            ? ownPID
            : NSWorkspace.shared.frontmostApplication?.processIdentifier
        var pids = ([frontmost].compactMap { $0 } + WindowUseTracker.shared.apps).reduce(into: [pid_t]()) { result, pid in
            if !result.contains(pid) { result.append(pid) }
        }
        // A menu acts on the app in front and nothing else: an app without a
        // window of its own must never hand the command to another app.
        if frontAppOnly { pids = frontmost.map { [$0] } ?? [] }

        guard let onScreenWindowIDs = onScreenWindowIDs() else { return nil }
        for pid in pids {
            let isFocusedOwnApp = pid == ownPID && hasFocusedResizableOwnWindow
            // One lookup by pid, not a fresh bridge of every running app on
            // each turn of a list that can hold dozens of them. The edge-snap
            // drag in this same file already resolves its app this way.
            // isTerminated is explicit because runningApplications drops a dead
            // pid on its own and NSRunningApplication(processIdentifier:) does
            // not: it answers with a terminated instance.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated,
                  isFocusedOwnApp
                    || (app.activationPolicy == .regular && !app.isHidden
                        && app.bundleIdentifier != ownBundleID)
            else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            // Bounded AX: a hung app in the MRU list must not stall the main
            // thread (and every event tap) for the default timeout.
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            // The focused and main windows first, then the rest; each window
            // is judged once even when it turns up under several names.
            var judged = Set<CGWindowID>()
            var windows = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap {
                windowAttribute(axApp, $0 as String)
            }
            var listedAll = false
            var index = 0
            while true {
                if index == windows.count {
                    guard !listedAll else { break }
                    listedAll = true
                    windows += windowsAttribute(axApp) ?? []
                    if index == windows.count { break }
                }
                let window = windows[index]
                index += 1
                guard let candidate = candidate(from: window, app: app, onScreenWindowIDs: onScreenWindowIDs),
                      judged.insert(candidate.key.windowID).inserted
                else { continue }
                switch judge(candidate) {
                case .accept: return candidate.target
                case .stop: return nil
                case .skip: continue
                }
            }
        }
        return nil
    }

    /// A window that could be acted on at all: a real, visible, unminimized
    /// window of some size. What it lets Accessibility change is asked
    /// separately, only for the capability a command needs.
    private func candidate(from window: AXUIElement,
                           app: NSRunningApplication,
                           onScreenWindowIDs: Set<CGWindowID>) -> WindowLayoutCandidate? {
        guard role(of: window) == (kAXWindowRole as String),
              !boolAttribute(window, kAXMinimizedAttribute as String),
              stringAttribute(window, kAXSubroleAttribute as String) != "AXFloatingWindow",
              let windowID = AXWindowResolver.windowID(for: window),
              onScreenWindowIDs.contains(windowID),
              let frame = frame(of: window),
              frame.size.width > 80,
              frame.size.height > 80
        else { return nil }
        let key = WindowLayoutWindowKey(
            processID: app.processIdentifier,
            processLaunchTime: app.launchDate?.timeIntervalSinceReferenceDate ?? 0,
            windowID: windowID
        )
        return WindowLayoutCandidate(window: window, app: app, key: key, frame: frame,
                                     isFullScreen: boolAttribute(window, "AXFullScreen"))
    }

    /// Whether a candidate lets Accessibility make the change a capability
    /// names. Only Full Screen may act on a window in full screen.
    private func supports(_ capability: WindowLayoutTargetCapability,
                          _ candidate: WindowLayoutCandidate) -> Bool {
        switch capability {
        case .position:
            return !candidate.isFullScreen && canSetPosition(on: candidate.window)
        case .frame:
            return !candidate.isFullScreen && canSetFrame(on: candidate.window)
        case .fullScreen:
            return canSetFullScreen(on: candidate.window)
        }
    }

    private func target(from window: AXUIElement,
                        app: NSRunningApplication,
                        onScreenWindowIDs: Set<CGWindowID>,
                        capability: WindowLayoutTargetCapability) -> WindowLayoutTarget? {
        guard let candidate = candidate(from: window, app: app, onScreenWindowIDs: onScreenWindowIDs),
              supports(capability, candidate)
        else { return nil }
        return candidate.target
    }

    /// The set of the display a window is on: vertical on a portrait one.
    private func setKind(for frame: WindowLayoutFrame, screens: [NSScreen]) -> WindowCommandSetKind {
        .forDisplay((bestScreen(for: frame, screens: screens) ?? NSScreen.main)?.frame ?? .zero)
    }

    /// The kinds of display connected right now, for the surfaces that print
    /// a built-in's shortcut before any window is picked.
    static func connectedSetKinds() -> Set<WindowCommandSetKind> {
        let kinds = Set(NSScreen.screens.map { WindowCommandSetKind.forDisplay($0.frame) })
        return kinds.isEmpty ? [.horizontal] : kinds
    }

    private func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(windows.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    /// Removes histories whose process or window no longer exists. This runs
    /// only for an explicit layout action, never from a timer or input tap.
    private func pruneWindowState(keeping current: WindowLayoutWindowKey) {
        guard var activeWindows = activeWindowKeys() else { return }
        activeWindows.insert(current)
        frameHistory.removeStaleWindows(keeping: activeWindows)
        lastActions = lastActions.filter { activeWindows.contains($0.key) }
        let placedBefore = snapRecords.count
        snapRecords = snapRecords.filter { activeWindows.contains($0.key) }
        if snapRecords.count != placedBefore { syncDragTracking() }
    }

    private func activeWindowKeys() -> Set<WindowLayoutWindowKey>? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var launchTimes: [pid_t: TimeInterval] = [:]
        var keys = Set<WindowLayoutWindowKey>()
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            if launchTimes[pid] == nil {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else { continue }
                launchTimes[pid] = app.launchDate?.timeIntervalSinceReferenceDate ?? 0
            }
            guard let launchTime = launchTimes[pid] else { continue }
            keys.insert(WindowLayoutWindowKey(processID: pid,
                                              processLaunchTime: launchTime,
                                              windowID: windowID))
        }
        return keys.isEmpty ? nil : keys
    }

    private func placement(for action: WindowLayoutAction,
                           current: WindowLayoutFrame,
                           visibleFrame: NSRect) -> WindowLayoutPlacement {
        let rect = WindowLayoutGeometry.rect(for: action,
                                             current: appKitFrame(fromAX: current),
                                             visibleFrame: visibleFrame,
                                             windowGap: WindowLayoutGaps.windowGap,
                                             screenGap: WindowLayoutGaps.screenGap)
        let integral = rect.integral
        return WindowLayoutPlacement(frame: axFrame(fromAppKit: integral), rect: integral)
    }

    private func setFrame(_ frame: WindowLayoutFrame,
                          on window: AXUIElement,
                          windowKey: WindowLayoutWindowKey) -> Bool {
        setFrame(frame,
                 targetRect: appKitFrame(fromAX: frame),
                 screenVisibleFrame: appKitFrame(fromAX: frame),
                 action: .restore,
                 anchor: .action(.restore),
                 on: window,
                 windowKey: windowKey)
    }

    /// `action` is the built-in behind the placement, if any, for restore
    /// bookkeeping; `anchor` decides how a window that cannot take the exact
    /// size is pinned and how the settle check recognises the result.
    private func setFrame(_ frame: WindowLayoutFrame,
                          targetRect: NSRect,
                          screenVisibleFrame: NSRect,
                          action: WindowLayoutAction?,
                          anchor: WindowPlacementAnchor,
                          on window: AXUIElement,
                          windowKey: WindowLayoutWindowKey) -> Bool {
        let windowID = windowKey.windowID
        cancelSettle(for: windowID)
        assistiveModeSuspensions.removeValue(forKey: windowID)?.resume()
        assistiveModeSuspensions[windowID] = EnhancedUserInterfaceSuspension.suspend(forAppOf: window)

        let original = self.frame(of: window)
        if attempt(frame, targetRect: targetRect, anchor: anchor, on: window) {
            assistiveModeSuspensions.removeValue(forKey: windowID)?.resume()
            return true
        }

        // Some apps commit Accessibility size changes with a short delay, so
        // the reads above can still see the old frame. Judging failure now and
        // restoring the original is what used to leave windows moved but never
        // resized (issue #334): let the window settle before deciding.
        scheduleSettle(SettleContext(window: window,
                                     windowID: windowID,
                                     frame: frame,
                                     targetRect: targetRect,
                                     screenVisibleFrame: screenVisibleFrame,
                                     action: action,
                                     anchor: anchor,
                                     original: original,
                                     previousAction: lastActions[windowKey],
                                     windowKey: windowKey,
                                     resultGeneration: resultGeneration + 1),
                       attempt: 0)
        return true
    }

    private func scheduleSettle(_ context: SettleContext, attempt: Int) {
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.settleTimers[context.windowID] = nil
            self.continueSettle(context, attempt: attempt)
        }
        settleTimers[context.windowID] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func continueSettle(_ context: SettleContext, attempt: Int) {
        if verified(context) {
            concludeSettle(context, success: true)
            return
        }
        if self.attempt(context.frame,
                        targetRect: context.targetRect,
                        anchor: context.anchor,
                        on: context.window) {
            concludeSettle(context, success: true)
            return
        }
        if attempt == 0 {
            scheduleSettle(context, attempt: 1)
            return
        }
        if let original = context.original, WindowLayoutGeometry.usesMaximizeFallback(context.anchor) {
            // An ungapped scratch frame that coaxes a stubborn window into
            // resizing; the gapped target is re-applied right after.
            let currentRect = appKitFrame(fromAX: original)
            let maxFrame = axFrame(fromAppKit: WindowLayoutGeometry.rect(for: .maximize,
                                                                         current: currentRect,
                                                                         visibleFrame: context.screenVisibleFrame))
            applyFrame(maxFrame, on: context.window)
            if self.attempt(context.frame,
                            targetRect: context.targetRect,
                            anchor: context.anchor,
                            on: context.window) {
                concludeSettle(context, success: true)
                return
            }
        }
        concludeSettle(context, success: false)
    }

    private func verified(_ context: SettleContext) -> Bool {
        guard let actual = frame(of: context.window) else { return false }
        return actual.isClose(to: context.frame, tolerance: frameTolerance)
            || accepted(actual: actual, targetRect: context.targetRect, anchor: context.anchor)
    }

    // The action already reported success while the window was settling, so a
    // refusal this late restores the window, undoes the bookkeeping and
    // republishes the result the panel feedback listens to.
    private func concludeSettle(_ context: SettleContext, success: Bool) {
        assistiveModeSuspensions.removeValue(forKey: context.windowID)?.resume()
        guard !success else { return }
        if let original = context.original {
            applyFrame(original, on: context.window)
        }
        if context.action == .restore {
            frameHistory.record(context.frame, for: context.windowKey)
        } else {
            frameHistory.discardLatest(for: context.windowKey)
        }
        if let previousAction = context.previousAction {
            lastActions[context.windowKey] = previousAction
        } else {
            lastActions.removeValue(forKey: context.windowKey)
        }
        // A second action already published a fresh result; this stale
        // failure must not overwrite the feedback the person is reading.
        if context.resultGeneration == resultGeneration {
            lastResult = .failure(.failed)
        }
    }

    private func cancelSettle(for windowID: CGWindowID) {
        settleTimers.removeValue(forKey: windowID)?.invalidate()
    }

    private func attempt(_ frame: WindowLayoutFrame,
                         targetRect: NSRect,
                         anchor: WindowPlacementAnchor,
                         on window: AXUIElement) -> Bool {
        let visibleFrame = bestScreen(for: frame)?.visibleFrame ?? targetRect
        for _ in 0..<3 {
            applyFrame(frame,
                       targetRect: targetRect,
                       visibleFrame: visibleFrame,
                       anchor: anchor,
                       on: window)
            guard let actual = self.frame(of: window) else { continue }
            if actual.isClose(to: frame, tolerance: frameTolerance)
                || accepted(actual: actual, targetRect: targetRect, anchor: anchor) {
                return true
            }
        }
        return false
    }

    private func applyFrame(_ frame: WindowLayoutFrame, on window: AXUIElement) {
        _ = setSize(frame.size, on: window)
        _ = setPosition(frame.origin, on: window)
        _ = setSize(frame.size, on: window)
        _ = setPosition(frame.origin, on: window)
    }

    private func applyFrame(_ frame: WindowLayoutFrame,
                            targetRect: NSRect,
                            visibleFrame: NSRect,
                            anchor: WindowPlacementAnchor,
                            on window: AXUIElement) {
        let requestedRect = WindowLayoutGeometry.anchoredRect(for: anchor,
                                                              targetRect: targetRect,
                                                              actualSize: frame.size,
                                                              visibleFrame: visibleFrame)
        let requestedFrame = axFrame(fromAppKit: requestedRect)
        _ = setPosition(requestedFrame.origin, on: window)
        _ = setSize(frame.size, on: window)
        let acceptedSize = self.frame(of: window)?.size ?? frame.size
        let anchoredRect = WindowLayoutGeometry.anchoredRect(for: anchor,
                                                            targetRect: targetRect,
                                                            actualSize: acceptedSize,
                                                            visibleFrame: visibleFrame)
        let anchoredFrame = axFrame(fromAppKit: anchoredRect)
        _ = setPosition(anchoredFrame.origin, on: window)
        _ = setSize(frame.size, on: window)
        let finalSize = self.frame(of: window)?.size ?? acceptedSize
        let finalRect = WindowLayoutGeometry.anchoredRect(for: anchor,
                                                         targetRect: targetRect,
                                                         actualSize: finalSize,
                                                         visibleFrame: visibleFrame)
        _ = setPosition(axFrame(fromAppKit: finalRect).origin, on: window)
    }

    private func accepted(actual: WindowLayoutFrame,
                          targetRect: NSRect,
                          anchor: WindowPlacementAnchor) -> Bool {
        let actualRect = appKitFrame(fromAX: actual)
        return WindowLayoutGeometry.accepts(actualRect: actualRect,
                                            targetRect: targetRect,
                                            anchor: anchor,
                                            anchorTolerance: anchorTolerance)
    }

    // MARK: - Commands

    /// The built-in behaviour behind a command, when it has one: a fixed kind,
    /// or an area that still has its built-in's exact rectangle. Those run the
    /// built-in path with everything it does (a repeated side crossing to the
    /// next display, Top twice maximizing). An edited or custom area is a
    /// plain grid placement.
    func placementAction(for command: WindowCommand, grid: WindowGrid) -> WindowLayoutAction? {
        if let fixed = command.kind.fixedAction { return fixed }
        if WindowCommandDefaults.isCanonical(command, in: grid) { return command.builtinID }
        return nil
    }

    /// The Accessibility capability a command needs from its window.
    private func capability(for command: WindowCommand,
                            setKind: WindowCommandSetKind) -> WindowLayoutTargetCapability {
        placementAction(for: command, grid: setKind.grid)?.targetCapability ?? .frame
    }

    /// A command shortcut fired. The window is looked up once, and the set
    /// comes from the display that same window is on; a combination only the
    /// other set uses does nothing. A window that cannot take the command (a
    /// fixed-size one, for a placement that resizes) is passed over for the
    /// next candidate, as every placement always did.
    fileprivate func runShortcut(slot: Int) {
        guard registeredShortcuts.indices.contains(slot) else { return }
        let shortcut = registeredShortcuts[slot]
        guard AXIsProcessTrusted() else {
            finish(.failure(.missingAccessibility))
            return
        }
        let configuration = commands
        let screens = NSScreen.screens
        var chosen: (command: WindowCommand, kind: WindowCommandSetKind)?
        var unusedHere = false
        let resolved = focusedTarget(frontAppOnly: false) { candidate in
            // A window that cannot even move never decides the set.
            guard candidate.isFullScreen || supports(.position, candidate) else { return .skip }
            let kind = setKind(for: candidate.frame, screens: screens)
            guard let command = WindowCommandShortcuts.command(for: shortcut, in: configuration, setKind: kind) else {
                unusedHere = true
                return .stop
            }
            guard supports(capability(for: command, setKind: kind), candidate) else { return .skip }
            chosen = (command, kind)
            return .accept
        }
        guard let target = resolved, let chosen else {
            if !unusedHere { finish(.failure(.noWindow)) }
            return
        }
        guard !isIgnored(processID: target.key.processID) else { return }
        _ = apply(chosen.command, setKind: chosen.kind, to: target, dropVisibleFrame: nil, historyFrame: nil,
                  origin: .shortcut)
    }

    /// Applies a command chosen by name: from the menu-bar menu or the
    /// green-button menu (which pass the window they were opened for), or
    /// Settings' Try It (the window in front). A chosen command never takes
    /// the keyboard's repeat rules. Ignored apps are left alone without a
    /// message.
    @discardableResult
    func apply(_ command: WindowCommand,
               setKind: WindowCommandSetKind,
               window: AXUIElement? = nil) -> WindowLayoutResult {
        guard !command.isSeparator else { return .failure(.failed) }
        guard AXIsProcessTrusted() else { return finish(.failure(.missingAccessibility)) }
        let capability = capability(for: command, setKind: setKind)
        let target: WindowLayoutTarget?
        if let window {
            target = self.target(forWindow: window, capability: capability)
        } else {
            target = focusedTarget(capability: capability)
        }
        guard let target else { return finish(.failure(.noWindow)) }
        guard !isIgnored(processID: target.key.processID) else { return .failure(.noWindow) }
        return apply(command, setKind: setKind, to: target, dropVisibleFrame: nil, historyFrame: nil,
                     origin: .menu)
    }

    private func apply(_ command: WindowCommand,
                       setKind: WindowCommandSetKind,
                       to target: WindowLayoutTarget,
                       dropVisibleFrame: NSRect?,
                       historyFrame: WindowLayoutFrame?,
                       origin: WindowCommandOrigin) -> WindowLayoutResult {
        if let action = placementAction(for: command, grid: setKind.grid) {
            return apply(action, to: target, dropVisibleFrame: dropVisibleFrame, historyFrame: historyFrame,
                         origin: origin)
        }
        guard case .area(let rect) = command.kind else { return finish(.failure(.failed)) }
        return applyArea(rect, grid: setKind.grid, to: target,
                         visibleFrame: dropVisibleFrame, historyFrame: historyFrame)
    }

    /// A grid area of a custom (or edited) command: the rectangle inside the
    /// margins, pinned to the screen edges it touches.
    private func applyArea(_ rect: GridRect,
                           grid: WindowGrid,
                           to target: WindowLayoutTarget,
                           visibleFrame: NSRect?,
                           historyFrame: WindowLayoutFrame?) -> WindowLayoutResult {
        pruneWindowState(keeping: target.key)
        guard let visible = visibleFrame ?? bestScreen(for: target.frame)?.visibleFrame else {
            return finish(.failure(.failed))
        }
        let targetRect = WindowCommandGeometry.frame(for: rect,
                                                     grid: grid,
                                                     visibleFrame: visible,
                                                     windowGap: WindowLayoutGaps.windowGap,
                                                     screenGap: WindowLayoutGaps.screenGap).integral
        let frame = axFrame(fromAppKit: targetRect)
        // An area never takes part in the "same side twice" rules.
        lastActions.removeValue(forKey: target.key)
        if frame == target.frame { return finish(.success(restored: false)) }
        let before = historyFrame ?? target.frame
        frameHistory.record(before, for: target.key)
        if setFrame(frame,
                    targetRect: targetRect,
                    screenVisibleFrame: visible,
                    action: nil,
                    anchor: .edges(WindowCommandGeometry.edgeContact(for: rect, grid: grid)),
                    on: target.window,
                    windowKey: target.key) {
            noteSnapped(target.key, placed: frame, before: before)
            return finish(.success(restored: false))
        }
        frameHistory.discardLatest(for: target.key)
        return finish(.failure(.failed))
    }

    /// Remembers the size a window had before Window Layout first snapped
    /// it. Snapping it again from one area straight to another keeps that
    /// first size, so a drag away always goes back to the window's own size.
    private func noteSnapped(_ key: WindowLayoutWindowKey,
                             placed: WindowLayoutFrame,
                             before: WindowLayoutFrame) {
        let beforeRect = CGRect(origin: before.origin, size: before.size)
        let hadPlacedWindows = !snapRecords.isEmpty
        if let existing = snapRecords[key],
           WindowRestoreOnDrag.isStillSnapped(current: beforeRect,
                                              placed: CGRect(origin: existing.placed.origin,
                                                             size: existing.placed.size),
                                              tolerance: 24) {
            snapRecords[key] = WindowSnapRecord(placed: placed, originalSize: existing.originalSize)
        } else {
            snapRecords[key] = WindowSnapRecord(placed: placed, originalSize: before.size)
        }
        // The first placed window wakes the drag listener when only
        // restoring sizes needs it.
        if !hadPlacedWindows { syncDragTracking() }
    }

    private func target(forWindow window: AXUIElement,
                        capability: WindowLayoutTargetCapability) -> WindowLayoutTarget? {
        guard let candidate = candidate(forWindow: window), supports(capability, candidate) else { return nil }
        return candidate.target
    }

    /// One given window (the green-button menu's, the menu-bar menu's) as a
    /// candidate, nothing else considered.
    private func candidate(forWindow window: AXUIElement) -> WindowLayoutCandidate? {
        var pid = pid_t(0)
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              let onScreenWindowIDs = onScreenWindowIDs()
        else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.35)
        return candidate(from: window, app: app, onScreenWindowIDs: onScreenWindowIDs)
    }

    // MARK: Ignored apps

    var ignoredBundleIDs: [String] {
        WindowLayoutIgnoreList.sanitized(
            UserDefaults.standard.stringArray(forKey: DefaultsKey.windowLayoutIgnoredApps) ?? [])
    }

    func isIgnored(bundleID: String?) -> Bool {
        WindowLayoutIgnoreList.contains(bundleID, in: ignoredBundleIDs)
    }

    private func isIgnored(processID: pid_t) -> Bool {
        isIgnored(bundleID: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier)
    }

    func toggleIgnored(bundleID: String) {
        UserDefaults.standard.set(WindowLayoutIgnoreList.toggled(bundleID, in: ignoredBundleIDs),
                                  forKey: DefaultsKey.windowLayoutIgnoredApps)
    }

    // MARK: Menu state

    /// What the menus need to know about the window a command would act on,
    /// gathered once when a menu opens. The green-button menu passes the
    /// window whose button was hovered; the menu-bar menu takes the app in
    /// front and only that app's own window, never one from another app.
    /// A window in full screen still counts, so Full Screen can bring it back.
    func menuContext(window: AXUIElement? = nil) -> WindowCommandMenuContext {
        let screens = NSScreen.screens
        var resolved: WindowLayoutCandidate?
        if AXIsProcessTrusted() {
            let usable: (WindowLayoutCandidate) -> Bool = { candidate in
                self.supports(.position, candidate) || (candidate.isFullScreen && self.supports(.fullScreen, candidate))
            }
            if let window {
                resolved = candidate(forWindow: window).flatMap { usable($0) ? $0 : nil }
            } else {
                var found: WindowLayoutCandidate?
                _ = focusedTarget(frontAppOnly: true) { candidate in
                    guard usable(candidate) else { return .skip }
                    found = candidate
                    return .accept
                }
                resolved = found
            }
        }
        var capabilities: WindowCommandCapabilities = []
        if let resolved {
            if !resolved.isFullScreen {
                if canSetPosition(on: resolved.window) { capabilities.insert(.move) }
                if canSetSize(on: resolved.window) { capabilities.insert(.resize) }
            }
            if canSetFullScreen(on: resolved.window) { capabilities.insert(.fullScreen) }
        }
        // Without a window of its own, the app in front is offered for the
        // ignore list only when it is an ordinary app (not a system agent
        // such as a password prompt).
        let frontmost = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.activationPolicy == .regular ? $0 : nil
        }
        let app = resolved?.app ?? (window == nil ? frontmost : nil)
        let screen = resolved.flatMap { bestScreen(for: $0.frame, screens: screens) } ?? NSScreen.main
        let kind = WindowCommandSetKind.forDisplay(screen?.frame ?? .zero)
        var canRestore = false
        if let resolved {
            canRestore = frameHistory.peekPrevious(for: resolved.key, current: resolved.frame) != nil
        }
        let isOwnApp = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        return WindowCommandMenuContext(setKind: kind,
                                        appName: isOwnApp ? nil : app?.localizedName,
                                        bundleID: isOwnApp ? nil : app?.bundleIdentifier,
                                        isIgnored: isIgnored(bundleID: app?.bundleIdentifier),
                                        displayCount: screens.count,
                                        canRestore: canRestore,
                                        capabilities: capabilities,
                                        target: resolved?.target,
                                        screenFrame: screen?.frame,
                                        visibleFrame: screen?.visibleFrame)
    }

    /// Whether a command would change the window, for greyed menu items:
    /// the window has to allow what the command changes (an area needs it to
    /// resize, not only to move) and the result has to differ from now.
    func isAvailable(_ command: WindowCommand, in context: WindowCommandMenuContext) -> Bool {
        var current: CGRect?
        var targetFrame: CGRect?
        if let target = context.target, let screenFrame = context.screenFrame,
           let visibleFrame = context.visibleFrame {
            let rect = appKitFrame(fromAX: target.frame)
            current = rect
            switch command.kind {
            case .area, .maximize, .marginMaximize, .center:
                targetFrame = previewFrame(for: command, setKind: context.setKind, current: rect,
                                           key: target.key,
                                           screen: WindowActivationScreen(frame: screenFrame,
                                                                          visibleFrame: visibleFrame),
                                           displays: activationScreens(),
                                           windowGap: WindowLayoutGaps.windowGap,
                                           screenGap: WindowLayoutGaps.screenGap,
                                           screenTop: menuBarScreenTopY)
            default:
                break
            }
        }
        let availability = WindowCommandAvailability.Context(hasWindow: context.target != nil,
                                                             appIsIgnored: context.isIgnored,
                                                             displayCount: context.displayCount,
                                                             canRestore: context.canRestore,
                                                             currentFrame: current,
                                                             targetFrame: targetFrame,
                                                             capabilities: context.capabilities)
        return WindowCommandAvailability.isEnabled(command.kind, context: availability)
    }

    // MARK: - Shortcuts

    /// Hotkey ids of command shortcuts start here, clear of the ids the
    /// earlier per-action registration used.
    private static let commandHotKeyBase: UInt32 = 1_000

    private func registerHotkeys() {
        // Switched-off and cleared shortcuts are simply absent: their key
        // combo stays free for other apps (issue #169). Both sets share one
        // registration per combination.
        let shortcuts = WindowCommandShortcuts.registrations(for: commands)
        if !hotKeyRefs.isEmpty, shortcuts == registeredShortcuts { return }
        unregisterHotkeys()

        ensureHotKeyEventHandler()

        var failures = Set<GlobalShortcut>()
        for (slot, shortcut) in shortcuts.enumerated() {
            let id = EventHotKeyID(signature: 0x5655_574C, // 'VUWL'
                                   id: Self.commandHotKeyBase + UInt32(slot))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                             shortcut.carbonModifiers,
                                             id,
                                             GetEventDispatcherTarget(),
                                             0,
                                             &ref)
            if status == noErr, let ref {
                hotKeyRefs[slot] = ref
            } else {
                failures.insert(shortcut)
            }
        }
        registeredShortcuts = shortcuts
        failedShortcuts = failures
    }

    private func ensureHotKeyEventHandler() {
        if eventHandler == nil {
            var specs = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                if let event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
                }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userData).takeUnretainedValue()
                let kind = event.map(GetEventKind) ?? 0
                if id.signature == 0x5655_5744 { // 'VUWD'
                    DispatchQueue.main.async {
                        kind == UInt32(kEventHotKeyPressed)
                            ? service.beginDirectionalGesture()
                            : service.finishDirectionalGesture()
                    }
                    return noErr
                }
                guard id.signature == 0x5655_574C,
                      kind == UInt32(kEventHotKeyPressed),
                      id.id >= WindowLayoutService.commandHotKeyBase else {
                    return OSStatus(eventNotHandledErr)
                }
                let slot = Int(id.id - WindowLayoutService.commandHotKeyBase)
                DispatchQueue.main.async { service.runShortcut(slot: slot) }
                return noErr
            }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        }
    }

    /// Lets go of the layout keys while a shortcut field is listening, so the
    /// user can record a combination the layout actions already use. The
    /// gesture tap is left alone: it watches the mouse, not the keyboard. The
    /// next `syncWithPreferences` takes the keys back.
    func suspendShortcuts() { unregisterHotkeys() }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        registeredShortcuts.removeAll()
        failedShortcuts.removeAll()
    }

    private func registerDirectionalHotkey() {
        guard let shortcut = UserDefaults.standard.string(forKey: DefaultsKey.windowDirectionalShortcut)
            .flatMap(GlobalShortcut.init(storageValue:)) else {
            directionalShortcutRegistrationFailed = true
            return
        }
        if directionalHotKeyRef != nil, registeredDirectionalShortcut == shortcut { return }
        unregisterDirectionalHotkey()
        ensureHotKeyEventHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5655_5744, id: 56)
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers, id,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            directionalHotKeyRef = ref
            registeredDirectionalShortcut = shortcut
            directionalShortcutRegistrationFailed = false
        } else {
            directionalShortcutRegistrationFailed = true
        }
    }

    private func unregisterDirectionalHotkey() {
        if let directionalHotKeyRef { UnregisterEventHotKey(directionalHotKeyRef) }
        directionalHotKeyRef = nil
        registeredDirectionalShortcut = nil
        directionalShortcutRegistrationFailed = false
        cancelDirectionalGesture()
    }

    private func beginDirectionalGesture() {
        guard directionalSession == nil,
              let target = focusedTarget(for: .leftHalf),
              // Ignored apps are left alone here too.
              !isIgnored(processID: target.key.processID),
              let screen = bestScreen(for: target.frame) else { return }
        directionalSession = WindowDirectionalSession(target: target,
                                                      visibleFrame: screen.visibleFrame,
                                                      pointerOrigin: NSEvent.mouseLocation,
                                                      action: nil,
                                                      manualOverride: nil)
        showDirectionalIndicator(at: NSEvent.mouseLocation, action: nil)
        directionalTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.updateDirectionalGesture()
        }
        startDirectionalTap()
    }

    private func startDirectionalTap() {
        guard directionalTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.observeDirectionalEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        directionalTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        directionalTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func observeDirectionalEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var session = directionalSession else { return Unmanaged.passUnretained(event) }

        if type == .scrollWheel {
            let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedDeltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let scrollY = deltaY != 0 ? deltaY : Double(fixedDeltaY)

            if scrollY > 0.5 {
                session.manualOverride = .maximize
                directionalSession = session
                updateDirectionalIndicator(action: .maximize)
                let preview = placement(for: .maximize, current: session.target.frame,
                                        visibleFrame: session.visibleFrame).rect
                showEdgeSnapPreview(frame: preview)
            } else if scrollY < -0.5 {
                session.manualOverride = .minimize
                directionalSession = session
                updateDirectionalIndicator(action: .minimize)
                hideEdgeSnapPreview(immediately: true)
            }
            return nil
        }

        if type == .leftMouseDown {
            session.manualOverride = .maximize
            directionalSession = session
            updateDirectionalIndicator(action: .maximize)
            let preview = placement(for: .maximize, current: session.target.frame,
                                    visibleFrame: session.visibleFrame).rect
            showEdgeSnapPreview(frame: preview)
            return nil
        }

        if type == .rightMouseDown {
            session.manualOverride = .minimize
            directionalSession = session
            updateDirectionalIndicator(action: .minimize)
            hideEdgeSnapPreview(immediately: true)
            return nil
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 || keyCode == 36 || keyCode == 126 { // Space, Return, Up
                session.manualOverride = .maximize
                directionalSession = session
                updateDirectionalIndicator(action: .maximize)
                let preview = placement(for: .maximize, current: session.target.frame,
                                        visibleFrame: session.visibleFrame).rect
                showEdgeSnapPreview(frame: preview)
                return nil
            } else if keyCode == 46 || keyCode == 125 { // M, Down
                session.manualOverride = .minimize
                directionalSession = session
                updateDirectionalIndicator(action: .minimize)
                hideEdgeSnapPreview(immediately: true)
                return nil
            } else if keyCode == 53 { // Escape
                cancelDirectionalGesture()
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func updateDirectionalGesture() {
        guard var session = directionalSession else { return }
        let currentMouse = NSEvent.mouseLocation
        let distance = hypot(currentMouse.x - session.pointerOrigin.x,
                             currentMouse.y - session.pointerOrigin.y)

        let directionalAction = WindowDirectionalGestureSupport.action(
            from: session.pointerOrigin,
            to: currentMouse
        )

        if distance >= WindowDirectionalGestureSupport.activationDistance {
            session.manualOverride = nil
        }

        let action = session.manualOverride ?? directionalAction
        guard action != session.action else { return }

        session.action = action
        directionalSession = session
        updateDirectionalIndicator(action: action)

        guard let action else {
            hideEdgeSnapPreview(immediately: false)
            return
        }

        if let layoutAction = action.layoutAction {
            let preview = placement(for: layoutAction, current: session.target.frame,
                                    visibleFrame: session.visibleFrame).rect
            showEdgeSnapPreview(frame: preview)
        } else {
            hideEdgeSnapPreview(immediately: true)
        }
    }

    private func finishDirectionalGesture() {
        stopDirectionalTap()
        guard let session = directionalSession else { return }
        directionalTimer?.invalidate()
        directionalTimer = nil
        directionalSession = nil
        hideEdgeSnapPreview(immediately: true)
        hideDirectionalIndicator()

        guard let action = session.action else { return }
        if let layoutAction = action.layoutAction {
            _ = applyPlacement(layoutAction, to: session.target, visibleFrame: session.visibleFrame,
                               cyclesRepeatedAction: false)
        } else if action == .minimize {
            _ = minimize(target: session.target)
        }
    }

    private func cancelDirectionalGesture() {
        stopDirectionalTap()
        directionalTimer?.invalidate()
        directionalTimer = nil
        directionalSession = nil
        hideEdgeSnapPreview(immediately: true)
        hideDirectionalIndicator()
    }

    private func stopDirectionalTap() {
        if let directionalTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), directionalTapSource, .commonModes)
        }
        directionalTapSource = nil
        if let directionalTap {
            CGEvent.tapEnable(tap: directionalTap, enable: false)
            CFMachPortInvalidate(directionalTap)
        }
        directionalTap = nil
    }

    @discardableResult
    private func minimize(target: WindowLayoutTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let status = AXUIElementSetAttributeValue(target.window,
                                                  kAXMinimizedAttribute as CFString,
                                                  kCFBooleanTrue)
        return status == .success
    }

    private func showDirectionalIndicator(at pointer: CGPoint, action: WindowDirectionalAction?) {
        let size = CGSize(width: 180, height: 180)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)
        let panel: NSPanel
        if let directionalIndicatorPanel {
            panel = directionalIndicatorPanel
        } else {
            panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                        .transient, .ignoresCycle]
            panel.animationBehavior = .none
            panel.contentView = WindowDirectionalIndicatorView(frame: CGRect(origin: .zero, size: size))
            directionalIndicatorPanel = panel
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        updateDirectionalIndicator(action: action)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func updateDirectionalIndicator(action: WindowDirectionalAction?) {
        guard let view = directionalIndicatorPanel?.contentView as? WindowDirectionalIndicatorView else { return }
        view.action = action
    }

    private func hideDirectionalIndicator() {
        directionalIndicatorPanel?.orderOut(nil)
    }

    // MARK: - Drag to screen edge

    /// The callback copies scalar values and gets out of the input path before
    /// any Accessibility or UI work. It only adjusts the exact top coordinate
    /// after a window move has already been confirmed on the main queue.
    private func startEdgeSnapTap() {
        guard edgeSnapTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.observeEdgeSnapEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        edgeSnapTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        edgeSnapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEdgeSnapTap() {
        edgeSnapSequenceGeneration += 1
        edgeSnapPressOrigin = nil
        edgeSnapPressCandidate = nil
        edgeSnapPressPlaces = false
        edgeSnapSequenceSuppressed = false
        edgeSnapResolveAttempts = 0
        edgeSnapDrag = nil
        hideEdgeSnapPreview(immediately: true)
        WindowLayoutOverlays.shared.endDrag()
        if let edgeSnapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), edgeSnapRunLoopSource, .commonModes)
        }
        if let edgeSnapTap {
            CGEvent.tapEnable(tap: edgeSnapTap, enable: false)
            CFMachPortInvalidate(edgeSnapTap)
        }
        edgeSnapTap = nil
        edgeSnapRunLoopSource = nil
        edgeSnapPreviewPanel = nil
    }

    private func observeEdgeSnapEvent(type: CGEventType,
                                      event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if SessionActivity.shared.isActive, AXIsProcessTrusted(), let edgeSnapTap {
                CGEvent.tapEnable(tap: edgeSnapTap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.syncWithPreferences() }
            }
            DispatchQueue.main.async { [weak self] in self?.cancelEdgeSnapTracking() }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownProcessID
        else { return Unmanaged.passUnretained(event) }

        if type == .leftMouseDown {
            // The system's own tiling owns drops. Giving a placed window its
            // size back never drops anything, so it keeps running beside it.
            edgeSnapSequenceSuppressed = !dragTracking.restoresSize && WindowEdgeSnapSupport.isSystemTilingEnabled
        } else if edgeSnapSequenceSuppressed {
            if type == .leftMouseUp { edgeSnapSequenceSuppressed = false }
            return Unmanaged.passUnretained(event)
        }
        guard !edgeSnapSequenceSuppressed else { return Unmanaged.passUnretained(event) }

        let input: WindowEdgeSnapPointerInput
        switch type {
        case .leftMouseDown:
            input = .down(location: event.location, flags: event.flags)
        case .leftMouseDragged:
            let originalLocation = event.location
            input = .dragged(location: originalLocation)
            if let drag = edgeSnapDrag,
               drag.isMoving,
               drag.protectsSystemTopEdge {
                event.location = WindowEdgeSnapSupport.locationAvoidingSystemTopDrag(
                    originalLocation,
                    screenFrames: drag.quartzScreenFrames,
                    enabledZones: drag.enabledZones
                )
            }
        case .leftMouseUp:
            input = .up(location: event.location)
        default:
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { [weak self] in self?.handleEdgeSnapInput(input) }
        return Unmanaged.passUnretained(event)
    }

    private func handleEdgeSnapInput(_ input: WindowEdgeSnapPointerInput) {
        switch input {
        case .down(let location, let flags):
            cancelEdgeSnapTracking()
            edgeSnapSequenceSuppressed = false
            // Decided afresh on every press: the switches, the system's own
            // tiling and the placed windows can all change between drags.
            let tracking = resolveDragTracking()
            dragTracking = tracking
            guard tracking.listens else {
                edgeSnapSequenceSuppressed = true
                syncDragTracking()
                return
            }
            guard !edgeSnapConflictsWithWindowGesture(flags: flags) else {
                edgeSnapSequenceSuppressed = true
                return
            }
            let ignored = ignoredBundleIDs
            guard let candidate = WindowServerWindowHitTest.candidate(at: location, pidIsEligible: {
                guard let app = NSRunningApplication(processIdentifier: $0) else { return false }
                return !app.isTerminated && app.activationPolicy == .regular
                    && !WindowLayoutIgnoreList.contains(app.bundleIdentifier, in: ignored)
            }),
            !WindowEdgeSnapSupport.startsAtResizeHandle(location, frame: candidate.frame),
            // With nothing to drop, only a window Window Layout placed is
            // worth following; every other press is left alone at once.
            tracking.tracksPress(onPlacedWindow: isPlacedWindow(pid: candidate.pid, windowID: candidate.windowID))
            else {
                edgeSnapSequenceSuppressed = true
                return
            }
            edgeSnapPressOrigin = location
            edgeSnapPressCandidate = candidate
            edgeSnapPressPlaces = tracking.placesOnDrop
            edgeSnapResolveAttempts = 0
            edgeSnapLastResolveAt = 0

        case .dragged(let location):
            guard let pressOrigin = edgeSnapPressOrigin,
                  let pressCandidate = edgeSnapPressCandidate,
                  activeGesture == nil, pendingGesture == nil
            else {
                cancelEdgeSnapTracking()
                return
            }
            if edgeSnapDrag == nil,
               WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location) {
                let now = ProcessInfo.processInfo.systemUptime
                if edgeSnapResolveAttempts < 4, now - edgeSnapLastResolveAt >= 0.08 {
                    edgeSnapResolveAttempts += 1
                    edgeSnapLastResolveAt = now
                    edgeSnapDrag = makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                    pressCandidate: pressCandidate,
                                                    places: edgeSnapPressPlaces)
                }
            }
            updateEdgeSnapDrag(at: location, forceSample: false)

        case .up(let location):
            let pressOrigin = edgeSnapPressOrigin
            let pressCandidate = edgeSnapPressCandidate
            let places = edgeSnapPressPlaces
            if edgeSnapDrag == nil,
               let pressOrigin, let pressCandidate,
               WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location) {
                edgeSnapDrag = makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                pressCandidate: pressCandidate,
                                                places: places)
            }
            updateEdgeSnapDrag(at: location, forceSample: true)
            let completed = edgeSnapDrag
            edgeSnapPressOrigin = nil
            edgeSnapPressCandidate = nil
            edgeSnapPressPlaces = false
            edgeSnapResolveAttempts = 0
            edgeSnapDrag = nil
            hideEdgeSnapPreview(immediately: false)
            WindowLayoutOverlays.shared.endDrag()
            // A drag that gave the last placed window its size back may
            // leave the listener with nothing to do.
            syncDragTracking()
            // Restoring alone never places anything on release.
            guard places else { return }
            let generation = edgeSnapSequenceGeneration
            guard let completed else {
                guard let pressOrigin, let pressCandidate,
                      WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, generation == self.edgeSnapSequenceGeneration,
                          let delayed = self.makeEdgeSnapDrag(pointerStart: pressOrigin,
                                                              pressCandidate: pressCandidate,
                                                              places: true)
                    else { return }
                    self.applyDelayedEdgeSnapIfMoved(delayed, releaseLocation: location)
                }
                return
            }
            if !completed.isMoving {
                guard let pressOrigin,
                      WindowGestureSupport.exceedsDragSlop(from: pressOrigin, to: location)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, generation == self.edgeSnapSequenceGeneration else { return }
                    self.applyDelayedEdgeSnapIfMoved(completed, releaseLocation: location)
                }
                return
            }
            guard let target = completed.target else { return }
            // The callback has already forwarded this mouse-up. One
            // more main-loop turn lets the target app finish its own drag
            // before the placement writes the final frame.
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.edgeSnapSequenceGeneration else { return }
                self.applyEdgeSnap(completed, target: target)
            }
        }
    }

    /// Whether Window Layout placed this window and still remembers its
    /// earlier size.
    private func isPlacedWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        snapRecords.keys.contains { $0.processID == pid && $0.windowID == windowID }
    }

    private func applyDelayedEdgeSnapIfMoved(_ drag: WindowEdgeSnapDrag,
                                             releaseLocation: CGPoint) {
        guard drag.places,
              let current = frame(of: drag.window),
              WindowEdgeSnapSupport.classify(
                initialFrame: drag.initialFrame,
                currentFrame: CGRect(origin: current.origin, size: current.size),
                pointerStart: drag.pointerStart,
                pointerNow: releaseLocation
              ) == .moving
        else { return }
        let context = drag.context ?? makeDragContext()
        guard let found = dragMatch(atQuartzPoint: releaseLocation, context: context),
              let target = dragTarget(for: found.match, command: found.command, setKind: found.kind,
                                      drag: drag, context: context)
        else { return }
        applyEdgeSnap(drag, target: target)
    }

    private func edgeSnapConflictsWithWindowGesture(flags: CGEventFlags) -> Bool {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureEnabled) else { return false }
        let move = WindowGestureSupport.modifiers(
            from: UserDefaults.standard.string(forKey: DefaultsKey.windowGestureModifiers)
        )
        return WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: move)
            || WindowGestureSupport.modifiersMatch(
                eventFlags: flags,
                expected: WindowGestureSupport.resizeModifiers(from: move)
            )
    }

    /// `places` is false when the drag is only followed to give a placed
    /// window its size back: then nothing about the pointer events changes
    /// and nothing is previewed.
    private func makeEdgeSnapDrag(pointerStart: CGPoint,
                                  pressCandidate: WindowServerWindowCandidate,
                                  places: Bool) -> WindowEdgeSnapDrag? {
        guard let app = NSRunningApplication(processIdentifier: pressCandidate.pid),
              !app.isTerminated, app.activationPolicy == .regular else { return nil }
        let axApp = AXUIElementCreateApplication(pressCandidate.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let window = windowsAttribute(axApp)?.first(where: {
                  AXWindowResolver.windowID(for: $0) == pressCandidate.windowID
              }) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard let onScreenWindowIDs = onScreenWindowIDs(),
              let target = target(from: window,
                                  app: app,
                                  onScreenWindowIDs: onScreenWindowIDs,
                                  capability: .frame) else { return nil }
        return WindowEdgeSnapDrag(window: target.window,
                                  key: target.key,
                                  initialFrame: pressCandidate.frame,
                                  pointerStart: pointerStart,
                                  places: places,
                                  protectsSystemTopEdge: places
                                      && WindowEdgeSnapSupport.isSystemTopWindowOverviewDragEnabled,
                                  quartzScreenFrames: places ? edgeSnapQuartzScreenFrames() : [],
                                  enabledZones: places ? WindowActivationHitTest.coveredLegacyZones(commands) : [],
                                  lastSampleAt: 0,
                                  mismatchCount: 0,
                                  isMoving: false,
                                  target: nil,
                                  restoredFrame: nil,
                                  context: nil,
                                  lastMatch: nil)
    }

    /// Follows a confirmed window drag. Every step is sampled at the same
    /// 30 Hz as the move check (a release always samples), the drop areas
    /// are hit-tested against displays and settings read once per drag, and
    /// the dragged window's frame is read through Accessibility only when
    /// the area under the pointer changes to one whose preview depends on it.
    private func updateEdgeSnapDrag(at location: CGPoint, forceSample: Bool) {
        guard var drag = edgeSnapDrag else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard forceSample || now - drag.lastSampleAt >= edgeSnapSampleInterval else { return }
        drag.lastSampleAt = now
        if !drag.isMoving {
            guard let current = frame(of: drag.window) else {
                cancelEdgeSnapTracking()
                return
            }
            let currentFrame = CGRect(origin: current.origin, size: current.size)
            switch WindowEdgeSnapSupport.classify(initialFrame: drag.initialFrame,
                                                  currentFrame: currentFrame,
                                                  pointerStart: drag.pointerStart,
                                                  pointerNow: location) {
            case .waiting:
                edgeSnapDrag = drag
                return
            case .moving:
                drag.isMoving = true
                drag.mismatchCount = 0
                if dragTracking.restoresSize {
                    restoreSizeIfSnapped(&drag, pointer: location)
                }
                guard drag.places else {
                    // Nothing to drop: the size is back, and the rest of this
                    // press goes by untouched.
                    cancelEdgeSnapTracking()
                    syncDragTracking()
                    return
                }
                let context = makeDragContext()
                drag.context = context
                WindowLayoutOverlays.shared.beginDrag(screens: context.screens,
                                                      commands: context.configuration,
                                                      settings: context.settings)
            case .resizing:
                cancelEdgeSnapTracking()
                return
            case .unrelated:
                drag.mismatchCount += 1
                if drag.mismatchCount >= 3 {
                    cancelEdgeSnapTracking()
                } else {
                    edgeSnapDrag = drag
                }
                return
            }
        }
        updateDragTarget(&drag, at: location)
        edgeSnapDrag = drag
    }

    /// Hit-tests first, with no Accessibility at all; works out a new
    /// preview only when the area under the pointer changed or its preview
    /// follows the window.
    private func updateDragTarget(_ drag: inout WindowEdgeSnapDrag, at location: CGPoint) {
        guard let context = drag.context else { return }
        let found = dragMatch(atQuartzPoint: location, context: context)
        let followsWindow = found?.command.kind.previewFollowsWindow ?? false
        if found?.match == drag.lastMatch, !followsWindow { return }
        drag.lastMatch = found?.match
        let target = found.flatMap {
            dragTarget(for: $0.match, command: $0.command, setKind: $0.kind, drag: drag, context: context)
        }
        guard target != drag.target else { return }
        drag.target = target
        WindowLayoutOverlays.shared.highlight(commandID: target?.commandID)
        if let target {
            showEdgeSnapPreview(frame: target.previewFrame)
        } else {
            hideEdgeSnapPreview(immediately: false)
        }
    }

    // MARK: - Command drag areas

    private var activationSettings: WindowActivationSettings {
        let defaults = UserDefaults.standard
        return WindowActivationSettings(
            edgeWidth: CGFloat(WindowActivationSettings.sanitizedEdgeWidth(
                defaults.integer(forKey: DefaultsKey.windowLayoutEdgeAreaWidth))),
            interiorScale: CGFloat(WindowActivationSettings.sanitizedInteriorScale(
                defaults.integer(forKey: DefaultsKey.windowLayoutInteriorAreaScale))) / 100)
    }

    private func activationScreens() -> [WindowActivationScreen] {
        NSScreen.screens.map { WindowActivationScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// Everything a drag reads more than once, read once when the window is
    /// confirmed moving: the displays, the area settings, the command sets
    /// and the margins.
    private func makeDragContext() -> WindowDragContext {
        WindowDragContext(screens: activationScreens(),
                          settings: activationSettings,
                          configuration: commands,
                          windowGap: WindowLayoutGaps.windowGap,
                          screenGap: WindowLayoutGaps.screenGap,
                          menuBarTop: menuBarScreenTopY)
    }

    /// The live drag area under a pointer (Quartz coordinates), if any.
    private func dragMatch(atQuartzPoint point: CGPoint,
                           context: WindowDragContext) -> (match: WindowActivationHitTest.Match,
                                                           command: WindowCommand,
                                                           kind: WindowCommandSetKind)? {
        let appKitPoint = CGPoint(x: point.x, y: context.menuBarTop - point.y)
        let configuration = context.configuration
        guard let match = WindowActivationHitTest.match(at: appKitPoint,
                                                        screens: context.screens,
                                                        commands: { configuration[$0] },
                                                        settings: context.settings),
              context.screens.indices.contains(match.screenIndex),
              let found = configuration.command(id: match.commandID)
        else { return nil }
        return (match, found.command, found.kind)
    }

    /// The command a dragged window would take if released over `match`,
    /// with the frame it would get.
    private func dragTarget(for match: WindowActivationHitTest.Match,
                            command: WindowCommand,
                            setKind: WindowCommandSetKind,
                            drag: WindowEdgeSnapDrag,
                            context: WindowDragContext) -> WindowCommandDragTarget? {
        let screen = context.screens[match.screenIndex]
        // Only a preview that follows the window asks Accessibility for its
        // frame; every other one is the same wherever the window is.
        let axCurrent = command.kind.previewFollowsWindow ? frame(of: drag.window) : nil
        let current = appKitFrame(fromAX: axCurrent ?? WindowLayoutFrame(origin: drag.initialFrame.origin,
                                                                         size: drag.initialFrame.size),
                                  screenTop: context.menuBarTop)
        guard let preview = previewFrame(for: command,
                                         setKind: setKind,
                                         current: current,
                                         key: drag.key,
                                         screen: screen,
                                         displays: context.screens,
                                         windowGap: context.windowGap,
                                         screenGap: context.screenGap,
                                         screenTop: context.menuBarTop)
        else { return nil }
        return WindowCommandDragTarget(commandID: command.id,
                                       setKind: setKind,
                                       previewFrame: preview.integral,
                                       visibleFrame: screen.visibleFrame)
    }

    /// Where a command would put a window, in AppKit coordinates: the drag
    /// preview, and the "nothing would change" check of the menus.
    private func previewFrame(for command: WindowCommand,
                              setKind: WindowCommandSetKind,
                              current: NSRect,
                              key: WindowLayoutWindowKey?,
                              screen: WindowActivationScreen,
                              displays: [WindowActivationScreen],
                              windowGap: CGFloat,
                              screenGap: CGFloat,
                              screenTop: CGFloat) -> NSRect? {
        if let builtin = placementAction(for: command, grid: setKind.grid) {
            switch builtin {
            case .restore:
                guard let key,
                      let previous = frameHistory.peekPrevious(for: key,
                                                               current: axFrame(fromAppKit: current,
                                                                                screenTop: screenTop))
                else { return nil }
                return appKitFrame(fromAX: previous, screenTop: screenTop)
            case .fullScreen:
                return screen.frame
            case .nextDisplay, .previousDisplay:
                guard let sourceIndex = displays.firstIndex(where: { $0.frame == screen.frame }),
                      let destinationIndex = WindowLayoutGeometry.adjacentDisplayIndex(
                        currentIndex: sourceIndex,
                        frames: displays.map(\.frame),
                        movingForward: builtin == .nextDisplay)
                else { return nil }
                return WindowLayoutGeometry.rectForDisplay(current: current,
                                                           sourceVisibleFrame: screen.visibleFrame,
                                                           destinationVisibleFrame: displays[destinationIndex].visibleFrame)
            default:
                return WindowLayoutGeometry.rect(for: builtin, current: current, visibleFrame: screen.visibleFrame,
                                                 windowGap: windowGap, screenGap: screenGap)
            }
        }
        guard case .area(let rect) = command.kind else { return nil }
        return WindowCommandGeometry.frame(for: rect, grid: setKind.grid, visibleFrame: screen.visibleFrame,
                                           windowGap: windowGap, screenGap: screenGap)
    }

    private func edgeSnapQuartzScreenFrames() -> [CGRect] {
        let top = menuBarScreenTopY
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX,
                   y: top - $0.frame.maxY,
                   width: $0.frame.width,
                   height: $0.frame.height)
        }
    }

    private func applyEdgeSnap(_ drag: WindowEdgeSnapDrag,
                               target: WindowCommandDragTarget) {
        guard drag.places,
              AppFeature.windowLayout.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.windowEdgeSnapEnabled),
              let command = commands.command(id: target.commandID)?.command,
              command.effectiveActivation != nil,
              !WindowEdgeSnapSupport.isSystemTilingEnabled,
              AXIsProcessTrusted(),
              canSetFrame(on: drag.window),
              AXWindowResolver.windowID(for: drag.window) == drag.key.windowID,
              let currentFrame = frame(of: drag.window)
        else { return }
        var processID = pid_t(0)
        guard AXUIElementGetPid(drag.window, &processID) == .success,
              processID == drag.key.processID else { return }

        let layoutTarget = WindowLayoutTarget(window: drag.window,
                                              key: drag.key,
                                              frame: currentFrame)
        // Restore goes back to where the window was before this drag; a
        // window that got its earlier size back mid-drag starts from that.
        let start = drag.restoredFrame ?? drag.initialFrame
        let history = WindowLayoutFrame(origin: start.origin, size: start.size)
        _ = apply(command,
                  setKind: target.setKind,
                  to: layoutTarget,
                  dropVisibleFrame: target.visibleFrame,
                  historyFrame: history,
                  origin: .drop)
    }

    /// Gives a window Window Layout placed (by a shortcut, a menu, a picker
    /// or a drag) its earlier size back as soon as a drag takes it out of
    /// that placement, keeping the pointer on the same spot of the title
    /// bar. Works with drag snapping off.
    private func restoreSizeIfSnapped(_ drag: inout WindowEdgeSnapDrag, pointer: CGPoint) {
        guard drag.restoredFrame == nil,
              UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutRestoreSizeOnDrag),
              let record = snapRecords[drag.key],
              WindowRestoreOnDrag.isStillSnapped(current: drag.initialFrame,
                                                 placed: CGRect(origin: record.placed.origin,
                                                                size: record.placed.size),
                                                 tolerance: 24),
              abs(record.originalSize.width - drag.initialFrame.width) > 1
                || abs(record.originalSize.height - drag.initialFrame.height) > 1
        else { return }
        let restored = WindowRestoreOnDrag.restoredFrame(snapped: drag.initialFrame,
                                                         originalSize: record.originalSize,
                                                         pointerStart: drag.pointerStart,
                                                         pointerNow: pointer)
        // Size first: shrinking at the old origin keeps the whole window on
        // screen for the one frame before the position follows.
        _ = setSize(restored.size, on: drag.window)
        _ = setPosition(restored.origin, on: drag.window)
        drag.restoredFrame = restored
        snapRecords.removeValue(forKey: drag.key)
    }

    private func cancelEdgeSnapTracking() {
        edgeSnapSequenceGeneration += 1
        edgeSnapPressOrigin = nil
        edgeSnapPressCandidate = nil
        edgeSnapPressPlaces = false
        edgeSnapSequenceSuppressed = true
        edgeSnapResolveAttempts = 0
        edgeSnapDrag = nil
        hideEdgeSnapPreview(immediately: false)
        WindowLayoutOverlays.shared.endDrag()
    }

    private func showEdgeSnapPreview(frame: CGRect) {
        edgeSnapPreviewGeneration += 1
        let panel: NSPanel
        if let existing = edgeSnapPreviewPanel {
            panel = existing
        } else {
            panel = makeEdgeSnapPreviewPanel()
            edgeSnapPreviewPanel = panel
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            (panel.contentView as? WindowEdgeSnapPreviewView)?.updateAppearance()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideEdgeSnapPreview(immediately: Bool) {
        guard let panel = edgeSnapPreviewPanel, panel.isVisible else { return }
        edgeSnapPreviewGeneration += 1
        let generation = edgeSnapPreviewGeneration
        if immediately {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel,
                  generation == self.edgeSnapPreviewGeneration else { return }
            panel.orderOut(nil)
        }
    }

    private func makeEdgeSnapPreviewPanel() -> NSPanel {
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = WindowEdgeSnapPreviewView(frame: .zero)
        return panel
    }

    // MARK: - Move and resize gesture

    private func startGestureTap() {
        guard gestureTap == nil else {
            isGestureRunning = true
            return
        }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handleGestureEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isGestureRunning = false
            return
        }

        gestureTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        gestureRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isGestureRunning = true
    }

    private func stopGestureTap() {
        // A press still under custody has to go back to the app before the
        // tap that is holding it disappears, or that click is simply lost.
        flushPending(proxy: nil, at: nil)
        if let gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
            CFMachPortInvalidate(gestureTap)
        }
        gestureTap = nil
        gestureRunLoopSource = nil
        activeGesture = nil
        pendingGesture = nil
        endGestureAssistiveMode()
        isGestureRunning = false
    }

    private var gestureState: WindowGestureState {
        if activeGesture != nil { return .active }
        if pendingGesture != nil { return .pending }
        return .idle
    }

    private var trackedGestureButton: WindowPointerGesture.Button? {
        activeGesture?.button ?? pendingGesture?.button
    }

    /// Whether the button that started the press is still down. Only worth
    /// asking when the tap was switched off, because that is the one moment
    /// the release can reach the app without passing through here.
    private func isTrackedButtonDown() -> Bool {
        guard let button = trackedGestureButton else { return false }
        return CGEventSource.buttonState(.combinedSessionState,
                                         button: button == .primary ? .left : .right)
    }

    /// A press that carries the chord is held back, not taken: the app only
    /// loses it once the pointer moves far enough to mean a window gesture.
    /// A press that ends where it started is handed straight back, so an
    /// ordinary modifier click keeps working in every app.
    private func handleGestureEvent(proxy: CGEventTapProxy?,
                                    type: CGEventType,
                                    event: CGEvent) -> Unmanaged<CGEvent>? {
        // The press this service gave back to the system. Looking at it again
        // would take it right back and never let go.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownProcessID {
            return Unmanaged.passUnretained(event)
        }

        let tapDisabled = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
        if tapDisabled, let gestureTap {
            if SessionActivity.shared.isActive, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: gestureTap, enable: true)
            } else {
                DispatchQueue.main.async { [weak self] in self?.syncWithPreferences() }
            }
        }

        var chord: (button: WindowPointerGesture.Button, wantsResize: Bool)?
        let input: WindowGestureInput
        if tapDisabled {
            input = .tapDisabled(buttonStillDown: isTrackedButtonDown())
        } else if !AXIsProcessTrusted() {
            // Never enter Accessibility from a live tap after the grant is
            // revoked. A blocked AX call here would stall system input.
            input = .accessibilityLost
        } else {
            switch type {
            case .leftMouseDown, .rightMouseDown:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseDown ? .primary : .secondary
                chord = gestureChord(type: type, flags: event.flags)
                input = .buttonDown(sameButton: button == trackedGestureButton,
                                    chordMatched: chord != nil)
            case .leftMouseDragged, .rightMouseDragged:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseDragged ? .primary : .secondary
                let pastSlop = pendingGesture.map {
                    WindowGestureSupport.exceedsDragSlop(from: $0.origin, to: event.location)
                } ?? false
                input = .buttonDragged(tracked: button == trackedGestureButton, pastSlop: pastSlop)
            case .leftMouseUp, .rightMouseUp:
                let button: WindowPointerGesture.Button =
                    type == .leftMouseUp ? .primary : .secondary
                input = .buttonUp(tracked: button == trackedGestureButton)
            default:
                input = .otherEvent
            }
        }

        var decision = WindowGestureSupport.decide(state: gestureState, input: input)
        switch decision {
        case .restartAsIdle:
            pendingGesture = nil
            decision = WindowGestureSupport.decide(state: .idle, input: input)
        case .flushThenRestart:
            flushPending(proxy: proxy, at: event.location)
            decision = WindowGestureSupport.decide(state: .idle, input: input)
        default:
            break
        }

        switch decision {
        case .passThrough, .restartAsIdle, .flushThenRestart:
            return Unmanaged.passUnretained(event)

        case .hold:
            return nil

        case .arm:
            guard let chord else { return Unmanaged.passUnretained(event) }
            return arm(chord: chord, event: event)

        case .promote:
            guard let pending = pendingGesture else { return nil }
            promote(pending, pointer: event.location)
            return nil

        case .applyMove:
            guard var gesture = activeGesture else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            let updateInterval: TimeInterval
            switch gesture.kind {
            case .move:
                updateInterval = moveGestureUpdateInterval
            case .resize:
                updateInterval = resizeGestureUpdateInterval
            }
            if now - gesture.lastAppliedAt >= updateInterval {
                apply(gesture, pointer: event.location)
                gesture.lastAppliedAt = now
                activeGesture = gesture
            }
            return nil

        case .applyFinish:
            if let gesture = activeGesture {
                apply(gesture, pointer: event.location)
            }
            activeGesture = nil
            endGestureAssistiveMode()
            return nil

        case .replayThenPass:
            // The held press goes back first and this release closes the pair,
            // so the app sees one ordinary click and never half of one.
            flushPending(proxy: proxy, at: event.location)
            return Unmanaged.passUnretained(event)

        case .flushThenPass:
            // A disabled tap carries no position, and its proxy is no longer a
            // dependable way back into the stream.
            flushPending(proxy: tapDisabled ? nil : proxy,
                         at: tapDisabled ? nil : event.location)
            return Unmanaged.passUnretained(event)

        case .dropState:
            activeGesture = nil
            pendingGesture = nil
            endGestureAssistiveMode()
            return Unmanaged.passUnretained(event)
        }
    }

    private func endGestureAssistiveMode() {
        let suspension = gestureAssistiveMode
        gestureAssistiveMode = nil
        // With the grant revoked there is no safe way to touch the app again;
        // the flag comes back when the assistive client sets it.
        guard AXIsProcessTrusted() else { return }
        suspension?.resume()
    }

    private func gestureChord(type: CGEventType,
                              flags: CGEventFlags) -> (button: WindowPointerGesture.Button,
                                                       wantsResize: Bool)? {
        let moveModifiers = WindowGestureSupport.modifiers(
            from: UserDefaults.standard.string(forKey: DefaultsKey.windowGestureModifiers)
        )
        let resizeModifiers = WindowGestureSupport.resizeModifiers(from: moveModifiers)
        if type == .leftMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: moveModifiers) {
            return (.primary, false)
        }
        if type == .leftMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: resizeModifiers) {
            return (.primary, true)
        }
        if type == .rightMouseDown,
           WindowGestureSupport.modifiersMatch(eventFlags: flags, expected: moveModifiers) {
            return (.secondary, true)
        }
        return nil
    }

    /// Takes custody of a press that matches the chord over a window this
    /// service can actually move. Anything it cannot move keeps its click.
    private func arm(chord: (button: WindowPointerGesture.Button, wantsResize: Bool),
                     event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let target = gestureTarget(at: event.location,
                                         requiresResize: chord.wantsResize)
        else { return Unmanaged.passUnretained(event) }

        let resolvedKind: WindowPointerGesture.Kind
        if chord.wantsResize {
            let frame = CGRect(origin: target.frame.origin, size: target.frame.size)
            let edges = WindowGestureSupport.resizeEdges(at: event.location, in: frame)
            guard !edges.isEmpty else { return Unmanaged.passUnretained(event) }
            resolvedKind = .resize(edges)
        } else {
            resolvedKind = .move
        }

        // Without a copy there is nothing to give back, and keeping a press
        // that can never be returned is worse than not holding it at all.
        guard let down = event.copy() else { return Unmanaged.passUnretained(event) }
        pendingGesture = PendingWindowGesture(down: down,
                                              button: chord.button,
                                              kind: resolvedKind,
                                              window: target.window,
                                              app: target.app,
                                              originalFrame: CGRect(origin: target.frame.origin,
                                                                    size: target.frame.size),
                                              origin: event.location)
        return nil
    }

    /// The press became a gesture. Raising happens here and not at the press,
    /// so a plain modifier click never activates or reorders a window.
    private func promote(_ pending: PendingWindowGesture, pointer: CGPoint) {
        pendingGesture = nil
        // Suspended for the whole gesture, not per frame write: the writes come
        // at pointer speed and the flag only needs to move twice.
        gestureAssistiveMode?.resume()
        gestureAssistiveMode = EnhancedUserInterfaceSuspension.suspend(forAppOf: pending.window)
        if UserDefaults.standard.bool(forKey: DefaultsKey.windowGestureRaiseWindow) {
            _ = pending.app.activate(options: [])
            AXUIElementPerformAction(pending.window, kAXRaiseAction as CFString)
        }
        // The press point stays the anchor: measuring from where the slop was
        // crossed would leave the window trailing the pointer for good.
        var gesture = WindowPointerGesture(window: pending.window,
                                           kind: pending.kind,
                                           button: pending.button,
                                           originalFrame: pending.originalFrame,
                                           pointerStart: pending.origin,
                                           lastAppliedAt: ProcessInfo.processInfo.systemUptime)
        apply(gesture, pointer: pointer)
        gesture.lastAppliedAt = ProcessInfo.processInfo.systemUptime
        activeGesture = gesture
    }

    /// Puts a held press back into the stream. It carries the release point
    /// and the current time so the app reads the pair as one short click on
    /// one element, however long the button was held.
    private func flushPending(proxy: CGEventTapProxy?, at point: CGPoint?) {
        guard let pending = pendingGesture else { return }
        pendingGesture = nil
        let down = pending.down
        down.location = point ?? pending.origin
        down.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        if let proxy {
            // Posted through the tap it is leaving, which places it ahead of
            // the event this callback is about to return.
            down.tapPostEvent(proxy)
        } else {
            down.post(tap: .cgSessionEventTap)
        }
    }

    private func apply(_ gesture: WindowPointerGesture, pointer: CGPoint) {
        switch gesture.kind {
        case .move:
            let origin = WindowGestureSupport.movedOrigin(from: gesture.originalFrame.origin,
                                                          pointerStart: gesture.pointerStart,
                                                          pointerNow: pointer)
            _ = setPosition(origin, on: gesture.window)
        case .resize(let edges):
            let frame = WindowGestureSupport.resizedFrame(from: gesture.originalFrame,
                                                          pointerStart: gesture.pointerStart,
                                                          pointerNow: pointer,
                                                          edges: edges)
            // Size must be written first. Moving a full-size window to the
            // requested top or left origin exposes a large intermediate frame
            // before AX applies the size, which appears as a jump or blank
            // content in windows with asynchronous layout.
            guard setSize(frame.size, on: gesture.window) else { return }

            let acceptedFrame = self.frame(of: gesture.window)
            let acceptedSize = acceptedFrame?.size ?? frame.size
            // Right and bottom resizing keeps the original origin, so the
            // helper returns nil instead of adding a non-atomic position write.
            guard let anchoredOrigin = WindowGestureSupport.anchoredOriginIfNeeded(
                original: gesture.originalFrame,
                requestedOrigin: frame.origin,
                acceptedSize: acceptedSize,
                edges: edges
            ) else { return }
            if let currentOrigin = acceptedFrame?.origin {
                if abs(currentOrigin.x - anchoredOrigin.x) > 0.5
                    || abs(currentOrigin.y - anchoredOrigin.y) > 0.5 {
                    _ = setPosition(anchoredOrigin, on: gesture.window)
                }
            } else {
                _ = setPosition(anchoredOrigin, on: gesture.window)
            }
        }
    }

    private func gestureTarget(at point: CGPoint,
                               requiresResize: Bool) -> WindowGestureTarget? {
        let system = AXUIElementCreateSystemWide()
        // No cap here: on the system-wide element a timeout is the default for
        // every question this process asks, whoever asks it (#938).
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &rawElement) == .success,
              let element = rawElement
        else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let window: AXUIElement?
        if role(of: element) == (kAXWindowRole as String) {
            window = element
        } else {
            window = windowAttribute(element, kAXWindowAttribute as String)
                ?? windowAttribute(element, kAXTopLevelUIElementAttribute as String)
        }
        guard let window else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)

        var pid = pid_t(0)
        guard role(of: window) == (kAXWindowRole as String),
              !boolAttribute(window, "AXFullScreen"),
              canSetPosition(on: window),
              (!requiresResize || canSetSize(on: window)),
              AXUIElementGetPid(window, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              app.activationPolicy == .regular,
              // Ignored apps keep their modifier clicks and drags.
              !isIgnored(bundleID: app.bundleIdentifier),
              let frame = frame(of: window),
              frame.size.width > 80,
              frame.size.height > 80
        else { return nil }
        return WindowGestureTarget(window: window, app: app, frame: frame)
    }

    private func canSetFrame(on window: AXUIElement) -> Bool {
        canSetPosition(on: window) && canSetSize(on: window)
    }

    private func canSetPosition(on window: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              kAXPositionAttribute as CFString,
                                              &positionSettable) == .success
            && positionSettable.boolValue
    }

    private func canSetSize(on window: AXUIElement) -> Bool {
        var sizeSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              kAXSizeAttribute as CFString,
                                              &sizeSettable) == .success
            && sizeSettable.boolValue
    }

    private func canSetFullScreen(on window: AXUIElement) -> Bool {
        var fullScreenSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window,
                                              "AXFullScreen" as CFString,
                                              &fullScreenSettable) == .success
            && fullScreenSettable.boolValue
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    private func frame(of element: AXUIElement) -> WindowLayoutFrame? {
        guard let origin = pointAttribute(element, kAXPositionAttribute as String),
              let size = sizeAttribute(element, kAXSizeAttribute as String),
              size.width > 0,
              size.height > 0
        else { return nil }
        return WindowLayoutFrame(origin: origin, size: size)
    }

    private func bestScreen(for frame: WindowLayoutFrame,
                            screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let appKitFrame = appKitFrame(fromAX: frame)
        return screens.max { lhs, rhs in
            lhs.frame.intersection(appKitFrame).area < rhs.frame.intersection(appKitFrame).area
        } ?? NSScreen.main ?? screens.first
    }

    private func adjacentScreen(to current: NSScreen,
                                screens: [NSScreen],
                                movingForward: Bool) -> NSScreen? {
        guard let currentIndex = screens.firstIndex(where: { $0 === current }),
              let destinationIndex = WindowLayoutGeometry.adjacentDisplayIndex(
                currentIndex: currentIndex,
                frames: screens.map(\.frame),
                movingForward: movingForward
              )
        else { return nil }
        return screens[destinationIndex]
    }

    private func sidewaysScreen(to current: NSScreen,
                                screens: [NSScreen],
                                movingRight: Bool) -> NSScreen? {
        guard let currentIndex = screens.firstIndex(where: { $0 === current }),
              let destinationIndex = WindowLayoutGeometry.horizontalNeighbourIndex(
                currentIndex: currentIndex,
                frames: screens.map(\.frame),
                movingRight: movingRight
              )
        else { return nil }
        return screens[destinationIndex]
    }

    private func axFrame(fromAppKit rect: NSRect) -> WindowLayoutFrame {
        axFrame(fromAppKit: rect, screenTop: menuBarScreenTopY)
    }

    private func appKitFrame(fromAX frame: WindowLayoutFrame) -> NSRect {
        appKitFrame(fromAX: frame, screenTop: menuBarScreenTopY)
    }

    /// The same conversions with the menu-bar display's top already known,
    /// for the paths that look it up once.
    private func axFrame(fromAppKit rect: NSRect, screenTop: CGFloat) -> WindowLayoutFrame {
        WindowLayoutFrame(origin: CGPoint(x: rect.minX, y: screenTop - rect.maxY),
                          size: rect.size)
    }

    private func appKitFrame(fromAX frame: WindowLayoutFrame, screenTop: CGFloat) -> NSRect {
        NSRect(x: frame.origin.x,
               y: screenTop - frame.origin.y - frame.size.height,
               width: frame.size.width,
               height: frame.size.height)
    }

    private var menuBarScreenTopY: CGFloat {
        let menuBarScreen = NSScreen.screens.first {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        }
        return (menuBarScreen ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return false }
        return (value as? Bool) ?? false
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func windowAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func windowsAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let values = value as? [AXUIElement]
        else { return nil }
        return values
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

private struct WindowLayoutTarget {
    let window: AXUIElement
    let key: WindowLayoutWindowKey
    let frame: WindowLayoutFrame

    var windowID: CGWindowID { key.windowID }
}

/// A window the lookup could act on, with what it already read about it.
private struct WindowLayoutCandidate {
    let window: AXUIElement
    let app: NSRunningApplication
    let key: WindowLayoutWindowKey
    let frame: WindowLayoutFrame
    let isFullScreen: Bool

    var target: WindowLayoutTarget { WindowLayoutTarget(window: window, key: key, frame: frame) }
}

/// What the lookup does with a candidate window.
private enum WindowCandidateVerdict {
    /// Act on this window.
    case accept
    /// This window cannot take the command; try the next one.
    case skip
    /// The command does not apply here: act on nothing.
    case stop
}

private struct WindowDirectionalSession {
    let target: WindowLayoutTarget
    let visibleFrame: NSRect
    let pointerOrigin: CGPoint
    var action: WindowDirectionalAction?
    var manualOverride: WindowDirectionalAction?
}

/// Native glass-ring container; no upstream artwork or media is bundled.
private final class WindowDirectionalIndicatorView: NSView {
    private let canvas: WindowDirectionalIndicatorCanvasView

    var action: WindowDirectionalAction? {
        didSet { canvas.action = action }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: frameRect.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        canvas = WindowDirectionalIndicatorCanvasView(
            frame: CGRect(origin: .zero, size: frameRect.size))
        canvas.autoresizingMask = [.width, .height]
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(effect)
        addSubview(canvas, positioned: .above, relativeTo: effect)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// The canvas stays separate from `NSVisualEffectView`: AppKit may composite
/// the material after a visual-effect subclass draws, hiding custom artwork.
private final class WindowDirectionalIndicatorCanvasView: NSView {
    var action: WindowDirectionalAction? { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        let outerRadius: CGFloat = 84
        let innerRadius: CGFloat = 46
        let track = annulus(center: center, outer: outerRadius, inner: innerRadius)

        // 1. Subtle frosted track background
        context.saveGState()
        context.addPath(track)
        context.setFillColor(NSColor(white: 0.10, alpha: 0.35).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        // 2. Soft borders for track
        context.saveGState()
        context.addPath(track)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
        context.restoreGState()

        // 3. Highlight active sector if one of the 8 directions is active
        if let direction = Direction(action: action) {
            let highlight = sector(center: center,
                                   outer: outerRadius - 1.5,
                                   inner: innerRadius + 1.5,
                                   centerAngle: direction.angle)
            context.saveGState()
            context.addPath(highlight)
            context.clip()

            let accent = NSColor.controlAccentColor
            let lighterAccent = accent.blended(withFraction: 0.30, of: .white) ?? accent
            let colors = [
                lighterAccent.withAlphaComponent(0.85).cgColor,
                accent.withAlphaComponent(0.75).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                let rad = direction.angle * .pi / 180
                let startPoint = CGPoint(x: center.x + cos(rad) * innerRadius,
                                         y: center.y + sin(rad) * innerRadius)
                let endPoint = CGPoint(x: center.x + cos(rad) * outerRadius,
                                       y: center.y + sin(rad) * outerRadius)
                context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
            }
            context.restoreGState()
        }

        // 4. Subtle dividers between the 8 sectors
        drawDividers(center: center, inner: innerRadius + 4, outer: outerRadius - 4, context: context)

        // 5. Directional pips on the outer ring
        drawDirectionPips(center: center, radius: (innerRadius + outerRadius) / 2, activeDirection: Direction(action: action), context: context)

        // 6. Center Hub & Glyph
        drawCenterHub(center: center, action: action, context: context)
    }

    private func annulus(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                   width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                                   width: inner * 2, height: inner * 2))
        return path
    }

    private func sector(center: CGPoint, outer: CGFloat, inner: CGFloat,
                        centerAngle: CGFloat) -> CGPath {
        let start = (centerAngle - 22.5) * .pi / 180
        let end = (centerAngle + 22.5) * .pi / 180
        let path = CGMutablePath()
        path.addArc(center: center, radius: outer, startAngle: start,
                    endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end,
                    endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func drawDividers(center: CGPoint, inner: CGFloat, outer: CGFloat,
                              context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.6)
        for angle in stride(from: CGFloat(22.5), to: 360, by: 45) {
            let radians = angle * .pi / 180
            context.move(to: CGPoint(x: center.x + cos(radians) * inner,
                                     y: center.y + sin(radians) * inner))
            context.addLine(to: CGPoint(x: center.x + cos(radians) * outer,
                                        y: center.y + sin(radians) * outer))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawDirectionPips(center: CGPoint, radius: CGFloat,
                                   activeDirection: Direction?, context: CGContext) {
        for direction in Direction.allCases {
            let isActive = direction == activeDirection
            let rad = direction.angle * .pi / 180
            let pipCenter = CGPoint(x: center.x + cos(rad) * radius,
                                    y: center.y + sin(rad) * radius)
            let pipRadius: CGFloat = isActive ? 3.5 : 2.0
            let pipRect = CGRect(x: pipCenter.x - pipRadius,
                                 y: pipCenter.y - pipRadius,
                                 width: pipRadius * 2,
                                 height: pipRadius * 2)
            context.saveGState()
            if isActive {
                context.setShadow(offset: .zero, blur: 8,
                                  color: NSColor.white.withAlphaComponent(0.8).cgColor)
                context.setFillColor(NSColor.white.cgColor)
            } else {
                context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            }
            context.fillEllipse(in: pipRect)
            context.restoreGState()
        }
    }

    private func drawCenterHub(center: CGPoint, action: WindowDirectionalAction?, context: CGContext) {
        let radius: CGFloat = 38
        let hub = CGRect(x: center.x - radius, y: center.y - radius,
                         width: radius * 2, height: radius * 2)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.25).cgColor)

        if action == .maximize {
            let accent = NSColor.controlAccentColor
            context.setFillColor(accent.withAlphaComponent(0.30).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(accent.withAlphaComponent(0.80).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        } else if action == .minimize {
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.22).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        } else {
            context.setFillColor(NSColor(white: 0.14, alpha: 0.80).cgColor)
            context.fillEllipse(in: hub)
            context.restoreGState()

            context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: hub.insetBy(dx: 0.5, dy: 0.5))
        }

        // Miniature macOS window frame
        let window = CGRect(x: center.x - 16, y: center.y - 12, width: 32, height: 24)
        let outline = CGPath(roundedRect: window, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)

        context.saveGState()
        context.addPath(outline)
        if action == .maximize {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        } else if action == .minimize {
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.90).cgColor)
        } else if action != nil {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        } else {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.50).cgColor)
        }
        context.setLineWidth(1.4)
        context.strokePath()
        context.restoreGState()

        // Content area inside window
        if action == .minimize {
            let arrowPath = CGMutablePath()
            arrowPath.move(to: CGPoint(x: center.x, y: center.y + 4.5))
            arrowPath.addLine(to: CGPoint(x: center.x, y: center.y - 3.5))
            arrowPath.move(to: CGPoint(x: center.x - 4, y: center.y - 0.5))
            arrowPath.addLine(to: CGPoint(x: center.x, y: center.y - 4.5))
            arrowPath.addLine(to: CGPoint(x: center.x + 4, y: center.y - 0.5))

            context.saveGState()
            context.addPath(arrowPath)
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        } else if action == .maximize {
            let inner = window.insetBy(dx: 2.5, dy: 2.5)
            context.saveGState()
            let fillPath = CGPath(roundedRect: inner, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            context.addPath(fillPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
            context.fillPath()
            context.restoreGState()
        } else if let action, let region = glyphRegion(for: action, in: window.insetBy(dx: 2.5, dy: 2.5)) {
            context.saveGState()
            let fillPath = CGPath(roundedRect: region, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(fillPath)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
            context.fillPath()
            context.restoreGState()
        }
    }

    private func glyphRegion(for action: WindowDirectionalAction, in rect: CGRect) -> CGRect? {
        switch action {
        case .leftHalf: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .rightHalf: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .topHalf: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .bottomHalf: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .topLeft: return CGRect(x: rect.minX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .topRight: return CGRect(x: rect.midX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .bottomLeft: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height / 2)
        case .bottomRight: return CGRect(x: rect.midX, y: rect.midY, width: rect.width / 2, height: rect.height / 2)
        case .maximize: return rect
        case .minimize: return nil
        }
    }

    private enum Direction: CaseIterable {
        case right, topRight, top, topLeft, left, bottomLeft, bottom, bottomRight

        var angle: CGFloat {
            switch self {
            case .right: return 0
            case .topRight: return 45
            case .top: return 90
            case .topLeft: return 135
            case .left: return 180
            case .bottomLeft: return 225
            case .bottom: return 270
            case .bottomRight: return 315
            }
        }

        var action: WindowDirectionalAction {
            switch self {
            case .right: return .rightHalf
            case .topRight: return .topRight
            case .top: return .topHalf
            case .topLeft: return .topLeft
            case .left: return .leftHalf
            case .bottomLeft: return .bottomLeft
            case .bottom: return .bottomHalf
            case .bottomRight: return .bottomRight
            }
        }

        init?(action: WindowDirectionalAction?) {
            guard let action, let value = Self.allCases.first(where: { $0.action == action }) else {
                return nil
            }
            self = value
        }
    }
}

/// Everything the deferred settle verification needs to finish judging a
/// discrete layout action after the grace period.
private struct SettleContext {
    let window: AXUIElement
    let windowID: CGWindowID
    let frame: WindowLayoutFrame
    let targetRect: NSRect
    let screenVisibleFrame: NSRect
    let action: WindowLayoutAction?
    let anchor: WindowPlacementAnchor
    let original: WindowLayoutFrame?
    let previousAction: WindowLayoutAction?
    let windowKey: WindowLayoutWindowKey
    /// Which published result this settle belongs to; a late failure only
    /// speaks when no newer action has published since.
    let resultGeneration: Int
}

private struct WindowLayoutPlacement {
    let frame: WindowLayoutFrame
    let rect: NSRect
}

private struct WindowGestureTarget {
    let window: AXUIElement
    let app: NSRunningApplication
    let frame: WindowLayoutFrame
}

private enum WindowEdgeSnapPointerInput {
    case down(location: CGPoint, flags: CGEventFlags)
    case dragged(location: CGPoint)
    case up(location: CGPoint)
}

private struct WindowEdgeSnapDrag {
    let window: AXUIElement
    let key: WindowLayoutWindowKey
    let initialFrame: CGRect
    let pointerStart: CGPoint
    /// False when the drag is followed only to restore a placed window's
    /// size: no preview, no drop, no change to the pointer events.
    let places: Bool
    let protectsSystemTopEdge: Bool
    let quartzScreenFrames: [CGRect]
    let enabledZones: Set<WindowEdgeSnapZone>
    var lastSampleAt: TimeInterval
    var mismatchCount: Int
    var isMoving: Bool
    var target: WindowCommandDragTarget?
    /// Set once the drag gave a snapped window its earlier size back.
    var restoredFrame: CGRect?
    /// Read once the window is confirmed moving.
    var context: WindowDragContext?
    /// The drag area under the pointer at the last sample.
    var lastMatch: WindowActivationHitTest.Match?
}

/// What a drag reads more than once, read once per drag.
private struct WindowDragContext {
    let screens: [WindowActivationScreen]
    let settings: WindowActivationSettings
    let configuration: WindowCommandConfiguration
    let windowGap: CGFloat
    let screenGap: CGFloat
    let menuBarTop: CGFloat
}

private struct WindowCommandDragTarget: Equatable {
    let commandID: UUID
    let setKind: WindowCommandSetKind
    let previewFrame: CGRect
    let visibleFrame: CGRect
}

private struct WindowSnapRecord {
    var placed: WindowLayoutFrame
    var originalSize: CGSize
}

/// A press the tap is holding while it is still undecided. It keeps the
/// original event so the click can be handed back untouched, with its
/// modifiers and its click count intact.
private struct PendingWindowGesture {
    let down: CGEvent
    let button: WindowPointerGesture.Button
    let kind: WindowPointerGesture.Kind
    let window: AXUIElement
    let app: NSRunningApplication
    let originalFrame: CGRect
    let origin: CGPoint
}

private struct WindowPointerGesture {
    enum Button {
        case primary
        case secondary
    }

    enum Kind {
        case move
        case resize(WindowGestureResizeEdges)
    }

    let window: AXUIElement
    let kind: Kind
    let button: Button
    let originalFrame: CGRect
    let pointerStart: CGPoint
    var lastAppliedAt: TimeInterval
}

/// The drop preview: where the window will land. Its look follows the
/// preview settings (a system material in light, dark or matching the
/// system, or the accent tint) and its border width.
private final class WindowEdgeSnapPreviewView: NSView {
    private let material = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        addSubview(material)
        setAccessibilityElement(false)
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// Re-read on every show, so a changed setting applies to the next drag.
    func updateAppearance() {
        guard let layer else { return }
        let defaults = UserDefaults.standard
        let style = WindowLayoutPreviewStyle.sanitized(defaults.string(forKey: DefaultsKey.windowLayoutPreviewStyle))
        let border = CGFloat(WindowLayoutPreviewStyle.sanitizedBorderWidth(
            defaults.integer(forKey: DefaultsKey.windowLayoutPreviewBorderWidth)))
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = border
        switch style {
        case .accent:
            let accent = NSColor.controlAccentColor
            material.isHidden = true
            layer.backgroundColor = accent.withAlphaComponent(0.16).cgColor
            layer.borderColor = accent.withAlphaComponent(0.88).cgColor
        case .system, .light, .dark:
            material.isHidden = false
            let forced: NSAppearance? = style == .light ? NSAppearance(named: .aqua)
                : style == .dark ? NSAppearance(named: .darkAqua) : nil
            // Assigned only on a real change: setting an appearance calls
            // back into viewDidChangeEffectiveAppearance.
            if material.appearance?.name != forced?.name { material.appearance = forced }
            if appearance?.name != forced?.name { appearance = forced }
            layer.backgroundColor = NSColor.clear.cgColor
            var borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
            (forced ?? effectiveAppearance).performAsCurrentDrawingAppearance {
                borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
            }
            layer.borderColor = borderColor
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

/// A snapshot of the window a menu acts on. The target itself stays private
/// to the service; menus only read the facts.
struct WindowCommandMenuContext {
    let setKind: WindowCommandSetKind
    /// The app the menu's Ignore item names; nil for Yaya's Space itself.
    let appName: String?
    let bundleID: String?
    let isIgnored: Bool
    let displayCount: Int
    let canRestore: Bool
    /// What the window lets Accessibility change.
    let capabilities: WindowCommandCapabilities
    fileprivate let target: WindowLayoutTarget?
    let screenFrame: CGRect?
    let visibleFrame: CGRect?

    var hasWindow: Bool { target != nil }

    /// The window the menu was opened for, which its commands act on.
    var window: AXUIElement? { target?.window }
}
