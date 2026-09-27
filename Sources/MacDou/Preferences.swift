import Combine
import Foundation

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var dotSource: DotSource {
        didSet { defaults.set(dotSource.rawValue, forKey: "dotSource") }
    }
    @Published var showBatteryPercentage: Bool {
        didSet { defaults.set(showBatteryPercentage, forKey: "showBatteryPercentage") }
    }
    @Published var iconSize: Double {
        didSet { defaults.set(iconSize, forKey: "iconSize") }
    }
    @Published var trackOpacity: Double {
        didSet { defaults.set(trackOpacity, forKey: "trackOpacity") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dotSource = defaults.string(forKey: "dotSource").flatMap(DotSource.init(rawValue:)) ?? .volume
        showBatteryPercentage = defaults.bool(forKey: "showBatteryPercentage")
        let savedSize = defaults.double(forKey: "iconSize")
        iconSize = [18.0, 20.0, 22.0].contains(savedSize) ? savedSize : 20
        let savedOpacity = defaults.double(forKey: "trackOpacity")
        trackOpacity = (0.15...0.45).contains(savedOpacity) ? savedOpacity : 0.22
    }

    func restoreDefaults() {
        dotSource = .volume
        showBatteryPercentage = false
        iconSize = 20
        trackOpacity = 0.22
    }
}
