import AppKit

struct RingState: Equatable {
    var batteryFraction: Double?
    var wifiConnection: WiFiConnection
    var activeDots: Int?
    var showsDots: Bool
    var trackOpacity: Double
    var powerGlyph: BatteryPowerGlyph
    var isLowPowerMode: Bool
    var isCharging: Bool { powerGlyph == .charging }

    init(snapshot: StatusSnapshot, source: DotSource, trackOpacity: Double = 0.22) {
        // Menu-bar changes only need whole-percent battery precision.
        batteryFraction = snapshot.battery.fraction.map { ($0 * 100).rounded() / 100 }
        wifiConnection = snapshot.wifi.connection
        powerGlyph = snapshot.battery.powerGlyph
        isLowPowerMode = snapshot.battery.isLowPowerMode
        activeDots = DotLevel.count(for: snapshot.fraction(for: source))
        showsDots = source != .hidden
        self.trackOpacity = min(0.45, max(0.15, trackOpacity))
    }
}

enum RingRenderer {
    @MainActor
    static func image(state: RingState, size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state: state, in: rect, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(state: RingState, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let scale = min(rect.width, rect.height) / 22
        context.translateBy(x: rect.midX - 11 * scale, y: rect.midY + 11 * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func color(_ alpha: CGFloat = 1) {
            context.setStrokeColor(CGColor(gray: 0, alpha: alpha))
            context.setFillColor(CGColor(gray: 0, alpha: alpha))
        }
        func dot(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, alpha: CGFloat = 1) {
            color(alpha)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        func batteryArc(fraction: Double, alpha: CGFloat) {
            guard fraction > 0 else { return }
            color(alpha)
            context.setLineWidth(1.5)
            context.beginPath()
            context.addArc(
                center: CGPoint(x: 11, y: 11.84), radius: 8,
                startAngle: 145 * .pi / 180,
                endAngle: CGFloat(145 + 250 * min(1, fraction)) * .pi / 180,
                clockwise: false
            )
            context.strokePath()
        }

        batteryArc(fraction: 1, alpha: state.trackOpacity)
        if let fraction = state.batteryFraction { batteryArc(fraction: fraction, alpha: 1) }

        let wifiAlpha: CGFloat = state.wifiConnection == .connected ? 1 : 0.28
        func wifiArc(centerY: CGFloat, radius: CGFloat, halfWidth: CGFloat, endpointY: CGFloat) {
            // True circular arcs, with circular line caps and no non-uniform scale.
            let start = atan2(endpointY - centerY, -halfWidth)
            let end = atan2(endpointY - centerY, halfWidth)
            color(wifiAlpha)
            context.setLineWidth(1.6)
            context.beginPath()
            context.addArc(center: CGPoint(x: 11, y: centerY), radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.strokePath()
        }
        wifiArc(centerY: 9.9 + sqrt(6.1 * 6.1 - 4.1 * 4.1), radius: 6.1, halfWidth: 4.1, endpointY: 9.9)
        wifiArc(centerY: 12 + sqrt(3.6 * 3.6 - 2.3 * 2.3), radius: 3.6, halfWidth: 2.3, endpointY: 12)
        dot(11, 14, radius: 1, alpha: wifiAlpha)

        if state.wifiConnection != .connected {
            color(0.85)
            context.setLineWidth(1.3)
            context.move(to: CGPoint(x: 7.4, y: 8.2))
            context.addLine(to: CGPoint(x: 14.7, y: 15.5))
            context.strokePath()
        }

        if state.showsDots {
            let positions: [CGPoint] = [.init(x: 6.3, y: 17.4), .init(x: 9.45, y: 18.2), .init(x: 12.55, y: 18.2), .init(x: 15.7, y: 17.4)]
            for (index, point) in positions.enumerated() {
                dot(point.x, point.y, radius: 0.95, alpha: index < (state.activeDots ?? 0) ? 1 : 0.20)
            }
        }

        if state.powerGlyph == .charging {
            // An outlined cutout keeps the small bolt separate from the battery arc.
            let bolt = CGMutablePath()
            bolt.move(to: CGPoint(x: 19.7, y: 1.4))
            bolt.addLine(to: CGPoint(x: 15.5, y: 6.6))
            bolt.addLine(to: CGPoint(x: 18.1, y: 6.6))
            bolt.addLine(to: CGPoint(x: 17, y: 10.1))
            bolt.addLine(to: CGPoint(x: 21.4, y: 4.7))
            bolt.addLine(to: CGPoint(x: 18.8, y: 4.7))
            bolt.closeSubpath()
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(bolt)
            context.setLineWidth(1.7)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
            color()
            context.addPath(bolt)
            context.fillPath()
        } else if state.powerGlyph == .pluggedIn {
            let prongsAndCable = CGMutablePath()
            prongsAndCable.move(to: CGPoint(x: 17.6, y: 1.7))
            prongsAndCable.addLine(to: CGPoint(x: 17.6, y: 4.1))
            prongsAndCable.move(to: CGPoint(x: 19.7, y: 1.7))
            prongsAndCable.addLine(to: CGPoint(x: 19.7, y: 4.1))
            prongsAndCable.move(to: CGPoint(x: 18.65, y: 7))
            prongsAndCable.addLine(to: CGPoint(x: 18.65, y: 8.2))
            prongsAndCable.addLine(to: CGPoint(x: 16.5, y: 9.7))
            let body = CGPath(roundedRect: CGRect(x: 16.8, y: 3.8, width: 3.7, height: 3.3),
                              cornerWidth: 0.8, cornerHeight: 0.8, transform: nil)
            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineWidth(2.8)
            context.addPath(prongsAndCable)
            context.strokePath()
            context.addPath(CGPath(roundedRect: CGRect(x: 16.2, y: 3.2, width: 4.9, height: 4.5),
                                   cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            context.fillPath()
            context.restoreGState()
            color()
            context.setLineWidth(1.2)
            context.addPath(prongsAndCable)
            context.strokePath()
            context.addPath(body)
            context.fillPath()
        }

        if state.isLowPowerMode {
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: 1.5, y: 6.5))
            leaf.addCurve(to: CGPoint(x: 6.5, y: 1.5),
                          control1: CGPoint(x: 1.4, y: 2.4), control2: CGPoint(x: 4.5, y: 1.2))
            leaf.addCurve(to: CGPoint(x: 1.5, y: 6.5),
                          control1: CGPoint(x: 6.8, y: 4.8), control2: CGPoint(x: 3.8, y: 7.2))
            leaf.closeSubpath()
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(leaf)
            context.setLineWidth(1.5)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
            color()
            context.addPath(leaf)
            context.fillPath()
            context.saveGState()
            context.setBlendMode(.clear)
            context.setLineWidth(0.65)
            context.move(to: CGPoint(x: 2.3, y: 5.7))
            context.addLine(to: CGPoint(x: 5.7, y: 2.4))
            context.strokePath()
            context.restoreGState()
        }
    }
}
