import AppKit
import SwiftUI

@MainActor
final class PopoverNavigation: ObservableObject {
    @Published var showsSettings: Bool
    @Published var showsCellular = false

    init(showsSettings: Bool, showsCellular: Bool = false) {
        self.showsSettings = showsSettings
        self.showsCellular = showsCellular
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var cellular: GuardModel
    @ObservedObject private var navigation: PopoverNavigation
    var openFeatures: (Int) -> Void
    var saveDiagnostics: () -> Void
    var cellularPreviewHeight: CGFloat
    private var showsSettings: Bool { navigation.showsSettings }
    private var snapshot: StatusSnapshot { cellular.merging(monitor.snapshot) }

    init(monitor: SystemMonitor, preferences: Preferences, cellular: GuardModel, showsSettings: Bool = false,
         showsCellular: Bool = false,
         openFeatures: @escaping (Int) -> Void = { _ in }, saveDiagnostics: @escaping () -> Void = {},
         cellularPreviewHeight: CGFloat = 500) {
        self.monitor = monitor
        self.preferences = preferences
        self.cellular = cellular
        self.openFeatures = openFeatures
        self.saveDiagnostics = saveDiagnostics
        self.cellularPreviewHeight = cellularPreviewHeight
        navigation = PopoverNavigation(showsSettings: showsSettings, showsCellular: showsCellular)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 20)
            if showsSettings { settings }
            else if navigation.showsCellular {
                CellularView(model: cellular, openFeatures: openFeatures, saveDiagnostics: saveDiagnostics,
                             height: cellularPreviewHeight)
            }
            else { overview }
            Divider().padding(.horizontal, 20)
            footer
        }
        .frame(width: navigation.showsCellular && !showsSettings ? 380 : 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showsSettings || navigation.showsCellular {
                Button { navigation.showsSettings = false; navigation.showsCellular = false } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 24)
                }
                .buttonStyle(.plain)
                .help("返回状态")
                .accessibilityLabel("返回状态")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(showsSettings ? "偏好设置" : navigation.showsCellular ? "4G 随行" : "MacDou")
                    .font(.system(size: 16, weight: .semibold))
                Text(showsSettings ? "让四点显示你关心的状态" : navigation.showsCellular ? "蜂窝模块与网络状态" : "电量、连接与此刻的状态")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !showsSettings && !navigation.showsCellular {
                Button { navigation.showsSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("偏好设置")
                .accessibilityLabel("偏好设置")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
    }

    private var overview: some View {
        VStack(spacing: 16) {
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
            }
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: snapshot.wifi.connection == .connected ? "wifi" : "wifi.slash")
                        .frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wi-Fi").font(.system(size: 12, weight: .medium))
                        Text(snapshot.wifi.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(snapshot.wifi.title).font(.system(size: 11, weight: .medium))
                }.padding(14)
                Divider().padding(.horizontal, 14)
                Button { navigation.showsCellular = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("4G 随行").font(.system(size: 12, weight: .medium))
                            Text(cellular.headline).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(cellular.cellularStatus.title).font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(14)
                Divider().padding(.horizontal, 14)
                HStack(spacing: 12) {
                    Image(systemName: preferences.dotSource.symbol).frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preferences.dotSource.title).font(.system(size: 12, weight: .medium))
                        Text("底部四点").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(snapshot.value(for: preferences.dotSource))
                        .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                }.padding(14)
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("四点显示").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("四点显示", selection: $preferences.dotSource) {
                        ForEach(DotSource.allCases) { source in Text(source.title).tag(source) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Text(snapshot.hint(for: preferences.dotSource))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 30, alignment: .topLeading)
            }
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
                Text("底部四点").font(.system(size: 12, weight: .semibold))
                Picker("底部四点", selection: $preferences.dotSource) {
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
            }
        }.padding(20)
    }

    private var footer: some View {
        HStack {
            if showsSettings {
                Button("恢复图标默认") { preferences.restoreDefaults() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text("每 2 秒更新 · 4G 信号约 6 秒更新").foregroundStyle(.tertiary)
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
