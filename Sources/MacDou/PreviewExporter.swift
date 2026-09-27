import AppKit
import SwiftUI

enum PreviewExporter {
    @MainActor
    static func export(to path: String, settings: Bool, dark: Bool, cellularPage: Bool, batteryModes: Set<String>,
                       fullCellularPreview: Bool) throws {
        let suite = "com.fan.macdou.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var demo = StatusSnapshot.preview
        if batteryModes.contains("--charging-preview") {
            demo.battery.isCharging = true
            demo.battery.isPluggedIn = true
        }
        if batteryModes.contains("--plugged-preview") {
            demo.battery.fraction = 1
            demo.battery.isPluggedIn = true
            demo.battery.isCharged = true
        }
        if batteryModes.contains("--low-battery-preview") {
            demo.battery.fraction = 0.17
            demo.battery.isCharging = false
            demo.battery.isPluggedIn = false
            demo.battery.isCharged = false
            demo.battery.minutesRemaining = 34
        }
        if batteryModes.contains("--critical-battery-preview") {
            demo.battery.fraction = 0.07
            demo.battery.isCharging = false
            demo.battery.isPluggedIn = false
            demo.battery.isCharged = false
            demo.battery.minutesRemaining = 8
            demo.battery.systemWarning = .critical
        }
        if batteryModes.contains("--low-power-preview") {
            demo.battery.isLowPowerMode = true
        }
        let monitor = SystemMonitor(preview: demo)
        let cellular = GuardModel.preview(defaults: defaults)
        let content = PopoverView(monitor: monitor, preferences: preferences, cellular: cellular,
                                  showsSettings: settings, showsCellular: cellularPage,
                                  cellularPreviewHeight: fullCellularPreview ? 700 : 500)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hostingView.fittingSize
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostingView
        window.appearance = hostingView.appearance
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "MacDouPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create bitmap"])
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MacDouPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("Rendered \(Int(size.width)) × \(Int(size.height)) preview: \(path)")
    }
}
