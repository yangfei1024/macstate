import SwiftUI
import AppKit

/// 渲染兼容性探针（独立可执行文件 MacStateRenderProbe）。
/// 在可疑机型上由 UICompatService 以子进程方式启动：宿主真实的设置界面，
/// 反复触发 SwiftUI 的离屏快照渲染（RenderBox ImageProvider 路径——正是
/// 各机型驱动遥测崩溃的触发点），任何一轮崩掉即判定该机器需进入 AppKit
/// 基础模式。探测须严苛：单次显示循环通过可能是侥幸（崩溃是概率性的）。
@main
struct RenderProbeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let host = NSHostingView(
            rootView: SettingsView(
                manager: MonitorManager.shared,
                showHistory: .constant(false),
                showSensors: .constant(false)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 940)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 940),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        // 近乎透明但仍走真实合成路径，用户不可见
        win.alphaValue = 0.02
        win.center()
        win.makeKeyAndOrderFront(nil)

        // 每 700ms 触发一轮 layer 快照渲染（layoutIfNeeded + cacheDisplay，
        // 与 RenderBox 崩溃同源的离屏路径），共 15 轮 ≈ 11 秒
        var round = 0
        let total = 15
        _ = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { t in
            host.layoutSubtreeIfNeeded()
            let bounds = host.bounds
            if let rep = host.bitmapImageRepForCachingDisplay(in: bounds) {
                host.cacheDisplay(in: bounds, to: rep)
            }
            round += 1
            if round >= total {
                t.invalidate()
                fflush(stdout)
                print("PROBE-OK")
                exit(0)
            }
        }
        app.run()
        exit(1)
    }
}
