import AIUsageKit
import ServiceManagement
import SwiftUI

/// Registers the app as a login item with `SMAppService.mainApp`.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $isEnabled)
            .toggleStyle(.checkbox)
            .onChange(of: isEnabled) { _, newValue in
                setEnabled(newValue)
            }
            .onAppear {
                isEnabled = SMAppService.mainApp.status == .enabled
            }
    }

    private func setEnabled(_ enable: Bool) {
        let service = SMAppService.mainApp
        let isRegistered = service.status == .enabled || service.status == .requiresApproval
        guard enable != isRegistered else {
            return
        }
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.app.notice("launch at login enabled=\(enable, privacy: .public) status=\(service.status.rawValue, privacy: .public)")
        } catch {
            Log.app.error("launch at login change failed enabled=\(enable, privacy: .public)")
            isEnabled = service.status == .enabled
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
