import SwiftUI

extension View {
    /// Translucent window background where the OS supports it.
    @ViewBuilder func glassWindowBackground() -> some View {
        if #available(macOS 15, *) {
            self.containerBackground(.regularMaterial, for: .window)
        } else {
            self
        }
    }

    /// Liquid Glass on macOS 26+, a flat tinted circle before that.
    @ViewBuilder func recordButtonBackground(recording: Bool) -> some View {
        let tint = recording ? Color.red.opacity(0.85) : Color.red
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.background(Circle().fill(tint))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
