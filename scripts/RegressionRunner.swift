import Foundation

// A dependency-free runner for machines with Command Line Tools but no XCTest.
private var assertionCount = 0

private func record(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
    assertionCount += 1
    guard passed else {
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
        exit(1)
    }
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    record(actual == expected, "Expected \(expected), received \(actual)", file: file, line: line)
}
func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    record(abs(actual - expected) <= accuracy, "Expected \(expected), received \(actual)", file: file, line: line)
}
func XCTAssertNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
    record(actual == nil, "Expected unavailable value", file: file, line: line)
}
func XCTAssertTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    record(actual, "Expected true", file: file, line: line)
}
func XCTAssertFalse(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    record(!actual, "Expected false", file: file, line: line)
}
func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ minimum: T, file: StaticString = #filePath, line: UInt = #line) {
    record(actual > minimum, "Expected \(actual) > \(minimum)", file: file, line: line)
}

@main
enum RegressionRunner {
    static func main() async {
        let tests = StatusTests()
        let cases: [(String, () -> Void)] = [
            ("底部状态阈值及无效读数", tests.testDotThresholdsAndInvalidReadings),
            ("切换数据源保持电量与 Wi-Fi 独立", tests.testSwitchingDotSourceUsesIndependentSensorWithoutChangingBattery),
            ("静音覆盖硬件音量", tests.testMuteOverridesCachedHardwareVolume),
            ("不支持的输出设备显示未知", tests.testUnsupportedOutputDoesNotBecomeFullVolume),
            ("Wi-Fi 信号档位及未知状态", tests.testWiFiRSSIThresholdsAndUnknownConnection),
            ("电池容量异常及零值", tests.testBatteryCapacityHandlesInvalidAndOverfullReadings),
            ("CPU 按时间窗口计算", tests.testCPUUsesIntervalInsteadOfLifetimeTotals),
            ("CPU 计数器溢出", tests.testCPUHandlesCounterWraparound),
            ("零电量与无电池保留底轨", tests.testTrackRemainsVisibleForZeroAndMissingBattery),
            ("充电状态与接电状态区分", tests.testChargingGlyphStateFollowsBatteryNotWallPower),
            ("已充满、低电量与低电量模式", tests.testChargedLowBatteryAndLowPowerModeAreDistinct),
            ("供电图标与低电量模式图形已绘制", tests.testPowerGlyphsAndLowPowerLeafAreActuallyDrawn),
            ("底部状态显示 4G 原始信号档位", tests.testCellularBarsUseOriginalFourLevelSignal)
        ]
        for (name, run) in cases { run(); print("PASS \(name)") }
        await tests.testSettingsPersistAndRestoreDefaults()
        print("PASS 设置保存、重读和恢复默认")
        await tests.testStaleOrCorruptPreferencesFallBackToUsableValues()
        print("PASS 旧设置及损坏设置回退")
        print("\(cases.count + 2) groups passed; \(assertionCount) assertions.")
    }
}
