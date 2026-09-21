// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yahya Elghobashy
//
// Yaya's Space: the "upstream inspiration" notice. UpdateService also reads
// the latest release of the project this fork is based on (read-only, same
// host, same auto-check toggle as our own update check) and remembers the
// last tag it showed, so each upstream release is surfaced once. Nothing is
// downloaded; the only action opens the release page in the browser.

import SwiftUI

/// Compact banner for the menu panel, shown under the app's own update
/// banner in the same slot.
struct UpstreamInspirationBanner: View {
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        if let release = updates.upstreamRelease {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.brandPlum)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: SealedBuild.upstreamNoticeFormat, release.version))
                            .font(.system(size: 11.5, weight: .semibold))
                        if let title = release.title {
                            Text(title)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if release.pageURL != nil {
                        Button {
                            updates.openUpstreamReleasePage()
                        } label: {
                            Label(SealedBuild.openReleasePageTitle, systemImage: "arrow.up.right.square")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button(SealedBuild.upstreamDismissTitle) {
                        updates.dismissUpstreamRelease()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brandPaper.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.brandPlum.opacity(0.25))
            )
            .foregroundStyle(Color(nsColor: .textColor))
            .colorScheme(.light)
        }
    }
}

/// The same notice as a Settings row, placed with the update status in the
/// Updates section of About.
struct UpstreamInspirationRow: View {
    @ObservedObject private var updates = UpdateService.shared

    var body: some View {
        if let release = updates.upstreamRelease {
            VStack(alignment: .leading, spacing: 4) {
                Label(String(format: SealedBuild.upstreamNoticeFormat, release.version),
                      systemImage: "lightbulb.fill")
                    .font(.callout.weight(.semibold))
                if let title = release.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let excerpt = release.excerpt {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if release.pageURL != nil {
                        Button(SealedBuild.openReleasePageTitle) {
                            updates.openUpstreamReleasePage()
                        }
                        .controlSize(.small)
                    }
                    Button(SealedBuild.upstreamDismissTitle) {
                        updates.dismissUpstreamRelease()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
