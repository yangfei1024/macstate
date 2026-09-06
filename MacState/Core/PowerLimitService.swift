import Foundation
import IOKit

/// Reads CPU/GPU/system power (W) and throttling limits from SMC.
/// Keys verified on Intel MacBook Pro (i9-9980HK, A2141); falls back
/// gracefully elsewhere.
///
/// The SMC carries two different "limit" values, and confusing them makes
/// the display lie:
/// - **PLIMIT command** (selector 11): the limit the SMC is enforcing
///   *right now* (0 = not limited). Instantaneous — drops within seconds
///   of a power spike and clears when the constraint is released.
/// - **"MSAc" key**: a diagnostic log value — the rolling AVERAGE of the
///   PLIMITs the SMC has sent. It lags a throttle event by tens of
///   minutes and reads ~0 on a machine that hasn't been clamped recently.
///
/// SMC reads can fail or return garbage when polled rapidly, so every metric
/// keeps a short-lived last-good cache and the speed limit falls back to the
/// MSAc average when the PLIMIT read fails.
final class PowerLimitService {
    static let shared = PowerLimitService()

    private struct CachedValue {
        let value: Double
        let at: Date
    }

    private let cacheLock = NSLock()
    private var cache: [String: CachedValue] = [:]
    private let cacheTTL: TimeInterval = 30

    private var plimitCache: CachedPair?
    private struct CachedPair {
        let value: (cpu: Double, gpu: Double, mem: Double)
        let at: Date
    }

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

    /// Limits the SMC is enforcing right now, percent of max (0 = not
    /// limited). Instantaneous: follows load within seconds, clears on release.
    /// Failed reads serve the last good value while it is fresh, so a flaky
    /// SMC doesn't flip the display to the lagging average or "--".
    func currentPowerLimits() -> (cpu: Double, gpu: Double, mem: Double)? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let p = SMCService.shared.readPLimit(), p.cpu <= 100, p.gpu <= 100, p.mem <= 100 {
            let value = (cpu: Double(p.cpu), gpu: Double(p.gpu), mem: Double(p.mem))
            plimitCache = CachedPair(value: value, at: Date())
            return value
        }
        if let cached = plimitCache, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.value
        }
        return nil
    }

    /// CPU speed limit for display, percent of max (100 = unlimited).
    ///
    /// Primary: the instantaneous PLIMIT command. Fallback: the "MSAc"
    /// average — NOT an instantaneous value, it trails a throttle event by
    /// tens of minutes — used only while the PLIMIT read fails.
    func cpuSpeedLimitPercent() -> Double? {
        if let limits = currentPowerLimits() {
            return limits.cpu > 0 ? limits.cpu : 100
        }
        if let v = cachedOrRead("MSAc", valid: { $0 >= 0 && $0 <= 100 }) {
            return v > 0 ? v : 100
        }
        return nil
    }

    /// GPU speed limit currently enforced, percent of max (100 = unlimited).
    /// Nil when the PLIMIT read fails.
    func gpuSpeedLimitPercent() -> Double? {
        guard let limits = currentPowerLimits() else { return nil }
        return limits.gpu > 0 ? limits.gpu : 100
    }

    /// Recent-average CPU limit from the SMC diagnostic key "MSAc" — the
    /// rolling average of PLIMITs the SMC has sent. Diagnostic only: it lags
    /// the real limit and reads ~0 on a machine that hasn't been clamped
    /// recently. Display it labelled as an average, never as "current".
    func cpuAverageLimitPercent() -> Double? {
        cachedOrRead("MSAc", valid: { $0 >= 0 && $0 <= 100 })
    }

    /// 0 = nominal, 1 = fair, 2 = serious, 3 = critical
    var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
