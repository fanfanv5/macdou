import AppKit
import SwiftUI

struct BatteryPageView: View {
    let snapshot: StatusSnapshot
    @ObservedObject var preferences: Preferences
    @ObservedObject var lowPowerControl: LowPowerModeControl
    let refreshSystem: () -> Void

    private var battery: BatteryStatus { snapshot.battery }

    private var lowPowerBinding: Binding<Bool> {
        Binding(get: { battery.isLowPowerMode }, set: { enabled in
            let onBattery = battery.isPresent && !battery.isPluggedIn
            lowPowerControl.setEnabled(enabled, onBattery: onBattery, onChange: refreshSystem)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                RingPreview(snapshot: snapshot, preferences: preferences, size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    Text(battery.title).font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
            }
            VStack(spacing: 10) {
                statusRow("供电状态", battery.isPresent ? battery.powerState : "无内置电池")
                HStack {
                    Text("低电量模式").foregroundStyle(.secondary)
                    Spacer()
                    if lowPowerControl.isBusy { ProgressView().controlSize(.small) }
                    Toggle("低电量模式", isOn: lowPowerBinding)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(lowPowerControl.isBusy || !battery.isPresent)
                }
                .font(.system(size: 12))
                if let warning = battery.warning.title { statusRow("电量提醒", warning) }
                if let errorMessage = lowPowerControl.errorMessage {
                    Text(errorMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .glassCard(radius: 13)
            HStack {
                Button("电池与电源模式…") { SystemSettings.openBattery() }
                Spacer()
                Button("菜单栏图标…") { SystemSettings.openMenuBar() }
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 12))
    }
}

struct WiFiPageView: View {
    let snapshot: StatusSnapshot
    @ObservedObject var control: WiFiControl
    let refreshSystem: () -> Void

    private var powerBinding: Binding<Bool> {
        Binding(
            get: { control.isPoweredOn },
            set: { control.setPower($0, onChange: refreshSystem) }
        )
    }

    private var headline: String {
        guard control.isAvailable else { return "Wi-Fi 不可用" }
        guard control.isPoweredOn else { return "Wi-Fi 已关闭" }
        return control.currentName ?? (snapshot.wifi.connection == .connected ? "已连接 Wi-Fi" : "Wi-Fi 已打开")
    }

    private var connectionDetail: String {
        guard control.isAvailable else { return "未检测到 Wi-Fi 硬件" }
        guard control.isPoweredOn else { return "打开开关即可连接网络" }
        return snapshot.wifi.connection == .connected ? snapshot.wifi.detail : "尚未连接 Wi-Fi 网络"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: control.isPoweredOn ? "wifi" : "wifi.slash")
                    .font(.system(size: 24)).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(connectionDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Text("Wi-Fi").font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("Wi-Fi", isOn: powerBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!control.isAvailable || control.isBusy)
                    .accessibilityLabel("Wi-Fi")
            }
            .padding(12)
            .glassCard()

            HStack {
                Text("附近网络").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("扫描") { control.scan() }
                    .disabled(!control.isPoweredOn || control.isBusy)
            }
            .font(.system(size: 11))

            if control.isBusy { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            if let message = control.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if control.locationNeedsPermission {
                Button("定位权限设置…") { SystemSettings.openPrivacy() }
                    .font(.system(size: 11)).buttonStyle(.plain)
            }
            if !control.networks.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(control.networks) { choice in
                            Button { control.join(choice, onChange: refreshSystem) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi").foregroundStyle(.secondary)
                                    Text(choice.name).lineLimit(1)
                                    Spacer()
                                    if choice.name == control.currentName { Image(systemName: "checkmark") }
                                    if choice.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                                }
                                .font(.system(size: 12))
                                .contentShape(Rectangle())
                                .padding(.horizontal, 11).padding(.vertical, 9)
                            }
                            .buttonStyle(.plain).disabled(control.isBusy)
                            if choice.id != control.networks.last?.id { Divider().padding(.horizontal, 11) }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .glassCard()
            }
            if control.isPoweredOn {
                Button { SystemSettings.openWiFi() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "personalhotspot")
                            .frame(width: 16)
                        Text("个人热点")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassCard()
            }
            HStack {
                Button("更多网络设置…") { SystemSettings.openNetwork() }
                Spacer()
                Button("菜单栏图标…") { SystemSettings.openMenuBar() }
            }
            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(item: $control.passwordNetwork) { choice in
            WiFiPasswordSheet(choice: choice, control: control, refreshSystem: refreshSystem)
        }
    }
}

private struct WiFiPasswordSheet: View {
    let choice: WiFiChoice
    @ObservedObject var control: WiFiControl
    let refreshSystem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 \(choice.name)").font(.system(size: 16, weight: .semibold))
            SecureField("网络密码", text: $control.pendingPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { connect() }
            HStack {
                Spacer()
                Button("取消") { control.pendingPassword = ""; control.passwordNetwork = nil }
                Button("连接") { connect() }.disabled(control.pendingPassword.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 300)
    }

    private func connect() {
        let password = control.pendingPassword
        guard !password.isEmpty else { return }
        control.pendingPassword = ""
        control.passwordNetwork = nil
        control.join(choice, password: password, onChange: refreshSystem)
    }
}
