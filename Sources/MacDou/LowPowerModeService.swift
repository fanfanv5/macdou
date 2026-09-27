import Combine
import Foundation

enum LowPowerModeResult {
    case updated
    case cancelled
}

private enum LowPowerModeError: LocalizedError {
    case failed

    var errorDescription: String? { "低电量模式更改失败，请检查管理员授权。" }
}

enum LowPowerModeService {
    static func setEnabled(_ enabled: Bool, onBattery: Bool) async throws -> LowPowerModeResult {
        try await Task.detached(priority: .userInitiated) {
            let source = onBattery ? "-b" : "-c"
            let value = enabled ? "1" : "0"
            let script = "do shell script \"/usr/bin/pmset \(source) lowpowermode \(value)\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if output.contains("(-128)") { return .cancelled }
                throw LowPowerModeError.failed
            }
            return .updated
        }.value
    }
}

@MainActor
final class LowPowerModeControl: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    func setEnabled(_ enabled: Bool, onBattery: Bool, onChange: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                _ = try await LowPowerModeService.setEnabled(enabled, onBattery: onBattery)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            onChange()
        }
    }
}
