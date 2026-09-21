// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Update preview window content: shows the next version's full changelog —
/// the same notes that ship with the release. Sealed fork: nothing is
/// downloaded; the footer carries a non-interactive notice instead of the
/// install button. Opened from Settings and the menu panel's update banner.
struct UpdatePreviewView: View {
    let version: String
    let notes: String?
    /// The release's own title and page, from the same GitHub Releases GET.
    var releaseTitle: String? = nil
    var releaseURL: URL? = nil
    var onCancel: () -> Void

    @ObservedObject private var l10n = L10n.shared

    private var release: ReleaseNotes {
        // The release body is the changelog section without its `## [..]` header;
        // synthesize one so the existing parser can structure it.
        let body = ReleaseNotes.inAppUpdateNotes(from: notes) ?? ""
        return ReleaseNotes.notes(for: version, changelog: "## [\(version)]\n\n" + body)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.s.tabReleaseNotes)
                        .font(.system(size: 22, weight: .bold))
                    if let releaseTitle, !releaseTitle.isEmpty {
                        Text(releaseTitle)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                ReleaseNotesContent(releases: [release])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(SealedBuild.updateNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if releaseURL != nil {
                    Button(SealedBuild.openReleasePageTitle) {
                        UpdateService.shared.openReleasePage()
                    }
                }
                Button(l10n.s.uninstallerCancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct UpdateSupportIntroView: View {
    var onFinish: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.openURL) private var openURL
    @State private var step: SupportUpdateIntroStep
    @State private var isMovingForward = true

    init(initialStep: SupportUpdateIntroStep = .support,
         onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .support:
                    supportContent
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 34)
            .clipped()

            Divider()

            footer
        }
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing)
                .combined(with: .opacity)
        )
    }

    private func move(to destination: SupportUpdateIntroStep, forward: Bool) {
        isMovingForward = forward
        withAnimation(.easeInOut(duration: 0.3)) {
            step = destination
        }
    }

    private var supportContent: some View {
        UpdateSupportContent()
    }

    private var footer: some View {
        ZStack {
            HStack {
                if let previous = step.previous {
                    Button(l10n.s.obBack) {
                        move(to: previous, forward: false)
                    }
                }
                Spacer()
                if let next = step.next {
                    Button(l10n.s.obContinue) {
                        move(to: next, forward: true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(l10n.s.supportIntroDoneButton) {
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            HStack(spacing: 6) {
                ForEach(SupportUpdateIntroStep.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step
                              ? Color.accentColor
                              : Color.secondary.opacity(0.24))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(16)
    }
}

private struct UpdateSupportContent: View {
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(Theme.spaceGradient)
                    .frame(width: 74, height: 74)
                Image(systemName: "heart.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(l10n.s.supportIntroTitle)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Yaya's Space: no donation link; the fork's attribution takes its place.
            Text(AppInfo.attribution)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)

            Text(l10n.s.supportIntroStarMessage)
                .font(.system(size: 13.5, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 2)

            Button {
                openURL(AppInfo.repositoryURL)
            } label: {
                Label(l10n.s.supportIntroStarButton, systemImage: "star.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// Renders one or more parsed release-note versions, each with a prominent
/// version header and the Added / Changed / Fixed sections, separated by a
/// divider so the newest update is easy to tell apart from older ones (the
/// newest is tinted with the accent colour). Shared by the What's New window and
/// the pre-install update preview so both look identical.
struct ReleaseNotesContent: View {
    let releases: [ReleaseNotes]

    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(releases.enumerated()), id: \.offset) { index, release in
                if index > 0 {
                    Divider().padding(.vertical, 18)
                }
                releaseBlock(release, isLatest: index == 0)
            }
        }
    }

    private func releaseBlock(_ release: ReleaseNotes, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("v\(release.version)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isLatest ? Color.accentColor : .primary)
                if let date = release.date {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if release.sections.isEmpty {
                fallbackNote
            } else {
                ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                    releaseSection(section)
                }
            }
        }
    }

    private var fallbackNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .center)
            Text(l10n.s.obWhatsNewFallback)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func releaseSection(_ section: ReleaseNoteSection) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !section.title.isEmpty {
                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                releaseItem(item, sectionTitle: section.title)
            }
        }
    }

    @ViewBuilder
    private func releaseItem(_ item: ReleaseNoteItem, sectionTitle: String) -> some View {
        switch item {
        case let .paragraph(text):
            Text(text)
                .font(.system(size: 12.8))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: iconName(for: sectionTitle))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, alignment: .center)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .image(image):
            if let nsImage = releaseNoteImage(image) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                    .accessibilityLabel(image.alt)
                    .padding(.leading, 27)
            }
        }
    }

    private func releaseNoteImage(_ image: ReleaseNoteImage) -> NSImage? {
        var path = image.path
        if let resourcesRange = path.range(of: "Resources/") {
            path = String(path[resourcesRange.lowerBound...])
        }
        if path.hasPrefix("Resources/") {
            path.removeFirst("Resources/".count)
        }
        let nsPath = path as NSString
        let ext = nsPath.pathExtension
        let name = (nsPath.deletingPathExtension as NSString).lastPathComponent
        let directory = nsPath.deletingLastPathComponent
        guard !name.isEmpty, !ext.isEmpty else { return nil }
        let subdirectory = directory.isEmpty || directory == "." ? nil : directory
        guard let url = Bundle.main.url(forResource: name,
                                        withExtension: ext,
                                        subdirectory: subdirectory) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func iconName(for title: String) -> String {
        switch title.lowercased() {
        case "added": return "plus.circle.fill"
        case "changed": return "slider.horizontal.3"
        case "fixed": return "checkmark.circle.fill"
        default: return "circle.fill"
        }
    }
}
