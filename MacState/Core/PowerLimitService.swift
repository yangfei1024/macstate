import Foundation
import IOKit

/// Reads CPU/GPU/system power (W) and throttling limits from SMC.
/// Keys verified on Intel MacBook Pro (i9-9980HK); falls back gracefully elsewhere.
///
/// SMC reads can fail or return garbage when polled rapidly, so every metric
/// keeps a short-lived last-good cache and the speed limit falls back to the
/// SMC PLIMIT value when its own key is unreadable.
final class PowerLimitService {
    static let shared = PowerLimitService()

    private struct CachedValue {
        let value: Double
        let at: Date
    }

    private let cacheLock = NSLock()
    private var cache: [String: CachedValue] = [:]
    private let cacheTTL: TimeInterval = 30

    private init() {}

    /// Reads a key; on failure or implausible value, serves the last good
    /// value if it is still fresh.
    private func cachedOrRead(_ key: String, valid: (Double) -> Bool) -> Double? {
        let raw = SMCService.shared.readKey(key)
        if let v = raw, valid(v) {
            cacheLock.lock()
            cache[key] = CachedValue(value: v, at: Date())
            cacheLock.unlock()
            return v
        }
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.value
        }
        return nil
    }

    /// Total system power in watts (SMC "PSTR", flt)
    func systemPowerWatts() -> Double? {
        cachedOrRead("PSTR") { $0 > 0 && $0 < 500 }
    }

    /// CPU package power in watts (SMC "PCPC", sp87)
    func cpuPowerWatts() -> Double? {
        cachedOrRead("PCPC") { $0 > 0 && $0 < 200 }
    }

    /// GPU power in watts (SMC "PCPG", sp87)
    func gpuPowerWatts() -> Double? {
        cachedOrRead("PCPG") { $0 >= 0 && $0 < 200 }
    }

    /// Current allowed CPU speed as percentage of max (SMC "MSAc", fp88).
    /// < 100 means the CPU is currently capped; a low value at idle is normal
    /// power management. Falls back to the PLIMIT CPU percentage.
    func cpuSpeedLimitPercent() -> Double? {
        if let v = cachedOrRead("MSAc", valid: { $0 >= 5 && $0 <= 100 }) {
            return v
        }
        if let limits = powerLimits(), limits.cpu >= 5, limits.cpu <= 100 {
            return limits.cpu
        }
        return nil
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
