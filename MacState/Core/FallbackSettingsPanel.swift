import AppKit

/// 基础模式设置面板（纯 AppKit，SwiftUI 不安全机器的完整替代）。
/// 视觉：系统设置风格——毛玻璃窗口背景、内嵌连续圆角分组卡片、
/// 行内图标/标签/控件三段式、分隔线自文字边缘内缩。
@MainActor
final class FallbackSettingsPanelController: NSObject {
    static let shared = FallbackSettingsPanelController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var summaryLabels: [NSTextField] = []
    private var limitValueLabel: NSTextField?
    private var powerValueLabel: NSTextField?
    private var thermalValueLabel: NSTextField?

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
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        startTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        stopTimer()
        refreshSummary()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSummary() }
        }
    }

    private func refreshSummary() {
        let power = PowerLimitService.shared
        let limit = power.cpuSpeedLimitPercent()
        let limits = power.currentPowerLimits()
        let l = L10n.shared

        limitValueLabel?.stringValue = limit.map { String(format: "%.0f%%", $0) } ?? "--"
        limitValueLabel?.textColor = (limit ?? 100) < 99 ? .systemOrange : .labelColor
        if let limits {
            powerValueLabel?.stringValue = String(format: "CPU %.0f%% · GPU %.0f%%", limits.cpu, limits.gpu)
        } else {
            powerValueLabel?.stringValue = "--"
        }
        switch power.thermalState {
        case .nominal: thermalValueLabel?.stringValue = l.thermalNominal
        case .fair: thermalValueLabel?.stringValue = l.thermalFair
        case .serious: thermalValueLabel?.stringValue = l.thermalSerious
        case .critical: thermalValueLabel?.stringValue = l.thermalCritical
        @unknown default: thermalValueLabel?.stringValue = "--"
        }
    }

    // MARK: - 构建

    private func buildPanel() {
        let l = L10n.shared
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 780),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.title = "\(l.appName) — \(l.settings)"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 300, height: 460)
        p.backgroundColor = .clear

        // 毛玻璃背景
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 780))
        effect.material = .windowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = effect

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let inset: CGFloat = 14
        var allConstraints: [NSLayoutConstraint] = []
        var lastBottom: NSLayoutYAxisAnchor = content.topAnchor
        var lastSpacing: CGFloat = 0

        func append(_ v: NSView, topSpacing: CGFloat, height: CGFloat? = nil) {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            allConstraints.append(v.topAnchor.constraint(equalTo: lastBottom, constant: topSpacing + lastSpacing))
            allConstraints.append(v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset))
            allConstraints.append(v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset))
            if let h = height {
                allConstraints.append(v.heightAnchor.constraint(equalToConstant: h))
            }
            lastBottom = v.bottomAnchor
            lastSpacing = 0
        }

        // ── 标题（避开红绿灯，顶部留 40pt）──
        let titleStack = NSStackView(views: [])
        titleStack.orientation = .vertical
        titleStack.alignment = .centerX
        titleStack.spacing = 2
        let appTitle = NSTextField(labelWithString: l.appName)
        appTitle.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: l.language == .zh ? "基础模式 · 原生渲染" : "Basic Mode · Native Rendering")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(appTitle)
        titleStack.addArrangedSubview(subtitle)
        append(titleStack, topSpacing: 0)
        allConstraints.append(titleStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40))

        // ── 分组 1：模块开关 ──
        var moduleRows: [NSView] = []
        moduleRows.append(makeSwitchRow(icon: "thermometer", title: l.moduleName(.cpuTemp), state: { (CpuTempToggle.shared.enabled, CpuTempToggle.shared.setEnabled) }))
        moduleRows.append(makeSwitchRow(icon: "cpu", title: l.moduleName(.cpuUsage), state: { (CpuToggle.shared.enabled, CpuToggle.shared.setEnabled) }))
        if GPUService.hasGPU {
            moduleRows.append(makeSwitchRow(icon: "cpu", title: l.moduleName(.igpu), state: { (IGpuToggle.shared.enabled, IGpuToggle.shared.setEnabled) }))
        }
        moduleRows.append(makeSwitchRow(icon: "network", title: l.moduleName(.network), state: { (NetworkToggle.shared.enabled, NetworkToggle.shared.setEnabled) }))
        if GPUService.hasDiscreteGPU {
            moduleRows.append(makeSwitchRow(icon: "display", title: l.moduleName(.dgpu), state: { (DGpuToggle.shared.enabled, DGpuToggle.shared.setEnabled) }))
        }
        moduleRows.append(makeSwitchRow(icon: "memorychip", title: l.moduleName(.memory), state: { (MemoryToggle.shared.enabled, MemoryToggle.shared.setEnabled) }))
        moduleRows.append(makeSwitchRow(icon: "fan", title: l.moduleName(.fan), state: { (FanToggle.shared.enabled, FanToggle.shared.setEnabled) }))
        if BatteryService.hasBattery {
            moduleRows.append(makeSwitchRow(icon: "bolt", title: l.moduleName(.battery), state: { (BatteryToggle.shared.enabled, BatteryToggle.shared.setEnabled) }))
        }
        moduleRows.append(makeSwitchRow(icon: "speedometer", title: l.moduleName(.limit), state: { (LimitToggle.shared.enabled, LimitToggle.shared.setEnabled) }))
        moduleRows.append(makeSwitchRow(icon: "contextualmenu.and.cursorarrow", title: l.finderMenu, state: { (FinderMenuToggle.shared.enabled, FinderMenuToggle.shared.setEnabled) }))
        append(makeCard(rows: moduleRows), topSpacing: 16, height: CGFloat(moduleRows.count) * 30 + 12)

        // ── 分组 2：功率摘要 ──
        let limitRow = makeInfoRow(title: l.cpuSpeedLimit, value: "--")
        let plimitRow = makeInfoRow(title: l.powerLimit, value: "--")
        let thermalRow = makeInfoRow(title: l.thermalStateLabel, value: "--")
        summaryLabels = [limitRow.value, plimitRow.value, thermalRow.value]
        append(makeCard(rows: [limitRow.view, plimitRow.view, thermalRow.view]), topSpacing: 16, height: 3 * 30 + 12)

        // ── 分组 3：监控（原生绘制，全机器可用）──
        let histRow = makeLinkRow(icon: "chart.xyaxis.line", title: l.language == .zh ? "历史曲线（功率 / 温度 / 负载）" : "History (power / temps / load)") { [weak self] in
            AppKitHistoryPanelController.shared.toggle()
        }
        let tempsRow = makeLinkRow(icon: "thermometer.medium", title: l.sensorsButton) { [weak self] in
            AppKitTempsPanelController.shared.toggle()
        }
        append(makeCard(rows: [histRow, tempsRow]), topSpacing: 16, height: 2 * 30 + 12)

        // ── 分组 4：通用 ──
        let refreshPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 92, height: 24))
        refreshPopup.addItems(withTitles: ["3s", "5s", "10s"])
        refreshPopup.selectItem(withTitle: "\(Int(MonitorManager.shared.refreshInterval))s")
        refreshPopup.target = self
        refreshPopup.action = #selector(refreshChanged(_:))
        let langPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 92, height: 24))
        langPopup.addItems(withTitles: Language.allCases.map(\.displayName))
        langPopup.selectItem(withTitle: l.language.displayName)
        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))
        let loginToggle = NSSwitch()
        loginToggle.controlSize = .small
        loginToggle.state = LaunchAtLoginService.shared.isEnabled ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled(_:))

        let generalRows = [
            makeSettingRow(icon: "clock.arrow.circlepath", title: l.refreshInterval, accessory: refreshPopup),
            makeSettingRow(icon: "globe", title: l.languageLabel, accessory: langPopup),
            makeSettingRow(icon: "power", title: l.launchAtLogin, accessory: loginToggle),
        ]
        append(makeCard(rows: generalRows), topSpacing: 16, height: 3 * 30 + 12)

        // ── 退出 ──
        let quit = NSButton(title: l.quit, target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false
        quit.contentTintColor = .systemRed
        quit.font = NSFont.systemFont(ofSize: 13)
        append(quit, topSpacing: 16, height: 28)
        allConstraints.append(quit.centerXAnchor.constraint(equalTo: content.centerXAnchor))
        allConstraints.append(quit.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16))

        NSLayoutConstraint.activate(allConstraints)
        for c in content.constraints where c.secondItem === content && (c.firstAttribute == .leading || c.firstAttribute == .trailing) {
            // 内容宽度跟随卡片（卡片已绑定 content 边缘）
            _ = c
        }

        self.panel = p
        p.setFrameAutosaveName("FallbackSettingsPanel2")
    }

    // MARK: - 构建辅助

    /// 内嵌圆角卡片：行垂直堆叠（手动约束，行撑满宽度）+ 行间内缩分隔线
    private func makeCard(rows: [NSView]) -> NSView {
        let group = NSView()
        group.wantsLayer = true
        group.layer?.cornerRadius = 10
        group.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        group.translatesAutoresizingMaskIntoConstraints = false

        var cons: [NSLayoutConstraint] = []
        var prevBottom: NSLayoutYAxisAnchor = group.topAnchor
        var prevSpacing: CGFloat = 6
        for (i, row) in rows.enumerated() {
            group.addSubview(row)
            cons.append(row.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12))
            cons.append(row.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12))
            cons.append(row.topAnchor.constraint(equalTo: prevBottom, constant: prevSpacing))
            if i < rows.count - 1 {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                group.addSubview(line)
                cons.append(line.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 50))
                cons.append(line.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12))
                cons.append(line.topAnchor.constraint(equalTo: row.bottomAnchor))
                cons.append(line.heightAnchor.constraint(equalToConstant: 1))
                prevBottom = line.bottomAnchor
                prevSpacing = 0
            } else {
                cons.append(row.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -6))
            }
        }
        NSLayoutConstraint.activate(cons)
        return group
    }

    /// 通用三段行：图标 + 标题 + （弹性空隙）+ 控件，行高 30
    private func makeRow(icon: String?, title: String, accessory: NSView) -> NSView {
        let row = hstack()
        row.translatesAutoresizingMaskIntoConstraints = false
        if let icon {
            let iconView = NSImageView()
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            iconView.contentTintColor = .secondaryLabelColor
            iconView.setContentCompressionResistancePriority(.init(751), for: .horizontal)
            row.addArrangedSubview(iconView)
            row.setCustomSpacing(8, after: iconView)
        }
        let t = label(title, size: 12)
        t.setContentCompressionResistancePriority(.init(749), for: .horizontal)
        row.addArrangedSubview(t)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        accessory.setContentHuggingPriority(.init(750), for: .horizontal)
        row.addArrangedSubview(accessory)
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return row
    }

    private func makeSwitchRow(icon: String, title: String, state: () -> (Bool, (Bool) -> Void)) -> NSView {
        let sw = NSSwitch()
        sw.controlSize = .small
        let current = state()
        sw.state = current.0 ? .on : .off
        sw.target = self
        sw.action = #selector(moduleSwitchChanged(_:))
        sw.identifier = NSUserInterfaceItemIdentifier(title)
        objc_setAssociatedObject(sw, "handler", current.1, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return makeRow(icon: icon, title: title, accessory: sw)
    }

    private func makeSettingRow(icon: String, title: String, accessory: NSView) -> NSView {
        makeRow(icon: icon, title: title, accessory: accessory)
    }

    /// 链接行：可点击（整行 NSButton 覆盖），尾部 chevron
    private func makeLinkRow(icon: String, title: String, action: @escaping () -> Void) -> NSView {
        let content = makeRow(icon: icon, title: title, accessory: {
            let chevron = NSImageView()
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            chevron.contentTintColor = .tertiaryLabelColor
            return chevron
        }())
        let cover = NSButton(title: "", target: nil, action: nil)
        cover.isBordered = false
        cover.isTransparent = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: content.topAnchor),
            cover.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        objc_setAssociatedObject(cover, "handler", action, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        cover.target = self
        cover.action = #selector(linkClicked(_:))
        return content
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let handler = objc_getAssociatedObject(sender, "handler") as? (() -> Void) else { return }
        handler()
    }

    /// 信息行：标题居左、值居右
    private func makeInfoRow(title: String, value: String) -> (view: NSView, value: NSTextField) {
        let v = label(value, size: 12, mono: true)
        let row = makeRow(icon: nil, title: title, accessory: v)
        return (row, v)
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, mono: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        if mono {
            t.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        } else {
            t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        }
        return t
    }

    private func hstack(spacing: CGFloat = 8) -> NSStackView {
        let sv = NSStackView(views: [])
        sv.orientation = .horizontal
        sv.alignment = .centerY
        sv.spacing = spacing
        return sv
    }

    // MARK: - Actions

    @objc private func moduleSwitchChanged(_ sender: NSSwitch) {
        guard let handler = objc_getAssociatedObject(sender, "handler") as? (Bool) -> Void else { return }
        handler(sender.state == .on)
    }

    @objc private func refreshChanged(_ sender: NSPopUpButton) {
        let title = sender.titleOfSelectedItem ?? "3s"
        MonitorManager.shared.updateRefreshInterval(TimeInterval(Int(title.replacingOccurrences(of: "s", with: "")) ?? 3))
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        if let lang = Language.allCases.first(where: { $0.displayName == sender.titleOfSelectedItem }) {
            L10n.shared.language = lang
        }
    }

    @objc private func loginToggled(_ sender: NSSwitch) {
        LaunchAtLoginService.shared.toggle()
        sender.state = LaunchAtLoginService.shared.isEnabled ? .on : .off
    }

    @objc private func openHistory(_ sender: NSButton) {
        AppKitHistoryPanelController.shared.toggle()
    }

    @objc private func openTemps(_ sender: NSButton) {
        AppKitTempsPanelController.shared.toggle()
    }

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.midX - p.frame.width / 2, y: visible.midY - p.frame.height / 2))
        }
    }
}
