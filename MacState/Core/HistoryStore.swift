import Foundation

/// One recorded sample of power / temperature / load / throttle state.
struct HistorySample: Codable {
    var t: TimeInterval          // epoch seconds
    var cpuLoad: Double          // percent 0-100
    var cpuTemp: Double          // °C
    var gpuTemp: Double          // °C
    var cpuPower: Double         // W (-1 = unavailable)
    var gpuPower: Double         // W (-1 = unavailable)
    var sysPower: Double         // W (-1 = unavailable)
    var cpuSpeedLimit: Double    // percent of max speed (-1 = unavailable)
    var thermalState: Int        // 0 nominal, 1 fair, 2 serious, 3 critical
}

/// Records samples on every monitor refresh and keeps the last 3 days on disk.
/// All state is guarded by a lock; safe to call from any thread.
final class HistoryStore {
    static let shared = HistoryStore()

    static let maxAge: TimeInterval = 3 * 24 * 3600

    /// UI display: max points per chart series before downsampling.
    static let maxChartPoints = 240

    private let lock = NSLock()
    private var samples: [HistorySample] = []
    private var lastRecord: TimeInterval = 0
    private var lastSave: TimeInterval = 0

    /// One sample per 10s regardless of refresh rate (3 days ≈ 26k samples).
    private let recordInterval: TimeInterval = 10
    private let saveInterval: TimeInterval = 60

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacState", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    // MARK: - Recording

    /// Called from the monitor refresh cycle (main queue).
    func record(
        cpuLoad: Double,
        cpuTemp: Double,
        gpuTemp: Double,
        cpuPower: Double,
        gpuPower: Double,
        sysPower: Double,
        cpuSpeedLimit: Double,
        thermalState: Int
    ) {
        let now = Date().timeIntervalSince1970
        let sample = HistorySample(
            t: now,
            cpuLoad: cpuLoad,
            cpuTemp: cpuTemp,
            gpuTemp: gpuTemp,
            cpuPower: cpuPower,
            gpuPower: gpuPower,
            sysPower: sysPower,
            cpuSpeedLimit: cpuSpeedLimit,
            thermalState: thermalState
        )

        lock.lock()
        defer { lock.unlock() }

        guard now - lastRecord >= recordInterval else { return }
        lastRecord = now
        samples.append(sample)

        pruneLocked()
        if now - lastSave >= saveInterval {
            lastSave = now
            saveLocked()
        }
    }

    /// Returns samples within the last `seconds`.
    func samplesWithin(seconds: TimeInterval) -> [HistorySample] {
        let cutoff = Date().timeIntervalSince1970 - seconds
        lock.lock()
        defer { lock.unlock() }
        return samples.filter { $0.t >= cutoff }
    }

    /// Flush pending samples to disk (call on app quit).
    func saveNow() {
        lock.lock()
        defer { lock.unlock() }
        saveLocked()
    }

    // MARK: - Downsample for display

    /// Reduces a metric to at most `2 * buckets` points, keeping each time
    /// bucket's min and max so short throttle dips stay visible.
    static func minMaxSeries(
        _ samples: [HistorySample],
        buckets: Int = maxChartPoints,
        value: (HistorySample) -> Double
    ) -> [(t: Date, v: Double)] {
        guard !samples.isEmpty else { return [] }

        let t0 = samples[0].t
        let t1 = samples[samples.count - 1].t
        guard t1 > t0, buckets > 1 else {
            return samples.map { (Date(timeIntervalSince1970: $0.t), value($0)) }
        }

        let width = (t1 - t0) / Double(buckets)
        var result: [(t: Date, v: Double)] = []
        result.reserveCapacity(buckets * 2)

        var idx = 0
        for b in 0..<buckets {
            let end = t0 + Double(b + 1) * width
            var mn = Double.greatestFiniteMagnitude
            var mx = -Double.greatestFiniteMagnitude
            var mnT = t0
            var mxT = t0
            var any = false

            while idx < samples.count, samples[idx].t < end {
                let v = value(samples[idx])
                if v >= 0 {
                    if v < mn { mn = v; mnT = samples[idx].t }
                    if v > mx { mx = v; mxT = samples[idx].t }
                    any = true
                }
                idx += 1
            }

            if any {
                result.append((Date(timeIntervalSince1970: mnT), mn))
                result.append((Date(timeIntervalSince1970: mxT), mx))
            }
        }

        return result.sorted { $0.t.timeIntervalSince1970 < $1.t.timeIntervalSince1970 }
    }

    // MARK: - Persistence (lock held)

    private func pruneLocked() {
        let cutoff = Date().timeIntervalSince1970 - Self.maxAge
        if let idx = samples.firstIndex(where: { $0.t < cutoff }) {
            samples.removeSubrange(0..<idx)
        }
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
        lock.lock()
        samples = decoded
        pruneLocked()
        lock.unlock()
    }
}
