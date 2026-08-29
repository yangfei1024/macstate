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
            activateApp()
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
        // Menu bar apps live in their own space; without these the window can
        // open on another space (or behind a fullscreen app) and look like a no-op.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        activateApp()
        window = win
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HistoryView: View {
    @ObservedObject private var l10n = L10n.shared

    @State private var rangeSeconds: TimeInterval = 6 * 3600

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
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
        }
    }

    /// Raw samples for the selected range (≤ ~26k for 3 days at 10s).
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
                statusItem(
                    label: l10n.cpuSpeedLimit,
                    value: limit.map { String(format: "%.0f%%", $0) } ?? "N/A",
                    highlight: (limit ?? 100) < 99
                )
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
                lineSeries(l10n.cpuPower) { $0.cpuPower }
                lineSeries(l10n.gpuPower) { $0.gpuPower }
                lineSeries(l10n.sysPower) { $0.sysPower }
            }
        }
    }

    private var temperatureChart: some View {
        chartCard(title: l10n.temperatureChartTitle) {
            Chart {
                lineSeries("CPU") { $0.cpuTemp }
                lineSeries("GPU") { $0.gpuTemp }
            }
            .chartYScale(domain: 20...110)
        }
    }

    private var loadChart: some View {
        chartCard(title: l10n.loadChartTitle) {
            Chart {
                ForEach(HistoryStore.minMaxSeries(samples) { $0.cpuLoad }, id: \.t) { p in
                    AreaMark(x: .value("t", p.t), y: .value("pct", p.v))
                        .foregroundStyle(.blue.opacity(0.25))
                    LineMark(x: .value("t", p.t), y: .value("pct", p.v))
                        .foregroundStyle(.blue)
                }
            }
            .chartYScale(domain: 0...100)
        }
    }

    private var limitChart: some View {
        chartCard(title: l10n.limitChartTitle) {
            Chart {
                ForEach(HistoryStore.minMaxSeries(samples) { $0.cpuSpeedLimit }, id: \.t) { p in
                    LineMark(x: .value("t", p.t), y: .value("pct", p.v))
                        .foregroundStyle(.red)
                }
                RuleMark(y: .value("pct", 100.0))
                    .foregroundStyle(.green.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4, 3]))
            }
            .chartYScale(domain: 0...105)
        }
    }

    /// Downsampled line series; unavailable values (-1 sentinel) are filtered
    /// by the downsampler itself.
    private func lineSeries(_ name: String, value: @escaping (HistorySample) -> Double) -> some ChartContent {
        ForEach(HistoryStore.minMaxSeries(samples, value: value), id: \.t) { p in
            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(by: .value("m", name))
        }
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
