import SwiftUI
import NXLibraryCore

/// A short status label; its dot is decorative, not the only status cue.
struct SeleneStatusDot: View {
    @Environment(\.seleneCanvas) private var canvas
    let text: String
    let color: Color
    var labelColor: Color = SeleneTheme.ink60
    var accessibilityTitle: String? = nil

    var body: some View {
        HStack(spacing: canvas.u(8)) {
            Circle().fill(color).frame(width: canvas.u(7), height: canvas.u(7)).accessibilityHidden(true)
            Text(text).seleneFont(15).foregroundColor(labelColor)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? text)
        .accessibilityValue(accessibilityTitle == nil ? "" : text)
    }
}
