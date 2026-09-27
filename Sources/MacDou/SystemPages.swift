import AppKit
import SwiftUI

struct BatteryPageView: View {
    let snapshot: StatusSnapshot
    @ObservedObject var preferences: Preferences

    private var battery: BatteryStatus { snapshot.battery }

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
                statusRow("低电量模式", battery.isLowPowerMode ? "已开启" : "已关闭")
                if let warning = battery.warning.title { statusRow("电量提醒", warning) }
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: snapshot.wifi.connection == .connected ? "wifi" : "wifi.slash")
                    .font(.system(size: 24)).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.currentName ?? snapshot.wifi.title)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(snapshot.wifi.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Text("Wi-Fi").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(control.isPoweredOn ? "关闭" : "打开") {
                    control.setPower(!control.isPoweredOn, onChange: refreshSystem)
                }
                .disabled(control.isBusy)
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

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
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
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
