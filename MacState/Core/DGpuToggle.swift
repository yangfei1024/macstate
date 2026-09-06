import Foundation

@MainActor
final class DGpuToggle: ObservableObject {
    static let shared = DGpuToggle()
    static let changedNotification = Notification.Name("MacStateDGpuToggleChanged")

    private let defaultsKey = "module_enabled_dgpu"

    @Published var enabled: Bool

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            // 迁移旧的合并 GPU 开关状态，避免用户重新设置
            if UserDefaults.standard.object(forKey: "module_enabled_gpu_temp") != nil {
                enabled = UserDefaults.standard.bool(forKey: "module_enabled_gpu_temp")
            } else {
                enabled = false
            }
        } else {
            enabled = UserDefaults.standard.bool(forKey: defaultsKey)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: DGpuToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
