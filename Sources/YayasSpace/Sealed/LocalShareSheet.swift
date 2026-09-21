// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Sealed fork: the upstream "Create link" actions uploaded a capture to a
// Yaya's Space server and handed back a temporary URL. This build never uploads
// anything itself; wherever that action lived, a "Share…" button now opens
// the macOS share sheet (NSSharingServicePicker) on the local PNG / MP4, so
// the person picks the destination (AirDrop, Messages, Mail, …) and macOS
// does the sending. No socket is opened by Yaya's Space.

import AppKit
import SwiftUI

/// Owns the picker while the sheet is up and reports when it goes away, so a
/// transient panel (the quick preview) can hold off its auto-dismiss.
final class LocalSharePresenter: NSObject, NSSharingServicePickerDelegate {
    private var picker: NSSharingServicePicker?
    private var onDismiss: ((_ chosen: Bool) -> Void)?

    func present(_ urls: [URL], from view: NSView, onDismiss: ((_ chosen: Bool) -> Void)? = nil) {
        guard view.window != nil, !urls.isEmpty else {
            onDismiss?(false)
            return
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        self.picker = picker
        self.onDismiss = onDismiss
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        picker = nil
        let callback = onDismiss
        onDismiss = nil
        if service != nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        callback?(service != nil)
    }
}

enum LocalShareSheet {
    /// Where in-memory captures are written so the share sheet has a real
    /// file to hand over. Files older than a day are swept on every use.
    static func stagingDirectory() -> URL? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent("Yaya's Space Shared Captures", isDirectory: true)
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        if let files = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for file in files where (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture < cutoff {
                try? manager.removeItem(at: file)
            }
        }
        return folder
    }

    /// Writes PNG bytes to the staging folder under a screenshot-style name
    /// and returns the file to share, or nil when the write failed.
    static func stagePNG(_ data: Data, fileNamePrefix: String) -> URL? {
        guard let folder = stagingDirectory() else { return nil }
        let name = ScreenshotSupport.fileName(prefix: fileNamePrefix, date: Date())
        let url = folder.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Hosts the invisible view the share sheet is anchored to. SwiftUI creates
/// and owns that view, so a button reaches whichever one is on screen right
/// now through the box.
struct LocalShareAnchor: NSViewRepresentable {
    final class Box {
        fileprivate weak var view: NSView?
        private let presenter = LocalSharePresenter()

        /// True when a picker was shown; false when there was no window yet.
        @discardableResult
        func present(_ urls: [URL], onDismiss: ((_ chosen: Bool) -> Void)? = nil) -> Bool {
            guard let view else {
                onDismiss?(false)
                return false
            }
            presenter.present(urls, from: view, onDismiss: onDismiss)
            return true
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
