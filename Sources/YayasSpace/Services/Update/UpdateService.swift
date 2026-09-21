// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// Checks GitHub Releases for a newer version of Yaya's Space, and separately
/// whether the upstream project this fork is based on (Vorssaint) has shipped
/// a new release worth a look. Sealed fork: both are read-only GETs to
/// api.github.com through `SealedURLSession`, and nothing is ever downloaded
/// or installed; the UI shows a notice instead.
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

    /// "Upstream inspiration": the latest upstream release when its tag differs
    /// from the one last dismissed, so the notice shows once per upstream
    /// release. nil when there is nothing new (or the check has not run).
    @Published private(set) var upstreamRelease: ReleaseInfo?

    /// Our own releases. Yaya's Space ships as source (rebuild to adopt), so a
    /// release without a .dmg asset still counts.
    private let repository = "YahyaElghobashy/yayas-space-mac"
    /// The project this fork is based on. Read-only, same host, same toggle;
    /// nothing from it is ever installed. Its releases are compared against
    /// `lastSeenUpstreamTag`, never against our own version.
    static let upstreamRepository = "vorssaint/vorssaint-utils"
    private var refreshTimer: Timer?
    private var notifiedVersion: String?   // last release we posted a notification for
    private var upstreamCheckInFlight = false
    private var upstreamTag: String?       // raw tag behind `upstreamRelease`, as GitHub spells it

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

        let request = Self.releasesRequest(endpoint)

        // One of the two update GETs in the sealed build (the other is
        // checkUpstream, same host, same toggle). SealedURLSession refuses any
        // host other than api.github.com before a task is created.
        checkUpstream()
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
                    currentVersion: AppInfo.releaseVersion,
                    includeBetas: self.includeBetaUpdates,
                    requireAsset: false
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

    private static func releasesRequest(_ endpoint: String) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("YayasSpace/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: - Upstream inspiration

    /// The upstream tag the person last dismissed (or that was current when
    /// the notice was first shown), so each upstream release is surfaced once.
    private var lastSeenUpstreamTag: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.lastSeenUpstreamTag) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.lastSeenUpstreamTag) }
    }

    /// Fetches the latest upstream release (stable only, `releases/latest`)
    /// and publishes it when its tag is one we have not shown before. Runs
    /// alongside every own-update check, under the same auto-check toggle.
    private func checkUpstream() {
        guard !upstreamCheckInFlight else { return }
        upstreamCheckInFlight = true
        let endpoint = "https://api.github.com/repos/\(Self.upstreamRepository)/releases/latest"
        SealedURLSession.get(Self.releasesRequest(endpoint)) { [weak self] data, _, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.upstreamCheckInFlight = false
                guard let data, error == nil,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      release.draft != true
                else { return }
                let tag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty, tag != self.lastSeenUpstreamTag else { return }
                let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.upstreamTag = tag
                self.upstreamRelease = ReleaseInfo(
                    version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
                    title: (title?.isEmpty == false) ? title : nil,
                    body: release.body,
                    pageURL: release.htmlURL)
            }
        }
    }

    /// Hides the upstream notice until the next upstream release.
    func dismissUpstreamRelease() {
        if let upstreamTag { lastSeenUpstreamTag = upstreamTag }
        upstreamTag = nil
        upstreamRelease = nil
    }

    /// Opens the upstream release page in the browser (click only).
    func openUpstreamReleasePage() {
        guard let url = upstreamRelease?.pageURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com"
        else { return }
        NSWorkspace.shared.open(url)
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
