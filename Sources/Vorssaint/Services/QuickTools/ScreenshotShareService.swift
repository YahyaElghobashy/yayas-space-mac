// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

// Sealed fork: link sharing uploaded the capture to a Vorssaint server. The
// upload, the delete request and the endpoint are gone; `createLink` refuses,
// no record is ever created, and the Settings section that offered it is
// hidden. The type stays so the editors compile unchanged.

enum ScreenshotShareError: Error {
    case invalidImage
    case invalidEndpoint
    case unavailable
    case rejected
    case invalidResponse
    case localStorage
}

@MainActor
final class ScreenshotShareService: ObservableObject {
    static let shared = ScreenshotShareService()

    /// Always empty in the sealed build: no link can be created.
    @Published private(set) var records: [ScreenshotShareRecord] = []

    private init() {}

    func refresh(now: Date = Date()) {
        records = []
    }

    func createLink(pngData: Data,
                    duration: ScreenshotShareDuration) async throws -> ScreenshotShareRecord {
        throw ScreenshotShareError.unavailable
    }

    func delete(_ record: ScreenshotShareRecord) async throws {
        records.removeAll { $0.id == record.id }
    }

    @discardableResult
    func copy(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(url.absoluteString, forType: .string)
    }
}
