// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy

import AppKit
import SystemConfiguration
import UniformTypeIdentifiers

/// Export, import and the optional sync folder for Window Layout settings.
/// The folder is any folder another program keeps in step between Macs
/// (iCloud Drive, Dropbox); this app only reads one file there a few seconds
/// after launch and writes it after changes. Last writer wins, and when both
/// sides changed since the last sync a note says which copy was kept.
///
/// Every file read and write runs on one serial background queue: the folder
/// can sit on a cloud drive whose file is still downloading, and a
/// coordinated read of such a file waits for the download. Only applying the
/// preferences a file brings hops back to the main thread. A file that is not
/// downloaded yet is never waited for: the system is asked to fetch it (the
/// folder's own client, such as iCloud Drive or Dropbox, does the download;
/// this app adds no network code) and it is looked at again a little later,
/// a limited number of times, with a note in Settings either way.
final class WindowLayoutSyncController: ObservableObject {
    static let shared = WindowLayoutSyncController()

    @Published private(set) var folderPath: String?
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var conflictNote: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false

    /// How long after the feature starts the first folder sync waits, so it
    /// never runs during launch or inside a preference sync.
    private static let firstSyncDelay: TimeInterval = 4
    /// A burst of writes (an import touches many keys) is checked once.
    private static let changeDebounce: TimeInterval = 0.5
    /// A change reaches the folder this long after the last edit.
    private static let writeDelay: TimeInterval = 1
    /// While the folder's file is still downloading, look again this often,
    /// a limited number of times; then Settings says the sync stopped
    /// trying. Sync Now, a change or the next launch start over.
    private static let downloadRetryDelay: TimeInterval = 30
    private static let downloadRetryLimit = 20

    private let io = DispatchQueue(label: "com.yahyaelghobashy.yayasspace.window-layout-sync", qos: .utility)
    private var keyObserver: WindowLayoutDefaultsObserver?
    private var isActive = false
    private var lastSnapshot: Snapshot?
    private var pendingCheck: DispatchWorkItem?
    private var pendingSync: DispatchWorkItem?
    private var syncInFlight = false
    private var syncRequestedAgain = false
    private var downloadRetries = 0
    /// Whether the status line shows a sync result (a later good sync clears
    /// it) rather than the result of an export or import.
    private var statusFromSync = false

    /// What a change is measured against: every synced preference and the
    /// command sets' stored text.
    private struct Snapshot: Equatable {
        let settings: [String: WindowLayoutSyncSupport.SyncValue]
        let commands: String
    }

    /// Everything a folder sync needs, gathered on the main thread so the
    /// background work never touches app state.
    private struct FolderSyncRequest {
        let fileURL: URL
        /// The real time of this Mac's last change; 0 when never changed.
        let localModifiedAt: TimeInterval
        let lastSyncedAt: TimeInterval
        let local: WindowLayoutSyncSupport.Document
    }

    private enum FolderSyncOutcome {
        case inStep(baseline: TimeInterval)
        case wrote(baseline: TimeInterval, conflictWith: String?)
        case adopt(WindowLayoutSyncSupport.Document, conflict: Bool)
        case waitingForDownload
        case unavailable
        case writeFailed
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

    /// Starts watching the synced preferences while the feature is installed
    /// and schedules one folder sync a few seconds later; stops when it is
    /// not. Cheap and idempotent, because the engine calls it on every
    /// preference sync: it never reads or writes a file itself.
    func sync(active: Bool) {
        if active {
            guard !isActive else { return }
            isActive = true
            lastSnapshot = currentSnapshot()
            keyObserver = WindowLayoutDefaultsObserver(keys: WindowLayoutSyncSupport.observedKeys) { [weak self] in
                self?.scheduleChangeCheck()
            }
            scheduleFolderSync(after: Self.firstSyncDelay)
        } else {
            guard isActive else { return }
            isActive = false
            keyObserver = nil
            pendingCheck?.cancel()
            pendingCheck = nil
            pendingSync?.cancel()
            pendingSync = nil
        }
    }

    /// Key-value observing reports on the writing thread; the check itself
    /// runs on the main thread once the writes have settled.
    private func scheduleChangeCheck() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.checkForChange() }
            self.pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.changeDebounce, execute: work)
        }
    }

    private func checkForChange() {
        pendingCheck = nil
        let snapshot = currentSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        guard folderURL != nil else { return }
        downloadRetries = 0
        scheduleFolderSync(after: Self.writeDelay)
    }

    private func scheduleFolderSync(after delay: TimeInterval) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSync = nil
            self?.requestFolderSync()
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        folderURL?.appendingPathComponent(WindowLayoutSyncSupport.fileName)
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
        downloadRetries = 0
        requestFolderSync()
    }

    func stopSyncing() {
        setFolder(nil)
        dismissConflictNote()
        if statusFromSync { clearStatus() }
    }

    func syncNow() {
        downloadRetries = 0
        requestFolderSync()
    }

    func dismissConflictNote() {
        conflictNote = nil
        UserDefaults.standard.set("", forKey: DefaultsKey.windowLayoutSyncNote)
    }

    private func setFolder(_ path: String?) {
        folderPath = path
        UserDefaults.standard.set(path ?? "", forKey: DefaultsKey.windowLayoutSyncFolder)
        // A new folder starts a new history: nothing has been synced to it.
        UserDefaults.standard.set(0.0, forKey: DefaultsKey.windowLayoutSyncedAt)
        lastSyncedAt = nil
    }

    /// Notes a finished sync: the change time both sides now share, which
    /// the next sync measures changes against, and when it happened.
    private func recordSync(baseline: TimeInterval) {
        UserDefaults.standard.set(baseline, forKey: DefaultsKey.windowLayoutSyncedAt)
        lastSyncedAt = Date()
        if statusFromSync { clearStatus() }
    }

    private func setConflictNote(_ note: String?) {
        conflictNote = note
        UserDefaults.standard.set(note ?? "", forKey: DefaultsKey.windowLayoutSyncNote)
    }

    /// Reads the folder's file and takes it when newer, or writes this Mac's
    /// settings when they are newer or the file does not exist yet. Gathers
    /// its inputs here, does the file work on the background queue and
    /// comes back to apply the result. One sync at a time; a request made
    /// while one runs is served right after it.
    private func requestFolderSync() {
        guard isActive, let fileURL else { return }
        if syncInFlight {
            syncRequestedAgain = true
            return
        }
        syncInFlight = true
        let defaults = UserDefaults.standard
        let localModifiedAt = defaults.double(forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        let request = FolderSyncRequest(fileURL: fileURL,
                                        localModifiedAt: localModifiedAt,
                                        lastSyncedAt: defaults.double(forKey: DefaultsKey.windowLayoutSyncedAt),
                                        local: localDocument(modifiedAt: localModifiedAt))
        io.async { [weak self] in
            let outcome = Self.performFolderSync(request)
            DispatchQueue.main.async { self?.finishFolderSync(outcome, request: request) }
        }
    }

    /// Background queue only: never touches the controller or the store.
    private static func performFolderSync(_ request: FolderSyncRequest) -> FolderSyncOutcome {
        let fileURL = request.fileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .unavailable }

        let document: WindowLayoutSyncSupport.Document?
        switch readiness(of: fileURL) {
        case .waitingForDownload:
            // Asks the system to bring the file to this Mac; the folder's
            // own client does the download, and the next look reads it.
            // Asking again on every look is harmless.
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            return .waitingForDownload
        case .missing:
            document = nil
        case .ready:
            guard let read = readDocument(at: fileURL) else { return .unavailable }
            document = read
        }
        let (decision, conflict) = WindowLayoutSyncSupport.decide(localModifiedAt: request.localModifiedAt,
                                                                  fileModifiedAt: document?.modifiedAt,
                                                                  lastSyncedAt: request.lastSyncedAt)
        switch decision {
        case .none:
            return .inStep(baseline: request.localModifiedAt)
        case .adoptFile:
            guard let document else { return .unavailable }
            return .adopt(document, conflict: conflict)
        case .writeLocal:
            guard write(request.local, to: fileURL) else { return .writeFailed }
            let otherDevice = document.map { $0.device.isEmpty ? "?" : $0.device }
            return .wrote(baseline: request.localModifiedAt, conflictWith: conflict ? otherDevice : nil)
        }
    }

    private func finishFolderSync(_ outcome: FolderSyncOutcome, request: FolderSyncRequest) {
        syncInFlight = false
        defer {
            if syncRequestedAgain {
                syncRequestedAgain = false
                requestFolderSync()
            }
        }
        // The folder was changed or dropped while the file work ran: the
        // result belongs to a folder this Mac no longer syncs with.
        guard request.fileURL == fileURL else { return }
        let defaults = UserDefaults.standard
        if case .waitingForDownload = outcome {} else { downloadRetries = 0 }
        switch outcome {
        case .inStep(let baseline):
            recordSync(baseline: baseline)
        case .wrote(let baseline, let otherDevice):
            recordSync(baseline: baseline)
            if let otherDevice {
                setConflictNote(String(format: strings.syncConflictFormat, otherDevice, Self.deviceName))
            }
        case .adopt(let document, let conflict):
            // Something changed here while the file was being read: this
            // Mac's change is the newer one now, so sync again instead.
            guard isActive,
                  defaults.double(forKey: DefaultsKey.windowLayoutSettingsModifiedAt) == request.localModifiedAt
            else {
                syncRequestedAgain = true
                break
            }
            apply(document)
            defaults.set(document.modifiedAt, forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
            recordSync(baseline: document.modifiedAt)
            if conflict {
                let device = document.device.isEmpty ? "?" : document.device
                setConflictNote(String(format: strings.syncConflictFormat, device, device))
            }
        case .waitingForDownload:
            if downloadRetries < Self.downloadRetryLimit {
                showStatus(strings.syncWaitingForDownload, isError: false, fromSync: true)
                if pendingSync == nil {
                    downloadRetries += 1
                    scheduleFolderSync(after: Self.downloadRetryDelay)
                }
            } else {
                // The last look still found it not downloaded: say so
                // instead of showing "Waiting" for good.
                showStatus(strings.syncDownloadStopped, isError: true, fromSync: true)
            }
        case .unavailable:
            showStatus(strings.syncFolderUnavailable, isError: true, fromSync: true)
        case .writeFailed:
            showStatus(strings.exportFailed, isError: true, fromSync: true)
        }
    }

    // MARK: Export and import

    func exportWithPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = WindowLayoutSyncSupport.fileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let modifiedAt = UserDefaults.standard.double(forKey: DefaultsKey.windowLayoutSettingsModifiedAt)
        let document = localDocument(modifiedAt: modifiedAt > 0 ? modifiedAt : Date().timeIntervalSince1970)
        io.async { [weak self] in
            let written = Self.write(document, to: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.showStatus(written ? self.strings.exported : self.strings.exportFailed,
                                isError: !written, fromSync: false)
            }
        }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        io.async { [weak self] in
            let document = Self.readDocument(at: url)
            DispatchQueue.main.async { self?.finishImport(document) }
        }
    }

    private func finishImport(_ document: WindowLayoutSyncSupport.Document?) {
        guard let document else {
            showStatus(strings.importFailed, isError: true, fromSync: false)
            return
        }
        // An import is a change made here: it dates itself now and goes on
        // to the sync folder like any other edit.
        apply(document)
        lastSnapshot = nil
        scheduleChangeCheck()
        showStatus(strings.imported, isError: false, fromSync: false)
    }

    /// Main thread: preferences and the live command sets.
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

    /// This Mac's settings as a file, read on the main thread.
    private func localDocument(modifiedAt: TimeInterval) -> WindowLayoutSyncSupport.Document {
        WindowLayoutSyncSupport.Document(modifiedAt: modifiedAt,
                                         device: Self.deviceName,
                                         settings: WindowLayoutSyncSupport.snapshot(of: .standard),
                                         commands: WindowCommandStore.shared.configuration)
    }

    private func showStatus(_ message: String, isError: Bool, fromSync: Bool) {
        statusMessage = message
        statusIsError = isError
        statusFromSync = fromSync
    }

    private func clearStatus() {
        statusMessage = nil
        statusIsError = false
        statusFromSync = false
    }

    // MARK: Files (background queue)

    /// Asks the file system, without opening the file, whether reading it
    /// would have to wait for a download.
    private static func readiness(of url: URL) -> WindowLayoutSyncSupport.FileReadiness {
        var info = stat()
        let exists = lstat(url.path, &info) == 0
        // SF_DATALESS: a placeholder whose content lives with a cloud provider.
        let isDataless = exists && (info.st_flags & 0x4000_0000) != 0
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        return WindowLayoutSyncSupport.readiness(exists: exists,
                                                 isDataless: isDataless,
                                                 isUbiquitous: values?.isUbiquitousItem ?? false,
                                                 downloadStatus: values?.ubiquitousItemDownloadingStatus)
    }

    private static func readDocument(at url: URL) -> WindowLayoutSyncSupport.Document? {
        var result: WindowLayoutSyncSupport.Document?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [],
                                                         error: &coordinationError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            result = WindowLayoutSyncSupport.decode(data)
        }
        return result
    }

    private static func write(_ document: WindowLayoutSyncSupport.Document, to url: URL) -> Bool {
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
