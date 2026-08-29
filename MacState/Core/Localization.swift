import Foundation
import Combine

enum Language: String, CaseIterable {
    case zh = "zh"
    case en = "en"

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: Language = .zh {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "app_language")
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "app_language"),
           let lang = Language(rawValue: saved) {
            language = lang
        }
    }

    // MARK: - 通用
    var appName: String { "MacState" }
    var back: String { language == .zh ? "返回" : "Back" }
    var settings: String { language == .zh ? "设置" : "Settings" }
    var quit: String { language == .zh ? "退出 MacState" : "Quit MacState" }

    // MARK: - 模块名称
    var modules: String { language == .zh ? "模块" : "Modules" }

    func moduleName(_ type: ModuleType) -> String {
        switch type {
        case .cpuUsage:
            return language == .zh ? "CPU 使用率" : "CPU Usage"
        case .cpuTemp:
            return language == .zh ? "CPU 温度" : "CPU Temperature"
        case .memory:
            return language == .zh ? "内存" : "Memory"
        case .fan:
            return language == .zh ? "风扇转速" : "Fan Speed"
        case .network:
            return language == .zh ? "网络速度" : "Network Speed"
        case .battery:
            return language == .zh ? "充电功率" : "Charging Power"
        case .gpuUsage:
            return language == .zh ? "GPU 使用率" : "GPU Usage"
        case .gpuTemp:
            return language == .zh ? "GPU 温度" : "GPU Temperature"
        }
    }

    // MARK: - 弹出面板
    var cpu: String { "CPU" }
    var temperature: String { language == .zh ? "温度" : "Temperature" }
    var memory: String { language == .zh ? "内存" : "Memory" }

    func fanLabel(_ index: Int) -> String {
        language == .zh ? "风扇 \(index)" : "Fan \(index)"
    }

    // MARK: - 网络
    var upload: String { language == .zh ? "上传" : "Upload" }
    var download: String { language == .zh ? "下载" : "Download" }

    // MARK: - 电池卡片
    var batteryPower: String { language == .zh ? "电池功率" : "Battery Power" }
    var chargingPrefix: String { language == .zh ? "充电" : "Charging" }
    var dischargingPrefix: String { language == .zh ? "放电" : "Discharging" }
    var charger: String { language == .zh ? "充电器" : "Charger" }
    var chargerPower: String { language == .zh ? "充电功率" : "Charging Power" }
    var adapterPower: String { language == .zh ? "充电功率" : "Charging Power" }
    var ratedPower: String { language == .zh ? "协商功率" : "Negotiated" }
    var adapterLabel: String { language == .zh ? "适配器" : "Adapter" }
    var notConnected: String { language == .zh ? "未连接" : "Not Connected" }
    var voltageLabel: String { language == .zh ? "电池电压" : "Battery Voltage" }
    var currentLabel: String { language == .zh ? "电池电流" : "Battery Current" }
    var batteryLevel: String { language == .zh ? "电池电量" : "Battery Level" }
    var cycleCountLabel: String { language == .zh ? "电池循环" : "Battery Cycles" }
    var batteryHealth: String { language == .zh ? "电池健康" : "Battery Health" }

    // MARK: - 进程面板
    var topProcesses: String { language == .zh ? "进程排行" : "Top Processes" }
    var processName: String { language == .zh ? "进程" : "Process" }
    var noActiveProcess: String { language == .zh ? "暂无活跃进程" : "No active processes" }
    var commandLine: String { language == .zh ? "命令行" : "Command" }
    var viewButton: String { language == .zh ? "查看" : "View" }
    var geoLocation: String { language == .zh ? "归属地" : "Location" }

    // MARK: - 能耗排行
    var energyRanking: String { language == .zh ? "能耗排行" : "Energy Ranking" }
    var discreteGPU: String { language == .zh ? "独立显卡" : "Discrete" }
    var integratedGPU: String { language == .zh ? "集成显卡" : "Integrated" }
    var usageLabel: String { language == .zh ? "使用率" : "Usage" }
    var temperatureLabel: String { language == .zh ? "温度" : "Temp" }

    // MARK: - 历史记录
    var historyTitle: String { language == .zh ? "历史曲线" : "History" }
    var retentionHint: String { language == .zh ? "保留最近 3 天数据" : "Keeps the last 3 days" }
    var threeDays: String { language == .zh ? "3天" : "3d" }
    var historyButton: String { language == .zh ? "历史曲线" : "History Charts" }
    var cpuSpeedLimit: String { language == .zh ? "CPU 限速" : "CPU Speed Limit" }
    var powerLimit: String { language == .zh ? "功率限制" : "Power Limit" }
    var thermalStateLabel: String { language == .zh ? "热状态" : "Thermal State" }
    var thermalNominal: String { language == .zh ? "正常" : "Nominal" }
    var thermalFair: String { language == .zh ? "轻微偏高" : "Fair" }
    var thermalSerious: String { language == .zh ? "偏高" : "Serious" }
    var thermalCritical: String { language == .zh ? "严重" : "Critical" }
    var powerChartTitle: String { language == .zh ? "功率 (W)" : "Power (W)" }
    var temperatureChartTitle: String { language == .zh ? "温度 (°C)" : "Temperature (°C)" }
    var loadChartTitle: String { language == .zh ? "CPU 负载 (%)" : "CPU Load (%)" }
    var limitChartTitle: String { language == .zh ? "CPU 限速 (%)" : "CPU Speed Limit (%)" }
    var cpuPower: String { language == .zh ? "CPU 功率" : "CPU Power" }
    var gpuPower: String { language == .zh ? "GPU 功率" : "GPU Power" }
    var sysPower: String { language == .zh ? "系统总功率" : "System Power" }

    // MARK: - 设置面板
    var refreshInterval: String { language == .zh ? "刷新间隔" : "Refresh Interval" }
    var general: String { language == .zh ? "通用" : "General" }
    var launchAtLogin: String { language == .zh ? "开机自启动" : "Launch at Login" }
    var languageLabel: String { language == .zh ? "语言" : "Language" }
    var finderMenu: String { language == .zh ? "Finder 右键菜单" : "Finder Context Menu" }
}
