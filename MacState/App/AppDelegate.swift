import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须最先执行：子进程探测 CoreUI 渲染管线是否会触发驱动崩溃；
        // 会崩则切换直通渲染（详见 CoreUIWarmup.h）
        macstate_prepare_coreui()

        // 诊断：布局期未捕获异常的完整原因落盘（AppKit 会随后主动崩溃）
        NSSetUncaughtExceptionHandler { ex in
            let msg = "UNCAUGHT \(ex.name.rawValue): \(ex.reason ?? "-")\n" +
                ex.callStackSymbols.joined(separator: "\n")
            try? msg.write(toFile: "/tmp/macstate_exception.log", atomically: true, encoding: .utf8)
            NSLog("UNCAUGHT \(ex.name.rawValue): \(ex.reason ?? "-")")
        }

        statusBarController = StatusBarController(manager: MonitorManager.shared)

        // Debug/self-test: open the history window right after launch
        if CommandLine.arguments.contains("--history-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                HistoryWindowController.shared.show()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            HistoryStore.shared.saveNow()
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenTerminal(_:)),
            name: Notification.Name("com.snail007.macstate.openTerminal"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleOpenTerminal(_ notification: Notification) {
        guard let directory = notification.object as? String, !directory.isEmpty else { return }
        openTerminal(at: directory)
    }

    private func openTerminal(at directory: String) {
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Terminal", directory]
            try proc.run()
        } catch {
            NSLog("MacState: open terminal failed: %@", error.localizedDescription)
        }
    }
}
