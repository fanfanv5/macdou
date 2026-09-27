import AppKit
import SwiftUI

@MainActor
final class PopoverNavigation: ObservableObject {
    enum Page { case overview, settings, cellular, battery, wifi }
    @Published var page: Page

    init(showsSettings: Bool, showsCellular: Bool = false, showsBattery: Bool = false, showsWiFi: Bool = false) {
        page = showsSettings ? .settings : showsCellular ? .cellular : showsBattery ? .battery : showsWiFi ? .wifi : .overview
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var cellular: GuardModel
    @ObservedObject var wifiControl: WiFiControl
    @ObservedObject private var navigation: PopoverNavigation
    var openFeatures: (Int) -> Void
    var saveDiagnostics: () -> Void
    var cellularPreviewHeight: CGFloat
    private var showsSettings: Bool { navigation.page == .settings }
    private var showsCellular: Bool { navigation.page == .cellular }
    private var snapshot: StatusSnapshot { cellular.merging(monitor.snapshot) }

    init(monitor: SystemMonitor, preferences: Preferences, cellular: GuardModel, wifiControl: WiFiControl,
         showsSettings: Bool = false,
         showsCellular: Bool = false, showsBattery: Bool = false, showsWiFi: Bool = false,
         openFeatures: @escaping (Int) -> Void = { _ in }, saveDiagnostics: @escaping () -> Void = {},
         cellularPreviewHeight: CGFloat = 500) {
        self.monitor = monitor
        self.preferences = preferences
        self.cellular = cellular
        self.wifiControl = wifiControl
        self.openFeatures = openFeatures
        self.saveDiagnostics = saveDiagnostics
        self.cellularPreviewHeight = cellularPreviewHeight
        navigation = PopoverNavigation(showsSettings: showsSettings, showsCellular: showsCellular,
                                       showsBattery: showsBattery, showsWiFi: showsWiFi)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 20)
            if showsSettings { settings }
            else if showsCellular {
                CellularView(model: cellular, openFeatures: openFeatures, saveDiagnostics: saveDiagnostics,
                             height: cellularPreviewHeight)
            }
            else if navigation.page == .battery { BatteryPageView(snapshot: snapshot, preferences: preferences) }
            else if navigation.page == .wifi {
                WiFiPageView(snapshot: snapshot, control: wifiControl) { Task { await monitor.refresh() } }
                    .onAppear { wifiControl.refresh(scanIfAuthorized: true) }
                    .onChange(of: snapshot.updatedAt) { wifiControl.refresh() }
            }
            else { overview }
            Divider().padding(.horizontal, 20)
            footer
        }
        .frame(width: showsCellular ? 380 : 340)
        .background(GlassPanelBackground())
    }

    private var header: some View {
        HStack(spacing: 8) {
            if navigation.page != .overview {
                Button { navigation.page = .overview } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 24)
                }
                .buttonStyle(.plain)
                .help("返回状态")
                .accessibilityLabel("返回状态")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                if showsCellular {
                    Text("蜂窝模块与网络状态")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if navigation.page == .overview {
                Button { navigation.page = .settings } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("偏好设置")
                .accessibilityLabel("偏好设置")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch navigation.page {
        case .overview: return "MacDou"
        case .settings: return "偏好设置"
        case .cellular: return "4G 模块"
        case .battery: return "电池"
        case .wifi: return "Wi-Fi"
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            Button { navigation.page = .battery } label: {
              HStack(spacing: 18) {
                RingPreview(snapshot: snapshot, preferences: preferences, size: 74)
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.battery.title)
                        .font(.system(size: snapshot.battery.fraction == nil ? 20 : 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Label(snapshot.battery.powerState, systemImage: batteryPowerSymbol)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = snapshot.battery.warning.title {
                        Label(warning, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    if snapshot.battery.isLowPowerMode {
                        Label("低电量模式", systemImage: "leaf.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, 6).help("打开电池详情")

            VStack(spacing: 0) {
                Button { navigation.page = .wifi } label: {
                  HStack(spacing: 10) {
                    Image(systemName: snapshot.wifi.connection == .connected ? "wifi" : "wifi.slash")
                        .frame(width: 22).foregroundStyle(.secondary)
                    Text("Wi-Fi").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    Text(snapshot.wifi.title).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                  }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(12).help("打开 Wi-Fi 控制：\(snapshot.wifi.detail)")
                Divider().padding(.horizontal, 12)
                Button { navigation.page = .cellular } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .frame(width: 22).foregroundStyle(.secondary)
                        Text("4G 模块").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if cellular.companionRunning || cellular.isRecovering || !cellular.cellularStatus.present {
                            Text(cellular.headline)
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        } else {
                            CellularSignalIndicator(status: cellular.cellularStatus)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(12).help("打开 4G 模块页面：\(cellular.headline)")
                Divider().padding(.horizontal, 12)
                HStack(spacing: 8) {
                    Image(systemName: "circle.grid.2x2")
                        .frame(width: 22).foregroundStyle(.secondary)
                    Text("底部状态").font(.system(size: 12, weight: .medium))
                    Picker("底部状态", selection: $preferences.dotSource) {
                        ForEach(DotSource.allCases) { source in Text(source.title).tag(source) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Spacer()
                    if preferences.dotSource != .hidden && preferences.dotSource != .cellularSignal {
                        Text(snapshot.value(for: preferences.dotSource))
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }.padding(12)
            }
            .glassCard(radius: 13)
        }
        .padding(20)
    }

    private var batteryPowerSymbol: String {
        switch snapshot.battery.powerGlyph {
        case .charging: return "bolt.fill"
        case .pluggedIn: return "powerplug.fill"
        case .none: return "battery.100percent"
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RingPreview(snapshot: snapshot, preferences: preferences, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时预览").font(.system(size: 12, weight: .medium))
                    Text("修改后立即生效并自动保存")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("底部状态").font(.system(size: 12, weight: .semibold))
                Picker("底部状态", selection: $preferences.dotSource) {
                    ForEach(DotSource.allCases) { source in
                        Label(source.title, systemImage: source.symbol).tag(source)
                    }
                }.labelsHidden().pickerStyle(.radioGroup)
                Text(preferences.dotSource.explanation)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28, alignment: .topLeading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                Toggle("在图标旁显示电量百分比", isOn: $preferences.showBatteryPercentage)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
                HStack {
                    Text("图标大小").font(.system(size: 12))
                    Spacer()
                    Picker("图标大小", selection: $preferences.iconSize) {
                        Text("小").tag(18.0)
                        Text("标准").tag(20.0)
                        Text("大").tag(22.0)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 165)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("电量底轨深浅")
                        Spacer()
                        Text("\(Int((preferences.trackOpacity * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.system(size: 12))
                    Slider(value: $preferences.trackOpacity, in: 0.15...0.45)
                        .accessibilityLabel("电量底轨深浅")
                    Text("浅色底轨始终保留，电量归零也可见。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button("管理系统电池与 Wi-Fi 图标…") { SystemSettings.openMenuBar() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("登录后启动", isOn: Binding(
                    get: { cellular.loginEnabled },
                    set: { cellular.setLoginEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                if let error = cellular.loginError {
                    Text(error).foregroundStyle(.secondary)
                } else if cellular.loginNeedsApproval {
                    Button("在系统登录项中批准…") { cellular.openLoginSettings() }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 11))
        }.padding(20)
    }

    private var footer: some View {
        HStack {
            if showsSettings {
                Button("恢复图标默认") { preferences.restoreDefaults() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 20).padding(.vertical, 13)
    }
}

struct RingPreview: View {
    let snapshot: StatusSnapshot
    @ObservedObject var preferences: Preferences
    var size: CGFloat

    var body: some View {
        Image(nsImage: RingRenderer.image(
            state: RingState(snapshot: snapshot, source: preferences.dotSource, trackOpacity: preferences.trackOpacity),
            size: size
        ))
        .renderingMode(.template)
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
