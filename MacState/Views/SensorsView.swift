import SwiftUI

// MARK: - 传感器分组

enum SensorGroup: Int, CaseIterable {
    case cpu, gpu, power, board, battery, heatsink, enclosure, ambient, other

    func title(_ language: Language) -> String {
        switch self {
        case .cpu: return language == .zh ? "CPU / 核显" : "CPU / iGPU"
        case .gpu: return language == .zh ? "独立显卡" : "Discrete GPU"
        case .power: return language == .zh ? "供电 / VRM（板级）" : "Power / VRM (board)"
        case .board: return language == .zh ? "芯片组 / 主板" : "Chipset / Board"
        case .battery: return language == .zh ? "电池" : "Battery"
        case .heatsink: return language == .zh ? "散热 / 风道" : "Heatsink / Airflow"
        case .enclosure: return language == .zh ? "外壳 / 掌托" : "Enclosure"
        case .ambient: return language == .zh ? "环境" : "Ambient"
        case .other: return language == .zh ? "其他 / 未标注" : "Other / Unlabeled"
        }
    }
}

struct SMCTempSensor: Identifiable {
    let key: String
    let zh: String
    let en: String
    let group: SensorGroup

    var id: String { key }
    func label(_ language: Language) -> String { language == .zh ? zh : en }
}

// MARK: - 温度传感器页面

/// 列出 SMC 上全部温度键（运行时枚举，不写死机型清单）。
/// 已知键显示中英文含义，未知键按原始键名归入"其他"。
struct SensorsView: View {
    @ObservedObject private var l10n = L10n.shared
    @StateObject private var reader = SensorReader()

    var showsHeader: Bool = true
    /// 弹窗整页模式自带 ScrollView；嵌入其他页面（已有 ScrollView）时关掉。
    var scrollable: Bool = true
    /// 窄容器（280 宽的设置页）下隐藏热力条，省出标签宽度。
    var compact: Bool = false

    @State private var sensors: [SMCTempSensor] = []
    @State private var discovered = false

    private static let catalog: [String: (zh: String, en: String, group: SensorGroup)] = [
        // CPU / 核显
        "TC0E": ("CPU 封装 E", "CPU Package E", .cpu),
        "TC0F": ("CPU 封装 F", "CPU Package F", .cpu),
        "TC0T": ("PECI 偏移", "PECI Offset", .cpu),
        "TC1C": ("CPU 核心 1", "CPU Core 1", .cpu),
        "TC2C": ("CPU 核心 2", "CPU Core 2", .cpu),
        "TC3C": ("CPU 核心 3", "CPU Core 3", .cpu),
        "TC4C": ("CPU 核心 4", "CPU Core 4", .cpu),
        "TC5C": ("CPU 核心 5", "CPU Core 5", .cpu),
        "TC6C": ("CPU 核心 6", "CPU Core 6", .cpu),
        "TC7C": ("CPU 核心 7", "CPU Core 7", .cpu),
        "TC8C": ("CPU 核心 8", "CPU Core 8", .cpu),
        "TCGC": ("核显核心", "iGPU Die", .cpu),
        "TCMX": ("CPU 最热核", "CPU Hottest Core", .cpu),
        "TCXC": ("CPU 复合 max", "CPU Complex Max", .cpu),
        "TCSA": ("System Agent", "System Agent", .cpu),
        // 独立显卡
        "TGDD": ("独显核心", "dGPU Die", .gpu),
        "TGDE": ("独显二极管 E", "dGPU Diode E", .gpu),
        "TGDF": ("独显二极管 F", "dGPU Diode F", .gpu),
        "TG0P": ("独显近旁", "dGPU Proximity", .gpu),
        "TG1P": ("独显近旁 2", "dGPU Proximity 2", .gpu),
        "TGDT": ("未挂载", "Unpopulated", .gpu),
        // 供电 / VRM（板级测点，非结温）
        "TC0P": ("CPU 供电区近旁", "CPU VRM-area Proximity", .power),
        "TGVP": ("独显供电区", "dGPU VRM Area", .power),
        "TGVF": ("独显供电区 F", "dGPU VRM Filtered", .power),
        // 芯片组 / 主板
        "TPCD": ("PCH 芯片组", "PCH Die", .board),
        "TM0P": ("内存区", "Memory Area", .board),
        "Tm0P": ("主板", "Mainboard", .board),
        "TW0P": ("无线网卡", "Wireless Card", .board),
        "TTLD": ("TB3 左侧", "Thunderbolt L", .board),
        "TTRD": ("TB3 右侧", "Thunderbolt R", .board),
        // 电池
        "TB0T": ("电池 1", "Battery 1", .battery),
        "TB1T": ("电池 2", "Battery 2", .battery),
        "TB2T": ("电池 3", "Battery 3", .battery),
        // 散热 / 风道
        "Th1H": ("热管区 1", "Heatsink 1", .heatsink),
        "Th2H": ("热管区 2", "Heatsink 2", .heatsink),
        "TH0F": ("风道 F", "Airflow F", .heatsink),
        "TH0X": ("风道 X", "Airflow X", .heatsink),
        "TH0a": ("进风热敏 a", "Inlet a", .heatsink),
        "TH0b": ("进风热敏 b", "Inlet b", .heatsink),
        "TH1a": ("进风热敏 1a", "Inlet 1a", .heatsink),
        "TH1b": ("进风热敏 1b", "Inlet 1b", .heatsink),
        // 外壳 / 掌托
        "Ts0P": ("掌托 左", "Palm Rest L", .enclosure),
        "Ts1P": ("掌托 右", "Palm Rest R", .enclosure),
        "Ts0S": ("外壳皮肤 1", "Shell Skin 1", .enclosure),
        "Ts1S": ("外壳皮肤 2", "Shell Skin 2", .enclosure),
        "Ts2S": ("外壳皮肤 3", "Shell Skin 3", .enclosure),
        "TaLC": ("左接口区", "Left Ports", .enclosure),
        "TaRC": ("右接口区", "Right Ports", .enclosure),
        // 环境
        "TA0V": ("环境空气", "Ambient Air", .ambient),
        // 未标注
        "TF0S": ("未标注", "Unlabeled", .other),
    ]

    var body: some View {
        Group {
            if discovered && sensors.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(l10n.language == .zh ? "未发现温度传感器" : "No temperature sensors found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if discovered {
                list
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(l10n.language == .zh ? "正在枚举 SMC…" : "Enumerating SMC…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: discover)
        .onDisappear { reader.stop() }
    }

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 10) {
            if showsHeader {
                HStack {
                    Text(l10n.language == .zh ? "温度传感器" : "Temperature Sensors")
                        .font(.headline)
                    Spacer()
                    Text("\(sensors.count) · 3s")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if scrollable {
                ScrollView {
                    content
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SensorGroup.allCases, id: \.rawValue) { group in
                let groupSensors = sensors.filter { $0.group == group }
                if !groupSensors.isEmpty {
                    section(group: group, sensors: groupSensors)
                }
            }
            Text(l10n.sensorsPowerNote)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func section(group: SensorGroup, sensors: [SMCTempSensor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title(l10n.language))
                .font(.subheadline.bold())
                .foregroundColor(.secondary)
            ForEach(sensors) { sensor in
                row(sensor)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func row(_ sensor: SMCTempSensor) -> some View {
        let value = reader.values[sensor.key]

        return HStack(spacing: 8) {
            Text(sensor.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(sensor.label(l10n.language))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                heatBar(value)
            }
            Text(valueText(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(valueColor(value))
                .frame(width: compact ? 48 : 56, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private func valueText(_ value: Double?) -> String {
        guard let value, isPlausible(value) else { return "--" }
        return String(format: "%.1f°C", value)
    }

    private func valueColor(_ value: Double?) -> Color {
        guard let value, isPlausible(value) else { return .secondary }
        if value >= 85 { return .red }
        if value >= 70 { return .orange }
        return .primary
    }

    /// 1–120°C 之外的读数不是真实温度：偏移量（TC0T ±0.x）、未挂载测点（TGDT 恒 0）。
    private func isPlausible(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value > 1 && value < 120
    }

    /// 20–100°C 映射到色条长度与颜色，一眼看出哪个测点最热。
    private func heatBar(_ value: Double?) -> some View {
        let fraction = value.flatMap { isPlausible($0) ? min(max(($0 - 20) / 80, 0), 1) : 0 } ?? 0

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
            Capsule()
                .fill(heatColor(value))
                .frame(width: max(36 * fraction, fraction > 0 ? 3 : 0), height: 4)
        }
        .frame(width: 36, height: 4)
    }

    private func heatColor(_ value: Double?) -> Color {
        guard let value, isPlausible(value) else { return .clear }
        if value >= 85 { return .red }
        if value >= 70 { return .orange }
        if value >= 55 { return .yellow }
        return .green
    }

    /// 运行时枚举 SMC 全键，取 T 开头的温度键。
    private func discover() {
        let keys = SMCService.shared.allKeys().filter { $0.hasPrefix("T") }
        sensors = keys.sorted().map { key in
            if let entry = Self.catalog[key] {
                return SMCTempSensor(key: key, zh: entry.zh, en: entry.en, group: entry.group)
            }
            return SMCTempSensor(key: key, zh: key, en: key, group: .other)
        }
        discovered = true
        if !sensors.isEmpty {
            reader.start(keys: sensors.map(\.key))
        }
    }
}

// MARK: - 周期读取

@MainActor
final class SensorReader: ObservableObject {
    @Published var values: [String: Double] = [:]

    private var timer: Timer?
    private var keys: [String] = []

    func start(keys: [String]) {
        self.keys = keys
        timer?.invalidate()
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.read() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        var latest: [String: Double] = [:]
        latest.reserveCapacity(keys.count)
        for key in keys {
            if let value = SMCService.shared.readKey(key) {
                latest[key] = value
            }
        }
        values = latest
    }
}
