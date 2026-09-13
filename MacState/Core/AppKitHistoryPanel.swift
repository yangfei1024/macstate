import AppKit

/// 纯 AppKit 的历史曲线面板：从 HistoryStore 取 3 天样本，用 NSBezierPath
/// 绘制功率 / 温度 / CPU 负载 / 限速四组折线图。基础模式机器上替代
/// SwiftUI + Charts 版（HistoryView），零 CoreImage/Metal 依赖。
@MainActor
final class AppKitHistoryPanelController {
    static let shared = AppKitHistoryPanelController()

    private var panel: NSPanel?
    private var chartView: HistoryChartView?
    private var refreshTimer: Timer?

    private init() {}

    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            stopTimer()
            return
        }
        show()
    }

    private func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        startTimer()
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.chartView?.needsDisplay = true }
        }
    }

    private func buildPanel() {
        let l = L10n.shared
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = l.historyTitle
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 520, height: 480)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = content

        // 时间范围选择
        let rangeLabel = NSTextField(labelWithString: l.refreshInterval == "" ? "" : (l.language == .zh ? "范围" : "Range"))
        rangeLabel.font = NSFont.systemFont(ofSize: 12)
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rangeLabel)

        let seg = NSSegmentedControl(labels: ["1h", "6h", "24h", l.threeDays], trackingMode: .selectOne, target: self, action: #selector(rangeChanged(_:)))
        seg.selectedSegment = 1
        seg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(seg)

        let chart = HistoryChartView(frame: NSRect(x: 0, y: 0, width: 620, height: 640))
        chart.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chart)
        self.chartView = chart

        NSLayoutConstraint.activate([
            rangeLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            rangeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            seg.centerYAnchor.constraint(equalTo: rangeLabel.centerYAnchor),
            seg.leadingAnchor.constraint(equalTo: rangeLabel.trailingAnchor, constant: 8),
            chart.topAnchor.constraint(equalTo: rangeLabel.bottomAnchor, constant: 8),
            chart.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            chart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            chart.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        self.panel = p
        p.setFrameAutosaveName("AppKitHistoryPanel")
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        let hours: [TimeInterval] = [1, 6, 24, 72]
        chartView?.rangeSeconds = hours[max(0, min(sender.selectedSegment, 3))] * 3600
        chartView?.needsDisplay = true
    }

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.midX - p.frame.width / 2, y: visible.midY - p.frame.height / 2))
        }
    }
}

/// 纯 CPU 绘制的多组折线图（NSBezierPath，无 Metal/CoreImage 参与）。
@MainActor
final class HistoryChartView: NSView {
    var rangeSeconds: TimeInterval = 6 * 3600

    private struct Series {
        var label: String
        var color: NSColor
        var unit: String
        var minScale: Double?
        var maxScale: Double?
        var value: (HistorySample) -> Double
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let samples = HistoryStore.shared.samplesWithin(seconds: rangeSeconds)
        let l = L10n.shared

        let series: [String] = [
            l.powerChartTitle,
            l.temperatureChartTitle,
            l.loadChartTitle,
            l.limitChartTitle,
        ]
        let chartHeight: CGFloat = 130
        let chartGap: CGFloat = 18
        let top: CGFloat = 6
        var y = bounds.height - top

        // 1) 功率
        drawChart(
            rect: NSRect(x: 6, y: y - chartHeight, width: bounds.width - 12, height: chartHeight),
            title: series[0],
            groups: [
                ("CPU", NSColor.systemBlue, { max($0.cpuPower, 0) }),
                ("GPU", NSColor.systemPurple, { max($0.gpuPower, 0) }),
                (l.sysPower, NSColor.systemGreen, { max($0.sysPower, 0) }),
            ],
            samples: samples, unit: "W"
        )
        y -= chartHeight + chartGap

        // 2) 温度
        drawChart(
            rect: NSRect(x: 6, y: y - chartHeight, width: bounds.width - 12, height: chartHeight),
            title: series[1],
            groups: [
                ("CPU", NSColor.systemRed, { max($0.cpuTemp, 0) }),
                ("GPU", NSColor.systemOrange, { max($0.gpuTemp, 0) }),
            ],
            samples: samples, unit: "°C", fixedMin: 0, fixedMax: 110
        )
        y -= chartHeight + chartGap

        // 3) CPU 负载
        drawChart(
            rect: NSRect(x: 6, y: y - chartHeight, width: bounds.width - 12, height: chartHeight),
            title: series[2],
            groups: [("CPU", NSColor.systemBlue, { max($0.cpuLoad, 0) })],
            samples: samples, unit: "%", fixedMin: 0, fixedMax: 100
        )
        y -= chartHeight + chartGap

        // 4) 限速
        drawChart(
            rect: NSRect(x: 6, y: y - chartHeight, width: bounds.width - 12, height: chartHeight),
            title: series[3],
            groups: [(l.cpuSpeedLimit, NSColor.systemRed, { $0.cpuSpeedLimit < 0 ? 100 : $0.cpuSpeedLimit })],
            samples: samples, unit: "%", fixedMin: 0, fixedMax: 105
        )
    }

    private func drawChart(
        rect: NSRect, title: String,
        groups: [(String, NSColor, (HistorySample) -> Double)],
        samples: [HistorySample], unit: String,
        fixedMin: Double? = nil, fixedMax: Double? = nil
    ) {
        let inset: CGFloat = 30 // 左侧留 y 轴标签
        let plot = NSRect(x: rect.minX + inset, y: rect.minY + 12,
                          width: rect.width - inset - 6, height: rect.height - 26)

        // 标题与图例
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (title as NSString).draw(at: NSPoint(x: rect.minX, y: rect.maxY - 14), withAttributes: attrs)
        var legendX = rect.minX + 80
        for (name, color, _) in groups {
            let text = "\(name) (\(unit))" as NSString
            text.draw(at: NSPoint(x: legendX, y: rect.maxY - 14), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: color,
            ])
            legendX += text.size().width + 16
        }

        // 汇总各组序列（min-max 降采样）
        var all: [(points: [(t: Date, v: Double)], color: NSColor)] = []
        var vMin = Double.greatestFiniteMagnitude
        var vMax = -Double.greatestFiniteMagnitude
        for (name, color, fn) in groups {
            var pts = HistoryStore.minMaxSeries(samples, buckets: Int(max(plot.width / 2, 40)), value: fn)
            if pts.isEmpty { continue }
            pts.insert((pts[0].t, pts[0].v), at: 0)
            all.append((pts, color))
            for p in pts { vMin = min(vMin, p.v); vMax = max(vMax, p.v) }
        }
        if all.isEmpty {
            ("(" + L10n.shared.notConnected + ")" as NSString).draw(
                at: NSPoint(x: plot.midX - 30, y: plot.midY),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            )
            return
        }
        if let fmin = fixedMin { vMin = fmin }
        if let fmax = fixedMax { vMax = fmax }
        if vMax - vMin < 1 { vMax = vMin + 1 }

        // 网格与 y 轴标签
        let gridAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for i in 0...2 {
            let frac = CGFloat(i) / 2
            let gy = plot.minY + plot.height * frac
            NSColor.gridColor.setStroke()
            NSBezierPath(rect: NSRect(x: plot.minX, y: gy, width: plot.width, height: 0)).stroke()
            let val = vMax - (vMax - vMin) * Double(frac)
            let text = "\(Int(val.rounded()))\(unit)" as NSString
            let ts = text.size(withAttributes: gridAttrs)
            text.draw(at: NSPoint(x: plot.minX - ts.width - 4, y: gy - ts.height / 2), withAttributes: gridAttrs)
        }

        guard let first = all.first?.points, let t0 = first.first?.t, let t1 = first.last?.t, t1 > t0 else { return }

        // x 轴时间标签（起止）
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let t0s = df.string(from: Date(timeIntervalSince1970: t0.timeIntervalSince1970)) as NSString
        let t1s = df.string(from: Date(timeIntervalSince1970: t1.timeIntervalSince1970)) as NSString
        t0s.draw(at: NSPoint(x: plot.minX, y: plot.minY - 11), withAttributes: gridAttrs)
        t1s.draw(at: NSPoint(x: plot.maxX - t1s.size().width, y: plot.minY - 11), withAttributes: gridAttrs)

        func xFor(_ t: Date) -> CGFloat {
            plot.minX + plot.width * CGFloat((t.timeIntervalSince1970 - t0.timeIntervalSince1970) / (t1.timeIntervalSince1970 - t0.timeIntervalSince1970))
        }
        func yFor(_ v: Double) -> CGFloat {
            plot.minY + plot.height * CGFloat((v - vMin) / (vMax - vMin))
        }

        NSColor.gridColor.setStroke()
        NSBezierPath(rect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height)).stroke()

        for (pts, color) in all {
            guard pts.count > 1 else { continue }
            let path = NSBezierPath()
            path.lineWidth = 1.4
            color.setStroke()
            for (i, p) in pts.enumerated() {
                let pt = NSPoint(x: xFor(p.t), y: yFor(p.v))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.stroke()
        }
    }
}
