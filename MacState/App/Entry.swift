import AppKit

/// 非 SwiftUI 生命周期入口：纯 NSApplication 启动（@main 结构），
/// 不创建 SwiftUI App/Scene。SwiftUI 只作为被动链接库存在——
/// 不安全机型（驱动遥测会崩 RenderBox 快照路径）上框架的后台
/// 渲染管线完全不被初始化。
@main
final class MacStateEntry {
    static func main() {
        // 第一件事：预热 CoreUI 共享 CIContext（见 CoreUIWarmup.m）。
        // 必须先于一切 AppKit/SwiftUI 工作，趁进程状态干净时创建并缓存，
        // 之后所有布局复用单例，绕开老驱动的遥测崩溃路径。
        macstate_warmup_coreui()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }
}
