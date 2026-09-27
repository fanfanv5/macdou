import SwiftUI

struct CellularView: View {
    @ObservedObject var model: GuardModel
    var openFeatures: (Int) -> Void
    var saveDiagnostics: () -> Void
    var height: CGFloat = 500

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: model.modem.present ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 25)).foregroundStyle(model.isReady ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.headline).font(.system(size: 15, weight: .semibold))
                        Text(model.modem.present ? "\(model.modem.operatorLabel) · \(model.modem.radioLabel) · \(model.modem.band ?? "—")" : "连接 USB 蜂窝模块后自动识别")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("网卡模式…") { openFeatures(0) }
                    Button("短信…") { openFeatures(1) }
                    Spacer()
                    Button("刷新状态") { model.refreshNow() }
                }.controlSize(.small)
                if model.companionRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原 4G 随行正在管理模块，MacDou 等待接管。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("退出 4G 随行并接管") { model.takeOverCompanion() }
                    }
                }
                VStack(spacing: 12) {
                    HStack {
                        speed("下载", symbol: "arrow.down", value: model.network?.downloadBytesPerSecond)
                        Spacer()
                        speed("上传", symbol: "arrow.up", value: model.network?.uploadBytesPerSecond)
                    }
                    TrafficSparkline(samples: model.history)
                        .frame(height: 40).accessibilityLabel("最近一分钟的 4G 流量趋势")
                    HStack {
                        Text("↓ \(DisplayUnits.bytes(model.network?.sessionReceivedBytes ?? 0))")
                        Spacer()
                        Text("本次流量").foregroundStyle(.tertiary)
                        Spacer()
                        Text("↑ \(DisplayUnits.bytes(model.network?.sessionSentBytes ?? 0))")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 9) {
                    detail("信号", model.cellularStatus.title)
                    detail("RSRP / SINR", model.visibleBars == nil ? "—" : "\(DisplayUnits.metric(model.modem.rsrpDbm, unit: "dBm")) / \(DisplayUnits.metric(model.modem.sinrDb, unit: "dB"))")
                    detail("SIM / 模块", "\(model.modem.simState ?? "—") · \(model.modem.model ?? "—")")
                    detail("网卡 / IP", "\(model.network?.interface ?? "—") · \(model.network?.ipv4 ?? "—")")
                    Text(model.defaultRoute).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if model.network?.ambiguous == true {
                        Text("检测到多个模块，请只连接一个后重试。")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("模块与网络详情") {
                    VStack(spacing: 9) {
                        detail("设备", model.modem.model ?? "—")
                        detail("固件", model.modem.firmware ?? "—")
                        detail("运营商代码", model.modem.mccmnc ?? "—")
                        detail("注册 / 漫游", registration)
                        detail("频段 / 信道", "\(model.modem.band ?? "—") / \(model.modem.channel.map(String.init) ?? "—")")
                        detail("RSSI / RSRQ", "\(DisplayUnits.metric(model.modem.rssiDbm, unit: "dBm")) / \(DisplayUnits.metric(model.modem.rsrqDb, unit: "dB"))")
                        detail("模块网关", model.network?.router ?? "—")
                        detail("USB 网卡模式", currentMode)
                        HStack {
                            Button("读取模式与模块能力") { Task { await model.refreshModeInfo() } }
                                .disabled(!model.canUseFeatures)
                            Spacer()
                        }
                        Text(model.featureStatus)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.top, 9)
                }
                .font(.system(size: 12, weight: .medium))
                Divider()
                HStack {
                    Button(model.isCheckingInternet ? "检测中…" : "检测 4G 外网") { model.checkInternet() }
                        .disabled(!model.isReady || model.isCheckingInternet || model.companionRunning)
                    Button("恢复连接") { model.scheduleRecovery(reason: "手动检查", manual: true) }
                        .disabled(!model.canUseFeatures)
                    Spacer()
                    Button("导出诊断…", action: saveDiagnostics)
                }.controlSize(.small)
                Text(model.internetStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(model.telemetryError ?? model.recoveryStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    Text("4G 设置").font(.system(size: 12, weight: .semibold))
                    Toggle("睡眠唤醒后自动恢复连接", isOn: $model.autoRecovery)
                    Toggle("菜单栏显示上下行网速", isOn: $model.showMenuSpeed)
                    Toggle("登录后自动启动 MacDou", isOn: Binding(
                        get: { model.loginEnabled },
                        set: { model.setLoginEnabled($0) }
                    ))
                    if let error = model.loginError {
                        Text(error).foregroundStyle(.secondary)
                    } else if model.loginNeedsApproval {
                        Text("请在系统登录项中批准 MacDou").foregroundStyle(.secondary)
                    }
                    Button("打开登录项设置") { model.openLoginSettings() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
            }.padding(20)
        }.frame(height: height)
    }

    private func speed(_ label: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.isReady ? DisplayUnits.speed(value ?? 0) : "—")
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11))
    }

    private var currentMode: String {
        guard let mode = model.modeInfo?.usbnet ?? model.modem.usbnet,
              USBNetworkMode.names.indices.contains(mode) else { return "尚未读取" }
        return USBNetworkMode.names[mode]
    }

    private var registration: String {
        guard let registered = model.modem.registered else { return "未知" }
        if !registered { return "未注册" }
        return model.modem.roaming == true ? "已注册 · 漫游" : "已注册"
    }
}

private struct TrafficSparkline: View {
    let samples: [GuardModel.RateSample]
    var body: some View {
        GeometryReader { geometry in
            let peak = max(1000, samples.flatMap { [$0.down, $0.up] }.max() ?? 1)
            ForEach(0..<2) { lane in
                Path { path in
                    for (index, sample) in samples.enumerated() {
                        let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(29, samples.count - 1)), y: geometry.size.height * (1 - (lane == 0 ? sample.down : sample.up) / peak))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(lane == 0 ? Color.green : Color.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
