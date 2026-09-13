import Foundation
import SwiftUI

// MARK: - SMC 温度传感器目录（AppKit / SwiftUI 面板共用）

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

enum SMCTempCatalog {
    static let all: [SMCTempSensor] = [
        // CPU / 核显
        SMCTempSensor(key: "TC0E", zh: "CPU 封装 E", en: "CPU Package E", group: .cpu),
        SMCTempSensor(key: "TC0F", zh: "CPU 封装 F", en: "CPU Package F", group: .cpu),
        SMCTempSensor(key: "TC0T", zh: "PECI 偏移", en: "PECI Offset", group: .cpu),
        SMCTempSensor(key: "TC1C", zh: "CPU 核心 1", en: "CPU Core 1", group: .cpu),
        SMCTempSensor(key: "TC2C", zh: "CPU 核心 2", en: "CPU Core 2", group: .cpu),
        SMCTempSensor(key: "TC3C", zh: "CPU 核心 3", en: "CPU Core 3", group: .cpu),
        SMCTempSensor(key: "TC4C", zh: "CPU 核心 4", en: "CPU Core 4", group: .cpu),
        SMCTempSensor(key: "TC5C", zh: "CPU 核心 5", en: "CPU Core 5", group: .cpu),
        SMCTempSensor(key: "TC6C", zh: "CPU 核心 6", en: "CPU Core 6", group: .cpu),
        SMCTempSensor(key: "TC7C", zh: "CPU 核心 7", en: "CPU Core 7", group: .cpu),
        SMCTempSensor(key: "TC8C", zh: "CPU 核心 8", en: "CPU Core 8", group: .cpu),
        SMCTempSensor(key: "TCGC", zh: "核显核心", en: "iGPU Die", group: .cpu),
        SMCTempSensor(key: "TCMX", zh: "CPU 最热核", en: "CPU Hottest Core", group: .cpu),
        SMCTempSensor(key: "TCXC", zh: "CPU 复合 max", en: "CPU Complex Max", group: .cpu),
        SMCTempSensor(key: "TCSA", zh: "System Agent", en: "System Agent", group: .cpu),
        // 独立显卡
        SMCTempSensor(key: "TGDD", zh: "独显核心", en: "dGPU Die", group: .gpu),
        SMCTempSensor(key: "TGDE", zh: "独显二极管 E", en: "dGPU Diode E", group: .gpu),
        SMCTempSensor(key: "TGDF", zh: "独显二极管 F", en: "dGPU Diode F", group: .gpu),
        SMCTempSensor(key: "TG0P", zh: "独显近旁", en: "dGPU Proximity", group: .gpu),
        SMCTempSensor(key: "TG1P", zh: "独显近旁 2", en: "dGPU Proximity 2", group: .gpu),
        SMCTempSensor(key: "TGDT", zh: "未挂载", en: "Unpopulated", group: .gpu),
        // 供电 / VRM（板级测点，非结温）
        SMCTempSensor(key: "TC0P", zh: "CPU 供电区近旁", en: "CPU VRM-area Proximity", group: .power),
        SMCTempSensor(key: "TGVP", zh: "独显供电区", en: "dGPU VRM Area", group: .power),
        SMCTempSensor(key: "TGVF", zh: "独显供电区 F", en: "dGPU VRM Filtered", group: .power),
        // 芯片组 / 主板
        SMCTempSensor(key: "TPCD", zh: "PCH 芯片组", en: "PCH Die", group: .board),
        SMCTempSensor(key: "TM0P", zh: "内存区", en: "Memory Area", group: .board),
        SMCTempSensor(key: "Tm0P", zh: "主板", en: "Mainboard", group: .board),
        SMCTempSensor(key: "TW0P", zh: "无线网卡", en: "Wireless Card", group: .board),
        SMCTempSensor(key: "TTLD", zh: "TB3 左侧", en: "Thunderbolt L", group: .board),
        SMCTempSensor(key: "TTRD", zh: "TB3 右侧", en: "Thunderbolt R", group: .board),
        // 电池
        SMCTempSensor(key: "TB0T", zh: "电池 1", en: "Battery 1", group: .battery),
        SMCTempSensor(key: "TB1T", zh: "电池 2", en: "Battery 2", group: .battery),
        SMCTempSensor(key: "TB2T", zh: "电池 3", en: "Battery 3", group: .battery),
        // 散热 / 风道
        SMCTempSensor(key: "Th1H", zh: "热管区 1", en: "Heatsink 1", group: .heatsink),
        SMCTempSensor(key: "Th2H", zh: "热管区 2", en: "Heatsink 2", group: .heatsink),
        SMCTempSensor(key: "TH0F", zh: "风道 F", en: "Airflow F", group: .heatsink),
        SMCTempSensor(key: "TH0X", zh: "风道 X", en: "Airflow X", group: .heatsink),
        SMCTempSensor(key: "TH0a", zh: "进风热敏 a", en: "Inlet a", group: .heatsink),
        SMCTempSensor(key: "TH0b", zh: "进风热敏 b", en: "Inlet b", group: .heatsink),
        SMCTempSensor(key: "TH1a", zh: "进风热敏 1a", en: "Inlet 1a", group: .heatsink),
        SMCTempSensor(key: "TH1b", zh: "进风热敏 1b", en: "Inlet 1b", group: .heatsink),
        // 外壳 / 掌托
        SMCTempSensor(key: "Ts0P", zh: "掌托 左", en: "Palm Rest L", group: .enclosure),
        SMCTempSensor(key: "Ts1P", zh: "掌托 右", en: "Palm Rest R", group: .enclosure),
        SMCTempSensor(key: "Ts0S", zh: "外壳皮肤 1", en: "Shell Skin 1", group: .enclosure),
        SMCTempSensor(key: "Ts1S", zh: "外壳皮肤 2", en: "Shell Skin 2", group: .enclosure),
        SMCTempSensor(key: "Ts2S", zh: "外壳皮肤 3", en: "Shell Skin 3", group: .enclosure),
        SMCTempSensor(key: "TaLC", zh: "左接口区", en: "Left Ports", group: .enclosure),
        SMCTempSensor(key: "TaRC", zh: "右接口区", en: "Right Ports", group: .enclosure),
        // 环境
        SMCTempSensor(key: "TA0V", zh: "环境空气", en: "Ambient Air", group: .ambient),
        // 未标注
        SMCTempSensor(key: "TF0S", zh: "未标注", en: "Unlabeled", group: .other),
    ]

    static let byKey: [String: SMCTempSensor] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }()
}
