import SwiftUI

// 传感器分组与目录定义已移至 Core/SMCTempCatalog.swift（AppKit/SwiftUI 共用）

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
            if let known = SMCTempCatalog.byKey[key] {
                return known
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
