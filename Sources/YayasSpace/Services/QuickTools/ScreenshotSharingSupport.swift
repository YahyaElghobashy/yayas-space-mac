// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum ScreenshotShareDuration: Int, CaseIterable, Codable, Identifiable {
    case oneHour = 3_600
    case sixHours = 21_600
    case twentyFourHours = 86_400

    var id: Int { rawValue }

    func title(_ strings: ScreenshotFeatureStrings) -> String {
        switch self {
        case .oneHour: strings.shareOneHour
        case .sixHours: strings.shareSixHours
        case .twentyFourHours: strings.shareTwentyFourHours
        }
    }
}

struct ScreenshotShareRecord: Codable, Equatable, Identifiable {
    let id: String
    let endpoint: URL
    let expiresAt: Date
    let deleteToken: String

    var url: URL {
        endpoint.appendingPathComponent("s", isDirectory: true)
            .appendingPathComponent(id, isDirectory: false)
    }
}

struct ScreenshotShareResponse: Decodable {
    let id: String
    let viewPath: String
    let expiresAt: String
    let deleteToken: String
}

enum ScreenshotSharingSupport {
    static let maximumUploadBytes = 25 * 1_024 * 1_024

    static func record(response: ScreenshotShareResponse,
                       endpoint: URL,
                       now: Date = Date()) -> ScreenshotShareRecord? {
        guard let expiresAt = expirationDate(response.expiresAt) else { return nil }
        guard response.id.range(of: "^[A-Za-z0-9_-]{32}$",
                                options: .regularExpression) != nil,
              response.deleteToken.range(of: "^[A-Za-z0-9_-]{43}$",
                                         options: .regularExpression) != nil,
              response.viewPath == "/s/\(response.id)",
              expiresAt > now,
              expiresAt <= now.addingTimeInterval(24 * 60 * 60 + 5 * 60)
        else { return nil }
        return ScreenshotShareRecord(id: response.id,
                                     endpoint: endpoint,
                                     expiresAt: expiresAt,
                                     deleteToken: response.deleteToken)
    }

    static func expirationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
