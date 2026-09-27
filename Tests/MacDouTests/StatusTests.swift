import AppKit
import Foundation

final class StatusTests {
    func testDotThresholdsAndInvalidReadings() {
        XCTAssertNil(DotLevel.count(for: nil))
        XCTAssertNil(DotLevel.count(for: .nan))
        XCTAssertNil(DotLevel.count(for: .infinity))
        XCTAssertEqual(DotLevel.count(for: -0.1), 0)
        XCTAssertEqual(DotLevel.count(for: 0), 0)
        XCTAssertEqual(DotLevel.count(for: 0.01), 1)
        XCTAssertEqual(DotLevel.count(for: 0.25), 1)
        XCTAssertEqual(DotLevel.count(for: 0.251), 2)
        XCTAssertEqual(DotLevel.count(for: 0.5), 2)
        XCTAssertEqual(DotLevel.count(for: 0.75), 3)
        XCTAssertEqual(DotLevel.count(for: 0.751), 4)
        XCTAssertEqual(DotLevel.count(for: 1.2), 4)
    }

    func testSwitchingDotSourceUsesIndependentSensorWithoutChangingBattery() {
        var snapshot = StatusSnapshot.preview
        snapshot.volume = VolumeStatus(fraction: 0.1)
        snapshot.cpuUsage = 0.8
        let volume = RingState(snapshot: snapshot, source: .volume)
        let cpu = RingState(snapshot: snapshot, source: .cpuUsage)
        let wifi = RingState(snapshot: snapshot, source: .wifiSignal)
        XCTAssertEqual(volume.activeDots, 1)
        XCTAssertEqual(cpu.activeDots, 4)
        XCTAssertEqual(wifi.activeDots, 3)
        XCTAssertEqual(volume.batteryFraction, cpu.batteryFraction)
        XCTAssertEqual(volume.wifiConnection, cpu.wifiConnection)
        XCTAssertFalse(RingState(snapshot: snapshot, source: .hidden).showsDots)
    }

    func testMuteOverridesCachedHardwareVolume() {
        var snapshot = StatusSnapshot.preview
        snapshot.volume = VolumeStatus(fraction: 0.9, isMuted: true)
        XCTAssertEqual(RingState(snapshot: snapshot, source: .volume).activeDots, 0)
        XCTAssertEqual(snapshot.value(for: .volume), "静音")
    }

    func testUnsupportedOutputDoesNotBecomeFullVolume() {
        var snapshot = StatusSnapshot.preview
        snapshot.volume = VolumeStatus()
        XCTAssertNil(RingState(snapshot: snapshot, source: .volume).activeDots)
        XCTAssertEqual(snapshot.value(for: .volume), "不可用")
    }

    func testWiFiRSSIThresholdsAndUnknownConnection() {
        let samples: [(Int, Int)] = [(-45, 4), (-55, 4), (-56, 3), (-67, 3), (-68, 2), (-75, 2), (-76, 1)]
        for (rssi, expected) in samples {
            XCTAssertEqual(DotLevel.count(for: WiFiStatus(connection: .connected, rssi: rssi).strength), expected)
        }
        XCTAssertNil(WiFiStatus(connection: .connected, rssi: nil).strength)
        XCTAssertNil(WiFiStatus(connection: .connected, rssi: 0).strength)
        XCTAssertEqual(WiFiStatus(connection: .poweredOff).strength, 0)
    }

    func testBatteryCapacityHandlesInvalidAndOverfullReadings() {
        XCTAssertEqual(BatteryStatus.normalizedCapacity(current: 3600, maximum: 5000), 0.72)
        XCTAssertEqual(BatteryStatus.normalizedCapacity(current: 5100, maximum: 5000), 1)
        XCTAssertEqual(BatteryStatus.normalizedCapacity(current: 0, maximum: 5000), 0)
        XCTAssertNil(BatteryStatus.normalizedCapacity(current: 50, maximum: 0))
        XCTAssertNil(BatteryStatus.normalizedCapacity(current: -1, maximum: 100))
        XCTAssertNil(RingState(snapshot: StatusSnapshot(), source: .volume).batteryFraction)
    }

    func testCPUUsesIntervalInsteadOfLifetimeTotals() {
        let old = CPUTicks(user: 1000, system: 500, idle: 5000, nice: 0)
        let new = CPUTicks(user: 1010, system: 510, idle: 5080, nice: 0)
        XCTAssertEqual(new.usage(since: old)!, 0.2, accuracy: 0.0001)
        XCTAssertNil(old.usage(since: old))
    }

    func testCPUHandlesCounterWraparound() {
        let old = CPUTicks(user: UInt32.max - 4, system: 0, idle: 100, nice: 0)
        let new = CPUTicks(user: 5, system: 0, idle: 110, nice: 0)
        XCTAssertEqual(new.usage(since: old)!, 0.5, accuracy: 0.0001)
    }

    func testTrackRemainsVisibleForZeroAndMissingBattery() {
        var snapshot = StatusSnapshot.preview
        snapshot.battery.fraction = 0
        XCTAssertGreaterThan(RingState(snapshot: snapshot, source: .volume, trackOpacity: 0).trackOpacity, 0)
        snapshot.battery.fraction = nil
        XCTAssertEqual(RingState(snapshot: snapshot, source: .volume).trackOpacity, 0.22)
    }

    func testChargingGlyphStateFollowsBatteryNotWallPower() {
        var snapshot = StatusSnapshot.preview
        snapshot.battery.isPluggedIn = true
        snapshot.battery.isCharging = false
        XCTAssertFalse(RingState(snapshot: snapshot, source: .volume).isCharging)
        XCTAssertEqual(RingState(snapshot: snapshot, source: .volume).powerGlyph, .pluggedIn)
        XCTAssertEqual(snapshot.battery.detail, "电源已连接 · 未在充电")
        snapshot.battery.isCharging = true
        XCTAssertTrue(RingState(snapshot: snapshot, source: .volume).isCharging)
        XCTAssertEqual(RingState(snapshot: snapshot, source: .volume).powerGlyph, .charging)
        XCTAssertEqual(snapshot.battery.detail, "正在充电")
        snapshot.battery.isPresent = false
        XCTAssertFalse(RingState(snapshot: snapshot, source: .volume).isCharging)
        XCTAssertEqual(RingState(snapshot: snapshot, source: .volume).powerGlyph, .none)
    }

    func testChargedLowBatteryAndLowPowerModeAreDistinct() {
        var battery = BatteryStatus(fraction: 1, isPluggedIn: true, isCharged: true, isPresent: true)
        XCTAssertEqual(battery.powerState, "已充满 · 电源已连接")
        XCTAssertEqual(battery.powerGlyph, .pluggedIn)
        XCTAssertEqual(battery.warning, .none)

        battery.fraction = 0.18
        battery.isPluggedIn = false
        battery.isCharged = false
        XCTAssertEqual(battery.warning, .low)
        XCTAssertEqual(battery.warning.title, "低电量")
        battery.fraction = 0.08
        XCTAssertEqual(battery.warning, .critical)
        battery.fraction = 0.5
        battery.systemWarning = .critical
        XCTAssertEqual(battery.warning, .critical)
        battery.systemWarning = .none
        battery.isLowPowerMode = true
        XCTAssertEqual(battery.warning, .none)
        XCTAssertTrue(battery.detail.contains("低电量模式"))
    }

    func testPowerGlyphsAndLowPowerLeafAreActuallyDrawn() {
        func pixels(_ battery: BatteryStatus) -> Data {
            var snapshot = StatusSnapshot.preview
            snapshot.battery = battery
            let context = CGContext(data: nil, width: 220, height: 220, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            RingRenderer.draw(state: RingState(snapshot: snapshot, source: .volume),
                              in: CGRect(x: 0, y: 0, width: 220, height: 220), context: context)
            return context.makeImage()!.dataProvider!.data! as Data
        }
        let battery = BatteryStatus(fraction: 0.72, isPresent: true)
        var charging = battery
        charging.isCharging = true
        charging.isPluggedIn = true
        var plugged = battery
        plugged.isPluggedIn = true
        var lowPower = battery
        lowPower.isLowPowerMode = true
        let plainPixels = pixels(battery)
        XCTAssertFalse(plainPixels == pixels(charging))
        XCTAssertFalse(plainPixels == pixels(plugged))
        XCTAssertFalse(plainPixels == pixels(lowPower))
        XCTAssertFalse(pixels(charging) == pixels(plugged))
    }

    func testCellularBarsUseOriginalFourLevelSignal() {
        var snapshot = StatusSnapshot.preview
        snapshot.cellular = CellularStatus(present: true, bars: 3)
        XCTAssertEqual(RingState(snapshot: snapshot, source: .cellularSignal).activeDots, 3)
        XCTAssertEqual(snapshot.value(for: .cellularSignal), "3/4 格")
        snapshot.cellular.bars = nil
        XCTAssertNil(RingState(snapshot: snapshot, source: .cellularSignal).activeDots)
        XCTAssertEqual(snapshot.value(for: .cellularSignal), "信号未知")
        snapshot.cellular.present = false
        XCTAssertEqual(snapshot.value(for: .cellularSignal), "未连接")
    }

    func testSettingsPersistAndRestoreDefaults() async {
        await MainActor.run {
            let suite = "com.fan.macdou.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let initial = Preferences(defaults: defaults)
            initial.dotSource = .memoryUsage
            initial.showBatteryPercentage = true
            initial.iconSize = 22
            initial.trackOpacity = 0.35
            let restored = Preferences(defaults: defaults)
            XCTAssertEqual(restored.dotSource, .memoryUsage)
            XCTAssertTrue(restored.showBatteryPercentage)
            XCTAssertEqual(restored.iconSize, 22)
            XCTAssertEqual(restored.trackOpacity, 0.35)
            restored.restoreDefaults()
            XCTAssertEqual(Preferences(defaults: defaults).dotSource, .volume)
            XCTAssertFalse(Preferences(defaults: defaults).showBatteryPercentage)
        }
    }

    func testStaleOrCorruptPreferencesFallBackToUsableValues() async {
        await MainActor.run {
            let suite = "com.fan.macdou.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("removed-plugin", forKey: "dotSource")
            defaults.set(-20, forKey: "iconSize")
            defaults.set(0, forKey: "trackOpacity")
            let preferences = Preferences(defaults: defaults)
            XCTAssertEqual(preferences.dotSource, .volume)
            XCTAssertEqual(preferences.iconSize, 20)
            XCTAssertGreaterThan(preferences.trackOpacity, 0)
        }
    }
}
