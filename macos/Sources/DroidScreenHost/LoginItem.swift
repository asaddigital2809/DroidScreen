import Foundation
import ServiceManagement

/// "Start DroidScreen at login" via `SMAppService.mainApp` (macOS 13+).
/// The app must run from a signed .app bundle. macOS may ask the user to approve the
/// login item in System Settings › General › Login Items (`status == .requiresApproval`).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the app as a login item. Throws the ServiceManagement error.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
