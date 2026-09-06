import AppKit

/// UICompatService 判定 SwiftUI 渲染不安全时的 AppKit 原生设置面板。
/// 全部控件为纯 AppKit（远程实测老驱动机型上安全），提供与 SettingsView
/// 对应的核心功能；SwiftUI 专属能力（历史曲线/全部温度）标注为不可用。
@MainActor
final class FallbackSettingsPanelController {
    static let shared = FallbackSettingsPanelController()

    private var panel: NSPanel?
    private var timer: Timer?
    private var limitValueLabel: NSTextField?
    private var powerValueLabel: NSTextField?
    private var thermalValueLabel: NSTextField?

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
            powerValueLabel?.stringValue = String(format: "CPU %.0f%% GPU %.0f%%", limits.cpu, limits.gpu)
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

    private func buildPanel() {
        let l = L10n.shared
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 720),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = "\(l.appName) — \(l.settings)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 280, height: 420)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = scroll

        let stack = vstack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 16),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 14),
        ])

        let version = "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        stack.addArrangedSubview(label("\(l.appName) \(version)（基础模式）", size: 13, bold: true))

        let hint = label(
            l.language == .zh
                ? "此设备的图形驱动与部分界面不兼容，已自动切换为基础模式（纯原生控件）。"
                : "This Mac's GPU driver is incompatible with parts of the UI; basic mode (native controls only) is active.",
            size: 11
        )
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 240
        stack.addArrangedSubview(hint)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel(l.modules))

        // 模块行（与 SwiftUI 设置页同一批开关单例）
        addModuleRow(stack, icon: "thermometer", title: l.moduleName(.cpuTemp)) {
            (CpuTempToggle.shared.enabled, CpuTempToggle.shared.setEnabled)
        }
        addModuleRow(stack, icon: "cpu", title: l.moduleName(.cpuUsage)) {
            (CpuToggle.shared.enabled, CpuToggle.shared.setEnabled)
        }
        if GPUService.hasGPU {
            addModuleRow(stack, icon: "cpu", title: l.moduleName(.igpu)) {
                (IGpuToggle.shared.enabled, IGpuToggle.shared.setEnabled)
            }
        }
        addModuleRow(stack, icon: "network", title: l.moduleName(.network)) {
            (NetworkToggle.shared.enabled, NetworkToggle.shared.setEnabled)
        }
        if GPUService.hasDiscreteGPU {
            addModuleRow(stack, icon: "display", title: l.moduleName(.dgpu)) {
                (DGpuToggle.shared.enabled, DGpuToggle.shared.setEnabled)
            }
        }
        addModuleRow(stack, icon: "memorychip", title: l.moduleName(.memory)) {
            (MemoryToggle.shared.enabled, MemoryToggle.shared.setEnabled)
        }
        addModuleRow(stack, icon: "fan", title: l.moduleName(.fan)) {
            (FanToggle.shared.enabled, FanToggle.shared.setEnabled)
        }
        if BatteryService.hasBattery {
            addModuleRow(stack, icon: "bolt", title: l.moduleName(.battery)) {
                (BatteryToggle.shared.enabled, BatteryToggle.shared.setEnabled)
            }
        }
        addModuleRow(stack, icon: "speedometer", title: l.moduleName(.limit)) {
            (LimitToggle.shared.enabled, LimitToggle.shared.setEnabled)
        }
        addModuleRow(stack, icon: "contextualmenu", title: l.finderMenu) {
            (FinderMenuToggle.shared.enabled, FinderMenuToggle.shared.setEnabled)
        }

        stack.addArrangedSubview(separator())

        // 限速摘要（3 秒刷新）
        stack.addArrangedSubview(sectionLabel(l.powerLimit))
        let limitLabel = label("--", size: 12, mono: true)
        let powerLabel = label("--", size: 12, mono: true)
        let thermalLabel = label("--", size: 12, mono: true)
        limitValueLabel = limitLabel
        powerValueLabel = powerLabel
        thermalValueLabel = thermalLabel
        stack.addArrangedSubview(row(prefix: l.cpuSpeedLimit, value: limitLabel))
        stack.addArrangedSubview(row(prefix: l.powerLimit, value: powerLabel))
        stack.addArrangedSubview(row(prefix: l.thermalStateLabel, value: thermalLabel))

        stack.addArrangedSubview(separator())

        // SwiftUI 专属功能：不可用（显示但不加载）
        stack.addArrangedSubview(sectionLabel(l.language == .zh ? "此设备不可用" : "Unavailable on this device"))
        let unavailableHint = label(
            l.language == .zh
                ? "历史曲线 / 全部温度 / 限速温度面板因图形驱动兼容问题停用。"
                : "History / all-temperatures / limit panel are disabled due to the GPU driver issue.",
            size: 11
        )
        unavailableHint.textColor = .secondaryLabelColor
        unavailableHint.maximumNumberOfLines = 0
        unavailableHint.preferredMaxLayoutWidth = 240
        stack.addArrangedSubview(unavailableHint)

        stack.addArrangedSubview(separator())

        // 刷新间隔
        let refreshRow = hstack()
        refreshRow.addArrangedSubview(label(l.refreshInterval, size: 12))
        let refreshPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
        refreshPopup.addItems(withTitles: ["3s", "5s", "10s"])
        let current = MonitorManager.shared.refreshInterval
        refreshPopup.selectItem(withTitle: "\(Int(current))s")
        refreshPopup.target = self
        refreshPopup.action = #selector(refreshChanged(_:))
        refreshRow.addArrangedSubview(refreshPopup)
        stack.addArrangedSubview(refreshRow)

        stack.addArrangedSubview(separator())

        // 语言
        let langRow = hstack()
        langRow.addArrangedSubview(label(l.languageLabel, size: 12))
        let langPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
        langPopup.addItems(withTitles: Language.allCases.map(\.displayName))
        langPopup.selectItem(withTitle: l.language.displayName)
        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))
        langRow.addArrangedSubview(langPopup)
        stack.addArrangedSubview(langRow)

        // 开机自启动
        let loginToggle = NSSwitch()
        loginToggle.controlSize = .small
        loginToggle.state = LaunchAtLoginService.shared.isEnabled ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled(_:))
        stack.addArrangedSubview(row(prefix: l.launchAtLogin, accessory: loginToggle))

        stack.addArrangedSubview(separator())

        let quit = NSButton(title: l.quit, target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.contentTintColor = .systemRed
        stack.addArrangedSubview(quit)

        self.panel = p
        p.setFrameAutosaveName("FallbackSettingsPanel")
    }

    // MARK: - 构建辅助

    private func vstack(spacing: CGFloat = 10) -> NSStackView {
        let sv = NSStackView(views: [])
        sv.orientation = .vertical
        sv.alignment = .leading
        sv.spacing = spacing
        return sv
    }

    private func hstack(spacing: CGFloat = 8) -> NSStackView {
        let sv = NSStackView(views: [])
        sv.orientation = .horizontal
        sv.spacing = spacing
        return sv
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, mono: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        if mono {
            t.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        } else {
            t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        }
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let t = label(text, size: 11, bold: true)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func row(prefix: String, value: NSTextField) -> NSView {
        let row = hstack()
        let p = label(prefix, size: 12)
        row.addArrangedSubview(p)
        row.addArrangedSubview(value)
        return row
    }

    private func row(prefix: String, accessory: NSView) -> NSView {
        let row = hstack()
        let p = label(prefix, size: 12)
        row.addArrangedSubview(p)
        row.addArrangedSubview(accessory)
        return row
    }

    private func addModuleRow(
        _ stack: NSStackView, icon: String, title: String,
        state: () -> (Bool, (Bool) -> Void)
    ) {
        let row = hstack()
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        row.addArrangedSubview(iconView)
        let t = label(title, size: 12)
        row.addArrangedSubview(t)

        let sw = NSSwitch()
        sw.controlSize = .small
        let current = state()
        sw.state = current.0 ? .on : .off
        sw.target = self
        sw.action = #selector(moduleSwitchChanged(_:))
        sw.identifier = NSUserInterfaceItemIdentifier(title)
        // 闭包经关联对象携带，避免 target/action 里反查
        objc_setAssociatedObject(sw, "handler", current.1, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        row.addArrangedSubview(sw)

        // 标签占满中间，开关贴右
        row.setCustomSpacing(60, after: iconView)
        stack.addArrangedSubview(row)
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

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.midX - p.frame.width / 2, y: visible.midY - p.frame.height / 2))
        }
    }
}
