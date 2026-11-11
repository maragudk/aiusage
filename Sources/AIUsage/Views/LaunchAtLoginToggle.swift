import AIUsageKit
import ServiceManagement
import SwiftUI

/// Registers the app as a login item with `SMAppService.mainApp`.
///
/// The checkbox shows whether the app is registered, which includes registrations still waiting for
/// approval in System Settings. Mirroring only `.enabled` would make a pending registration look off,
/// and the resulting change would unregister it.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = Self.isRegistered

    var body: some View {
        Toggle("Launch at login", isOn: $isEnabled)
            .toggleStyle(.checkbox)
            .onChange(of: isEnabled) { _, newValue in
                setEnabled(newValue)
            }
            .onAppear {
                isEnabled = Self.isRegistered
            }
    }

    private static var isRegistered: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func setEnabled(_ enable: Bool) {
        guard enable != Self.isRegistered else {
            return
        }
        let service = SMAppService.mainApp
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.app.notice("launch at login enabled=\(enable, privacy: .public) status=\(service.status.rawValue, privacy: .public)")
        } catch {
            Log.app.error("launch at login change failed enabled=\(enable, privacy: .public)")
            isEnabled = Self.isRegistered
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
