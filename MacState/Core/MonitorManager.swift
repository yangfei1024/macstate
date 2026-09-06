import Foundation
import Combine

protocol MonitorModule: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var isEnabled: Bool { get set }
    var isAvailable: Bool { get }

    func refresh()
}

enum ModuleType: String, CaseIterable, Identifiable {
    case cpuUsage = "cpu_usage"
    case cpuTemp = "cpu_temp"
    case memory = "memory"
    case fan = "fan"
    case network = "network"
    case battery = "battery"
    case gpuUsage = "gpu_usage"
    case gpuTemp = "gpu_temp"
    case igpu = "igpu"
    case dgpu = "dgpu"
    case limit = "limit"

    var id: String { rawValue }

    var defaultsKey: String {
        return "module_enabled_\(rawValue)"
    }
}

@MainActor
final class MonitorManager: ObservableObject {
    static let shared = MonitorManager()

    @Published var cpuUsage: Double = 0
    @Published var cpuTemp: Double = 0
    @Published var memoryUsage: MemoryUsage = MemoryUsage(
        total: 0, used: 0, free: 0, active: 0, inactive: 0, wired: 0, compressed: 0
    )
    @Published var fanSpeeds: [(current: Double, min: Double, max: Double)] = []
    @Published var networkSpeed = NetworkSpeed(upload: 0, download: 0)
    @Published var batteryInfo = BatteryInfo()
    @Published var gpuUsage: Double = -1
    @Published var gpuTemp: Double = 0
    @Published var igpuUsage: Double = -1
    @Published var igpuTemp: Double = 0
    @Published var dgpuUsage: Double = -1
    @Published var dgpuTemp: Double = 0
    @Published var cpuSpeedLimit: Double = -1

    @Published var refreshInterval: TimeInterval = 3.0

    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let intervalKey = "refreshInterval"

    private init() {
        migrateOldSettings()
        loadInterval()
        startMonitoring()
        DispatchQueue.global(qos: .utility).async {
            _ = ProcessCPUService.shared
        }
    }

    // MARK: - Refresh Interval

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(1.0, min(30.0, interval))
        defaults.set(refreshInterval, forKey: intervalKey)
        startMonitoring()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private let workQueue = DispatchQueue(label: "com.snail007.macstate.monitor", qos: .utility)

    private func refresh() {
        let cpuTempEnabled = CpuTempToggle.shared.enabled
        let memoryEnabled = MemoryToggle.shared.enabled
        let fanEnabled = FanToggle.shared.enabled
        let networkEnabled = NetworkToggle.shared.enabled
        let batteryEnabled = BatteryToggle.shared.enabled
        let igpuEnabled = IGpuToggle.shared.enabled
        let dgpuEnabled = DGpuToggle.shared.enabled
        let gpuTracked = igpuEnabled || dgpuEnabled
        let limitEnabled = LimitToggle.shared.enabled

        workQueue.async { [weak self] in
            let cpu = CPUService.shared.totalUsage()
            let temp = SMCService.shared.cpuTemperature() ?? 0
            let mem = memoryEnabled ? MemoryService.shared.usage() : nil
            let fans = fanEnabled ? SMCService.shared.allFanSpeeds() : nil
            let net = networkEnabled ? NetworkService.shared.currentSpeed() : nil
            let bat = batteryEnabled ? BatteryService.shared.info() : nil
            let gpuUsages = gpuTracked ? GPUService.shared.allGPUUsages() : []
            let gpuTemps = gpuTracked ? GPUService.shared.allGPUTemperatures() : []
            let igpuU = gpuUsages.first { $0.name == "integrated" }?.usage ?? -1.0
            let dgpuU = gpuUsages.first { $0.name == "discrete" }?.usage ?? -1.0
            let igpuT = gpuTemps.first { $0.label == "integrated" }?.temp ?? 0
            let dgpuT = gpuTemps.first { $0.label == "discrete" }?.temp ?? 0
            let gpu = gpuTracked ? max(igpuU, dgpuU) : -1.0
            let gpuT = gpuTracked ? max(igpuT, dgpuT) : 0

            // Power / throttle metrics for history recording (SMC reads are
            // cheap but stay off the main thread)
            let power = PowerLimitService.shared
            let cpuPower = power.cpuPowerWatts() ?? -1
            let gpuPower = power.gpuPowerWatts() ?? -1
            let sysPower = power.systemPowerWatts() ?? -1
            let speedLimit = power.cpuSpeedLimitPercent() ?? -1
            let thermalState = power.thermalState.rawValue

            DispatchQueue.main.async {
                guard let self else { return }
                if Int(self.cpuUsage) != Int(cpu) { self.cpuUsage = cpu }
                if cpuTempEnabled && Int(self.cpuTemp) != Int(temp) { self.cpuTemp = temp }
                if let mem, Int(self.memoryUsage.usedPercentage) != Int(mem.usedPercentage) { self.memoryUsage = mem }
                if let fans {
                    if fans.count != self.fanSpeeds.count || !zip(fans, self.fanSpeeds).allSatisfy({ Int($0.0.current) == Int($0.1.current) }) {
                        self.fanSpeeds = fans
                    }
                }
                if let net {
                    if Int(net.upload) != Int(self.networkSpeed.upload) || Int(net.download) != Int(self.networkSpeed.download) {
                        self.networkSpeed = net
                    }
                }
                if let bat {
                    if bat.percentage != self.batteryInfo.percentage ||
                       bat.isCharging != self.batteryInfo.isCharging ||
                       bat.isPluggedIn != self.batteryInfo.isPluggedIn ||
                       Int(bat.adapterPowerWatts * 10) != Int(self.batteryInfo.adapterPowerWatts * 10) ||
                       Int(bat.powerWatts * 10) != Int(self.batteryInfo.powerWatts * 10) {
                        self.batteryInfo = bat
                    }
                }
                if gpuTracked && Int(self.gpuUsage) != Int(gpu) { self.gpuUsage = gpu }
                if gpuTracked && Int(self.gpuTemp) != Int(gpuT) { self.gpuTemp = gpuT }
                if igpuEnabled && Int(self.igpuUsage) != Int(igpuU) { self.igpuUsage = igpuU }
                if igpuEnabled && Int(self.igpuTemp) != Int(igpuT) { self.igpuTemp = igpuT }
                if dgpuEnabled && Int(self.dgpuUsage) != Int(dgpuU) { self.dgpuUsage = dgpuU }
                if dgpuEnabled && Int(self.dgpuTemp) != Int(dgpuT) { self.dgpuTemp = dgpuT }
                if limitEnabled && Int(self.cpuSpeedLimit) != Int(speedLimit) { self.cpuSpeedLimit = speedLimit }

                HistoryStore.shared.record(
                    cpuLoad: cpu,
                    cpuTemp: temp,
                    gpuTemp: gpuT,
                    cpuPower: cpuPower,
                    gpuPower: gpuPower,
                    sysPower: sysPower,
                    cpuSpeedLimit: speedLimit,
                    thermalState: thermalState
                )
            }
        }
    }

    // MARK: - Settings

    private func loadInterval() {
        let interval = defaults.double(forKey: intervalKey)
        if interval > 0 {
            refreshInterval = interval
        }
    }

    private func migrateOldSettings() {
        let oldKey = "enabledModules"
        let versionKey = "settingsVersion"
        let currentVersion = 2

        if defaults.integer(forKey: versionKey) < currentVersion {
            if let saved = defaults.array(forKey: oldKey) as? [String] {
                for moduleType in ModuleType.allCases {
                    if moduleType == .cpuUsage { continue }
                    defaults.set(saved.contains(moduleType.rawValue), forKey: moduleType.defaultsKey)
                }
                defaults.removeObject(forKey: oldKey)
            }

            let allKeys = defaults.dictionaryRepresentation().keys
            for key in allKeys {
                if key.hasPrefix("NSStatusItem") {
                    defaults.removeObject(forKey: key)
                }
            }

            defaults.set(currentVersion, forKey: versionKey)
        }
    }
}
