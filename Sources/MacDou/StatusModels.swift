import Foundation

enum DotSource: String, CaseIterable, Identifiable, Codable {
    case volume, wifiSignal, cellularSignal, cpuUsage, memoryUsage, hidden

    var id: String { rawValue }
    var title: String {
        switch self {
        case .volume: return "系统音量"
        case .wifiSignal: return "Wi-Fi 信号"
        case .cellularSignal: return "4G 信号"
        case .cpuUsage: return "CPU 使用率"
        case .memoryUsage: return "内存占用"
        case .hidden: return "隐藏四点"
        }
    }
    var symbol: String {
        switch self {
        case .volume: return "speaker.wave.2"
        case .wifiSignal: return "wifi"
        case .cellularSignal: return "antenna.radiowaves.left.and.right"
        case .cpuUsage: return "cpu"
        case .memoryUsage: return "memorychip"
        case .hidden: return "eye.slash"
        }
    }
    var explanation: String {
        switch self {
        case .volume: return "每点约 25% 音量；静音时四点变浅。"
        case .wifiSignal: return "从弱到强分为四档；点越多，信号越强。"
        case .cellularSignal: return "四点随模块信号强弱变化，优先读取 RSRP；过期或不可用时四点变浅。"
        case .cpuUsage: return "每点约 25% CPU 使用率，每 2 秒更新。"
        case .memoryUsage: return "每点约 25% 内存占用，统计活跃、驻留与压缩内存。"
        case .hidden: return "收起底部四点，只显示电量与 Wi-Fi。"
        }
    }
}

enum BatteryWarning: Equatable {
    case none, low, critical

    var title: String? {
        switch self {
        case .none: return nil
        case .low: return "低电量"
        case .critical: return "电量危急"
        }
    }
}

enum BatteryPowerGlyph: Equatable {
    case none, charging, pluggedIn
}

struct BatteryStatus: Equatable {
    var fraction: Double?
    var isCharging = false
    var isPluggedIn = false
    var isCharged = false
    var isLowPowerMode = false
    var systemWarning: BatteryWarning = .none
    var isPresent = false
    var minutesRemaining: Int?

    static func normalizedCapacity(current: Int, maximum: Int) -> Double? {
        guard current >= 0, maximum > 0 else { return nil }
        return min(1, Double(current) / Double(maximum))
    }

    var title: String {
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        return isPresent ? "读取中" : "无内置电池"
    }
    var powerGlyph: BatteryPowerGlyph {
        guard isPresent else { return .none }
        if isCharging { return .charging }
        if isPluggedIn { return .pluggedIn }
        return .none
    }
    var warning: BatteryWarning {
        guard isPresent else { return .none }
        if systemWarning == .critical || (fraction.map { $0 <= 0.10 } == true) { return .critical }
        if systemWarning == .low || (fraction.map { $0 <= 0.20 } == true) { return .low }
        return .none
    }
    var powerState: String {
        guard isPresent else { return "电量弧保留浅色底轨" }
        if isCharging { return "正在充电" }
        if isPluggedIn { return isCharged ? "已充满 · 电源已连接" : "电源已连接 · 未在充电" }
        if let minutesRemaining, minutesRemaining > 0 {
            let hours = minutesRemaining / 60
            let minutes = minutesRemaining % 60
            return "预计剩余 " + (hours > 0 ? "\(hours) 小时 " : "") + "\(minutes) 分钟"
        }
        return "电池供电"
    }
    var detail: String {
        var parts = [powerState]
        if let warning = warning.title { parts.append(warning) }
        if isLowPowerMode { parts.append("低电量模式") }
        return parts.joined(separator: " · ")
    }
}

enum WiFiConnection: String { case connected, disconnected, poweredOff, unavailable }

struct WiFiStatus: Equatable {
    var connection: WiFiConnection = .unavailable
    var rssi: Int?

    var title: String {
        switch connection {
        case .connected: return "已连接"
        case .disconnected: return "未连接"
        case .poweredOff: return "已关闭"
        case .unavailable: return "不可用"
        }
    }
    var strength: Double? {
        guard connection == .connected else { return connection == .unavailable ? nil : 0 }
        guard let rssi, rssi < 0 else { return nil }
        switch rssi {
        case -55 ... -1: return 1
        case -67 ... -56: return 0.75
        case -75 ... -68: return 0.5
        default: return 0.25
        }
    }
    var detail: String {
        if connection == .connected {
            if let rssi { return "信号 \(rssi) dBm" }
            return "已连接，信号强度暂不可用"
        }
        switch connection {
        case .poweredOff: return "可在系统设置中打开 Wi-Fi"
        case .disconnected: return "尚未连接 Wi-Fi 网络"
        default: return "未检测到可用的 Wi-Fi 接口"
        }
    }
}

struct VolumeStatus: Equatable {
    var fraction: Double?
    var isMuted = false
    var effectiveFraction: Double? { isMuted ? 0 : fraction }
    var title: String {
        if isMuted { return "静音" }
        guard let fraction else { return "不可用" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

struct StatusSnapshot: Equatable {
    var battery = BatteryStatus()
    var wifi = WiFiStatus()
    var volume = VolumeStatus()
    var cpuUsage: Double?
    var memoryUsage: Double?
    var updatedAt: Date?
    var cellular = CellularStatus()

    func fraction(for source: DotSource) -> Double? {
        switch source {
        case .volume: return volume.effectiveFraction
        case .wifiSignal: return wifi.strength
        case .cellularSignal: return cellular.bars.map { Double($0) / 4 }
        case .cpuUsage: return cpuUsage
        case .memoryUsage: return memoryUsage
        case .hidden: return nil
        }
    }
    func value(for source: DotSource) -> String {
        if source == .hidden { return "已隐藏" }
        if source == .volume { return volume.title }
        if source == .cellularSignal { return cellular.title }
        if source == .wifiSignal {
            guard wifi.connection == .connected else { return wifi.title }
            guard let rssi = wifi.rssi else { return "强度未知" }
            return "\(rssi) dBm"
        }
        guard let value = fraction(for: source) else { return "读取中" }
        return "\(Int((value * 100).rounded()))%"
    }
    func hint(for source: DotSource) -> String {
        if source == .volume, volume.effectiveFraction == nil {
            return "当前输出设备不提供系统音量读数。"
        }
        if source == .wifiSignal, wifi.connection == .connected, wifi.rssi == nil {
            return "系统暂未提供信号强度；未知值显示为浅色点。"
        }
        return source.explanation
    }

    static let preview = StatusSnapshot(
        battery: BatteryStatus(fraction: 0.72, isPresent: true),
        wifi: WiFiStatus(connection: .connected, rssi: -58),
        volume: VolumeStatus(fraction: 0.5),
        cpuUsage: 0.28, memoryUsage: 0.63, updatedAt: Date()
    )
}

struct CellularStatus: Equatable {
    var present = false
    var bars: Int?
    var title: String {
        guard present else { return "未连接" }
        guard let bars else { return "信号未知" }
        switch min(4, max(0, bars)) {
        case 0: return "无信号"
        case 1: return "信号弱"
        case 2: return "信号一般"
        case 3: return "信号良好"
        default: return "信号强"
        }
    }
}

enum DotLevel {
    static func count(for fraction: Double?) -> Int? {
        guard let fraction, fraction.isFinite else { return nil }
        return Int(ceil(min(1, max(0, fraction)) * 4))
    }
}

struct CPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    func usage(since old: CPUTicks) -> Double? {
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        return total > 0 ? Double(busy) / Double(total) : nil
    }
}
