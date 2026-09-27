import AppKit
import CoreLocation
import CoreWLAN

struct WiFiChoice: Identifiable {
    let network: CWNetwork
    let name: String
    let rssi: Int
    let isProtected: Bool
    let isEnterprise: Bool
    var id: String { name }
}

private enum WiFiControlError: LocalizedError {
    case unavailable
    var errorDescription: String? { "未检测到 Wi-Fi 硬件" }
}

@MainActor
final class WiFiControl: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isAvailable = false
    @Published private(set) var isPoweredOn = false
    @Published private(set) var currentName: String?
    @Published private(set) var networks: [WiFiChoice] = []
    @Published private(set) var isBusy = false
    @Published private(set) var locationNeedsPermission = false
    @Published var message: String?
    @Published var passwordNetwork: WiFiChoice?
    @Published var pendingPassword = ""

    private let preview: Bool
    private var locationManager: CLLocationManager?
    private var scanAfterAuthorization = false

    init(preview: Bool = false) {
        self.preview = preview
        super.init()
        if preview {
            isAvailable = true
            isPoweredOn = true
            currentName = "示例网络"
        } else {
            refresh()
        }
    }

    func refresh(scanIfAuthorized: Bool = false) {
        guard !preview else { return }
        guard let interface = CWWiFiClient.shared().interface() else {
            if isAvailable { isAvailable = false }
            if isPoweredOn { isPoweredOn = false }
            if currentName != nil { currentName = nil }
            if !networks.isEmpty { networks = [] }
            if message != "未检测到 Wi-Fi 硬件" { message = "未检测到 Wi-Fi 硬件" }
            return
        }
        if !isAvailable { isAvailable = true }
        if message == "未检测到 Wi-Fi 硬件" { message = nil }
        let poweredOn = interface.powerOn()
        let name = interface.ssid()
        if isPoweredOn != poweredOn { isPoweredOn = poweredOn }
        if currentName != name { currentName = name }
        if !poweredOn {
            if !networks.isEmpty { networks = [] }
        } else if scanIfAuthorized, locationManagerForScan().authorizationStatus == .authorizedAlways {
            scan()
        }
    }

    func setPower(_ enabled: Bool, onChange: @escaping () -> Void) {
        guard !preview, !isBusy else { return }
        isBusy = true
        message = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> Void in
                guard let interface = CWWiFiClient.shared().interface() else { throw WiFiControlError.unavailable }
                try interface.setPower(enabled)
            }
            Task { @MainActor in
                if case .failure(let error) = result { self.message = error.localizedDescription }
                self.refresh()
                self.isBusy = false
                onChange()
            }
        }
    }

    func scan() {
        guard !preview, !isBusy, isPoweredOn else { return }
        let manager = locationManagerForScan()
        switch manager.authorizationStatus {
        case .authorizedAlways:
            locationNeedsPermission = false
            performScan()
        case .notDetermined:
            scanAfterAuthorization = true
            manager.requestWhenInUseAuthorization()
        default:
            locationNeedsPermission = true
            message = "允许 MacDou 使用定位服务后，才能列出 Wi-Fi 网络。"
        }
    }

    private func locationManagerForScan() -> CLLocationManager {
        if let locationManager { return locationManager }
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        return manager
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.handleAuthorization(status) }
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        guard scanAfterAuthorization else { return }
        switch status {
        case .authorizedAlways:
            scanAfterAuthorization = false
            locationNeedsPermission = false
            scan()
        case .denied, .restricted:
            scanAfterAuthorization = false
            locationNeedsPermission = true
            message = "定位权限未开启。可在系统设置中选网，或允许 MacDou 使用定位服务。"
        default: break
        }
    }

    private func performScan() {
        isBusy = true
        message = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> Set<CWNetwork> in
                guard let interface = CWWiFiClient.shared().interface() else { throw WiFiControlError.unavailable }
                return try interface.scanForNetworks(withSSID: nil)
            }
            Task { @MainActor in
                self.isBusy = false
                switch result {
                case .success(let found):
                    var strongest: [String: WiFiChoice] = [:]
                    for network in found {
                        guard let name = network.ssid, !name.isEmpty else { continue }
                        let enterprise = network.supportsSecurity(.enterprise) || network.supportsSecurity(.wpaEnterprise) ||
                            network.supportsSecurity(.wpaEnterpriseMixed) || network.supportsSecurity(.wpa2Enterprise) ||
                            network.supportsSecurity(.wpa3Enterprise) || network.supportsSecurity(.dynamicWEP)
                        let choice = WiFiChoice(network: network, name: name, rssi: network.rssiValue,
                                                isProtected: !network.supportsSecurity(.none), isEnterprise: enterprise)
                        if choice.rssi > (strongest[name]?.rssi ?? Int.min) { strongest[name] = choice }
                    }
                    self.networks = strongest.values.sorted {
                        $0.rssi == $1.rssi ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.rssi > $1.rssi
                    }
                    if self.networks.isEmpty {
                        self.message = found.isEmpty ? "没有发现附近的 Wi-Fi 网络。" : "无法显示网络名称；请检查定位权限。"
                    }
                    self.refresh()
                case .failure(let error):
                    self.message = "扫描失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func join(_ choice: WiFiChoice, password: String? = nil, onChange: @escaping () -> Void) {
        guard !preview, !isBusy else { return }
        if choice.isEnterprise {
            message = "企业网络需要账号或证书，请在系统网络设置中连接。"
            return
        }
        isBusy = true
        message = "正在连接 \(choice.name)…"
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> Void in
                guard let interface = CWWiFiClient.shared().interface() else { throw WiFiControlError.unavailable }
                try interface.associate(to: choice.network, password: password)
            }
            Task { @MainActor in
                self.isBusy = false
                switch result {
                case .success:
                    self.message = "已连接 \(choice.name)"
                    self.passwordNetwork = nil
                    self.refresh()
                    onChange()
                case .failure(let error):
                    if password == nil, choice.isProtected {
                        self.pendingPassword = ""
                        self.passwordNetwork = choice
                        self.message = nil
                    }
                    else { self.message = "连接失败：\(error.localizedDescription)" }
                }
            }
        }
    }
}
