import SwiftUI

struct PopoverView: View {
    let manager: MonitorManager

    @State private var showHistory = false
    @State private var showSensors = false
    @State private var sensorsExpanded = false

    var body: some View {
        Group {
            if showHistory {
                historyPage
            } else if showSensors {
                sensorsPage
            } else {
                SettingsView(manager: manager, showHistory: $showHistory, showSensors: $showSensors)
            }
        }
        .onAppear { postPopoverSize() }
        .onChange(of: showHistory) { _ in postPopoverSize() }
        .onChange(of: showSensors) { _ in postPopoverSize() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MacStateSensorsExpanded"))) { n in
            sensorsExpanded = (n.userInfo?["expanded"] as? Bool) ?? false
            postPopoverSize()
        }
    }

    /// History lives INSIDE the popover (not a separate window) so it is
    /// always visible regardless of fullscreen apps / spaces.
    private var historyPage: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: { showHistory = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L10n.shared.back)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { HistoryWindowController.shared.show() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text(L10n.shared.openInWindow)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HistoryView()
        }
        .padding(12)
        .frame(width: 640, height: 700)
    }

    private var sensorsPage: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: { showSensors = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L10n.shared.back)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Spacer()
            }

            SensorsView()
        }
        .padding(12)
        .frame(width: 460, height: 680)
    }

    private func postPopoverSize() {
        let w: Double
        let h: Double
        if showHistory {
            w = 640; h = 700
        } else if showSensors {
            w = 460; h = 680
        } else {
            // 温度列表展开时加高弹窗，少滚动一截
            w = 280; h = sensorsExpanded ? 900 : 660
        }
        NotificationCenter.default.post(
            name: Notification.Name("MacStatePopoverSize"),
            object: nil,
            userInfo: ["width": w, "height": h]
        )
    }
}
