import AppKit

enum SystemSettings {
    static func openBattery() { openPane("com.apple.Battery-Settings.extension") }
    static func openWiFi() { openPane("com.apple.wifi-settings-extension") }
    static func openNetwork() { openPane("com.apple.Network-Settings.extension") }
    static func openMenuBar() { openPane("com.apple.ControlCenter-Settings.extension") }
    static func openPrivacy() { openPane("com.apple.settings.PrivacySecurity.extension") }

    private static func openPane(_ identifier: String) {
        let url = URL(string: "x-apple.systempreferences:\(identifier)")!
        if NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
