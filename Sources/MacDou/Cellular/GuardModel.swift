import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class GuardModel: ObservableObject {
    @Published var modem = ModemSnapshot()
    @Published var network: NetworkSnapshot?
    @Published var history: [RateSample] = []
    @Published var isRecovering = false
    @Published var isCheckingInternet = false
    @Published var recoveryStatus = "正常睡眠，唤醒后检查连接"
    @Published var internetStatus = "尚未检测外网"
    @Published var lastUpdate: Date?
    @Published var telemetryError: String?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var loginError: String?
    @Published var featureBusy = false
    @Published var featureStatus = "请先读取模块能力"
    @Published var modeInfo: ModemSnapshot?
    @Published var smsStatus = "打开短信页后自动载入；不会发送或删除。"
    @Published var messages: [SMSMessage] = []
    @Published var autoRecovery: Bool {
        didSet { defaults.set(autoRecovery, forKey: "autoRecovery"); if !autoRecovery { recoveryTask?.cancel() } }
    }
    @Published var showMenuSpeed: Bool {
        didSet {
            defaults.set(showMenuSpeed, forKey: "showMenuSpeed")
            scheduleTimer()
            if showMenuSpeed { Task { await tick() } }
        }
    }
    private let defaults: UserDefaults
    @Published var companionRunning = false
    private let checksCompanion: Bool
    private let sampler = NetworkSampler()
    private let runner = CommandRunner()
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var popoverVisible = false
    private var observers: [NSObjectProtocol] = []
    private var recoveryTask: Task<Void, Never>?
    private var sleeping = false
    private var pollBusy = false
    private var sampleBusy = false
    private var nextModemPoll = Date.distantPast
    private var nextGatewayCheck = Date.distantPast
    private var gatewayBusy = false
    private var epoch = 0
    private var smsGeneration = 0
    private var lastReset = Date.distantPast
    private var lastGatewayGood = false
    private var priorInterface: String?
    private var logEntries: [String] = []
    struct RateSample: Identifiable { let id = UUID(); let down: Double; let up: Double }

    init(startMonitoring: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checksCompanion = startMonitoring
        let oldSettings = startMonitoring ? UserDefaults(suiteName: "local.fan.dji4gguard") : nil
        autoRecovery = defaults.object(forKey: "autoRecovery") as? Bool ??
            (oldSettings?.object(forKey: "autoRecovery") as? Bool ?? true)
        showMenuSpeed = defaults.object(forKey: "showMenuSpeed") as? Bool ??
            (oldSettings?.object(forKey: "showMenuSpeed") as? Bool ?? false)
        guard startMonitoring else { return }
        companionRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.fan.dji4gguard").isEmpty
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.willSleep() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.didWake() } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.refreshLoginState()
                if self.autoRecovery && !self.isReady { self.scheduleRecovery(reason: "解锁后检查") }
            }
        })
        scheduleTimer()
        refreshLoginState()
        Task { await tick() }
    }
    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        scheduleTimer()
        if visible { Task { await tick() } }
    }
    private func scheduleTimer() {
        guard checksCompanion, !sleeping else { return }
        let interval: TimeInterval = popoverVisible || showMenuSpeed ? 2 : (modem.present || isReady ? 5 : 10)
        guard timer == nil || timerInterval != interval else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer?.tolerance = interval * 0.2
    }
    var isReady: Bool { network?.linkActive == true && network?.ipv4 != nil && network?.ambiguous != true }
    var isStale: Bool { lastUpdate == nil || Date().timeIntervalSince(lastUpdate!) > 12 }
    var visibleBars: Int? { !companionRunning && !isStale && telemetryError == nil && modem.present && modem.atOK ? modem.bars : nil }
    var headline: String {
        if companionRunning { return "4G 随行正在运行" }
        if isRecovering { return "正在恢复连接" }
        if modem.present && modem.simState != nil && modem.simState != "READY" { return "SIM：\(modem.simState!)" }
        if isReady { return "4G 网卡已就绪" }
        return modem.present ? "等待网络连接" : "未检测到模块"
    }
    var defaultRoute: String {
        guard let route = network?.defaultInterface else { return "暂无默认出口" }
        if route == network?.interface { return "当前默认出口：4G" }
        if route == "en0" { return "当前默认出口：Wi-Fi" }
        return "当前默认出口：\(route.hasPrefix("utun") ? "VPN · " : "")\(route)"
    }
    var menuTitle: String {
        let state = isRecovering ? "4G…" : modem.present || isReady ? "4G" : "4G —"
        guard showMenuSpeed, let network, isReady else { return state }
        return "\(state) ↓\(DisplayUnits.speed(network.downloadBytesPerSecond, compact: true)) ↑\(DisplayUnits.speed(network.uploadBytesPerSecond, compact: true))"
    }
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/modem-helper") }

    func tick() async {
        guard !sleeping, !sampleBusy else { return }
        defer { scheduleTimer() }
        sampleBusy = true
        let version = epoch, fresh = await sampler.sample()
        sampleBusy = false
        guard version == epoch, !sleeping else { return }
        let appeared = priorInterface == nil && fresh.interface != nil
        let changed = priorInterface != fresh.interface
        priorInterface = fresh.interface
        if network != fresh { network = fresh }
        if changed { internetStatus = "尚未检测外网"; history.removeAll(); lastGatewayGood = false; nextGatewayCheck = .distantPast }
        if fresh.interface != nil {
            history.append(.init(down: fresh.downloadBytesPerSecond, up: fresh.uploadBytesPerSecond))
            if history.count > 30 { history.removeFirst(history.count - 30) }
        }
        if checksCompanion {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.fan.dji4gguard").isEmpty
            if companionRunning != running { companionRunning = running }
        }
        if companionRunning {
            recoveryTask?.cancel(); runner.cancelAll()
            lastUpdate = nil
            recoveryStatus = "退出原 4G 随行后，MacDou 将自动接管模块。"
            return
        }
        if appeared && autoRecovery && !isReady && !isRecovering { scheduleRecovery(reason: "模块接入后检查") }
        if Date() >= nextModemPoll && !pollBusy && !isRecovering && !featureBusy {
            nextModemPoll = Date().addingTimeInterval(5); await refreshModem()
        }
        if Date() >= nextGatewayCheck && isReady && !isRecovering && !gatewayBusy {
            gatewayBusy = true; nextGatewayCheck = Date().addingTimeInterval(30)
            let currentInterface = network?.interface
            let reachable = await gatewayReachable()
            gatewayBusy = false
            if version == epoch, !sleeping, currentInterface == network?.interface, reachable == true { lastGatewayGood = true }
        }
    }
    private func readModem(action: String = "snapshot") async -> ModemSnapshot? {
        let output = await runner.run(helperURL, [action], timeout: 20)
        guard !sleeping, !Task.isCancelled else { return nil }
        if output.timedOut { telemetryError = "模块响应超时，稍后重试"; return nil }
        guard let result = try? JSONDecoder().decode(ModemSnapshot.self, from: output.output) else {
            telemetryError = "未能读取模块（\(output.code)）"; return nil
        }
        return result
    }
    func refreshModem() async {
        guard !pollBusy, !sleeping, !companionRunning, !featureBusy else { return }
        pollBusy = true; defer { pollBusy = false }
        let version = epoch
        if let result = await readModem(), version == epoch {
            let appeared = !modem.present && result.present
            modem = result; lastUpdate = Date()
            scheduleTimer()
            telemetryError = result.atOK || !result.present ? nil : "模块控制通道暂不可用"
            if appeared && autoRecovery && !isReady && !isRecovering { scheduleRecovery(reason: "模块已检测到") }
        }
    }
    func refreshNow() { nextModemPoll = .distantPast; Task { await tick() } }
    private func willSleep() {
        sleeping = true; epoch += 1; recoveryTask?.cancel(); runner.cancelAll()
        timer?.invalidate(); timer = nil; timerInterval = nil
        history.removeAll(); lastUpdate = nil; recoveryStatus = "已暂停，等待 Mac 唤醒"
        clearMessages(); smsStatus = "已睡眠，短信内容已从界面清空；唤醒后可重新读取。"
        modeInfo = nil
        log("Mac 进入睡眠，暂停读取并关闭控制句柄")
    }
    private func didWake() {
        sleeping = false; epoch += 1; nextModemPoll = Date().addingTimeInterval(8)
        scheduleTimer()
        internetStatus = "唤醒后尚未检测外网"
        let pending = recoveryTask, version = epoch
        Task {
            await pending?.value
            guard version == epoch, !sleeping else { return }
            await sampler.resetBaseline()
            if autoRecovery { scheduleRecovery(reason: "Mac 唤醒") }
            else { recoveryStatus = "Mac 已唤醒；自动恢复已关闭" }
        }
    }
    func scheduleRecovery(reason: String, manual: Bool = false) {
        guard !sleeping, !companionRunning, !isRecovering, !featureBusy else { return }
        recoveryTask?.cancel(); isRecovering = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false; self.nextModemPoll = .distantPast }
            await self.recover(reason: reason, manual: manual)
        }
    }
    private func delay(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return !sleeping && !Task.isCancelled }
        catch { return false }
    }
    private func gatewayReachable() async -> Bool? {
        guard let interface = network?.interface, let gateway = network?.router, isReady else { return nil }
        let result = await runner.run(URL(fileURLWithPath: "/sbin/ping"), ["-n", "-q", "-b", interface, "-c", "1", "-W", "1000", "-t", "2", gateway], timeout: 3)
        return result.code == 0
    }
    private func recover(reason: String, manual: Bool) async {
        log(reason); recoveryStatus = "等待 USB 和网卡恢复…"
        guard await delay(manual ? 1 : 8) else { return }
        for attempt in 0..<3 {
            network = await sampler.sample()
            if network?.ambiguous == true { recoveryStatus = "检测到多个模块，请仅连接一个后重试"; return }
            if isReady {
                if await gatewayReachable() == true { lastGatewayGood = true; recoveryStatus = "网卡和模块网关已恢复"; log(recoveryStatus); return }
                if !lastGatewayGood { recoveryStatus = "网卡已就绪，外网可用性待检测"; return }
            }
            if attempt < 2 { guard await delay(5) else { return } }
        }
        for _ in 0..<20 where pollBusy { guard await delay(1) else { return } }
        guard !pollBusy, let probe = await readModem(), probe.present else {
            recoveryStatus = "模块未就绪；请检查 USB 连接或配件授权"; return
        }
        if let sim = probe.simState, sim != "READY" { recoveryStatus = "SIM 尚未就绪：\(sim)，未重启模块"; return }
        if probe.registered == false { recoveryStatus = "模块尚未注册运营商，请检查信号和 SIM"; return }
        guard !sleeping, !Task.isCancelled else { return }
        if Date().timeIntervalSince(lastReset) < 300 { recoveryStatus = "已尝试恢复，冷却 5 分钟后可重试"; return }
        lastReset = Date(); recoveryStatus = "正在重新识别 USB 模块…"
        log("尝试 USB reset（当前用户权限）")
        let reset = await readModem(action: "usb-reset")
        log(reset?.success == true ? "USB reset 已接受" : "USB reset 未确认成功")
        await sampler.resetBaseline()
        for _ in 0..<6 {
            guard await delay(3) else { return }; network = await sampler.sample()
            if isReady, await gatewayReachable() == true { lastGatewayGood = true; recoveryStatus = "USB 重新识别后连接已恢复"; log(recoveryStatus); return }
        }
        guard !sleeping, !Task.isCancelled else { return }
        recoveryStatus = "正在软重启模块，等待重新入网…"
        log("尝试 AT+CFUN=1,1，不写入 USB 模式配置")
        let reboot = await readModem(action: "restart")
        guard reboot?.success == true else { recoveryStatus = "自动恢复未成功，可拔插模块后重试"; log(recoveryStatus); return }
        for _ in 0..<12 {
            guard await delay(3) else { return }; network = await sampler.sample()
            if isReady, await gatewayReachable() == true { lastGatewayGood = true; recoveryStatus = "模块重启后连接已恢复"; log(recoveryStatus); return }
        }
        recoveryStatus = "模块仍未恢复，请检查 SIM、信号和 USB 连接"; log(recoveryStatus)
    }
    func checkInternet() {
        guard !isCheckingInternet, !sleeping, let interface = network?.interface, isReady else { return }
        isCheckingInternet = true; internetStatus = "通过 4G 网卡检测中…"
        let version = epoch
        Task {
            defer { isCheckingInternet = false }
            if await gatewayReachable() == true { lastGatewayGood = true }
            // System DNS may return a proxy Fake-IP (198.18/15), which cannot be
            // reached directly through this NIC. Query the modem's own resolver
            // with its source IPv4; this does not alter saved DNS or routes.
            guard let source = network?.ipv4, let gateway = network?.router else {
                internetStatus = "模块 IPv4 或网关不可用，未执行外网检测"; return
            }
            let dns = await runner.run(URL(fileURLWithPath: "/usr/bin/dig"), ["+time=2", "+tries=1", "-b", source, "@" + gateway, "www.apple.com", "A", "+short"], timeout: 4)
            guard version == epoch, !sleeping else { return }
            let address = String(data: dns.output, encoding: .utf8)?.split(whereSeparator: \.isNewline).map(String.init).first(where: DisplayUnits.isPublicIPv4)
            guard let address else { internetStatus = "模块 DNS 未返回公网地址；无法确认外网"; return }
            let result = await runner.run(URL(fileURLWithPath: "/usr/bin/curl"), ["--silent", "--fail", "--noproxy", "*", "--interface", interface, "--ipv4", "--resolve", "www.apple.com:443:" + address, "--connect-timeout", "4", "--max-time", "6", "--max-filesize", "16384", "https://www.apple.com/library/test/success.html"], timeout: 7)
            guard version == epoch, !sleeping else { return }
            let body = String(data: result.output, encoding: .utf8) ?? ""
            internetStatus = result.code == 0 && body.contains("Success") ? "4G 外网可用（刚刚检测）" : "4G 外网检测未通过；不代表模块故障"
        }
    }
    func refreshLoginState() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    var canUseFeatures: Bool { !sleeping && !companionRunning && !isRecovering && !featureBusy }
    func clearMessages() { smsGeneration += 1; messages.removeAll(); smsStatus = "显示已清空；切换存储区或点刷新可重新载入。" }
    func featureRequest(_ arguments: [String]) async -> ModemSnapshot? {
        guard canUseFeatures else { return nil }
        featureBusy = true
        defer { featureBusy = false; nextModemPoll = .distantPast }
        let generation = epoch
        for _ in 0..<100 where pollBusy {
            guard await delay(0.1), generation == epoch else { return nil }
        }
        guard !pollBusy, !sleeping, generation == epoch else { return nil }
        let result = await runner.run(helperURL, arguments, timeout: arguments.first == "sms" ? 26 : 20)
        guard generation == epoch, !sleeping, !result.timedOut,
            let decoded = try? JSONDecoder().decode(ModemSnapshot.self, from: result.output) else { return nil }
        return decoded
    }
    func refreshModeInfo() async {
        guard canUseFeatures else { return }
        featureStatus = "读取当前 USB 网卡模式及固件能力…"
        let result = await featureRequest(["mode-info"])
        modeInfo = result?.success == true ? result : nil
        featureStatus = result?.success == true ? "已读取。选择模式不会立即生效，应用前还需确认。" : "读取失败：\(result?.error ?? "模块忙、未连接或已睡眠")"
    }
    func applyMode(_ target: Int, expected: Int) async {
        guard canUseFeatures, target != expected, (0...3).contains(target),
            modeInfo?.usbnet == expected, ((modeInfo?.supportedModes ?? 0) & (1 << target)) != 0 else { return }
        featureStatus = "正在写入并读回确认，随后请求模块重启…"
        let result = await featureRequest(["set-usbnet", String(target), String(expected), "--confirm"])
        modeInfo = nil
        // Avoid auto recovery fighting intentional USB re-enumeration.
        lastReset = Date(); nextModemPoll = Date().addingTimeInterval(10)
        featureStatus = result?.success == true ? "模式已保存；重启指令已接受。请等待 USB 重连，再读取确认。尚未确认网络恢复。" :
            result?.modeWritten == true ? "模式写入已接受，但读回或重启未确认；请读取当前模式，不要重复写入。" :
            "切换未确认：\(result?.error ?? "响应中断或超时")。请先重新读取当前模式。"
    }
    func refreshSMS(storage: String, allowMarkRead: Bool) async {
        guard canUseFeatures, ["ME", "SM"].contains(storage) else { return }
        smsStatus = "正在读取 \(storage == "ME" ? "模块" : "SIM 卡") 短信…"
        let generation = smsGeneration
        let result = await featureRequest(["sms", storage] + (allowMarkRead ? ["--allow-mark-read"] : []))
        guard generation == smsGeneration else { return }
        guard result?.success == true else {
            messages.removeAll()
            smsStatus = result?.error == "read_requires_marking" ? "固件不支持保留未读。勾选“允许标记已读”后自动重试；不会删除短信。" : "短信读取失败：\(result?.error ?? "模块忙、未连接或已睡眠")"
            return
        }
        messages = SMSDecoder.parse(result?.smsPdu ?? "")
        smsStatus = "\(storage) 已用 \(result?.smsUsed ?? 0)/\(result?.smsCapacity ?? 0) · 收件 \(messages.count) 条 · \(result?.smsPreservesUnread == true ? "使用保留未读参数" : "读取会标记已读") · 刚刚更新"
    }
    func setLoginEnabled(_ enabled: Bool) {
        loginError = nil
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { loginError = "登录项设置失败：\(error.localizedDescription)" }
        refreshLoginState()
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func log(_ message: String) {
        logEntries.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if logEntries.count > 100 { logEntries.removeFirst() }
    }
    func saveDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "4G-诊断.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = """
        MacDou · 4G 随行 · \(Date())
        模块：\(modem.model ?? "未知") / \(modem.firmware ?? "未知")
        网卡：\(network?.interface ?? "未发现")，IPv4：\(network?.ipv4 ?? "无")
        默认出口：\(network?.defaultInterface ?? "无")
        网络：\(modem.radioLabel)，\(modem.band ?? "未知")
        信号 RSRP：\(DisplayUnits.metric(modem.rsrpDbm, unit: "dBm"))
        SIM：\(modem.simState ?? "未知")，注册：\(modem.registrationStatus.map(String.init) ?? "未知")
        恢复：\(recoveryStatus)
        \(logEntries.joined(separator: "\n"))
        """
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { recoveryStatus = "诊断保存失败：\(error.localizedDescription)" }
    }
    func shutdown() {
        sleeping = true; epoch += 1; clearMessages()
        timer?.invalidate(); recoveryTask?.cancel(); runner.cancelAll()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
