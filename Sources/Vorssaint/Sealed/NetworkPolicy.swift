// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Sealed fork: every outbound request this build makes is a read-only HTTPS
// GET that passes through this file. Uploads, feedback, the in-app speed
// test, third-party publisher (Sparkle) feeds, Homebrew analytics, showcase
// media and the DMG installer were removed at the source. This file is the
// single choke point, so the policy is enforced in code as well as by
// Tools/check-sealed.sh.

import Foundation

enum NetworkPolicy {
    /// The only hosts a request may be sent to, and why:
    ///
    /// - `api.github.com` — the Vorssaint update check (GitHub Releases JSON);
    ///   nothing is downloaded or installed, a notice is shown instead.
    /// - `itunes.apple.com` — App Updates: App Store lookup by bundle id.
    /// - `uclient-api.itunes.apple.com` — App Updates: App Store lookup by
    ///   store id (gives the Mac build and minimum OS for universal listings).
    /// - `formulae.brew.sh` — App Updates: the public Homebrew cask catalog
    ///   (`/api/cask.json` only; the analytics endpoint stays removed).
    ///
    /// One deliberate exception sits outside this set: the radial menu's
    /// "Fetch Website Icon" button asks for `/favicon.ico` on exactly the host
    /// the person typed, through `SealedURLSession.get(_:allowingHost:)`, for
    /// that one click only (GET, 5 s, 2 MB, same-origin redirects). The
    /// allowlist itself never changes at runtime.
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "itunes.apple.com",
        "uclient-api.itunes.apple.com",
        "formulae.brew.sh",
    ]

    /// Only https to an allowed host, and only a GET, is ever sent.
    static func allows(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return false }
        return isBodilessGet(request)
    }

    /// The favicon exception: the request's host must be exactly `host`
    /// (case-insensitive), the scheme http or https, and the method a
    /// body-less GET. Nothing else is consulted, in particular not the
    /// static allowlist.
    static func allows(_ request: URLRequest, forExactHost host: String) -> Bool {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let requestHost = url.host?.lowercased(),
              !requestHost.isEmpty,
              requestHost == host.lowercased()
        else { return false }
        return isBodilessGet(request)
    }

    private static func isBodilessGet(_ request: URLRequest) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        return method == "GET" && request.httpBody == nil && request.httpBodyStream == nil
    }
}

enum SealedNetworkError: LocalizedError {
    case blocked(host: String?)
    case tooLarge
    case rejected(status: Int)

    var errorDescription: String? {
        switch self {
        case let .blocked(host):
            return "Sealed build: request to \(host ?? "unknown host") is not allowed"
        case .tooLarge:
            return "Sealed build: response exceeded the byte limit"
        case let .rejected(status):
            return "Sealed build: server answered \(status)"
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

    /// The per-call allowance for the favicon fetch: one GET to exactly
    /// `host` (the host of the URL the person typed), 5 s end to end, at most
    /// `byteLimit` bytes (the transfer is cancelled past it, never buffered),
    /// redirects only within the same scheme/host/port. Any other host, or
    /// anything but a GET, is refused before a task exists.
    static func get(_ request: URLRequest,
                    allowingHost host: String,
                    byteLimit: Int = 2 * 1_024 * 1_024,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        guard NetworkPolicy.allows(request, forExactHost: host) else {
            completion(.failure(SealedNetworkError.blocked(host: request.url?.host)))
            return
        }
        var sealed = request
        sealed.httpMethod = "GET"
        sealed.httpBody = nil
        sealed.httpBodyStream = nil
        sealed.cachePolicy = .reloadIgnoringLocalCacheData
        sealed.timeoutInterval = 5
        BoundedDownload(request: sealed, byteLimit: byteLimit, completion: completion).start()
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            self.scheme = scheme
            self.host = host
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    /// A delegate-driven task so the byte cap applies while the body streams
    /// in, and redirects can be checked against the origin that was allowed.
    private final class BoundedDownload: NSObject, URLSessionDataDelegate {
        private let request: URLRequest
        private let byteLimit: Int
        private let completion: (Result<Data, Error>) -> Void
        private let origin: Origin?
        private var session: URLSession?
        private var data = Data()
        private var finished = false

        init(request: URLRequest, byteLimit: Int, completion: @escaping (Result<Data, Error>) -> Void) {
            self.request = request
            self.byteLimit = byteLimit
            self.completion = completion
            origin = request.url.flatMap(Origin.init)
        }

        func start() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(.failure(SealedNetworkError.rejected(status: 0)))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completionHandler(.cancel)
                finish(.failure(SealedNetworkError.rejected(status: http.statusCode)))
                return
            }
            guard response.expectedContentLength <= 0
                    || response.expectedContentLength <= Int64(byteLimit) else {
                completionHandler(.cancel)
                finish(.failure(SealedNetworkError.tooLarge))
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            guard data.count + chunk.count <= byteLimit else {
                dataTask.cancel()
                finish(.failure(SealedNetworkError.tooLarge))
                return
            }
            data.append(chunk)
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection newResponse: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let redirectURL = request.url,
                  let origin, Origin(redirectURL) == origin,
                  (request.httpMethod ?? "GET").uppercased() == "GET"
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
            } else {
                finish(.success(data))
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            session?.invalidateAndCancel()
            session = nil
            completion(result)
        }
    }
}

enum SealedBuild {
    /// Shown wherever the upstream app offered to download and install an
    /// update. This fork never downloads anything; rebuild it from source.
    static let updateNotice = "Sealed build — no auto-install. Rebuild the fork to adopt."
    static let openReleasePageTitle = "Open release page"
    static let versionSuffix = "sealed"
    /// App Updates → "Include other installed apps": in this build the source
    /// is the public Homebrew cask catalog only (no publisher feeds).
    static let onlineCatalogCaption = "Checks the public Homebrew cask catalog (formulae.brew.sh). "
        + "The app’s own updater installs the update. Publisher feeds are not queried in this build."
}
