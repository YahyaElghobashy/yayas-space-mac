// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The Window Layout page: a General tab for how the feature behaves and a
/// Commands tab for the two command sets. A notice sits above both while
/// another window manager is running.
struct WindowLayoutSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var tabs = WindowLayoutSettingsTabs.shared

    private var text: WindowCommandStrings { .localized(l10n.language) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tabs.tab) {
                Text(text.tabGeneral).tag(WindowLayoutSettingsTabs.Tab.general)
                Text(text.tabCommands).tag(WindowLayoutSettingsTabs.Tab.commands)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 300)
            .padding(.top, 16)
            .padding(.bottom, 10)
            OtherWindowManagerBanner()
            switch tabs.tab {
            case .general:
                WindowLayoutGeneralTab()
            case .commands:
                WindowLayoutCommandsTab()
            }
        }
    }
}

/// Which tab the page shows; the menu-bar item and the panel can ask for one.
final class WindowLayoutSettingsTabs: ObservableObject {
    static let shared = WindowLayoutSettingsTabs()

    enum Tab: Hashable {
        case general
        case commands
    }

    @Published var tab: Tab = .general

    private init() {}
}

/// Shown while Magnet runs next to Window Layout: both would answer the
/// same shortcuts and drags. Quitting it is offered, never done unasked.
struct OtherWindowManagerBanner: View {
    static let bundleIdentifier = "com.crowdcafe.windowmagnet"

    @ObservedObject private var l10n = L10n.shared
    // Seeded at creation: the view below is empty while nothing runs, and an
    // empty view never gets an appear event to fill it in.
    @State private var running = OtherWindowManagerBanner.find()

    private var text: WindowCommandStrings { .localized(l10n.language) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let running {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text.otherManagerTitle)
                            .font(.headline)
                        Text(text.otherManagerMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(String(format: text.otherManagerQuitFormat, running.localizedName ?? "Magnet")) {
                        running.terminate()
                    }
                    .controlSize(.regular)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35))
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification)) { _ in refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification)) { _ in refresh() }
    }

    private func refresh() {
        running = Self.find()
    }

    static func find() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
    }
}

/// General tab: sync, the menu-bar item, keyboard, dragging, drag areas,
/// the drop preview, the green-button menu, margins, ignored apps and reset.
struct WindowLayoutGeneralTab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = WindowLayoutService.shared
    @ObservedObject private var sync = WindowLayoutSyncController.shared
    @AppStorage(DefaultsKey.panelUtilityWindowLayout) private var showInPanel = true
    @AppStorage(DefaultsKey.windowLayoutShowMenuBarItem) private var showMenuBarItem = true
    @AppStorage(DefaultsKey.windowLayoutShortcutsEnabled) private var shortcutsEnabled = false
    @AppStorage(DefaultsKey.windowDirectionalEnabled) private var directionalEnabled = false
    @AppStorage(DefaultsKey.windowDirectionalShortcut) private var directionalShortcutRaw =
        GlobalShortcut.windowDirectionalDefault.storageValue
    @AppStorage(DefaultsKey.windowEdgeSnapEnabled) private var snapEnabled = false
    @AppStorage(DefaultsKey.windowLayoutRestoreSizeOnDrag) private var restoreOnDrag = true
    @AppStorage(DefaultsKey.windowGestureEnabled) private var gestureEnabled = false
    @AppStorage(DefaultsKey.windowGestureModifiers) private var gestureModifiers =
        WindowGestureSupport.defaultModifierStorageValue
    @AppStorage(DefaultsKey.windowGestureRaiseWindow) private var gestureRaiseWindow = false
    @AppStorage(DefaultsKey.windowLayoutHighlightAreas) private var highlightAreas = false
    @AppStorage(DefaultsKey.windowLayoutInteriorAreaScale) private var interiorScale =
        WindowActivationSettings.defaultInteriorScalePercent
    @AppStorage(DefaultsKey.windowLayoutEdgeAreaWidth) private var edgeWidth =
        WindowActivationSettings.defaultEdgeWidth
    @AppStorage(DefaultsKey.windowLayoutPreviewStyle) private var previewStyleRaw =
        WindowLayoutPreviewStyle.system.rawValue
    @AppStorage(DefaultsKey.windowLayoutPreviewBorderWidth) private var previewBorder =
        WindowLayoutPreviewStyle.defaultBorderWidth
    @AppStorage(DefaultsKey.windowLayoutGreenButtonMenuEnabled) private var greenButtonEnabled = false
    @AppStorage(DefaultsKey.windowLayoutGreenButtonDelay) private var greenButtonDelay =
        WindowGreenButtonMenuLayout.defaultDelayMilliseconds
    @AppStorage(DefaultsKey.windowLayoutGreenButtonLayout) private var greenButtonLayoutRaw =
        WindowGreenButtonMenuLayout.list.rawValue
    @AppStorage(DefaultsKey.windowLayoutWindowGap) private var windowGap = 0
    @AppStorage(DefaultsKey.windowLayoutScreenGap) private var screenGap = 0
    @AppStorage(DefaultsKey.windowLayoutFitTightly) private var fitTightly = false
    @State private var ignoredApps = WindowLayoutService.shared.ignoredBundleIDs
    // Same preference the Switcher page shows next to Dock Preview; mirrored
    // here because it is a window-juggling behaviour people look for here too.
    @AppStorage(DefaultsKey.dockClickCycleWindows) private var dockClickCycleWindows = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var systemTilingEnabled = WindowEdgeSnapSupport.isSystemTilingEnabled
    @State private var confirmingReset = false

    private var text: WindowCommandStrings { .localized(l10n.language) }
    private var layoutText: WindowLayoutFeatureStrings { FeatureStrings.windowLayout(l10n.language) }

    var body: some View {
        Form {
            if !permissions.accessibility {
                Section(l10n.s.permissionRequired) {
                    PermissionRow(kind: .accessibility)
                    Text(layoutText.permissionCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            syncSection
            generalSection
            keyboardSection
            draggingSection
            areasSection
            previewSection
            greenButtonSection
            marginsSection
            ignoredSection
            Section {
                Toggle(l10n.s.dockClickCycleWindows, isOn: $dockClickCycleWindows)
                    .onChange(of: dockClickCycleWindows) { _, _ in
                        DockClickService.shared.syncWithPreferences()
                    }
                Text(l10n.s.dockClickCycleWindowsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(text.resetSection) {
                Button(text.resetAll, role: .destructive) { confirmingReset = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemState()
        }
        .alert(text.resetAllTitle, isPresented: $confirmingReset) {
            Button(text.reset, role: .destructive) { WindowLayoutSettingsActions.resetAll() }
            Button(text.cancel, role: .cancel) {}
        } message: {
            Text(text.resetAllMessage)
        }
    }

    // MARK: Sections

    private var syncSection: some View {
        Section(text.syncSection) {
            Text(text.syncCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(text.exportSettings) { sync.exportWithPanel() }
                Button(text.importSettings) { sync.importWithPanel() }
                Spacer()
            }
            LabeledContent(text.syncFolder) {
                HStack(spacing: 8) {
                    if let folder = sync.folderDisplayPath {
                        Text(folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(folder)
                    } else {
                        Text(text.syncFolderOff)
                            .foregroundStyle(.secondary)
                    }
                    Button(text.chooseSyncFolder) { sync.chooseFolder() }
                }
            }
            if sync.folderDisplayPath != nil {
                HStack {
                    Text(sync.lastSyncedText(strings: text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(text.syncNow) { sync.syncNow() }
                    Button(text.stopSyncing) { sync.stopSyncing() }
                }
                .controlSize(.small)
            }
            if let note = sync.conflictNote {
                HStack(alignment: .top) {
                    Label(note, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(text.dismiss) { sync.dismissConflictNote() }
                        .controlSize(.small)
                }
            }
            if let status = sync.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(sync.statusIsError ? .orange : .secondary)
            }
        }
    }

    private var generalSection: some View {
        Section(text.generalSection) {
            Toggle(text.showMenuBarItem, isOn: $showMenuBarItem)
                .onChange(of: showMenuBarItem) { _, _ in service.syncWithPreferences() }
            Text(text.showMenuBarItemCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(text.openAtLogin, isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LaunchAtLogin.isEnabled else { return }
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(text.openAtLoginCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(layoutText.showInPanel, isOn: $showInPanel)
        }
    }

    private var keyboardSection: some View {
        Section(text.keyboardSection) {
            Toggle(layoutText.shortcuts, isOn: $shortcutsEnabled)
                .onChange(of: shortcutsEnabled) { _, _ in service.syncWithPreferences() }
            Text(layoutText.shortcutsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if shortcutsEnabled, !service.failedShortcuts.isEmpty {
                Text(l10n.s.shortcutUnavailable + " "
                     + service.failedShortcuts.map(\.displayString).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle(WindowDirectionalStrings.localized(l10n.language).title, isOn: $directionalEnabled)
                .onChange(of: directionalEnabled) { _, _ in service.syncWithPreferences() }
            Text(WindowDirectionalStrings.localized(l10n.language).caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if directionalEnabled {
                ShortcutRecorderButton(shortcut: directionalShortcut,
                                       isEnabled: permissions.accessibility,
                                       waitingTitle: l10n.s.shortcutPressKeys,
                                       invalidAction: {},
                                       captureAction: saveDirectionalShortcut)
                    .frame(width: 130)
                if service.directionalShortcutRegistrationFailed {
                    Text(l10n.s.shortcutUnavailable)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var draggingSection: some View {
        Section(text.draggingSection) {
            Toggle(text.snapByDragging, isOn: $snapEnabled)
                .onChange(of: snapEnabled) { _, _ in service.syncWithPreferences() }
            Text(text.snapByDraggingCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if systemTilingEnabled {
                Label(layoutText.edgeSnapSystemConflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if snapEnabled {
                    Text(layoutText.edgeSnapWaitingForSystem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(layoutText.edgeSnapOpenSystemSettings) {
                    NSWorkspace.shared.open(WindowEdgeSnapSupport.desktopAndDockSettingsURL)
                }
                .controlSize(.small)
            }
            // Works for windows placed by any route, so it does not wait
            // for snapping by dragging to be on.
            Toggle(text.restoreOnDrag, isOn: $restoreOnDrag)
                .onChange(of: restoreOnDrag) { _, _ in service.syncWithPreferences() }
            Text(text.restoreOnDragCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(layoutText.gestureEnable, isOn: $gestureEnabled)
                .onChange(of: gestureEnabled) { _, _ in service.syncWithPreferences() }
            Text(layoutText.gestureCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if gestureEnabled {
                WindowGestureModifierPicker(storageValue: $gestureModifiers, title: layoutText.gestureModifiers)
                    .onChange(of: gestureModifiers) { _, _ in service.syncWithPreferences() }
                WindowGestureHints(modifierStorage: gestureModifiers,
                                   moveText: layoutText.gestureMove,
                                   resizeText: layoutText.gestureResize)
                Text(layoutText.gestureResizeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(layoutText.gestureRaiseWindow, isOn: $gestureRaiseWindow)
            }
        }
    }

    private var areasSection: some View {
        Section(text.areasSection) {
            Toggle(text.highlightAreas, isOn: $highlightAreas)
            WindowLayoutStepperRow(title: text.interiorScale,
                                   value: $interiorScale,
                                   range: WindowActivationSettings.interiorScaleRange,
                                   step: 5,
                                   format: text.percentFormat)
            WindowLayoutStepperRow(title: text.edgeWidth,
                                   value: $edgeWidth,
                                   range: WindowActivationSettings.edgeWidthRange,
                                   step: 1,
                                   format: text.pointsFormat)
        }
    }

    private var previewSection: some View {
        Section(text.previewSection) {
            Picker(text.previewStyle, selection: $previewStyleRaw) {
                Text(text.styleSystem).tag(WindowLayoutPreviewStyle.system.rawValue)
                Text(text.styleLight).tag(WindowLayoutPreviewStyle.light.rawValue)
                Text(text.styleDark).tag(WindowLayoutPreviewStyle.dark.rawValue)
                Text(text.styleAccent).tag(WindowLayoutPreviewStyle.accent.rawValue)
            }
            .pickerStyle(.menu)
            WindowLayoutStepperRow(title: text.previewBorder,
                                   value: $previewBorder,
                                   range: WindowLayoutPreviewStyle.borderWidthRange,
                                   step: 1,
                                   format: text.pointsFormat)
        }
    }

    private var greenButtonSection: some View {
        Section(text.greenButtonSection) {
            Toggle(text.greenButtonMenu, isOn: $greenButtonEnabled)
                .onChange(of: greenButtonEnabled) { _, _ in service.syncWithPreferences() }
            Text(text.greenButtonCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            WindowLayoutStepperRow(title: text.greenButtonDelay,
                                   value: $greenButtonDelay,
                                   range: WindowGreenButtonMenuLayout.delayRange,
                                   step: 50,
                                   format: text.millisecondsFormat)
            Picker(text.greenButtonLayout, selection: $greenButtonLayoutRaw) {
                Text(text.layoutList).tag(WindowGreenButtonMenuLayout.list.rawValue)
                Text(text.layoutGrid).tag(WindowGreenButtonMenuLayout.grid.rawValue)
            }
            .pickerStyle(.menu)
            Text(text.greenButtonSystemNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var marginsSection: some View {
        Section(text.marginsSection) {
            WindowLayoutStepperRow(title: text.margins,
                                   value: marginBinding,
                                   range: 0...128,
                                   step: 2,
                                   format: text.pointsFormat)
            Toggle(text.fitTightly, isOn: fitTightlyBinding)
            Text(text.fitTightlyCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var ignoredSection: some View {
        Section {
            AppBundleList(title: text.ignoredSection,
                          caption: text.ignoredCaption,
                          addTitle: text.addApp,
                          removeLabel: text.remove,
                          bundleIDs: ignoredApps,
                          reachesEveryApp: true,
                          onAdd: { bundleID in
                              setIgnoredApps(WindowLayoutIgnoreList.sanitized(ignoredApps + [bundleID]))
                          },
                          onRemove: { bundleID in
                              setIgnoredApps(ignoredApps.filter {
                                  $0.caseInsensitiveCompare(bundleID) != .orderedSame
                              })
                          })
        }
        // The menu-bar item can change the list while this page is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let stored = WindowLayoutService.shared.ignoredBundleIDs
            if stored != ignoredApps { ignoredApps = stored }
        }
    }

    private func setIgnoredApps(_ apps: [String]) {
        ignoredApps = apps
        UserDefaults.standard.set(apps, forKey: DefaultsKey.windowLayoutIgnoredApps)
    }

    // MARK: Margins

    /// Margins map onto the two existing gap preferences: the window margin
    /// always, the screen margin unless windows fit tightly to the edges.
    private var marginBinding: Binding<Int> {
        Binding(get: { windowGap }, set: { value in
            let gaps = WindowCommandGeometry.gaps(margin: value, fitTightly: fitTightly)
            windowGap = gaps.windowGap
            screenGap = gaps.screenGap
        })
    }

    private var fitTightlyBinding: Binding<Bool> {
        Binding(get: { fitTightly }, set: { value in
            fitTightly = value
            screenGap = WindowCommandGeometry.gaps(margin: windowGap, fitTightly: value).screenGap
        })
    }

    // MARK: Helpers

    private var directionalShortcut: GlobalShortcut {
        GlobalShortcut(storageValue: directionalShortcutRaw) ?? .windowDirectionalDefault
    }

    private func saveDirectionalShortcut(_ shortcut: GlobalShortcut) {
        guard service.directionalShortcutConflictTitle(shortcut) == nil else { return }
        directionalShortcutRaw = shortcut.storageValue
        service.syncWithPreferences()
    }

    private func refreshSystemState() {
        systemTilingEnabled = WindowEdgeSnapSupport.isSystemTilingEnabled
        launchAtLogin = LaunchAtLogin.isEnabled
        service.syncWithPreferences()
    }
}

/// A row with a value and a stepper, the way the numeric settings read.
struct WindowLayoutStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(String(format: format, clamped))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: Binding(get: { clamped }, set: { value = min(max($0, range.lowerBound),
                                                                               range.upperBound) }),
                        in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clamped: Int { min(max(value, range.lowerBound), range.upperBound) }
}

/// Settings actions shared by both tabs.
enum WindowLayoutSettingsActions {
    /// Every preference on the two tabs, back to how it shipped. The command
    /// sets are rebuilt from the defaults; nothing that could fight another
    /// window manager is left on.
    static let resettableKeys: [String] = [
        DefaultsKey.windowLayoutShowMenuBarItem,
        DefaultsKey.windowLayoutShortcutsEnabled,
        DefaultsKey.windowDirectionalEnabled,
        DefaultsKey.windowDirectionalShortcut,
        DefaultsKey.windowEdgeSnapEnabled,
        DefaultsKey.windowLayoutRestoreSizeOnDrag,
        DefaultsKey.windowGestureEnabled,
        DefaultsKey.windowGestureModifiers,
        DefaultsKey.windowGestureRaiseWindow,
        DefaultsKey.windowLayoutHighlightAreas,
        DefaultsKey.windowLayoutInteriorAreaScale,
        DefaultsKey.windowLayoutEdgeAreaWidth,
        DefaultsKey.windowLayoutPreviewStyle,
        DefaultsKey.windowLayoutPreviewBorderWidth,
        DefaultsKey.windowLayoutGreenButtonMenuEnabled,
        DefaultsKey.windowLayoutGreenButtonDelay,
        DefaultsKey.windowLayoutGreenButtonLayout,
        DefaultsKey.windowLayoutWindowGap,
        DefaultsKey.windowLayoutScreenGap,
        DefaultsKey.windowLayoutFitTightly,
        DefaultsKey.windowLayoutIgnoredApps,
        DefaultsKey.panelUtilityWindowLayout,
    ]

    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in resettableKeys { defaults.removeObject(forKey: key) }
        WindowCommandStore.shared.resetToDefaults(.horizontal)
        WindowCommandStore.shared.resetToDefaults(.vertical)
        WindowLayoutService.shared.syncWithPreferences()
    }
}
