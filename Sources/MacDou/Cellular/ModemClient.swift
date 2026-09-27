import Foundation
import Darwin

struct ModemSnapshot: Decodable, Sendable {
    var present = false
    var atOK = false
    var action: String?
    var success: Bool?
    var error: String?
    var manufacturer: String?
    var model: String?
    var firmware: String?
    var simState: String?
    var operatorName: String?
    var mccmnc: String?
    var technology: String?
    var band: String?
    var channel: Int?
    var csq: Int?
    var rssiDbm: Double?
    var rsrpDbm: Double?
    var rsrqDb: Double?
    var sinrDb: Double?
    var registered: Bool?
    var roaming: Bool?
    var registrationStatus: Int?
    var usbnet: Int?
    var moduleSleep: Int?
    var supportedModes: Int?
    var modeWritten: Bool?
    var restartAccepted: Bool?
    var smsPdu: String?
    var smsStorage: String?
    var smsUsed: Int?
    var smsCapacity: Int?
    var smsPreservesUnread: Bool?

    var operatorLabel: String {
        if let code = mccmnc {
            if ["46000", "46002", "46004", "46007", "46008"].contains(code) { return "中国移动" }
            if ["46001", "46006", "46009"].contains(code) { return "中国联通" }
            if ["46003", "46005", "46011"].contains(code) { return "中国电信" }
            if code == "46015" { return "中国广电" }
        }
        return operatorName.flatMap { $0.isEmpty ? nil : $0 } ?? "运营商未知"
    }
    var radioLabel: String {
        guard let tech = technology else { return "—" }
        return tech.uppercased().contains("LTE") ? "4G · \(tech)" : tech
    }
    var bars: Int? {
        if let rsrp = rsrpDbm { return rsrp >= -85 ? 4 : rsrp >= -95 ? 3 : rsrp >= -105 ? 2 : rsrp >= -115 ? 1 : 0 }
        guard let rssi = rssiDbm else { return nil }
        return rssi >= -75 ? 4 : rssi >= -85 ? 3 : rssi >= -95 ? 2 : rssi >= -105 ? 1 : 0
    }
}

struct CommandResult: Sendable {
    let output: Data
    let code: Int32
    let timedOut: Bool
}

/// Call only bounded, small-output helpers; all waits happen off the main thread.
final class CommandRunner: @unchecked Sendable {
    private final class OutputBuffer: @unchecked Sendable { var data = Data() }
    private let lock = NSLock()
    private var running: [UUID: Process] = [:]
    func cancelAll() {
        lock.lock(); let processes = Array(running.values); lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 20) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), output = Pipe(), token = UUID()
                process.executableURL = executable; process.arguments = arguments
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    self.lock.lock(); self.running[token] = process; self.lock.unlock()
                    let buffer = OutputBuffer(), reading = DispatchGroup()
                    reading.enter()
                    DispatchQueue.global(qos: .utility).async {
                        // Drain concurrently: a full SMS store can exceed pipe capacity.
                        while let chunk = try? output.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                            if buffer.data.count + chunk.count <= 2_000_000 { buffer.data.append(chunk) }
                        }
                        reading.leave()
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    var timedOut = false
                    while process.isRunning {
                        if ProcessInfo.processInfo.systemUptime - start > timeout {
                            timedOut = true; process.terminate()
                            Thread.sleep(forTimeInterval: 3.5) // Allow bounded SMS setting cleanup.
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.04)
                    }
                    process.waitUntilExit()
                    reading.wait()
                    self.lock.lock(); self.running.removeValue(forKey: token); self.lock.unlock()
                    continuation.resume(returning: CommandResult(output: buffer.data, code: process.terminationStatus, timedOut: timedOut))
                } catch { continuation.resume(returning: CommandResult(output: Data(), code: -1, timedOut: false)) }
            }
        }
    }
}

enum DisplayUnits {
    static func isPublicIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]
        return a > 0 && a < 224 && a != 10 && a != 127 &&
            !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b)) &&
            !(a == 192 && b == 168) && !(a == 198 && (18...19).contains(b)) &&
            !(a == 100 && (64...127).contains(b))
    }
    static func speed(_ value: Double, compact: Bool = false) -> String {
        guard value.isFinite, value > 0 else { return compact ? "0K" : "0 KB/s" }
        let mega = value >= 1_000_000, number = value / (value >= 1_000_000 ? 1_000_000 : 1_000)
        return String(format: "%.*f", number < 10 && mega ? 1 : 0, number) + (compact ? (mega ? "M" : "K") : (mega ? " MB/s" : " KB/s"))
    }
    static func bytes(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .decimal) }
    static func metric(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: value.rounded() == value ? "%.0f %@" : "%.1f %@", value, unit)
    }
}
