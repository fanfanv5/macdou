import AppKit
import Combine
import CoreAudio
import CoreWLAN
import Darwin
import IOKit.ps
import Network

actor SensorReader {
    private let wifiClient = CWWiFiClient.shared()
    private let host = mach_host_self()
    private var previousCPU: CPUTicks?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func read(wifiPathActive: Bool) -> StatusSnapshot {
        StatusSnapshot(
            battery: readBattery(), wifi: readWiFi(pathActive: wifiPathActive),
            volume: readVolume(), cpuUsage: readCPU(), memoryUsage: readMemory(), updatedAt: Date()
        )
    }

    private func readBattery() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryStatus(isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled) }

        for source in list {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  (values[kIOPSIsPresentKey] as? Bool) != false
            else { continue }
            let capacity: Double?
            if let current = values[kIOPSCurrentCapacityKey] as? Int,
               let maximum = values[kIOPSMaxCapacityKey] as? Int {
                capacity = BatteryStatus.normalizedCapacity(current: current, maximum: maximum)
            } else { capacity = nil }
            let minutes = values[kIOPSTimeToEmptyKey] as? Int
            let warning: BatteryWarning
            switch IOPSGetBatteryWarningLevel() {
            case kIOPSLowBatteryWarningFinal: warning = .critical
            case kIOPSLowBatteryWarningEarly: warning = .low
            default: warning = .none
            }
            return BatteryStatus(
                fraction: capacity,
                isCharging: values[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isCharged: values[kIOPSIsChargedKey] as? Bool ?? false,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                systemWarning: warning,
                isPresent: true,
                minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return BatteryStatus(isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func readWiFi(pathActive: Bool) -> WiFiStatus {
        guard let interface = wifiClient.interface() else { return WiFiStatus() }
        guard interface.powerOn() else { return WiFiStatus(connection: .poweredOff) }
        let reading = interface.rssiValue()
        let rssi = (-120 ... -1).contains(reading) ? reading : nil
        // RSSI and the active route are sufficient; never request location or scan SSIDs.
        let connected = rssi != nil || pathActive
        return WiFiStatus(connection: connected ? .connected : .disconnected, rssi: rssi)
    }

    private func readVolume() -> VolumeStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return VolumeStatus() }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr

        func volume(channel: AudioObjectPropertyElement) -> Double? {
            var property = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: channel
            )
            guard AudioObjectHasProperty(device, &property) else { return nil }
            var result: Float32 = 0
            var count = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &count, &result) == noErr,
                  result.isFinite else { return nil }
            return Double(min(1, max(0, result)))
        }

        let master = volume(channel: kAudioObjectPropertyElementMain)
        let channels = master == nil ? [volume(channel: 1), volume(channel: 2)].compactMap { $0 } : []
        let fraction = master ?? (channels.isEmpty ? nil : channels.reduce(0, +) / Double(channels.count))
        return VolumeStatus(fraction: fraction, isMuted: hasMute && muted != 0)
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousCPU = ticks }
        return previousCPU.flatMap { ticks.usage(since: $0) }
    }

    private func readMemory() -> Double? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Double(info.active_count) + Double(info.wire_count) + Double(info.compressor_page_count)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(1, max(0, pages * Double(vm_kernel_page_size) / total))
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = StatusSnapshot()
    private let reader = SensorReader()
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var wifiPathActive = false
    private var sampling = false
    private var isSuspended = false
    private var observers: [NSObjectProtocol] = []

    init(preview: StatusSnapshot? = nil) {
        if let preview { snapshot = preview; return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let active = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.wifiPathActive = active
                await self?.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.fan.macdou.network", qos: .utility))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
        resume()
    }

    func refresh() async {
        guard !sampling, !isSuspended else { return }
        sampling = true
        let next = await reader.read(wifiPathActive: wifiPathActive)
        snapshot = next
        sampling = false
    }

    private func suspend() {
        isSuspended = true
        timer?.invalidate()
        timer = nil
    }
    private func resume() {
        isSuspended = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.tolerance = 0.4
        Task { await refresh() }
    }

    func stop() {
        suspend()
        pathMonitor.cancel()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers.removeAll()
    }
}
