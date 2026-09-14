import AppKit

/// 纯 AppKit 的"全部温度"面板：功率摘要头 + 分组温度表格，3 秒刷新。
/// 基础模式（SwiftUI 不安全的机器）下由限速段点击与设置面板按钮打开，
/// 与 SwiftUI 版共享同一份 SMCTempCatalog 与 SMCService 数据。
@MainActor
final class AppKitTempsPanelController: NSObject {
    static let shared = AppKitTempsPanelController()

    private var panel: NSPanel?
    private var table: NSTableView?
    private var rows: [Row] = []
    private var refreshTimer: Timer?
    private var summaryLabels: [NSTextField] = []
    /// 每个数据行连续无效读数的次数；≥10 判定为本机不存在的传感器，隐藏
    private var invalidCounts: [Int] = []

    private struct Row {
        var isHeader: Bool = false
        var title: String = ""
        var key: String = ""
        var value: Double?
    }

    private let valueColumnID = NSUserInterfaceItemIdentifier("akTempValue")

    private override init() {}

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
        rebuildRows()
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        refreshSummary()
        var changed = false
        for (i, row) in rows.enumerated() where !row.isHeader {
            if let v = SMCService.shared.readKey(row.key), v > 1, v < 120 {
                rows[i].value = v
                invalidCounts[i] = 0
            } else {
                // 从未有效过的键累计无效次数，达到阈值判定为本机不存在 → 隐藏
                if rows[i].value == nil {
                    invalidCounts[i] = min(invalidCounts[i] + 1, 11)
                    if invalidCounts[i] == 10 { changed = true }
                }
            }
        }
        if changed { table?.reloadData() }
        table?.enumerateAvailableRowViews { rowView, row in
            guard row < self.rows.count, !self.rows[row].isHeader,
                  self.invalidCounts[row] < 10 else { return }
            let v = self.rows[row].value
            if let cell = rowView.view(atColumn: 2) as? NSTextField {
                cell.stringValue = v.map { String(format: "%.1f°C", $0) } ?? "--"
                cell.textColor = self.valueColor(v)
            }
        }
    }

    private func refreshSummary() {
        let power = PowerLimitService.shared
        let l = L10n.shared
        let limit = power.cpuSpeedLimitPercent()
        let limits = power.currentPowerLimits()
        let thermal: String
        switch power.thermalState {
        case .nominal: thermal = l.thermalNominal
        case .fair: thermal = l.thermalFair
        case .serious: thermal = l.thermalSerious
        case .critical: thermal = l.thermalCritical
        @unknown default: thermal = "--"
        }
        guard summaryLabels.count == 3 else { return }
        summaryLabels[0].stringValue = "\(l.cpuSpeedLimit): \(limit.map { String(format: "%.0f%%", $0) } ?? "--")"
        summaryLabels[0].textColor = (limit ?? 100) < 99 ? .systemOrange : .labelColor
        summaryLabels[1].stringValue = limits.map { String(format: "\(l.powerLimit): CPU %.0f%% GPU %.0f%%", $0.cpu, $0.gpu) } ?? "\(l.powerLimit): --"
        summaryLabels[2].stringValue = "\(l.thermalStateLabel): \(thermal)"
    }

    private func rebuildRows() {
        let l = L10n.shared
        rows = []
        invalidCounts = []
        for group in SensorGroup.allCases {
            let groupSensors = SMCTempCatalog.all.filter { $0.group == group }
            guard !groupSensors.isEmpty else { continue }
            rows.append(Row(isHeader: true, title: group.title(l.language)))
            invalidCounts.append(-1) // 分组头不参与计数
            for gs in groupSensors {
                rows.append(Row(isHeader: false, title: gs.label(l.language), key: gs.key, value: nil))
                invalidCounts.append(0)
            }
        }
        table?.reloadData()
        refresh()
    }

    private func buildPanel() {
        let l = L10n.shared
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = "\(l.powerLimit) — \(l.sensorsTitle)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 400, height: 480)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = content

        // 功率摘要头（3s 刷新）
        var summary: [NSTextField] = []
        for _ in 0..<3 {
            let t = NSTextField(labelWithString: "--")
            t.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            t.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(t)
            summary.append(t)
        }
        summaryLabels = summary

        NSLayoutConstraint.activate([
            summary[0].topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            summary[0].leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summary[1].topAnchor.constraint(equalTo: summary[0].bottomAnchor, constant: 3),
            summary[1].leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            summary[2].topAnchor.constraint(equalTo: summary[1].bottomAnchor, constant: 3),
            summary[2].leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
        ])

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: summary[2].bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 24
        table.gridStyleMask = []
        table.backgroundColor = .clear
        let keyCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("akTempKey"))
        keyCol.width = 46
        table.addTableColumn(keyCol)
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("akTempName"))
        nameCol.width = 240
        table.addTableColumn(nameCol)
        let valCol = NSTableColumn(identifier: valueColumnID)
        valCol.width = 70
        table.addTableColumn(valCol)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        self.table = table

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        self.panel = p
        p.setFrameAutosaveName("AppKitTempsPanel")
    }

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.midX - p.frame.width / 2, y: visible.midY - p.frame.height / 2))
        }
    }

    private func valueColor(_ v: Double?) -> NSColor {
        guard let v else { return .secondaryLabelColor }
        if v >= 85 { return .systemRed }
        if v >= 70 { return .systemOrange }
        return .labelColor
    }
}

extension AppKitTempsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { rows.count }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MainActor.assumeIsolated {
            guard row < rows.count else { return 24 }
            // 本机不存在的传感器（连续 10 次 × 3 秒无有效读数）隐藏
            if !rows[row].isHeader, rows[row].value == nil, invalidCounts[row] >= 10 { return 0 }
            if rows[row].isHeader { return row == 0 ? 30 : 36 }
            return 24
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard row < rows.count else { return nil }
            let row_ = rows[row]

            if row_.isHeader {
                // 分组头只占首列，其余列留空
                guard tableColumn?.identifier == .init("akTempKey") else { return NSView() }
                let cell = NSTextField(labelWithString: row_.title.uppercased())
                cell.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                cell.textColor = .secondaryLabelColor
                return cell
            }

            let id = tableColumn?.identifier
            if id == .init("akTempKey") {
                let cell = NSTextField(labelWithString: row_.key)
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                cell.textColor = .secondaryLabelColor
                return cell
            }
            if id == .init("akTempName") {
                let cell = NSTextField(labelWithString: row_.title)
                cell.font = NSFont.systemFont(ofSize: 12)
                cell.lineBreakMode = .byTruncatingTail
                return cell
            }
            let v = rows[row].value
            let cell = NSTextField(labelWithString: v.map { String(format: "%.1f°C", $0) } ?? "--")
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .right
            cell.textColor = valueColor(v)
            return cell
        }
    }
}
