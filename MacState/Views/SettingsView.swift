import SwiftUI

/// Always-visible throttle summary shown in the settings popover.
private struct ThrottleStatusSection: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var showAllTemps = false
    /// 展开状态变化时通知外层（弹窗加高、滚动定位）
    var onExpandedChange: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { showAllTemps.toggle() }
                onExpandedChange?(showAllTemps)
                NotificationCenter.default.post(
                    name: Notification.Name("MacStateSensorsExpanded"),
                    object: nil,
                    userInfo: ["expanded": showAllTemps]
                )
            }) {
                HStack {
                    Text(l10n.powerLimit)
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showAllTemps ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            summary

            if showAllTemps {
                SensorsView(showsHeader: false, scrollable: false, compact: true)
            }
        }
        .onAppear {
            // 测试钩子：MACSTATE_AUTO_EXPAND=1 时 5 秒后自动走一遍展开链路
            guard ProcessInfo.processInfo.environment["MACSTATE_AUTO_EXPAND"] == "1" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showAllTemps = true
                onExpandedChange?(true)
                NotificationCenter.default.post(
                    name: Notification.Name("MacStateSensorsExpanded"),
                    object: nil,
                    userInfo: ["expanded": true]
                )
            }
        }
    }

    private var summary: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                let power = PowerLimitService.shared
                let limits = power.currentPowerLimits()
                let avg = power.cpuAverageLimitPercent()
                let thermal = power.thermalState

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
                        value: thermalName(thermal),
                        highlight: thermal.rawValue >= 2
                    )
                    Spacer()
                }

                Text(l10n.throttleHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
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

struct SettingsView: View {
    @ObservedObject var l10n: L10n = L10n.shared
    @StateObject private var loginService = LaunchAtLoginService.shared
    @ObservedObject private var cpuToggle = CpuToggle.shared
    @ObservedObject private var cpuTempToggle = CpuTempToggle.shared
    @ObservedObject private var memoryToggle = MemoryToggle.shared
    @ObservedObject private var fanToggle = FanToggle.shared
    @ObservedObject private var networkToggle = NetworkToggle.shared
    @ObservedObject private var batteryToggle = BatteryToggle.shared
    @ObservedObject private var igpuToggle = IGpuToggle.shared
    @ObservedObject private var dgpuToggle = DGpuToggle.shared
    @ObservedObject private var limitToggle = LimitToggle.shared
    @ObservedObject private var finderMenuToggle = FinderMenuToggle.shared

    let manager: MonitorManager
    @Binding var showHistory: Bool
    @Binding var showSensors: Bool

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(l10n.appName) v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")(\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://github.com/snail007/macstate") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text("GitHub")
                    }
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            Divider()

            Text(l10n.modules)
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.cpuTemp))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "cpuTemp", isOn: cpuTempToggle.enabled) { newValue in
                    CpuTempToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.cpuUsage))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "cpu", isOn: cpuToggle.enabled) { newValue in
                    CpuToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            if GPUService.hasGPU {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.moduleName(.igpu))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AppKitSwitch(label: "igpu", isOn: igpuToggle.enabled) { newValue in
                        IGpuToggle.shared.setEnabled(newValue)
                    }
                    .frame(width: 54, height: 24)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "network")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.network))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "network", isOn: networkToggle.enabled) { newValue in
                    NetworkToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            if GPUService.hasGPU {
                HStack(spacing: 8) {
                    Image(systemName: "display")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.moduleName(.dgpu))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AppKitSwitch(label: "dgpu", isOn: dgpuToggle.enabled) { newValue in
                        DGpuToggle.shared.setEnabled(newValue)
                    }
                    .frame(width: 54, height: 24)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.memory))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "memory", isOn: memoryToggle.enabled) { newValue in
                    MemoryToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            HStack(spacing: 8) {
                Image(systemName: "fan")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.fan))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "fan", isOn: fanToggle.enabled) { newValue in
                    FanToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            if BatteryService.hasBattery {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.moduleName(.battery))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AppKitSwitch(label: "battery", isOn: batteryToggle.enabled) { newValue in
                        BatteryToggle.shared.setEnabled(newValue)
                    }
                    .frame(width: 54, height: 24)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .frame(width: 20, alignment: .center)
                Text(l10n.moduleName(.limit))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "limit", isOn: limitToggle.enabled) { newValue in
                    LimitToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            HStack(spacing: 8) {
                Image(systemName: "contextualmenu.and.cursorarrow")
                    .frame(width: 20, alignment: .center)
                Text(l10n.finderMenu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppKitSwitch(label: "finderMenu", isOn: finderMenuToggle.enabled) { newValue in
                    FinderMenuToggle.shared.setEnabled(newValue)
                }
                .frame(width: 54, height: 24)
            }

            Divider()

            ThrottleStatusSection(onExpandedChange: { expanded in
                guard expanded else { return }
                // 展开后把温度区滚动到可视位置，否则看起来像点了没反应
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo("throttleSection", anchor: .top) }
                }
            })
            .id("throttleSection")

            Divider()

            Button(action: {
                showHistory = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.historyButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            Button(action: {
                showSensors = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.sensorsButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            Divider()

            HStack {
                Text(l10n.refreshInterval)
                    .font(.subheadline.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { manager.refreshInterval },
                    set: { manager.updateRefreshInterval($0) }
                )) {
                    Text("3s").tag(3.0 as TimeInterval)
                    Text("5s").tag(5.0 as TimeInterval)
                    Text("10s").tag(10.0 as TimeInterval)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            Divider()

            Text(l10n.general)
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            Toggle(isOn: Binding(
                get: { loginService.isEnabled },
                set: { _ in loginService.toggle() }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 20, alignment: .center)
                    Text(l10n.launchAtLogin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .frame(width: 20, alignment: .center)
                Text(l10n.languageLabel)
                Spacer()
                Picker("", selection: $l10n.language) {
                    ForEach(Language.allCases, id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            Divider()

            Button(l10n.quit) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            }
            // 锁定内容宽度：280 弹窗 - 2×20 padding。不锁的话节流摘要会把
            // VStack 撑到 ~330pt，开关被顶出右边界裁掉
            .frame(width: 240)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}
