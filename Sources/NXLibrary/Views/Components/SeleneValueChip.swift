import SwiftUI
import NXLibraryCore

struct SeleneValueChip: View {
    @Environment(\.seleneCanvas) private var canvas
    let text: String
    var symbol: String? = nil

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).accessibilityLabel(text)
            } else {
                Text(text)
            }
        }
            .seleneFont(17, .semibold)
            .foregroundColor(SeleneTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, canvas.u(symbol == nil ? 16 : 9))
            .padding(.top, canvas.u(4))
            .padding(.bottom, canvas.u(5))
            .background(RoundedRectangle(cornerRadius: canvas.u(17), style: .continuous)
                .fill(symbol == nil ? SeleneTheme.ink.opacity(0.13) : SeleneTheme.glassSolid))
    }
}
