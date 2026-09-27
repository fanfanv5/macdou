import AppKit

extension GuardModel {
    var cellularStatus: CellularStatus {
        CellularStatus(present: modem.present || isReady, bars: visibleBars)
    }

    func merging(_ snapshot: StatusSnapshot) -> StatusSnapshot {
        var result = snapshot
        result.cellular = cellularStatus
        return result
    }

    func takeOverCompanion() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.fan.dji4gguard") {
            app.terminate()
        }
        refreshNow()
    }

    static func preview(defaults: UserDefaults) -> GuardModel {
        let model = GuardModel(startMonitoring: false, defaults: defaults)
        model.modem = ModemSnapshot(present: true, atOK: true, model: "QDC507", simState: "READY", operatorName: "中国移动", technology: "LTE", band: "B3", rsrpDbm: -91, sinrDb: 18, registered: true)
        model.lastUpdate = Date()
        model.network = NetworkSnapshot(interface: "en7", ipv4: "192.0.2.2", router: "192.0.2.1", defaultInterface: "en0", linkActive: true, receivedBytes: 0, sentBytes: 0, downloadBytesPerSecond: 2_460_000, uploadBytesPerSecond: 128_000, sessionReceivedBytes: 236_000_000, sessionSentBytes: 18_000_000, ambiguous: false)
        model.history = (0..<30).map { i -> GuardModel.RateSample in
            let wave = sin(Double(i) * 0.7) * 700_000
            let down = 1_000_000 + wave + Double(i % 5) * 280_000
            let up = 100_000 + Double(i % 7) * 38_000
            return GuardModel.RateSample(down: down, up: up)
        }
        return model
    }
}

/// One status item, with optional fixed-width upload/download rows next to the ring.
@MainActor
struct UnifiedMenuContent: Equatable {
    let ring: RingState
    let size: Double
    let showsSpeed: Bool
    let upload: String
    let download: String

    init(ring: RingState, size: Double, model: GuardModel) {
        self.ring = ring
        self.size = size
        showsSpeed = model.showMenuSpeed
        upload = showsSpeed ? Self.rate(model.isReady ? model.network?.uploadBytesPerSecond : nil) : ""
        download = showsSpeed ? Self.rate(model.isReady ? model.network?.downloadBytesPerSecond : nil) : ""
    }

    static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 999_500 { return String(format: "%.0fK", bytes / 1000) }
        if bytes < 999_500_000 {
            let value = bytes / 1_000_000
            return String(format: value < 9.95 ? "%.1fM" : "%.0fM", value)
        }
        return bytes < 9_950_000_000 ? String(format: "%.1fG", bytes / 1_000_000_000) : ">9G"
    }

    func image() -> NSImage {
        guard showsSpeed else { return RingRenderer.image(state: ring, size: size) }
        let glyph = RingRenderer.image(state: ring, size: size)
        let result = NSImage(size: NSSize(width: size + 39, height: max(20, size)), flipped: false) { rect in
            glyph.draw(in: NSRect(x: 0, y: (rect.height - size) / 2, width: size, height: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium), .foregroundColor: NSColor.black]
            for (arrow, value, y) in [("↑", upload, rect.midY), ("↓", download, rect.midY - 10)] {
                (arrow as NSString).draw(at: NSPoint(x: size + 3, y: y), withAttributes: attributes)
                (value as NSString).draw(at: NSPoint(x: size + 11, y: y), withAttributes: attributes)
            }
            return true
        }
        result.isTemplate = true
        return result
    }
}
