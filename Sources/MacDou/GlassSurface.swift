import AppKit
import SwiftUI

// The popover uses one material background; cards add a quiet glass edge without changing layout.
struct GlassPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.thinMaterial)
        }
    }
}

private struct GlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.13 : 0.55), lineWidth: 0.7))
        }
    }
}

extension View {
    func glassCard(radius: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }
}
