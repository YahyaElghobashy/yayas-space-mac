// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Yahya Elghobashy (Yaya's Space rebrand)

import Foundation

/// Static identity of the app, shared by UI, notifications and tooling.
///
/// Yaya's Space is a sealed, local-first fork of Vorssaint (by Pedro Gomes),
/// distributed under the same GPL-3.0-or-later licence. The upstream name,
/// icon, bundle id, signing identity, update feed and community links are
/// not used; only the attribution below refers to the upstream project.
enum AppInfo {
    static let name = "Yaya's Space"
    static let author = "Yahya Elghobashy"
    static let copyright = "© 2026 Yahya Elghobashy"
    static let websiteURL = URL(string: "https://github.com/YahyaElghobashy")!
    static let repositoryURL = URL(string: "https://github.com/YahyaElghobashy/yayas-space-mac")!

    // MARK: Upstream attribution (the only place the upstream name is shown)

    static let upstreamName = "Vorssaint"
    static let upstreamAuthor = "Pedro Gomes"
    /// Opened in the browser on a click only; the update check for upstream
    /// releases goes to api.github.com (see UpdateService.upstreamRepository).
    static let upstreamRepositoryURL = URL(string: "https://github.com/vorssaint/vorssaint-utils")!
    static let attributionShort = "Based on"
    static let attribution = "Yaya's Space is a sealed, local-first fork of \(upstreamName) by \(upstreamAuthor), "
        + "released under GPL-3.0-or-later. Not affiliated with or endorsed by \(upstreamName)."
    static let supportHeading = "A personal fork, kept local"
    static let upstreamHeading = "Upstream inspiration"
    static let upstreamMessage = "\(upstreamName) is the project this app grew out of. "
        + "Its releases are watched read-only so new ideas can be brought over by hand; nothing is installed from it."
    static let upstreamButtonTitle = "Open \(upstreamName) on GitHub"

    /// The bundle version. The fallback only applies to the bare binary
    /// (e.g. `--selftest`), never the shipped app, which reads its Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The version the update check compares against our own GitHub Releases:
    /// `version` minus any `-sealed.N` / `-dev` style suffix build.sh may stamp
    /// on a local build, so "1.0.0-dev.3" never counts as a pre-release of 1.0.0
    /// and the release it was built from is not offered as an update forever.
    static var releaseVersion: String {
        let v = version
        for suffix in ["-\(SealedBuild.versionSuffix)", "-dev"] {
            if let range = v.range(of: suffix) { return String(v[..<range.lowerBound]) }
        }
        return v
    }

    /// Kept for call sites that predate the rebrand: same as `releaseVersion`.
    static var upstreamVersion: String { releaseVersion }

    /// True for the local "Yaya's Space (Developer)" build (bundle id ends in `.dev`).
    /// It is never published and never auto-updates; all work is tested here first.
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// True when the current version is a pre-release (e.g. 1.1.0-beta.1 or 1.1.0-rc.1).
    static var isBeta: Bool {
        if isDeveloperBuild && UserDefaults.standard.bool(forKey: DefaultsKey.simulateBetaUI) {
            return true
        }
        let v = version.lowercased()
        return v.contains("-beta") || v.contains("-rc") || v.contains("-alpha")
    }

    /// The git commit a Developer build was compiled from, e.g. "ed2ebba · 2026-06-15 21:30"
    /// (or with a "-dirty" suffix on the SHA for uncommitted changes). build.sh stamps
    /// this into the Developer bundle only, so you can confirm at a glance that the
    /// running dev app matches the source you are about to change. nil in the official app.
    static var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "YayasSpaceBuildCommit") as? String
    }
}
