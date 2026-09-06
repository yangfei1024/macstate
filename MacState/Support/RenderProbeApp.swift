import SwiftUI
import AppKit

/// 渲染兼容性探针（独立可执行文件 MacStateRenderProbe）。
/// 在可疑机型上由 UICompatService 以子进程方式启动：宿主真实的设置界面
/// 跑几秒真实显示循环。若机器的 GPU 驱动（如 macOS 14 Iris Pro 的
/// MetalOld.dylib）在 CoreUI/SwiftUI 渲染路径上崩溃，本进程会 SIGABRT，
/// 父进程据此判定该机器需进入 AppKit 基础模式。
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

        _ = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            fflush(stdout)
            print("PROBE-OK")
            exit(0)
        }
        app.run()
        exit(1)
    }
}
