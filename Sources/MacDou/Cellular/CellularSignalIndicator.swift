import SwiftUI

struct CellularSignalIndicator: View {
    let status: CellularStatus
    private var activeBars: Int { status.present ? min(4, max(0, status.bars ?? 0)) : 0 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < activeBars ? Color.primary : Color.primary.opacity(0.18))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("4G \(status.title)")
    }
}
