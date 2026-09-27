import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var preferences: Preferences!
    private var monitor: SystemMonitor!
    private var cellular: GuardModel!
    private var wifiControl: WiFiControl!
    private var features: ModuleFeaturesWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var previousMenuContent: UnifiedMenuContent?
    private var previousButtonTitle: String?
    private var previousButtonSummary: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--enable-login") || arguments.contains("--login-status") {
            let model = GuardModel(startMonitoring: false)
            model.refreshLoginState()
            if arguments.contains("--enable-login"), !model.loginEnabled, !model.loginNeedsApproval {
                model.setLoginEnabled(true)
            }
            if let error = model.loginError {
                fputs("\(error)\n", stderr)
                exit(1)
            }
            if model.loginEnabled { print("enabled"); exit(0) }
            if model.loginNeedsApproval { print("requiresApproval"); exit(2) }
            print("notRegistered")
            exit(1)
        }
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
            do {
                try PreviewExporter.export(to: arguments[index + 1], settings: arguments.contains("--settings-preview"),
                    dark: arguments.contains("--dark-preview"), cellularPage: arguments.contains("--cellular-preview"),
                    batteryModes: Set(arguments),
                    fullCellularPreview: arguments.contains("--full-cellular-preview"))
            } catch {
                fputs("Preview failed: \(error)\n", stderr)
                exit(1)
            }
            NSApplication.shared.terminate(nil)
            return
        }
        if arguments.contains("--diagnose") {
            Task {
                let reader = SensorReader()
                _ = await reader.read(wifiPathActive: false)
                try? await Task.sleep(for: .milliseconds(350))
                let snapshot = await reader.read(wifiPathActive: false)
                let report: [String: Any] = [
                    "batteryPresent": snapshot.battery.isPresent,
                    "batteryPercent": snapshot.battery.fraction.map { Int(($0 * 100).rounded()) } as Any? ?? NSNull(),
                    "charging": snapshot.battery.isCharging,
                    "pluggedIn": snapshot.battery.isPluggedIn,
                    "charged": snapshot.battery.isCharged,
                    "lowPowerMode": snapshot.battery.isLowPowerMode,
                    "batteryWarning": snapshot.battery.warning.title as Any? ?? NSNull(),
                    "wifi": snapshot.wifi.connection.rawValue,
                    "wifiRSSI": snapshot.wifi.rssi as Any? ?? NSNull(),
                    "volume": snapshot.volume.fraction as Any? ?? NSNull(),
                    "muted": snapshot.volume.isMuted,
                    "cpuUsage": snapshot.cpuUsage as Any? ?? NSNull(),
                    "memoryUsage": snapshot.memoryUsage as Any? ?? NSNull()
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if arguments.contains("--diagnose-cellular") {
            Task {
                let model = GuardModel(startMonitoring: false)
                await model.refreshModem()
                let report: [String: Any] = [
                    "modulePresent": model.modem.present,
                    "atOK": model.modem.atOK,
                    "signalBars": model.visibleBars as Any? ?? NSNull(),
                    "simReady": model.modem.simState == "READY",
                    "registered": model.modem.registered as Any? ?? NSNull()
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                model.shutdown()
                NSApplication.shared.terminate(nil)
            }
            return
        }

        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.fan.macdou").count > 1 {
            NSApplication.shared.terminate(nil)
            return
        }

        preferences = Preferences()
        monitor = SystemMonitor()
        cellular = GuardModel()
        wifiControl = WiFiControl()
        monitor.setSamplingMode(source: preferences.dotSource, popoverVisible: false)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = "MacDouStatusRing"
        statusItem?.isVisible = true
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.monitor.setSamplingMode(source: self.preferences.dotSource, popoverVisible: self.popover.isShown)
                self.updateStatusItem()
            }
        }.store(in: &subscriptions)
        cellular.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        updateStatusItem()

        if arguments.contains("--show") || !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let snapshot = cellular.merging(monitor.snapshot)
        let ring = RingState(snapshot: snapshot, source: preferences.dotSource, trackOpacity: preferences.trackOpacity)
        let menu = UnifiedMenuContent(ring: ring, size: preferences.iconSize, model: cellular)
        if menu != previousMenuContent {
            button.image = menu.image()
            previousMenuContent = menu
        }
        var batteryLabels: [String] = []
        if preferences.showBatteryPercentage && snapshot.battery.fraction != nil {
            batteryLabels.append(snapshot.battery.title)
        }
        if let warning = snapshot.battery.warning.title { batteryLabels.append(warning) }
        if snapshot.battery.isLowPowerMode { batteryLabels.append("低电量模式") }
        let title = batteryLabels.isEmpty ? "" : " " + batteryLabels.joined(separator: " · ")
        if title != previousButtonTitle {
            button.title = title
            previousButtonTitle = title
        }
        let summary = "MacDou：电量 \(snapshot.battery.title)（\(snapshot.battery.detail)），Wi-Fi \(snapshot.wifi.title)，4G \(snapshot.cellular.title)，\(preferences.dotSource.title) \(snapshot.value(for: preferences.dotSource))"
        if summary != previousButtonSummary {
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
            previousButtonSummary = summary
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem?.button {
            popover.performClose(nil)
            let menu = NSMenu()
            let title = NSMenuItem(title: "四点显示", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for source in DotSource.allCases {
                let item = NSMenuItem(title: source.title, action: #selector(selectDotSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = source.rawValue
                item.state = preferences.dotSource == source ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            let quit = NSMenuItem(title: "退出 MacDou", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else if popover.isShown {
            popover.performClose(sender)
        } else { showPopover() }
    }

    @objc private func selectDotSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = DotSource(rawValue: raw) else { return }
        preferences.dotSource = source
    }

    @objc private func openSettings() {
        showPopover(settings: true)
    }

    private func showPopover(settings: Bool = false) {
        let target = statusItem?.button
        guard let target else { return }
        if popover.isShown { popover.performClose(nil) }
        popover.contentViewController = makePopoverController(settings: settings)
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: target.bounds, of: target, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        monitor.setSamplingMode(source: preferences.dotSource, popoverVisible: true)
        cellular.setPopoverVisible(true)
        Task { await monitor.refresh() }
    }

    private func makePopoverController(settings: Bool = false) -> NSHostingController<PopoverView> {
        let controller = NSHostingController(rootView: PopoverView(
            monitor: monitor, preferences: preferences, cellular: cellular, wifiControl: wifiControl,
            showsSettings: settings,
            openFeatures: { [weak self] tab in self?.openFeatures(tab: tab) },
            saveDiagnostics: { [weak self] in self?.cellular.saveDiagnostics() }
        ))
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }

    private func openFeatures(tab: Int) {
        if features == nil { features = ModuleFeaturesWindow(model: cellular) }
        popover.performClose(nil)
        features?.open(tab: tab)
    }

    func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
            self.monitor.setSamplingMode(source: self.preferences.dotSource, popoverVisible: false)
            self.cellular.setPopoverVisible(false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        cellular?.shutdown()
    }
}

@main
enum MacDouMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
