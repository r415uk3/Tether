import SwiftUI

extension View {
    /// A floating card: Liquid Glass on macOS 26+, a quiet filled rounded rectangle on 15.
    @ViewBuilder
    func tetherCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(RoundedRectangle(cornerRadius: cornerRadius).fill(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.separator))
        }
    }

    /// The main action of an empty or error state: prominent glass on macOS 26+, bordered prominent on 15.
    @ViewBuilder
    func tetherProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Separates toolbar groups on macOS 26+ (each group gets its own glass capsule); nothing on 15.
struct TetherToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
    }
}
