import SwiftUI
import Charts
import AppKit

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.shared.historyTitle
        win.contentView = NSHostingView(rootView: HistoryView())
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct HistoryView: View {
    @ObservedObject private var l10n = L10n.shared

    @State private var rangeSeconds: TimeInterval = 6 * 3600
    @State private var now = Date()

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rangePicker
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    powerChart
                    temperatureChart
                    loadChart
                    limitChart
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 620)
        .onReceive(timer) { _ in now = Date() }
    }

    private var samples: [HistorySample] {
        HistoryStore.shared.samplesWithin(seconds: rangeSeconds)
    }

    // MARK: - Header: current throttle status

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.historyTitle)
                    .font(.headline)
                Spacer()
                Text(l10n.retentionHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            let limit = PowerLimitService.shared.cpuSpeedLimitPercent()
            let limits = PowerLimitService.shared.powerLimits()
            let thermal = PowerLimitService.shared.thermalState

            HStack(spacing: 16) {
                if let limit {
                    statusItem(
                        label: l10n.cpuSpeedLimit,
                        value: String(format: "%.0f%%", limit),
                        highlight: limit < 99
                    )
                } else {
                    statusItem(label: l10n.cpuSpeedLimit, value: "N/A", highlight: false)
                }
                if let limits {
                    statusItem(
                        label: l10n.powerLimit,
                        value: String(format: "CPU %.0f%% / GPU %.0f%%", limits.cpu, limits.gpu),
                        highlight: limits.cpu < 99
                    )
                }
                statusItem(
                    label: l10n.thermalStateLabel,
                    value: thermalName(thermal),
                    highlight: thermal.rawValue >= 2
                )
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func statusItem(label: String, value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundColor(highlight ? .orange : .primary)
        }
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return l10n.thermalNominal
        case .fair: return l10n.thermalFair
        case .serious: return l10n.thermalSerious
        case .critical: return l10n.thermalCritical
        @unknown default: return "—"
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("", selection: $rangeSeconds) {
            Text("1h").tag(TimeInterval(3600))
            Text("6h").tag(TimeInterval(6 * 3600))
            Text("24h").tag(TimeInterval(24 * 3600))
            Text(l10n.threeDays).tag(TimeInterval(3 * 24 * 3600))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Charts

    private var powerChart: some View {
        chartCard(title: l10n.powerChartTitle) {
            Chart {
                ForEach(samples, id: \.t) { s in
                    if s.cpuPower >= 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("w", s.cpuPower))
                            .foregroundStyle(by: .value("m", l10n.cpuPower))
                    }
                }
                ForEach(samples, id: \.t) { s in
                    if s.gpuPower >= 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("w", s.gpuPower))
                            .foregroundStyle(by: .value("m", l10n.gpuPower))
                    }
                }
                ForEach(samples, id: \.t) { s in
                    if s.sysPower >= 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("w", s.sysPower))
                            .foregroundStyle(by: .value("m", l10n.sysPower))
                    }
                }
            }
        }
    }

    private var temperatureChart: some View {
        chartCard(title: l10n.temperatureChartTitle) {
            Chart {
                ForEach(samples, id: \.t) { s in
                    if s.cpuTemp > 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("c", s.cpuTemp))
                            .foregroundStyle(by: .value("m", "CPU"))
                    }
                }
                ForEach(samples, id: \.t) { s in
                    if s.gpuTemp > 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("c", s.gpuTemp))
                            .foregroundStyle(by: .value("m", "GPU"))
                    }
                }
            }
            .chartYScale(domain: 20...110)
        }
    }

    private var loadChart: some View {
        chartCard(title: l10n.loadChartTitle) {
            Chart {
                ForEach(samples, id: \.t) { s in
                    AreaMark(x: .value("t", dateOf(s)), y: .value("pct", s.cpuLoad))
                        .foregroundStyle(.blue.opacity(0.25))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", dateOf(s)), y: .value("pct", s.cpuLoad))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...100)
        }
    }

    private var limitChart: some View {
        chartCard(title: l10n.limitChartTitle) {
            Chart {
                ForEach(samples, id: \.t) { s in
                    if s.cpuSpeedLimit >= 0 {
                        LineMark(x: .value("t", dateOf(s)), y: .value("pct", s.cpuSpeedLimit))
                            .foregroundStyle(.red)
                    }
                }
                RuleMark(y: .value("pct", 100.0))
                    .foregroundStyle(.green.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4, 3]))
            }
            .chartYScale(domain: 0...105)
        }
    }

    private func dateOf(_ s: HistorySample) -> Date {
        Date(timeIntervalSince1970: s.t)
    }

    private func chartCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            content()
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 140)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}
