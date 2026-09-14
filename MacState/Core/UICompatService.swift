import Foundation
import IOKit

/// 渲染兼容性判定服务。
/// 部分机型的 GPU 驱动（macOS 14 Iris Pro 的 MetalOld.dylib、macOS 26 的
/// AMD 驱动遥测）会在渲染路径上随机 SIGABRT。CoreUIWarmup 里的 NSNumber
/// 转发兜底 + 直通扁平化已在进程内消除整个崩溃类；本服务仅负责：
/// 1. MetalOld 机器（Haswell/Broadwell Intel 核显）→ 基础模式（双保险）；
/// 2. 本版本曾在该机器上发生过遥测崩溃（扫描崩溃日志）→ 基础模式
///    （自学习：未知坏组合最多崩一次，之后永久稳定）。
/// 基础模式下 SwiftUI 界面不加载，功能标注"不可用"而不是闪退。
@MainActor
final class UICompatService: ObservableObject {
    static let shared = UICompatService()

    /// 探测完成前保守视为不安全，避免用户在启动头几秒点到就崩
    @Published var swiftUISafe: Bool = false
    @Published private(set) var probeFinished: Bool = false

    private init() {
        runProbe()
    }

    private func runProbe() {
        // 测试钩子：强制走基础模式（跳过所有判定，视为不安全）
        if ProcessInfo.processInfo.environment["MACSTATE_FORCE_BASIC"] == "1" {
            probeFinished = true
            swiftUISafe = false
            return
        }
        // 用户自救开关：defaults write com.snail007.macstate ForceBasicMode -bool YES
        // （驱动仍随机崩溃时的持久化兜底，基础模式纯 AppKit 渲染）
        if UserDefaults.standard.bool(forKey: "ForceBasicMode") {
            probeFinished = true
            swiftUISafe = false
            return
        }
        // 测试钩子：MACSTATE_ALLOW_SWIFTUI=1 跳过自学习，仅按静态判定
        if ProcessInfo.processInfo.environment["MACSTATE_ALLOW_SWIFTUI"] == "1" {
            DispatchQueue.global(qos: .utility).async {
                let bad = Self.isMetalOldMachine()
                Task { @MainActor in
                    self.swiftUISafe = !bad
                    self.probeFinished = true
                    NotificationCenter.default.post(name: Notification.Name("MacStateUICompatChanged"), object: nil)
                }
            }
            return
        }
        // 层1：MetalOld 老驱动机器（Haswell/Broadwell 核显），静态秒判
        DispatchQueue.global(qos: .utility).async {
            var ok = !Self.isMetalOldMachine()
            // 层2：本版本曾在本机发生过遥测崩溃 → 自学习降级
            if ok, Self.currentBuildCrashedWithTelemetry() {
                NSLog("MacState UICompat: current build previously crashed with GPU telemetry signature -> basic mode")
                ok = false
            }
            Task { @MainActor in
                self.swiftUISafe = ok
                self.probeFinished = true
                NotificationCenter.default.post(name: Notification.Name("MacStateUICompatChanged"), object: nil)
            }
        }
    }

    /// MetalOld.dylib 服务的老 Intel 核显机器（Haswell / Broadwell）。
    /// 该驱动栈的遥测在 CoreUI/RenderBox/Metal 提交路径上存在无法捕获的
    /// 随机崩溃（dispatch_once noexcept 帧，@try 接不住），且实测直通
    /// 替换只能保住 AppKit 控件层，SwiftUI 的 RenderBox 管线照样崩
    /// （真机 5 轮开关存活、点开 SwiftUI 温度面板数秒内崩）。
    /// 用 CPU 型号判定（IOClass 字段在该代机器上不可靠）：
    /// Haswell = model 60/63/69/70，Broadwell = model 61/71。
    private nonisolated static func isMetalOldMachine() -> Bool {
        // Apple Silicon 上这些 sysctl 无意义，直接排除
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        if arm64 == 1 { return false }

        var model: Int32 = 0
        sysctlbyname("machdep.cpu.model", &model, &size, nil, 0)
        // Haswell: 0x3C(60) 0x3F(63) 0x45(69) 0x46(70)；Broadwell: 0x3D(61) 0x47(71)
        let metalOldModels: Set<Int32> = [60, 63, 69, 70, 61, 71]
        return metalOldModels.contains(model)
    }

    /// 自学习：扫描崩溃日志，若"当前版本"在本机发生过 GPU 遥测崩溃
    /// （getCStringForCFString / MetalOld 特征），则本次启动进入基础模式。
    /// 每个新版本重置——修复后自动恢复完整 UI。
    private nonisolated static func currentBuildCrashedWithTelemetry() -> Bool {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return false }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)

        let names = files
            .filter { $0.hasPrefix("MacState-") && $0.hasSuffix(".ips") }
            .sorted()
            .suffix(30)

        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let attr = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attr[.modificationDate] as? Date, mtime > cutoff,
                  let raw = try? String(contentsOf: url, encoding: .utf8),
                  let nl = raw.firstIndex(of: "\n") else { continue }

            guard let metaData = try? JSONSerialization.jsonObject(with: Data(raw[..<nl].utf8)) as? [String: Any],
                  (metaData["app_version"] as? String)?.hasPrefix(current) == true else { continue }
            guard let body = try? JSONSerialization.jsonObject(with: Data(raw[nl...].utf8)) as? [String: Any] else { continue }

            let threads = body["threads"] as? [[String: Any]] ?? []
            let imgs = body["usedImages"] as? [[String: Any]] ?? []
            let matched = threads.contains { th in
                (th["frames"] as? [[String: Any]] ?? []).contains { fr in
                    guard let i = fr["imageIndex"] as? Int, i < imgs.count else { return false }
                    let imgName = imgs[i]["name"] as? String ?? ""
                    let sym = fr["symbol"] as? String ?? ""
                    return sym.contains("getCStringForCFString") || imgName == "MetalOld"
                }
            }
            if matched { return true }
        }
        return false
    }
}
