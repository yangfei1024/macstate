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
final class HistoryStore {
    static let shared = HistoryStore()

    static let maxAge: TimeInterval = 3 * 24 * 3600

    private(set) var samples: [HistorySample] = []

    private let queue = DispatchQueue(label: "com.snail007.macstate.history", qos: .utility)
    private var lastSave = Date(timeIntervalSince1970: 0)
    private var lastRecord: TimeInterval = 0
    private let recordInterval: TimeInterval = 10  // one sample per 10s regardless of refresh rate
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

    /// Called on the main thread after each monitor refresh.
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
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            guard now - self.lastRecord >= self.recordInterval else { return }
            self.lastRecord = now
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
            self.samples.append(sample)
            self.pruneLocked()
            let saveNow = Date()
            if saveNow.timeIntervalSince(self.lastSave) >= self.saveInterval {
                self.lastSave = saveNow
                self.saveLocked()
            }
        }
    }

    private func pruneLocked() {
        let cutoff = Date().timeIntervalSince1970 - Self.maxAge
        if let idx = samples.firstIndex(where: { $0.t < cutoff }) {
            samples.removeSubrange(0..<idx)
        }
    }

    // MARK: - Query (called from MainActor UI)

    /// Returns samples within the last `seconds`, loading from disk if needed.
    func samplesWithin(seconds: TimeInterval) -> [HistorySample] {
        // ensure any pending appends are visible
        queue.sync {}
        let cutoff = Date().timeIntervalSince1970 - seconds
        return samples.filter { $0.t >= cutoff }
    }

    // MARK: - Persistence

    private func load() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: self.fileURL),
                  let decoded = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
            self.samples = decoded
            self.pruneLocked()
        }
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Flush pending samples to disk (call on app quit).
    func saveNow() {
        queue.sync {}
        queue.sync {
            saveLocked()
            lastSave = Date()
        }
    }
}
