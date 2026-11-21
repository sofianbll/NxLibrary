import SwiftUI
import NXLibraryCore

/// Cloud work can start before it knows a total. Never show a fabricated percentage.
struct SeleneProgressBar: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    let progress: Double?
    var height: CGFloat = 4

    var body: some View {
        Group {
            if let progress {
                AchievementProgressBar(fraction: progress, height: height)
            } else if reduceMotion {
                Capsule().fill(SeleneTheme.ink15)
                    .overlay { Capsule().fill(SeleneTheme.focus).frame(width: canvas.u(28)) }
                    .frame(height: canvas.u(height))
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    .tint(SeleneTheme.focus)
            }
        }
        .accessibilityHidden(true)
    }
}
