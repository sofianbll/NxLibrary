import SwiftUI
import NXLibraryCore

/// Cloud work can start before it knows a total. Never show a fabricated percentage.
struct SeleneProgressBar: View {
    @Environment(\.seleneCanvas) private var canvas
    let progress: Double?
    var height: CGFloat = 4
    var color = SeleneTheme.focus

    var body: some View {
        Group {
            if let progress {
                AchievementProgressBar(fraction: progress, height: height, fill: color)
            } else {
                Capsule().fill(SeleneTheme.ink15)
                    .overlay { Capsule().fill(color).frame(width: canvas.u(28)) }
                    .frame(height: canvas.u(height))
            }
        }
        .accessibilityHidden(true)
    }
}
