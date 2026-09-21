// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Sealed fork: the speed-test row shared by the Network card and the
/// network metric detail. Two local tools instead of an in-app test: run
/// Apple's networkQuality and show its numbers inline, or open Speedtest.app.
struct NetworkQualityControls<Trailing: View>: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var tool = NetworkQualityTool.shared
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var trailing: () -> Trailing

    init(@ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if tool.isRunning {
                    ProgressView().controlSize(.small)
                    Text(l10n.s.speedTestTesting)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        tool.run()
                    } label: {
                        Label(NetworkQualityTool.runTitle,
                              systemImage: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!tool.isAvailable)
                    .help(NetworkQualityTool.executablePath)
                }
                Button {
                    tool.openSpeedtest()
                } label: {
                    Label(NetworkQualityTool.openSpeedtestTitle,
                          systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!tool.speedtestInstalled)
                .help(tool.speedtestInstalled
                      ? NetworkQualityTool.speedtestAppURL.path
                      : NetworkQualityTool.notInstalledCaption)
                Spacer()
                if let result = tool.lastResult {
                    Text("↓\(NetworkQualityTool.mbps(result.downloadMbps)) ↑\(NetworkQualityTool.mbps(result.uploadMbps)) Mbps")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                trailing()
            }
            switch tool.phase {
            case let .failed(reason):
                Text("\(l10n.s.speedTestFailed): \(reason)")
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .foregroundStyle(PanelMetricColor.orange(for: colorScheme))
            case let .finished(result):
                HStack(spacing: 6) {
                    if let rpm = result.responsivenessRPM {
                        Text("\(rpm) RPM")
                    }
                    if let rtt = result.baseRTTms {
                        Text("\(l10n.s.speedTestLatency): \(Int(rtt.rounded())) ms")
                    }
                    Text("· \(NetworkQualityTool.timestamp(result.finishedAt))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
        }
    }
}
