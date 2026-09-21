// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Sealed fork: the upstream speed test talked to Cloudflare from inside the
// app. This build opens no socket of its own for a speed test; instead it
// offers the two tools already on the Mac: Apple's `/usr/bin/networkQuality`
// (run as a local Process, JSON parsed here) and the Ookla Speedtest app
// (only launched). Tools/check-sealed.sh allows exactly that executable path.

import AppKit
import Combine
import Foundation

@MainActor
final class NetworkQualityTool: ObservableObject {
    static let shared = NetworkQualityTool()

    struct Result: Equatable {
        let downloadMbps: Double
        let uploadMbps: Double
        /// Round trips per minute under load, as networkQuality reports it.
        let responsivenessRPM: Int?
        /// Idle latency in milliseconds, when the tool reports it.
        let baseRTTms: Double?
        let finishedAt: Date
    }

    enum Phase: Equatable {
        case idle
        case running
        case finished(Result)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var lastResult: Result? {
        if case let .finished(result) = phase { return result }
        return nil
    }

    static let executablePath = "/usr/bin/networkQuality"
    static let speedtestAppURL = URL(fileURLWithPath: "/Applications/Speedtest.app", isDirectory: true)
    static let runTitle = "Run networkQuality"
    static let openSpeedtestTitle = "Open Speedtest"
    static let notInstalledCaption = "Speedtest.app is not installed"

    /// The tool ships with macOS 12+, but the check keeps the button honest
    /// on a stripped system.
    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.executablePath)
    }

    var speedtestInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.speedtestAppURL.path)
    }

    private init() {}

    /// Runs `networkQuality -c` (machine-readable JSON, sequential up/down is
    /// the tool's default) and publishes the parsed numbers. One run at a
    /// time; the tool itself takes roughly 15–30 s.
    func run() {
        guard !isRunning else { return }
        guard isAvailable else {
            phase = .failed("\(Self.executablePath) not found")
            return
        }
        phase = .running
        Task.detached(priority: .userInitiated) {
            let output = BoundedProcessRunner.run(
                Self.executablePath, ["-c"], timeout: 120, maxOutputBytes: 256 * 1_024)
            let parsed = Self.parse(output.output)
            await MainActor.run {
                if output.timedOut {
                    self.phase = .failed("networkQuality timed out")
                } else if let parsed {
                    self.phase = .finished(parsed)
                } else {
                    let text = String(decoding: output.output, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
                    self.phase = .failed(firstLine.isEmpty
                                         ? "networkQuality exited with status \(output.status)"
                                         : firstLine)
                }
            }
        }
    }

    /// Launches the Ookla app; the app does its own test in its own window.
    func openSpeedtest() {
        guard speedtestInstalled else { return }
        NSWorkspace.shared.openApplication(at: Self.speedtestAppURL,
                                           configuration: NSWorkspace.OpenConfiguration(),
                                           completionHandler: nil)
    }

    /// `-c` prints one JSON object. Throughputs are bits per second;
    /// responsiveness is RPM; base_rtt is milliseconds. The object is located
    /// by its braces so a stray warning line ahead of it does not break parsing.
    nonisolated static func parse(_ data: Data, now: Date = Date()) -> Result? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end,
              let object = try? JSONSerialization.jsonObject(with: data[start...end]) as? [String: Any]
        else { return nil }
        func number(_ key: String) -> Double? {
            (object[key] as? NSNumber)?.doubleValue
        }
        guard let down = number("dl_throughput"), let up = number("ul_throughput") else { return nil }
        let rpm = number("responsiveness").map { Int($0.rounded()) }
        return Result(downloadMbps: down / 1_000_000,
                      uploadMbps: up / 1_000_000,
                      responsivenessRPM: rpm,
                      baseRTTms: number("base_rtt"),
                      finishedAt: now)
    }

    nonisolated static func mbps(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", locale: MetricFormat.locale, value)
                     : String(format: "%.1f", locale: MetricFormat.locale, value)
    }

    nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = MetricFormat.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
