// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import SystemConfiguration
import UniformTypeIdentifiers

/// Export, import and the optional sync folder for Window Layout settings.
/// The folder is any folder another program keeps in step between Macs
/// (iCloud Drive, Dropbox); this app only reads one file there at launch and
/// writes it after changes. Last writer wins, and when both sides changed
/// since the last sync a note says which copy was kept.
final class WindowLayoutSyncController: ObservableObject {
    static let shared = WindowLayoutSyncController()

    @Published private(set) var folderPath: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var conflictNote: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    private var observer: NSObjectProtocol?
    private var lastSnapshot: Snapshot?
    private var checkScheduled = false
    private var pendingWrite: DispatchWorkItem?

    /// What a change is measured against: every synced preference and the
    /// command sets' stored text.
    private struct Snapshot: Equatable {
        let settings: [String: WindowLayoutSyncSupport.SyncValue]
        let commands: String
    }

    private init() {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: DefaultsKey.windowLayoutSyncFolder) ?? ""
        folderPath = path.isEmpty ? nil : path
        let synced = defaults.double(forKey: DefaultsKey.windowLayoutSyncedAt)
        lastSyncedAt = synced > 0 ? Date(timeIntervalSince1970: synced) : nil
        let note = defaults.string(forKey: DefaultsKey.windowLayoutSyncNote) ?? ""
        conflictNote = note.isEmpty ? nil : note
    }

    private var strings: WindowCommandStrings { .localized(L10n.shared.language) }

    // MARK: Lifecycle

    /// Starts watching for changes (and reads the sync folder once) while the
    /// feature is installed; stops when it is not.
    func sync(active: Bool) {
        if active {
            guard observer == nil else { return }
            lastSnapshot = currentSnapshot()
            observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                              object: nil,
                                                              queue: .main) { [weak self] _ in
                self?.scheduleChangeCheck()
            }
            syncWithFolder(onLaunch: true)
        } else {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            pendingWrite?.cancel()
            pendingWrite = nil
        }
    }

    /// A burst of preference writes (an import touches many) collapses into
    /// one check on the next turn of the run loop.
    private func scheduleChangeCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.checkForChange()
        }
    }

    private func checkForChange() {
        let snapshot = currentSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        guard folderURL != nil else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncWithFolder(onLaunch: false) }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(settings: WindowLayoutSyncSupport.snapshot(of: .standard),
                 commands: UserDefaults.standard.string(forKey: DefaultsKey.windowLayoutCommands) ?? "")
    }

    // MARK: Folder

    private var folderURL: URL? {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var fileURL: URL? {
        folderURL?.appendingPathComponent(strings.syncFileName)
    }

    var folderDisplayPath: String? {
        folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    func lastSyncedText(strings: WindowCommandStrings) -> String {
        guard let lastSyncedAt else { return strings.neverSynced }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(format: strings.lastSyncedFormat,
                      formatter.localizedString(for: lastSyncedAt, relativeTo: Date()))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = strings.chooseSyncFolder.replacingOccurrences(of: "…", with: "")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url.path)
        syncWithFolder(onLaunch: true)
    }

    func stopSyncing() {
        setFolder(nil)
        dismissConflictNote()
    }

    func syncNow() {
        syncWithFolder(onLaunch: true)
    }

    func dismissConflictNote() {
        conflictNote = nil
        UserDefaults.standard.set("", forKey: DefaultsKey.windowLayoutSyncNote)
    }

    private func setFolder(_ path: String?) {
        folderPath = path
        UserDefaults.standard.set(path ?? "", forKey: DefaultsKey.windowLayoutSyncFolder)
        // A new folder starts a new history: nothing has been synced to it.
        setSyncedAt(nil)
    }

    private func setSyncedAt(_ time: TimeInterval?) {
        lastSyncedAt = time.map { Date(timeIntervalSince1970: $0) }
        UserDefaults.standard.set(time ?? 0, forKey: DefaultsKey.windowLayoutSyncedAt)
    }

    private func setConflictNote(_ note: String?) {
        conflictNote = note
        UserDefaults.standard.set(note ?? "", forKey: DefaultsKey.windowLayoutSyncNote)
    }

    /// Reads the folder's file and takes it when newer, or writes this Mac's
    /// settings when they are newer or the file does not exist yet.
    private func syncWithFolder(onLaunch: Bool) {
        guard let fileURL else { return }
        let defaults = UserDefaults.standard
        var localModifiedAt = defaults.double(forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        if localModifiedAt == 0 {
            // Never changed since the command sets arrived: date the setup now
            // so a file from another Mac that is older does not replace it.
            localModifiedAt = onLaunch ? 1 : Date().timeIntervalSince1970
        }
        let lastSynced = defaults.double(forKey: DefaultsKey.windowLayoutSyncedAt)
        let document = readDocument(at: fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path), document == nil {
            showStatus(strings.syncFolderUnavailable, isError: true)
            return
        }
        let (decision, conflict) = WindowLayoutSyncSupport.decide(localModifiedAt: localModifiedAt,
                                                                  fileModifiedAt: document?.modifiedAt,
                                                                  lastSyncedAt: lastSynced)
        switch decision {
        case .none:
            setSyncedAt(localModifiedAt)
        case .adoptFile:
            guard let document else { return }
            apply(document)
            defaults.set(document.modifiedAt, forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
            setSyncedAt(document.modifiedAt)
            if conflict {
                setConflictNote(String(format: strings.syncConflictFormat,
                                       document.device.isEmpty ? "?" : document.device,
                                       document.device.isEmpty ? "?" : document.device))
            }
        case .writeLocal:
            let written = max(localModifiedAt, 1)
            guard write(to: fileURL, modifiedAt: written) else {
                showStatus(strings.exportFailed, isError: true)
                return
            }
            setSyncedAt(written)
            if conflict, let document {
                setConflictNote(String(format: strings.syncConflictFormat,
                                       document.device.isEmpty ? "?" : document.device,
                                       Self.deviceName))
            }
        }
    }

    // MARK: Export and import

    func exportWithPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = strings.syncFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let modifiedAt = UserDefaults.standard.double(forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        if write(to: url, modifiedAt: modifiedAt > 0 ? modifiedAt : Date().timeIntervalSince1970) {
            showStatus(strings.exported, isError: false)
        } else {
            showStatus(strings.exportFailed, isError: true)
        }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let document = readDocument(at: url) else {
            showStatus(strings.importFailed, isError: true)
            return
        }
        // An import is a change made here: it dates itself now and goes on
        // to the sync folder like any other edit.
        apply(document)
        lastSnapshot = nil
        scheduleChangeCheck()
        showStatus(strings.imported, isError: false)
    }

    private func apply(_ document: WindowLayoutSyncSupport.Document) {
        WindowLayoutSyncSupport.apply(document.settings, to: .standard)
        if let commands = document.commands {
            WindowCommandStore.shared.replaceConfiguration(commands)
        }
        // Taken as the new baseline, so adopting a file is not itself seen
        // as a local change and written straight back.
        lastSnapshot = currentSnapshot()
        WindowLayoutService.shared.syncWithPreferences()
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    // MARK: Files

    private func readDocument(at url: URL) -> WindowLayoutSyncSupport.Document? {
        var result: WindowLayoutSyncSupport.Document?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [],
                                                         error: &coordinationError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            result = WindowLayoutSyncSupport.decode(data)
        }
        return result
    }

    private func write(to url: URL, modifiedAt: TimeInterval) -> Bool {
        let document = WindowLayoutSyncSupport.Document(
            modifiedAt: modifiedAt,
            device: Self.deviceName,
            settings: WindowLayoutSyncSupport.snapshot(of: .standard),
            commands: WindowCommandStore.shared.configuration)
        guard let data = WindowLayoutSyncSupport.encode(document) else { return false }
        var written = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { writeURL in
            written = (try? data.write(to: writeURL, options: .atomic)) != nil
        }
        return written
    }

    /// The Mac's own name, read locally (never a network lookup).
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
