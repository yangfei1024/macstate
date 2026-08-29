import Foundation

@MainActor
final class LimitToggle: ObservableObject {
    static let shared = LimitToggle()
    static let changedNotification = Notification.Name("MacStateLimitToggleChanged")

    private let defaultsKey = "module_enabled_limit"

    @Published var enabled: Bool

    private init() {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: defaultsKey)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: LimitToggle.changedNotification,
            object: nil,
            userInfo: ["enabled": value]
        )
    }
}
