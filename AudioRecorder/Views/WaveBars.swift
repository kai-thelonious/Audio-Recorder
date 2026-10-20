import SwiftUI

/// The nine bars of the app icon. Shows the logo at rest and a live level meter while recording.
struct WaveBars: View {
    static let barCount = 9
    private static let profile: [CGFloat] = [140, 260, 420, 560, 380, 500, 300, 200, 120].map { $0 / 560 }
    /// White in dark mode, dark in light mode, so the bars stay visible on the window material.
    static let barColor = Color.primary

    /// nil shows the logo shape.
    var levels: [Float]?
    var height: CGFloat = 72

    var body: some View {
        HStack(spacing: height * 0.085) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(Self.barColor)
                    .frame(width: height * 0.1, height: barHeight(i))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let shape = Self.profile[i]
        guard let levels else { return height * shape }
        let level = CGFloat(levels[i])
        return height * (0.1 + 0.9 * level * (0.5 + 0.5 * shape))
    }
}
