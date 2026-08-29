import Foundation
import IOKit

/// Reads CPU/GPU/system power (W) and throttling limits from SMC.
/// Keys verified on Intel MacBook Pro (i9-9980HK); falls back gracefully elsewhere.
final class PowerLimitService {
    static let shared = PowerLimitService()

    private init() {}

    /// Total system power in watts (SMC "PSTR", flt)
    func systemPowerWatts() -> Double? {
        guard let v = SMCService.shared.readKey("PSTR"), v > 0, v < 500 else { return nil }
        return v
    }

    /// CPU package power in watts (SMC "PCPC", sp87)
    func cpuPowerWatts() -> Double? {
        guard let v = SMCService.shared.readKey("PCPC"), v > 0, v < 200 else { return nil }
        return v
    }

    /// GPU power in watts (SMC "PCPG", sp87)
    func gpuPowerWatts() -> Double? {
        guard let v = SMCService.shared.readKey("PCPG"), v >= 0, v < 200 else { return nil }
        return v
    }

    /// Current allowed CPU speed as percentage of max (SMC "MSAc", fp88).
    /// < 100 means the CPU is currently throttled.
    func cpuSpeedLimitPercent() -> Double? {
        guard let v = SMCService.shared.readKey("MSAc"), v > 0, v <= 100 else { return nil }
        return v
    }

    /// Power limits reported by the SMC PLIMIT command (values are percentages).
    func powerLimits() -> (cpu: Double, gpu: Double, mem: Double)? {
        let p = SMCService.shared.readPLimit()
        guard p.cpu > 0 || p.gpu > 0 || p.mem > 0 else { return nil }
        return (cpu: Double(p.cpu), gpu: Double(p.gpu), mem: Double(p.mem))
    }

    /// 0 = nominal, 1 = fair, 2 = serious, 3 = critical
    var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
