// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Sealed fork: the only outbound network traffic this build may produce is a
// read-only HTTPS GET to api.github.com for the update check. Every other
// network path (uploads, feedback, speed test, catalogs, favicons, showcase
// media, the DMG installer) was removed at the source. This file is the single
// choke point the remaining request goes through, so the policy is enforced
// in code as well as by Tools/check-sealed.sh.

import Foundation

enum NetworkPolicy {
    static let allowedHosts: Set<String> = ["api.github.com"]

    /// Only https to an allowed host, and only a GET, is ever sent.
    static func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        return method == "GET" && request.httpBody == nil && request.httpBodyStream == nil
    }
}

enum SealedNetworkError: LocalizedError {
    case blocked(host: String?)

    var errorDescription: String? {
        switch self {
        case let .blocked(host):
            return "Sealed build: request to \(host ?? "unknown host") is not allowed"
        }
    }
}

/// The one URLSession wrapper in the sealed build. A request whose host is not
/// in `NetworkPolicy.allowedHosts` never reaches the network: the completion
/// runs with `SealedNetworkError.blocked` and no task is created.
enum SealedURLSession {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func get(_ request: URLRequest,
                    completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        guard NetworkPolicy.allows(request) else {
            completion(nil, nil, SealedNetworkError.blocked(host: request.url?.host))
            return
        }
        var sealed = request
        sealed.httpMethod = "GET"
        session.dataTask(with: sealed, completionHandler: completion).resume()
    }
}

enum SealedBuild {
    /// Shown wherever the upstream app offered to download and install an
    /// update. This fork never downloads anything; rebuild it from source.
    static let updateNotice = "Sealed build — update by rebuilding the fork"
    static let versionSuffix = "sealed"
}
