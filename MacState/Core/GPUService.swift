import Foundation
import IOKit

final class GPUService {
    static let shared = GPUService()

    // SMC fallback keys per vendor (source: github.com/exelban/stats Modules/GPU/reader.swift)
    private let smcFallbackAMD = "TGDD"
    private let smcFallbackIntel = "TCGC"

    private init() {}

    /// Returns a raw type key: "discrete" or "integrated".
    /// Localization happens in StatusBarController (MainActor).
    private func gpuTypeKey(ioClass: String) -> String {
        let cls = ioClass.lowercased()
        if cls.contains("amd") || cls.contains("nvidia") {
            return "discrete"
        }
        return "integrated"
    }

    /// Returns max GPU utilization across ALL GPUs as percentage (0-100), or -1 if unavailable
    func gpuUsage() -> Double {
        let all = allGPUUsages()
        if all.isEmpty { return -1 }
        return all.map { $0.usage }.max() ?? -1
    }

    func allGPUUsages() -> [(name: String, usage: Double)] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var gpus: [(name: String, usage: Double)] = []
        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            let kr = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
            if kr == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as? [String: Any] {
                if let stats = dict["PerformanceStatistics"] as? [String: Any] {
                    var usage: Double? = nil
                    if let val = stats["GPU Activity(%)"] as? Int {
                        usage = Double(val)
                    }
                    if let val = stats["Device Utilization %"] as? Int {
                        usage = Double(val)
                    }
                    if let u = usage {
                        let ioClass = dict["IOClass"] as? String ?? ""
                        gpus.append((name: gpuTypeKey(ioClass: ioClass), usage: u))
                    }
                }
            } else {
                properties?.release()
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        return gpus
    }

    func gpuTemperature() -> Double? {
        let temps = allGPUTemperatures()
        return temps.map { $0.temp }.max()
    }

    func allGPUTemperatures() -> [(label: String, temp: Double)] {
        var results: [(label: String, temp: Double)] = []
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard kr == KERN_SUCCESS else { return results }
        defer { IOObjectRelease(iterator) }

        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            let propKr = IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
            if propKr == KERN_SUCCESS, let dict = properties?.takeRetainedValue() as? [String: Any] {
                let ioClass = dict["IOClass"] as? String ?? ""

                var temp: Double? = nil
                if let stats = dict["PerformanceStatistics"] as? [String: Any],
                   let t = stats["Temperature(C)"] as? Int, t > 0, t < 150 {
                    temp = Double(t)
                }

                let cls = ioClass.lowercased()
                if temp == nil {
                    if cls.contains("amd") {
                        if let v = SMCService.shared.readKey(smcFallbackAMD), v > 0, v < 150 { temp = v }
                    } else if cls.contains("intel") {
                        if let v = SMCService.shared.readKey(smcFallbackIntel), v > 0, v < 150 { temp = v }
                    }
                }

                if let t = temp {
                    results.append((label: gpuTypeKey(ioClass: ioClass), temp: t))
                }
            } else {
                properties?.release()
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        // 独显休眠时其 IOAccelerator 节点会从注册表消失，用 SMC 键兜底，
        // 保证菜单栏始终有独显温度
        if !results.contains(where: { $0.label == "discrete" }),
           let v = SMCService.shared.readKey(smcFallbackAMD), v > 0, v < 150 {
            results.append((label: "discrete", temp: v))
        }
        if !results.contains(where: { $0.label == "integrated" }),
           let v = SMCService.shared.readKey(smcFallbackIntel), v > 0, v < 150 {
            results.append((label: "integrated", temp: v))
        }

        return results
    }

    /// Whether this machine has a GPU we can monitor.
    /// Cached after first check: hardware presence is fixed per boot, and
    /// re-querying IOAccelerator on every UI render makes rows flicker when
    /// the dGPU sleeps (its accelerator node temporarily disappears).
    private static var cachedHasGPU: Bool?

    static var hasGPU: Bool {
        if let cached = cachedHasGPU { return cached }
        let value = GPUService.shared.gpuUsage() >= 0
        cachedHasGPU = value
        return value
    }
}
