import AppKit
import SwiftUI
import Combine

private enum MetricSegmentKind: CaseIterable {
    case network    // 2-line: upload / download
    case cpu        // 2-line: load / temp
    case igpu       // 2-line: usage / temp
    case dgpu       // 2-line: usage / temp
    case memory     // 2-line: memory / fan speed
    case battery    // 2-line: power / percent
    case limit      // 2-line: speed limit / thermal state
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let metricsItem: NSStatusItem
    private let settingsItem: NSStatusItem

    private var settingsPanel: NSPanel?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let manager: MonitorManager

    private var observers: [Any] = []

    private var hostingController: NSHostingController<PopoverView>?

    private let segmentSpacing: CGFloat = 4
    private var segmentVisibility: [MetricSegmentKind: Bool] = [:]

    private var pendingCpu: String = " --"
    private var pendingCpuTemp: String = " --"
    private var pendingMemory: String = " --"
    private var pendingNetUpload: String = " --"
    private var pendingNetDownload: String = " --"
    private var pendingBattery: String = " --"
    private var pendingIGpu: String = " --"
    private var pendingIGpuTemp: String = " --"
    private var pendingDGpu: String = " --"
    private var pendingDGpuTemp: String = " --"
    private var pendingLimit: String = " --"
    private var pendingLimitValue: Double = -1
    private var pendingBatteryIcon: String = "bolt.fill"
    private var pendingBatteryPercent: Int = 0
    private var renderScheduled = false
    private var energyRefreshTimer: Timer?
    private var activeTip: NSPopover?
    private var tipClickMonitor: Any?

    private var segmentRanges: [(MetricSegmentKind, ClosedRange<CGFloat>)] = []

    private let metricFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

    private var maxSegmentWidths: [MetricSegmentKind: CGFloat] = [:]

    init(manager: MonitorManager) {
        self.manager = manager

        settingsItem = NSStatusBar.system.statusItem(withLength: 18)
        metricsItem = NSStatusBar.system.statusItem(withLength: 10)

        super.init()

        setupSettingsPanel()
        setupSettingsItem()
        setupMetricsButton()
        setupInitialSegmentVisibility()
        observeDataChanges()
        observeToggleNotifications()
        observePopoverSizeNotifications()
        observeLanguageChange()
        scheduleRender()

        // 测试钩子（见 showSettingsPopover 注释）
        if ProcessInfo.processInfo.environment["MACSTATE_AUTO_CYCLE_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, let button = self.settingsItem.button else { return }
                self.showSettingsPopover(from: button)
            }
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    /// 设置面板用 NSPanel 浮窗而非 NSPopover：macOS 26 上 NSPopover+SwiftUI
    /// 在独显激活时开合会触发 RenderBox/AMD 驱动崩溃（cacheDisplay 快照路径）
    private func setupSettingsPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 660),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = L10n.shared.settings
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 280, height: 500)
        p.setFrameAutosaveName("SettingsPanel")
        settingsPanel = p
    }

    /// 面板锚定到设置图标正下方
    private func positionSettingsPanel() {
        guard let panel = settingsPanel, let button = settingsItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = buttonFrame.midX - panel.frame.width / 2
        x = max(visible.minX + 4, min(x, visible.maxX - panel.frame.width - 4))
        let y = buttonFrame.minY - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 4, y)))
    }

    private func hideSettingsPanel() {
        settingsPanel?.orderOut(nil)
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideSettingsPanel() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    private func setupSettingsItem() {
        settingsItem.button?.target = self
        settingsItem.button?.action = #selector(settingsItemClicked(_:))
        let icon = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L10n.shared.settings)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        settingsItem.button?.image = icon?.withSymbolConfiguration(config)
        settingsItem.length = 18
    }

    private func setupMetricsButton() {
        guard let button = metricsItem.button else { return }
        button.target = self
        button.action = #selector(metricsItemClicked(_:))
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func setupInitialSegmentVisibility() {
        segmentVisibility[.network] = NetworkToggle.shared.enabled
        segmentVisibility[.cpu] = CpuToggle.shared.enabled || CpuTempToggle.shared.enabled
        segmentVisibility[.igpu] = IGpuToggle.shared.enabled
        segmentVisibility[.dgpu] = DGpuToggle.shared.enabled
        segmentVisibility[.memory] = MemoryToggle.shared.enabled || FanToggle.shared.enabled
        segmentVisibility[.battery] = BatteryService.hasBattery && BatteryToggle.shared.enabled
        segmentVisibility[.limit] = LimitToggle.shared.enabled
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushRender()
        }
    }

    // MARK: - Segment content

    /// The text lines (1 or 2) shown next to the segment icon. Two-line
    /// segments keep the menu bar compact; each line respects its module toggle.
    private func segmentLines(_ kind: MetricSegmentKind) -> [String] {
        switch kind {
        case .network:
            return ["↑\(pendingNetUpload)", "↓\(pendingNetDownload)"]
        case .cpu:
            var lines: [String] = []
            if CpuToggle.shared.enabled { lines.append(pendingCpu) }
            if CpuTempToggle.shared.enabled { lines.append(pendingCpuTemp) }
            return lines
        case .igpu:
            var lines: [String] = []
            if IGpuToggle.shared.enabled {
                lines.append(pendingIGpu)
                lines.append(pendingIGpuTemp)
            }
            return lines
        case .dgpu:
            var lines: [String] = []
            if DGpuToggle.shared.enabled {
                lines.append(pendingDGpu)
                lines.append(pendingDGpuTemp)
            }
            return lines
        case .memory:
            var lines: [String] = []
            if MemoryToggle.shared.enabled { lines.append(pendingMemory) }
            if FanToggle.shared.enabled {
                let fans = manager.fanSpeeds
                lines.append(fans.isEmpty ? " --" : String(format: " %.0f", fans.first?.current ?? 0))
            }
            return lines
        case .battery:
            var lines: [String] = []
            if BatteryService.hasBattery && BatteryToggle.shared.enabled {
                lines.append(pendingBattery)
                lines.append(" \(pendingBatteryPercent)%")
            }
            return lines
        case .limit:
            var lines: [String] = []
            if LimitToggle.shared.enabled {
                lines.append(pendingLimit)
                lines.append(" \(thermalShort(PowerLimitService.shared.thermalState))")
            }
            return lines
        }
    }

    private func thermalShort(_ state: ProcessInfo.ThermalState) -> String {
        let l = L10n.shared
        switch state {
        case .nominal: return l.thermalShortNominal
        case .fair: return l.thermalShortFair
        case .serious: return l.thermalShortSerious
        case .critical: return l.thermalShortCritical
        @unknown default: return "--"
        }
    }

    private func iconName(for kind: MetricSegmentKind) -> String {
        switch kind {
        case .network: return "network"
        case .cpu: return "cpu.fill"
        case .igpu: return "cpu"
        case .dgpu: return "display"
        case .memory: return "memorychip"
        case .battery: return pendingBatteryIcon
        case .limit: return "speedometer"
        }
    }

    /// 核显/独显段用单字文字图标，比 SF Symbol（显示器/芯片）更直白
    private func iconGlyph(for kind: MetricSegmentKind) -> String? {
        switch kind {
        case .igpu: return "核"
        case .dgpu: return "独"
        default: return nil
        }
    }

    private static let glyphFont = NSFont.boldSystemFont(ofSize: 10)

    /// True when the CPU is genuinely thermal/power throttled: the allowed
    /// speed is capped while the load is actually high. A low limit at idle
    /// is normal power management, not throttling.
    private var throttleActive: Bool {
        let limit = pendingLimitValue
        return limit >= 0 && limit < 95 && manager.cpuUsage >= 50
    }

    private func flushRender() {
        renderScheduled = false
        guard let button = metricsItem.button else { return }

        let barHeight = NSStatusBar.system.thickness
        let iconSize: CGFloat = 12
        let iconTextGap: CGFloat = 2

        let order: [MetricSegmentKind] = [.cpu, .igpu, .network, .dgpu, .memory, .battery, .limit]

        struct SegmentInfo {
            let kind: MetricSegmentKind
            let width: CGFloat
        }

        var segments: [SegmentInfo] = []
        var totalWidth: CGFloat = 0
        var ranges: [(MetricSegmentKind, ClosedRange<CGFloat>)] = []

        for kind in order {
            guard segmentVisibility[kind] == true else { continue }

            var actualIconW = iconSize
            let iconName = self.iconName(for: kind)
            if let glyph = self.iconGlyph(for: kind) {
                actualIconW = ceil((glyph as NSString).size(withAttributes: [.font: Self.glyphFont]).width)
            } else if iconName == "_battery_custom_" {
                actualIconW = 22 + 3  // batteryBodyW + batteryCapW, must match drawing code
            } else if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfig) {
                let rawSize = iconImage.size
                if rawSize.width > rawSize.height && rawSize.height > 0 {
                    actualIconW = iconSize * rawSize.width / rawSize.height
                }
            }

            let lines = segmentLines(kind)
            let font = lines.count >= 2 ? networkFont : metricFont
            var textW: CGFloat = 0
            for line in lines {
                textW = max(textW, (line as NSString).size(withAttributes: [.font: font]).width)
            }
            let width = actualIconW + iconTextGap + textW

            let stableWidth = ceil(max(width, maxSegmentWidths[kind] ?? 0))
            if stableWidth > (maxSegmentWidths[kind] ?? 0) {
                maxSegmentWidths[kind] = stableWidth
            }

            segments.append(SegmentInfo(kind: kind, width: stableWidth))
        }

        for (i, seg) in segments.enumerated() {
            let x = totalWidth
            totalWidth += seg.width
            if i < segments.count - 1 { totalWidth += segmentSpacing }
            ranges.append((seg.kind, x...(x + seg.width)))
        }

        totalWidth = max(10, ceil(totalWidth))
        segmentRanges = ranges

        let image = NSImage(size: NSSize(width: totalWidth, height: barHeight), flipped: false) { [self] drawRect in
            var x: CGFloat = 0

            for seg in segments {
                let iconName = self.iconName(for: seg.kind)

                var actualIconW = iconSize

                if let glyph = self.iconGlyph(for: seg.kind) {
                    let gSize = (glyph as NSString).size(withAttributes: [.font: Self.glyphFont])
                    let gY = (barHeight - gSize.height) / 2
                    (glyph as NSString).draw(
                        at: NSPoint(x: x, y: gY),
                        withAttributes: [.font: Self.glyphFont, .foregroundColor: NSColor.labelColor]
                    )
                    actualIconW = ceil(gSize.width)
                } else if iconName == "_battery_custom_" {
                    let batteryH: CGFloat = 11
                    let bodyW: CGFloat = 22
                    let capW: CGFloat = 1.5
                    let capH = batteryH * 0.5
                    let batteryW = bodyW + capW
                    let iconY = (barHeight - batteryH) / 2
                    let lineW: CGFloat = 1.0
                    let bodyRect = NSRect(x: x, y: iconY, width: bodyW, height: batteryH)

                    // Battery outline
                    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.5, yRadius: 3.5)
                    bodyPath.lineWidth = lineW
                    NSColor.labelColor.setStroke()
                    bodyPath.stroke()

                    // Battery cap (positive terminal)
                    let capX = x + bodyW
                    let capY = iconY + (batteryH - capH) / 2
                    let capRect = NSRect(x: capX, y: capY, width: capW, height: capH)
                    let capPath = NSBezierPath(roundedRect: capRect, xRadius: 1.5, yRadius: 1.5)
                    NSColor.labelColor.setFill()
                    capPath.fill()

                    // Detect actual menu bar appearance via button (not NSApp which reflects system setting)
                    let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

                    let pct = CGFloat(max(0, min(100, self.pendingBatteryPercent))) / 100.0
                    let inset: CGFloat = lineW
                    let fillMaxW = bodyW - inset * 2
                    let fillW = fillMaxW * pct
                    let innerRect = NSRect(x: x + inset, y: iconY + inset, width: fillMaxW, height: batteryH - inset * 2)
                    let cornerR: CGFloat = 2.5

                    // Depleted area background (semi-transparent labelColor)
                    let depletePath = NSBezierPath(roundedRect: innerRect, xRadius: cornerR, yRadius: cornerR)
                    NSColor.labelColor.withAlphaComponent(0.45).setFill()
                    depletePath.fill()

                    // Charged area fill
                    if fillW > 0 {
                        let fillRect = NSRect(x: x + inset, y: iconY + inset, width: fillW, height: batteryH - inset * 2)
                        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerR, yRadius: cornerR)
                        NSColor.labelColor.setFill()
                        fillPath.fill()
                    }

                    let pctText = "\(self.pendingBatteryPercent)"
                    let pctFont = NSFont.monospacedDigitSystemFont(ofSize: round(batteryH * 0.72), weight: .bold)
                    let textSize = (pctText as NSString).size(withAttributes: [.font: pctFont])
                    let textOrigin = NSPoint(
                        x: x + (bodyW - textSize.width) / 2,
                        y: iconY + (batteryH - textSize.height) / 2
                    )
                    // contrast against labelColor fill: dark text on light fill, light text on dark fill
                    let textColor: NSColor = isDark
                        ? NSColor.black.withAlphaComponent(0.65)
                        : NSColor.white.withAlphaComponent(0.85)
                    (pctText as NSString).draw(at: textOrigin, withAttributes: [.font: pctFont, .foregroundColor: textColor])

                    actualIconW = batteryW
                } else if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(self.iconConfig.applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))) {
                    let rawSize = iconImage.size
                    let drawW: CGFloat
                    let drawH: CGFloat
                    if rawSize.width > rawSize.height && rawSize.height > 0 {
                        drawH = iconSize
                        drawW = iconSize * rawSize.width / rawSize.height
                    } else {
                        drawW = iconSize
                        drawH = iconSize
                    }
                    let iconY = (barHeight - drawH) / 2
                    iconImage.draw(in: NSRect(x: x, y: iconY, width: drawW, height: drawH))
                    actualIconW = drawW
                }

                let textX = x + actualIconW + iconTextGap
                let lines = self.segmentLines(seg.kind)
                let font = lines.count >= 2 ? self.networkFont : self.metricFont

                let textColor: NSColor = (seg.kind == .limit && self.throttleActive)
                    ? NSColor.systemRed
                    : NSColor.labelColor
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor
                ]

                if lines.count >= 2 {
                    let lineHeight = (lines[0] as NSString).size(withAttributes: attrs).height
                    let totalTextHeight = lineHeight * 2
                    let startY = (barHeight - totalTextHeight) / 2
                    (lines[1] as NSString).draw(at: NSPoint(x: textX, y: startY), withAttributes: attrs)
                    (lines[0] as NSString).draw(at: NSPoint(x: textX, y: startY + lineHeight), withAttributes: attrs)
                } else if let line = lines.first {
                    let textSize = (line as NSString).size(withAttributes: attrs)
                    let textY = (barHeight - textSize.height) / 2
                    (line as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
                }

                x += seg.width + self.segmentSpacing
            }

            return true
        }

        image.isTemplate = false

        if metricsItem.length != totalWidth {
            metricsItem.length = totalWidth
        }
        button.image = image
    }

    // MARK: - Toggle Visibility

    private func observeToggleNotifications() {
        func observe(_ name: Notification.Name, compute: @escaping () -> Bool) {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.setVisibility(compute(), for: nil)
            })
        }

        observe(CpuToggle.changedNotification) { CpuToggle.shared.enabled }
        observe(CpuTempToggle.changedNotification) { CpuTempToggle.shared.enabled }
        observe(MemoryToggle.changedNotification) { MemoryToggle.shared.enabled }
        observe(FanToggle.changedNotification) { FanToggle.shared.enabled }
        observe(NetworkToggle.changedNotification) { NetworkToggle.shared.enabled }
        observe(LimitToggle.changedNotification) { LimitToggle.shared.enabled }
        observe(BatteryToggle.changedNotification) { BatteryService.hasBattery && BatteryToggle.shared.enabled }
        observe(IGpuToggle.changedNotification) { IGpuToggle.shared.enabled }
        observe(DGpuToggle.changedNotification) { DGpuToggle.shared.enabled }
    }

    /// `kind == nil` re-evaluates every segment (one toggle can affect a whole
    /// combined column).
    private func setVisibility(_ visible: Bool, for kind: MetricSegmentKind?) {
        if let kind {
            segmentVisibility[kind] = visible
        } else {
            setupInitialSegmentVisibility()
        }
        maxSegmentWidths.removeAll()
        scheduleRender()
    }

    private func observePopoverSizeNotifications() {
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("MacStatePopoverSize"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let w = note.userInfo?["width"] as? Double,
                  let h = note.userInfo?["height"] as? Double else { return }
            self.settingsPanel?.setContentSize(NSSize(width: w, height: h))
            self.positionSettingsPanel()
        })
    }

    // MARK: - Observe Data Changes

    private func observeDataChanges() {
        manager.$cpuUsage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingCpu = String(format: " %.0f%%", value)
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$cpuTemp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingCpuTemp = value > 0 ? String(format: " %.0f\u{00B0}", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$memoryUsage
            .removeDuplicates { $0.usedPercentage == $1.usedPercentage }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (mem: MemoryUsage) in
                guard let self else { return }
                self.pendingMemory = String(format: " %.0f%%", mem.usedPercentage)
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$networkSpeed
            .removeDuplicates { $0.upload == $1.upload && $0.download == $1.download }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (speed: NetworkSpeed) in
                guard let self else { return }
                self.pendingNetUpload = speed.uploadFormatted
                self.pendingNetDownload = speed.downloadFormatted
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$batteryInfo
            .removeDuplicates { lhs, rhs in
                lhs.percentage == rhs.percentage &&
                lhs.isCharging == rhs.isCharging &&
                lhs.isPluggedIn == rhs.isPluggedIn &&
                Int(lhs.adapterPowerWatts * 10) == Int(rhs.adapterPowerWatts * 10) &&
                Int(lhs.powerWatts * 10) == Int(rhs.powerWatts * 10)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (info: BatteryInfo) in
                guard let self else { return }
                self.pendingBatteryPercent = info.percentage
                if info.isCharging {
                    self.pendingBatteryIcon = "bolt.fill"
                } else if info.isPluggedIn {
                    self.pendingBatteryIcon = "powerplug.fill"
                } else {
                    self.pendingBatteryIcon = "_battery_custom_"
                }
                if info.isAvailable {
                    let w = info.adapterPowerWatts > 0 ? info.adapterPowerWatts : abs(info.powerWatts)
                    self.pendingBattery = w > 0.05 ? String(format: " %.1fW", w) : " --"
                } else {
                    self.pendingBattery = " --"
                }
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$igpuUsage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingIGpu = value >= 0 ? String(format: " %.0f%%", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$igpuTemp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingIGpuTemp = value > 0 ? String(format: " %.0f\u{00B0}", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$dgpuUsage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingDGpu = value >= 0 ? String(format: " %.0f%%", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$dgpuTemp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingDGpuTemp = value > 0 ? String(format: " %.0f\u{00B0}", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$cpuSpeedLimit
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingLimitValue = value
                self.pendingLimit = value >= 0 ? String(format: " %.0f%%", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)
    }

    // MARK: - Language Change

    private func observeLanguageChange() {
        L10n.shared.$language
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPopover()
            }
            .store(in: &cancellables)
    }

    private func refreshPopover() {
        if settingsPanel?.isVisible == true {
            hostingController?.rootView = PopoverView(manager: manager)
        }
    }

    // MARK: - Click Handling

    @objc private func settingsItemClicked(_ sender: NSStatusBarButton) {
        showSettingsPopover(from: sender)
    }

    private func showSettingsPopover(from sender: NSStatusBarButton) {
        // 渲染兼容性分流：探针判定 SwiftUI 不安全的机器走纯 AppKit 基础面板，
        // 宁可功能降级也不闪退
        guard UICompatService.shared.swiftUISafe else {
            dismissActiveTip()
            FallbackSettingsPanelController.shared.toggle()
            return
        }

        guard let panel = settingsPanel else { return }

        if panel.isVisible {
            hideSettingsPanel()
            return
        }

        if hostingController == nil {
            let hc = NSHostingController(rootView: PopoverView(manager: manager))
            hostingController = hc
            panel.contentView = hc.view
        }
        panel.setContentSize(NSSize(width: 280, height: 660))
        positionSettingsPanel()
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()

        // 测试钩子：MACSTATE_AUTO_CYCLE_SETTINGS=1 时模拟用户反复开合设置面板
        guard ProcessInfo.processInfo.environment["MACSTATE_AUTO_CYCLE_SETTINGS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.settingsPanel?.isVisible == true else { return }
            self.hideSettingsPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let button = self.settingsItem.button else { return }
                self.showSettingsPopover(from: button)
            }
        }
    }

    @objc private func metricsItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showCpuUsageTooltip(button: sender)
            return
        }

        let pointInWindow = event.locationInWindow
        let pointInButton = sender.convert(pointInWindow, from: nil)

        for (kind, range) in segmentRanges {
            if range.contains(pointInButton.x) {
                showTooltip(for: kind, button: sender)
                return
            }
        }

        showCpuUsageTooltip(button: sender)
    }

    private func segmentRect(for kind: MetricSegmentKind, in button: NSStatusBarButton) -> NSRect {
        for (k, range) in segmentRanges {
            if k == kind {
                return NSRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: button.bounds.height)
            }
        }
        return button.bounds
    }

    private func showTooltip(for kind: MetricSegmentKind, button: NSStatusBarButton) {
        switch kind {
        case .cpu:
            dismissActiveTip()
            CPUProcessPanel.shared.toggle(cpuUsage: String(format: "%.1f%%", manager.cpuUsage))
        case .memory:
            dismissActiveTip()
            let mem = manager.memoryUsage
            let used = String(format: "%.1fGB", Double(mem.used) / 1_073_741_824)
            let total = String(format: "%.1fGB", Double(mem.total) / 1_073_741_824)
            var info = "\(used)/\(total) (\(String(format: "%.0f%%", mem.usedPercentage)))"
            let fans = manager.fanSpeeds
            if !fans.isEmpty {
                let l = L10n.shared
                let fanParts = fans.enumerated().map { "\(l.fanLabel($0.offset + 1)) \(Int($0.element.current))RPM" }
                info += "\n" + fanParts.joined(separator: "  ")
            }
            MemoryProcessPanel.shared.toggle(memoryInfo: info)
        case .network:
            dismissActiveTip()
            let s = manager.networkSpeed
            NetworkProcessPanel.shared.toggle(upload: s.uploadFormatted, download: s.downloadFormatted)
        case .battery:
            showBatteryTooltip(button: button, kind: kind)
        case .igpu, .dgpu:
            showGpuColumnTooltip(button: button, kind: kind)
        case .limit:
            showLimitTooltip(button: button, kind: kind)
        }
    }

    private func showCpuUsageTooltip(button: NSStatusBarButton) {
        dismissActiveTip()
        CPUProcessPanel.shared.toggle(cpuUsage: String(format: "%.1f%%", manager.cpuUsage))
    }

    private func showGpuColumnTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let usages = GPUService.shared.allGPUUsages()
        let temps = GPUService.shared.allGPUTemperatures()
        let l = L10n.shared
        let rect = segmentRect(for: kind, in: button)

        if usages.isEmpty && temps.isEmpty {
            showSimpleTooltip(text: "GPU: N/A", button: button, rect: rect)
            return
        }

        let gpuPower = PowerLimitService.shared.gpuPowerWatts()
        var lines: [String] = []
        let labels = usages.map { $0.name } + temps.map { $0.label }
        let uniqueLabels = Array(Set(labels))
        for label in uniqueLabels.sorted() {
            let usage = usages.first { $0.name == label }?.usage
            let temp = temps.first { $0.label == label }?.temp
            var parts: [String] = [localizedGpuLabel(label)]
            if let usage { parts.append("\(l.usageLabel) \(String(format: "%.0f%%", usage))") }
            if let temp { parts.append("\(String(format: "%.0f°C", temp))") }
            lines.append(parts.joined(separator: "  "))
        }
        if let gpuPower {
            lines.append("\(l.gpuPower): \(String(format: "%.1fW", gpuPower))")
        }
        showSimpleTooltip(text: lines.joined(separator: "\n"), button: button, rect: rect)
    }

    private func showLimitTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        // SwiftUI 不安全的机器回退到纯文字摘要（AppKit 气泡），避免加载限速温度面板
        guard UICompatService.shared.swiftUISafe else {
            dismissActiveTip()
            showLegacyLimitTooltip(button: button, kind: kind)
            return
        }
        dismissActiveTip()
        LimitPanelController.shared.toggle()
    }

    /// 纯 AppKit 文字版限速摘要（基础模式使用）
    private func showLegacyLimitTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let l = L10n.shared
        let power = PowerLimitService.shared
        var lines: [String] = []

        let limit = power.cpuSpeedLimitPercent()
        let marker = throttleActive ? " ⚠️" : ""
        lines.append("\(l.cpuSpeedLimit): \(limit.map { String(format: "%.0f%%", $0) } ?? "N/A")\(marker)")

        if let limits = power.currentPowerLimits() {
            lines.append("\(l.powerLimit): CPU \(String(format: "%.0f%%", limits.cpu)) / GPU \(String(format: "%.0f%%", limits.gpu))")
        }
        lines.append("\(l.thermalStateLabel): \(thermalName(power.thermalState))")
        lines.append("\(l.cpuLoadLabel): \(String(format: "%.0f%%", manager.cpuUsage)) · \(l.moduleName(.cpuTemp)): \(String(format: "%.0f°C", manager.cpuTemp))")

        showSimpleTooltip(text: lines.joined(separator: "\n"), button: button, rect: segmentRect(for: kind, in: button))
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        let l = L10n.shared
        switch state {
        case .nominal: return l.thermalNominal
        case .fair: return l.thermalFair
        case .serious: return l.thermalSerious
        case .critical: return l.thermalCritical
        @unknown default: return "—"
        }
    }

    private func localizedGpuLabel(_ key: String) -> String {
        key == "discrete" ? L10n.shared.discreteGPU : L10n.shared.integratedGPU
    }

    private func showSimpleTooltip(text: String, button: NSStatusBarButton, rect: NSRect) {
        dismissActiveTip()

        let tip = NSPopover()
        tip.behavior = .applicationDefined
        tip.animates = false
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        let lineCount = max(text.components(separatedBy: "\n").count, 1)
        let height = CGFloat(lineCount * 18 + 16)
        tip.contentSize = NSSize(width: 240, height: height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: height))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])
        let vc = NSViewController()
        vc.view = container
        tip.contentViewController = vc
        tip.show(relativeTo: rect, of: button, preferredEdge: .minY)
        activeTip = tip
        installTipClickMonitor()
    }

    private func showBatteryTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        dismissActiveTip()

        let info = manager.batteryInfo
        let l = L10n.shared
        let tip = NSPopover()
        tip.behavior = .applicationDefined
        tip.animates = false

        let labelFont = NSFont.systemFont(ofSize: 12)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        var rows: [(String, String)] = []

        if info.adapterPowerWatts > 0 {
            let rated = info.adapterWatts > 0 ? " (\(l.ratedPower) \(info.adapterWatts)W)" : ""
            rows.append((l.adapterPower, String(format: "%.1fW%@", info.adapterPowerWatts, rated)))
        } else {
            rows.append((l.adapterLabel, l.notConnected))
        }

        let w = info.powerWatts
        let hint = w >= 0 ? l.chargingPrefix : l.dischargingPrefix
        rows.append((l.batteryPower, String(format: "%.1fW (%@)", abs(w), hint)))

        let absMa = abs(info.amperage)
        let currentStr: String
        if absMa >= 1000 {
            currentStr = String(format: "%.2fA", Double(absMa) / 1000.0)
        } else {
            currentStr = "\(absMa)mA"
        }
        let currentHint = info.amperage >= 0 ? l.chargingPrefix : l.dischargingPrefix
        rows.append((l.currentLabel, "\(currentStr) (\(currentHint))"))

        rows.append((l.voltageLabel, String(format: "%.1fV", Double(info.voltage) / 1000.0)))
        rows.append((l.batteryLevel, "\(info.percentage)%"))
        rows.append((l.cycleCountLabel, "\(info.cycleCount)"))
        rows.append((l.batteryHealth, "\(info.healthPercentage)%"))

        var labels: [NSTextField] = []
        var values: [NSTextField] = []

        for (labelText, valueText) in rows {
            let lbl = NSTextField(labelWithString: labelText.isEmpty ? "" : "\(labelText):")
            lbl.font = labelFont
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(lbl)
            labels.append(lbl)

            let val = NSTextField(labelWithString: valueText)
            val.font = valueFont
            val.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(val)
            values.append(val)
        }

        let labelMaxW: CGFloat = labels.reduce(0) { max($0, $1.intrinsicContentSize.width) }
        let valueMaxW: CGFloat = values.reduce(0) { max($0, $1.intrinsicContentSize.width) }
        let totalW = 12 + labelMaxW + 6 + valueMaxW + 12

        for i in 0..<labels.count {
            let topAnchor = i == 0 ? container.topAnchor : labels[i - 1].bottomAnchor
            let topConst: CGFloat = i == 0 ? 10 : 4
            NSLayoutConstraint.activate([
                labels[i].topAnchor.constraint(equalTo: topAnchor, constant: topConst),
                labels[i].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                labels[i].widthAnchor.constraint(equalToConstant: labelMaxW),
                values[i].centerYAnchor.constraint(equalTo: labels[i].centerYAnchor),
                values[i].leadingAnchor.constraint(equalTo: labels[i].trailingAnchor, constant: 6),
                values[i].trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            ])
        }

        let energySep = NSBox()
        energySep.boxType = .separator
        energySep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energySep)

        let energyTitle = NSTextField(labelWithString: "⚡ \(l.energyRanking)")
        energyTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        energyTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energyTitle)

        let lastLbl = labels.last!
        NSLayoutConstraint.activate([
            energySep.topAnchor.constraint(equalTo: lastLbl.bottomAnchor, constant: 8),
            energySep.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            energySep.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            energyTitle.topAnchor.constraint(equalTo: energySep.bottomAnchor, constant: 6),
            energyTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        ])

        var energyIconViews: [NSImageView] = []
        var energyNameFields: [NSTextField] = []
        var energyRows: [NSView] = []
        var prevAnchor: NSLayoutYAxisAnchor = energyTitle.bottomAnchor

        for _ in 0..<3 {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            row.addSubview(iconView)

            let nameField = NSTextField(labelWithString: "")
            nameField.font = labelFont
            nameField.translatesAutoresizingMaskIntoConstraints = false
            nameField.lineBreakMode = .byTruncatingTail
            row.addSubview(nameField)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: prevAnchor, constant: 4),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: 18),
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14),
                nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
                nameField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                nameField.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            ])

            energyIconViews.append(iconView)
            energyNameFields.append(nameField)
            energyRows.append(row)
            prevAnchor = row.bottomAnchor
        }

        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomSpacer)
        NSLayoutConstraint.activate([
            bottomSpacer.topAnchor.constraint(equalTo: prevAnchor),
            bottomSpacer.heightAnchor.constraint(equalToConstant: 10),
            bottomSpacer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomSpacer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])

        func updateEnergyRows() {
            let procs = EnergyService.shared.topProcesses(limit: 3)
            let hasData = !procs.isEmpty
            energySep.isHidden = !hasData
            energyTitle.isHidden = !hasData
            for i in 0..<3 {
                if i < procs.count {
                    energyIconViews[i].image = procs[i].icon
                    energyNameFields[i].stringValue = "\(i + 1). \(procs[i].name)"
                    energyRows[i].isHidden = false
                } else {
                    energyRows[i].isHidden = true
                }
            }
        }

        updateEnergyRows()

        let basicHeight: CGFloat = 10 + CGFloat(rows.count) * 18 + CGFloat(rows.count - 1) * 4
        let energyHeight: CGFloat = 99
        let height: CGFloat = basicHeight + energyHeight + 10
        tip.contentSize = NSSize(width: max(260, totalW), height: height)

        energyRefreshTimer?.invalidate()
        energyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard self?.activeTip != nil else { return }
            updateEnergyRows()
        }

        let vc = NSViewController()
        vc.view = container
        tip.contentViewController = vc
        tip.show(relativeTo: segmentRect(for: kind, in: button), of: button, preferredEdge: .minY)
        activeTip = tip
        installTipClickMonitor()
    }

    private func dismissActiveTip() {
        energyRefreshTimer?.invalidate()
        energyRefreshTimer = nil
        if let monitor = tipClickMonitor {
            NSEvent.removeMonitor(monitor)
            tipClickMonitor = nil
        }
        activeTip?.performClose(nil)
        activeTip = nil
    }

    private func installTipClickMonitor() {
        if let monitor = tipClickMonitor {
            NSEvent.removeMonitor(monitor)
            tipClickMonitor = nil
        }
        tipClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissActiveTip()
            }
        }
    }
}
