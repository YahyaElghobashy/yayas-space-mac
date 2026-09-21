// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Checks GitHub Releases for a newer version. Sealed fork: this is the only
/// network call in the app (one read-only GET through `SealedURLSession`), and
/// nothing is ever downloaded or installed; the UI shows a notice instead.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// Markdown release notes for the available update, shown in the pre-install
    /// preview. Set alongside `.available`; cleared otherwise.
    @Published private(set) var availableNotes: String?
    /// Sealed fork: what the GitHub Releases GET already returns about the
    /// available release (title, body, page), for the rich notice. Set
    /// alongside `.available`; cleared otherwise. Nothing is downloaded.
    @Published private(set) var availableRelease: ReleaseInfo?

    struct ReleaseInfo: Equatable {
        let version: String
        let title: String?
        let body: String?
        let pageURL: URL?

        /// The first few changelog lines with markdown headers, bullets and
        /// emphasis lightly stripped; "…" closes it when more follow.
        var excerpt: String? { UpdateService.changelogExcerpt(from: body) }
    }

    private let repository = "YahyaElghobashy/yayas-space-mac"
    private var refreshTimer: Timer?
    private var notifiedVersion: String?   // last release we posted a notification for

    private init() {}

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.autoCheckUpdates) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoCheckUpdates)
            configureAutomaticChecks()
        }
    }

    var includeBetaUpdates: Bool {
        get {
            if let explicit = UserDefaults.standard.object(forKey: DefaultsKey.includeBetaUpdates) as? Bool {
                return explicit
            }
            return AppInfo.isBeta
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.includeBetaUpdates)
        }
    }

    // MARK: - Scheduling

    /// Called at launch: checks shortly after start and then daily, if enabled.
    func startAutomaticChecks() {
        if AppInfo.isBeta && UserDefaults.standard.object(forKey: DefaultsKey.includeBetaUpdates) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKey.includeBetaUpdates)
        }
        // Sealed fork: the Developer variant is the build people actually run,
        // so it checks for real instead of simulating (nothing is installed
        // either way; a newer release only surfaces a notice).
        configureAutomaticChecks()
        if autoCheckEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.check(manual: false)
            }
        }
    }

    private func configureAutomaticChecks() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard autoCheckEnabled else { return }
        // Hourly (was daily). Combined with the activate / panel-open checks, a new
        // release surfaces within the hour instead of up to a day later.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
        timer.tolerance = 60 * 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Check

    func check(manual: Bool) {
        if case .checking = state { return }
        state = .checking

        let endpoint = includeBetaUpdates
            ? "https://api.github.com/repos/\(repository)/releases?per_page=10"
            : "https://api.github.com/repos/\(repository)/releases/latest"

        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Yaya's Space/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // The only network call in the sealed build. SealedURLSession refuses
        // any host other than api.github.com before a task is created.
        SealedURLSession.get(request) { [weak self] data, _, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lastChecked = Date()
                guard let data, error == nil else {
                    self.availableNotes = nil
                    self.availableRelease = nil
                    self.state = .failed(error?.localizedDescription ?? "-")
                    return
                }

                let releases: [GitHubRelease]
                if self.includeBetaUpdates {
                    releases = (try? JSONDecoder().decode([GitHubRelease].self, from: data)) ?? []
                } else if let single = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
                    releases = [single]
                } else {
                    releases = []
                }

                guard !releases.isEmpty else {
                    self.availableNotes = nil
                    self.availableRelease = nil
                    self.state = .failed(error?.localizedDescription ?? "-")
                    return
                }

                let candidates = releases.map { rel -> UpdateServiceSupport.ReleaseCandidate in
                    let asset = rel.assets.first { $0.name.hasSuffix(".dmg") }
                    return UpdateServiceSupport.ReleaseCandidate(
                        tagName: rel.tagName,
                        isPrerelease: rel.prerelease ?? false,
                        isDraft: rel.draft ?? false,
                        dmgURL: asset?.browserDownloadURL,
                        dmgExpectedBytes: asset?.size,
                        body: rel.body
                    )
                }

                if let chosen = UpdateServiceSupport.selectUpdate(
                    from: candidates,
                    currentVersion: AppInfo.upstreamVersion,
                    includeBetas: self.includeBetaUpdates
                ) {
                    let versionClean = chosen.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    self.availableNotes = ReleaseNotes.inAppUpdateNotes(from: chosen.body)
                    let source = releases.first { $0.tagName == chosen.tagName }
                    let title = source?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.availableRelease = ReleaseInfo(
                        version: versionClean,
                        title: (title?.isEmpty == false) ? title : nil,
                        body: chosen.body,
                        pageURL: source?.htmlURL)
                    self.state = .available(version: versionClean)
                    // Notify once per distinct release, not on every hourly re-check.
                    if !manual, versionClean != self.notifiedVersion {
                        self.notifiedVersion = versionClean
                        let s = L10n.shared.s
                        Notifier.post(title: s.updateNotifyTitle,
                                      body: "\(s.updateAvailablePrefix) \(versionClean)")
                    }
                } else {
                    self.availableNotes = nil
                    self.availableRelease = nil
                    self.state = .upToDate
                }
            }
        }
    }

    /// Re-checks only if the last check is stale — called when the app reactivates
    /// or the panel opens, so a new release surfaces promptly without hammering the
    /// API. The hourly timer is the floor; this makes it feel immediate.
    func checkIfStale(maxAge: TimeInterval = 15 * 60) {
        guard autoCheckEnabled else { return }
        if case .checking = state { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < maxAge { return }
        check(manual: false)
    }

    /// Opens the release page in the default browser. Only ever called from
    /// a click; the sealed build never fetches the page itself.
    func openReleasePage() {
        guard let url = availableRelease?.pageURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com"
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// First `maxLines` content lines of a release body with markdown
    /// headers, list markers, block quotes and bold/italic markers stripped;
    /// blank lines and the distribution footer are dropped.
    static func changelogExcerpt(from body: String?, maxLines: Int = 8) -> String? {
        guard let cleaned = ReleaseNotes.inAppUpdateNotes(from: body) else { return nil }
        var lines: [String] = []
        var truncated = false
        for raw in cleaned.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            while line.hasPrefix(">") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line.removeFirst(marker.count)
                line = "• " + line.trimmingCharacters(in: .whitespaces)
                break
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            guard !line.isEmpty else { continue }
            if lines.count == maxLines {
                truncated = true
                break
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + (truncated ? "\n…" : "")
    }

    // MARK: - Version compare

    /// True when `latest` is a higher semantic version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        UpdateServiceSupport.isNewer(latest, than: current)
    }
}

// MARK: - GitHub API shapes

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL?
    let prerelease: Bool?
    let draft: Bool?
    let assets: [Asset]
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
        case body
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
