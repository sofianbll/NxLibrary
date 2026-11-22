import AppKit
import SwiftUI
import NXLibraryCore

/// The shared modal frame. Only the backdrop accepts outside clicks. Content keeps its
/// own stable row IDs and existing keyboard/controller commands, including Back.
struct SeleneOverlay<Content: View>: View {
    let style: SeleneOverlayStyle
    var alignment: Alignment = .center
    var onOutside: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: alignment) {
            veil
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onOutside?() }
                .accessibilityHidden(true)
            content()
        }
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var veil: some View {
        let tint = SeleneTheme.scrim.opacity(style.veilOpacity)
        if style == .search {
            tint.background(.ultraThinMaterial)
        } else {
            tint
        }
    }
}

extension View {
    /// A covered layer cannot announce its controls, handle pointer input or draw a second help bar.
    func seleneOverlayOwnership(_ ownsInput: Bool) -> some View {
        allowsHitTesting(ownsInput)
            .accessibilityHidden(!ownsInput)
            .transformEnvironment(\.seleneHintsCovered) { $0 = $0 || !ownsInput }
    }
}

/// SwiftUI can emit a fresh hover when a surface redraws under a still pointer.
/// Do not let that event reclaim the focus after a keyboard or controller press.
struct SeleneHoverFocus {
    private var pointer = NSEvent.mouseLocation

    mutating func moved(_ hovering: Bool) -> Bool {
        let now = NSEvent.mouseLocation
        guard hovering, now != pointer else { return false }
        pointer = now
        return true
    }
}
