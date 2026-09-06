import SwiftUI
import AppKit

/// 点击菜单栏"CPU 限速"段弹出的面板：上半是限速/功率/热状态，
/// 下半是全部温度传感器（与"全部温度"子页面同一份 SensorsView）。
@MainActor
final class LimitPanelController {
    static let shared = LimitPanelController()

    private var panel: NSPanel?

    private init() {}

    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            return
        }
        show()
    }

    private func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        panel.title = "\(L10n.shared.powerLimit) — \(L10n.shared.sensorsTitle)"
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 800),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = "\(L10n.shared.powerLimit) — \(L10n.shared.sensorsTitle)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 420, height: 500)
        p.contentView = NSHostingView(
            rootView: VStack(spacing: 0) {
                LimitSummaryHeader()
                Divider()
                SensorsView()
                    .padding(12)
            }
        )
        self.panel = p
        p.setFrameAutosaveName("LimitSensorsPanel")
    }

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let panelFrame = p.frame
            let x = visibleFrame.midX - panelFrame.width / 2
            let y = visibleFrame.midY - panelFrame.height / 2
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

/// 面板顶部的限速摘要（与设置页限速卡片同一套数据）
private struct LimitSummaryHeader: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                let power = PowerLimitService.shared
                let limits = power.currentPowerLimits()
                let avg = power.cpuAverageLimitPercent()

                HStack(spacing: 14) {
                    item(
                        label: l10n.currentLimitLabel,
                        value: limits.map { String(format: "CPU %.0f%% GPU %.0f%%", $0.cpu, $0.gpu) } ?? "--",
                        highlight: limits.map { $0.cpu < 99 || $0.gpu < 99 } ?? false
                    )
                    item(
                        label: l10n.recentAvgLimitLabel,
                        value: avg.map { String(format: "%.0f%%", $0) } ?? "--",
                        highlight: false
                    )
                    item(
                        label: l10n.thermalStateLabel,
                        value: thermalName(power.thermalState),
                        highlight: power.thermalState.rawValue >= 2
                    )
                    Spacer()
                }

                Text(l10n.throttleHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func item(label: String, value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundColor(highlight ? .orange : .primary)
        }
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return l10n.thermalNominal
        case .fair: return l10n.thermalFair
        case .serious: return l10n.thermalSerious
        case .critical: return l10n.thermalCritical
        @unknown default: return "--"
        }
    }
}
