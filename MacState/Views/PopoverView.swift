import SwiftUI

struct PopoverView: View {
    let manager: MonitorManager

    @State private var showHistory = false

    var body: some View {
        Group {
            if showHistory {
                historyPage
            } else {
                SettingsView(manager: manager, showHistory: $showHistory)
            }
        }
        .onAppear { postPopoverSize() }
        .onChange(of: showHistory) { _ in postPopoverSize() }
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

    private func postPopoverSize() {
        let w: Double = showHistory ? 640 : 280
        let h: Double = showHistory ? 700 : 660
        NotificationCenter.default.post(
            name: Notification.Name("MacStatePopoverSize"),
            object: nil,
            userInfo: ["width": w, "height": h]
        )
    }
}
