// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The central editor for every global shortcut belonging to an installed
/// feature. It writes the same preferences as each feature page, so there is
/// still one setting and one registration path for every action.
struct ShortcutsSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var superKey = SuperKeyService.shared
    @ObservedObject private var windowCommands = WindowCommandStore.shared
    @AppStorage(DefaultsKey.keyboardBrightnessShortcutsEnabled) private var keyboardBrightnessShortcutsEnabled = false
    @State private var expandedFeatures: Set<AppFeature> = [.screenshot]
    @State private var showsAppShortcuts = false

    private var text: ShortcutSettingsStrings { FeatureStrings.shortcuts(l10n.language) }
    private var hub: FeatureHubStrings { FeatureStrings.hub(l10n.language) }

    private var availableRoles: [GlobalShortcutRole] {
        GlobalShortcutRole.availableRoles(isAvailable: { $0.isAvailable }).filter {
            !$0.isKeyboardBrightness || BrightnessService.keyboardLightIsSupported
        }
    }

    private var captureRoles: [GlobalShortcutRole] {
        GlobalShortcutRole.captureRoles(in: availableRoles)
    }

    private var visibleGroups: [FeatureGroup] {
        FeatureGroup.allCases.filter { group in
            availableRoles.contains { $0.group == group }
                || (group == .windowsDock && AppFeature.windowLayout.isAvailable)
        }
    }

    var body: some View {
        Form {
            Section {
                Text(l10n.s.shortcutsPageCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visibleGroups, id: \.self) { group in
                Section(groupTitle(group)) {
                    ForEach(featuresWithShortcuts(in: group), id: \.self) { feature in
                        if feature == .screenshot {
                            captureGroupRows
                        } else if feature == .soundOutputSwitcher {
                            featureRows(feature, in: group)
                                .settingsSectionAnchor(.soundOutputSwitcher)
                        } else {
                            featureRows(feature, in: group)
                        }
                    }
                }
            }

            if AppFeature.commandBar.isAvailable {
                Section {
                    Button {
                        showsAppShortcuts = true
                    } label: {
                        Label(FeatureStrings.commandBar(l10n.language).appCenterTitle,
                              systemImage: "app.badge")
                    }
                    Text(FeatureStrings.commandBar(l10n.language).appCenterCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsAppShortcuts) {
            CommandBarAppShortcutsView()
        }
    }

    private func featuresWithShortcuts(in group: FeatureGroup) -> [AppFeature] {
        AppFeature.allCases.filter { feature in
            // The screenshot slot anchors the combined capture group; the
            // other capture tools render inside it instead of on their own.
            if feature == .screenshot { return group == .tools && !captureRoles.isEmpty }
            if GlobalShortcutRole.captureFeatures.contains(feature) { return false }
            if feature == .windowLayout {
                return group == .windowsDock && feature.isAvailable
            }
            return availableRoles.contains { $0.feature == feature && $0.group == group }
        }
    }

    /// One group for every capture tool's shortcut. Rows keep each tool's own
    /// icon; the group carries the shared page's name and symbol.
    @ViewBuilder
    private var captureGroupRows: some View {
        let roles = captureRoles
        disclosureHeader(
            title: FeatureStrings.screenshot(l10n.language).screenCaptureTitle,
            symbolName: AppFeature.screenshot.symbolName,
            isActive: featureHasActiveShortcut(.screenshot, roles: roles),
            count: roles.count,
            isExpanded: expansionBinding(for: .screenshot))
        if expandedFeatures.contains(.screenshot) {
            ForEach(roles) { role in
                roleRow(role, showsFeatureContext: false)
                    .disclosureIndent()
            }
        }
    }

    @ViewBuilder
    private func featureRows(_ feature: AppFeature, in group: FeatureGroup) -> some View {
        let roles = availableRoles.filter { $0.feature == feature && $0.group == group }
        let count = feature == .windowLayout ? windowCommandCount : roles.count
        if count > 1 {
            disclosureHeader(
                title: featureTitle(feature, roles: roles),
                symbolName: featureSymbol(feature, roles: roles),
                isActive: featureHasActiveShortcut(feature, roles: roles),
                count: count,
                isExpanded: expansionBinding(for: feature))
            if expandedFeatures.contains(feature) {
                if feature == .windowLayout {
                    // Both command sets, as the Window Layout page's Commands
                    // tab lists them; each row edits the same command.
                    ForEach(WindowCommandSetKind.allCases) { kind in
                        Text(windowSetTitle(kind))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .disclosureIndent()
                        ForEach(windowCommands.commands(kind).filter { !$0.isSeparator }) { command in
                            CentralWindowCommandShortcutRow(
                                command: command,
                                kind: kind,
                                shortcutsEnabled: UserDefaults.standard.bool(
                                    forKey: DefaultsKey.windowLayoutShortcutsEnabled),
                                showsSuperKeyAlternative: superKey.isRunning,
                                superKeyModifiers: superKey.modifiers,
                                superKeySource: superKey.source,
                                text: text
                            )
                            .disclosureIndent()
                        }
                    }
                } else {
                    if feature == .brightness {
                        KeyboardBrightnessShortcutToggle(isEnabled: $keyboardBrightnessShortcutsEnabled)
                            .disclosureIndent()
                    }
                    ForEach(roles) { role in
                        roleRow(role, showsFeatureContext: false)
                            .disclosureIndent()
                    }
                }
            }
        } else if let role = roles.first {
            roleRow(role)
        }
    }

    private func featureTitle(_ feature: AppFeature, roles: [GlobalShortcutRole]) -> String {
        if !roles.isEmpty, roles.allSatisfy(\.isKeyboardBrightness) {
            return FeatureStrings.brightness(l10n.language).keyboardLight
        }
        return feature.hubTitle(l10n.s, hub: hub)
    }

    private func featureSymbol(_ feature: AppFeature, roles: [GlobalShortcutRole]) -> String {
        !roles.isEmpty && roles.allSatisfy(\.isKeyboardBrightness)
            ? "keyboard" : feature.symbolName
    }

    private func disclosureHeader(title: String,
                                  symbolName: String,
                                  isActive: Bool,
                                  count: Int,
                                  isExpanded: Binding<Bool>) -> some View {
        DisclosureHeaderRow(isExpanded: isExpanded) {
            ShortcutRowLabel(
                title: title,
                symbolName: symbolName,
                contextLabel: nil,
                statusText: isActive ? text.active : text.inactive,
                statusIsActive: isActive
            )
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }

    private func roleRow(_ role: GlobalShortcutRole,
                         showsFeatureContext: Bool = true) -> some View {
        let title = role.title(l10n.s)
        let featureTitle = role.feature.hubTitle(l10n.s, hub: hub)
        let active = role.requiredEnableKeys.allSatisfy {
            UserDefaults.standard.bool(forKey: $0)
        }
        return ShortcutPreferenceRow(
            role: role,
            isEnabled: !role.isKeyboardBrightness || keyboardBrightnessShortcutsEnabled,
            label: title,
            symbolName: role.isKeyboardBrightness ? "keyboard" : role.feature.symbolName,
            contextLabel: showsFeatureContext && title != featureTitle ? featureTitle : nil,
            statusText: active ? text.active : text.inactive,
            statusIsActive: active,
            showsSuperKeyAlternative: superKey.isRunning,
            superKeyModifiers: superKey.modifiers,
            includeInactiveConflicts: true,
            additionalConflict: { shortcut in
                guard AppFeature.windowLayout.isAvailable else { return nil }
                return WindowLayoutService.shared.shortcutConflictTitle(shortcut)
            },
            onChange: {
                FeatureRuntime.shared.sync(role.availabilityFeatures)
            }
        )
    }

    private func expansionBinding(for feature: AppFeature) -> Binding<Bool> {
        Binding {
            expandedFeatures.contains(feature)
        } set: { expanded in
            if expanded {
                expandedFeatures.insert(feature)
            } else {
                expandedFeatures.remove(feature)
            }
        }
    }

    private func featureHasActiveShortcut(_ feature: AppFeature,
                                          roles: [GlobalShortcutRole]) -> Bool {
        if feature == .windowLayout {
            return UserDefaults.standard.bool(forKey: DefaultsKey.windowLayoutShortcutsEnabled)
                && WindowCommandShortcuts.registrations(for: windowCommands.configuration).isEmpty == false
        }
        return roles.contains { role in
            role.requiredEnableKeys.allSatisfy { UserDefaults.standard.bool(forKey: $0) }
        }
    }

    private var windowCommandCount: Int {
        WindowCommandSetKind.allCases.reduce(0) { total, kind in
            total + windowCommands.commands(kind).filter { !$0.isSeparator }.count
        }
    }

    private func windowSetTitle(_ kind: WindowCommandSetKind) -> String {
        let strings = WindowCommandStrings.localized(l10n.language)
        return kind == .horizontal ? strings.setHorizontal : strings.setVertical
    }

    private func groupTitle(_ group: FeatureGroup) -> String {
        switch group {
        case .windowsDock: return hub.groupWindowsDock
        case .mouseKeyboard: return hub.groupMouseKeyboard
        case .clipboardFiles: return hub.groupClipboardFiles
        case .sound: return hub.groupSound
        case .energyDisplay: return hub.groupEnergyDisplay
        case .tools: return hub.groupTools
        case .monitor: return hub.groupMonitor
        }
    }
}

private struct KeyboardBrightnessShortcutToggle: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var brightness = BrightnessService.shared
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(FeatureStrings.brightness(l10n.language).keyboardBrightnessShortcuts,
               isOn: $isEnabled)
            .onChange(of: isEnabled) { _, _ in
                brightness.syncWithPreferences()
            }
        if isEnabled, brightness.keyboardBrightnessShortcutRegistrationFailed {
            Text(l10n.s.shortcutUnavailable)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct CentralWindowCommandShortcutRow: View {
    @ObservedObject private var l10n = L10n.shared
    let command: WindowCommand
    let kind: WindowCommandSetKind
    let shortcutsEnabled: Bool
    let showsSuperKeyAlternative: Bool
    let superKeyModifiers: GlobalShortcutModifiers
    let superKeySource: SuperKeySource
    let text: ShortcutSettingsStrings
    @State private var errorText: String?
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                ShortcutRowLabel(
                    title: WindowCommandStrings.displayName(of: command, language: l10n.language),
                    symbolName: AppFeature.windowLayout.symbolName,
                    contextLabel: nil,
                    statusText: isActive ? text.active : text.inactive,
                    statusIsActive: isActive
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        ShortcutRecorderButton(
                            shortcut: command.shortcut ?? WindowCommandDefaults.maximize,
                            isEnabled: true,
                            waitingTitle: l10n.s.shortcutPressKeys,
                            emptyTitle: command.shortcut == nil ? l10n.s.shortcutNone : nil,
                            clearAction: clear,
                            notCapturedAction: { errorText = l10n.s.shortcutNotCaptured },
                            recordingChanged: { recording in
                                isRecording = recording
                                if recording { errorText = nil }
                            },
                            invalidAction: { errorText = l10n.s.shortcutInvalid },
                            captureAction: { errorText = WindowCommandShortcutEditing.save($0, for: command, in: kind) }
                        )
                        .frame(width: 108)
                        Button {
                            clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(command.shortcut == nil)
                        .help(l10n.s.shortcutClear)
                        .accessibilityLabel(l10n.s.shortcutClear)
                        if let fallback = defaultShortcut {
                            Button(l10n.s.shortcutReset) {
                                errorText = WindowCommandShortcutEditing.save(fallback, for: command, in: kind)
                            }
                            .disabled(command.effectiveShortcut == fallback)
                        }
                    }
                    if let alternative = superKeyAlternative {
                        Text(String(format: text.superKeyAlternativeFormat, alternative))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(alternative)
                    }
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if isRecording {
                Text(ShortcutRecordingCaption.text(l10n.s, canClear: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: l10n.language) { _, _ in errorText = nil }
    }

    private var defaultShortcut: GlobalShortcut? {
        WindowCommandShortcutEditing.defaultShortcut(for: command, in: kind)
    }

    private var isActive: Bool {
        shortcutsEnabled && command.effectiveShortcut != nil
    }

    private var superKeyAlternative: String? {
        guard showsSuperKeyAlternative, let shortcut = command.effectiveShortcut else { return nil }
        return shortcut.superKeyAlternative(
            sourceLabel: FeatureStrings.superKey(l10n.language).sourceLabel(superKeySource),
            superKeyModifiers: superKeyModifiers)
    }

    private func clear() {
        errorText = nil
        WindowCommandShortcutEditing.set(nil, for: command, in: kind)
    }
}
