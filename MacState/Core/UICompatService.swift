import Foundation

/// 渲染兼容性探测服务。
/// 部分机型的 GPU 驱动（macOS 14 Iris Pro 的 MetalOld.dylib、macOS 26 的
/// AMD 驱动遥测）会在 SwiftUI/CoreUI 渲染路径上直接 SIGABRT。启动时用
/// 子进程探针实测：探针崩溃 ⇒ 该机器进入 AppKit 基础模式，所有 SwiftUI
/// 界面（设置页/全部温度/历史曲线/限速面板）不再加载，避免闪退。
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
        // 测试钩子：强制走基础模式（跳过探针，视为不安全）
        if ProcessInfo.processInfo.environment["MACSTATE_FORCE_BASIC"] == "1" {
            probeFinished = true
            swiftUISafe = false
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.runProbeProcess()
            Task { @MainActor in
                self.swiftUISafe = ok
                self.probeFinished = true
                NotificationCenter.default.post(name: Notification.Name("MacStateUICompatChanged"), object: nil)
            }
        }
    }

    private nonisolated static func runProbeProcess() -> Bool {
        guard let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("MacStateRenderProbe"),
            FileManager.default.fileExists(atPath: exe.path) else {
            // 探针缺失时不拦截（老版本升级场景）
            return true
        }

        let task = Process()
        task.executableURL = exe
        task.standardOutput = Pipe()
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return true
        }

        // 探针正常 ~4 秒退出；给到 15 秒上限（含首次 Swift 运行时预热）
        let deadline = Date().addingTimeInterval(15)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if task.isRunning {
            // 超时视为不安全（渲染可能已挂起）
            task.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if task.isRunning { task.terminate() }
            return false
        }

        // 正常退出 = 安全；被信号杀死（SIGABRT）= 驱动崩溃 = 不安全
        return task.terminationReason == .exit && task.terminationStatus == 0
    }
}
