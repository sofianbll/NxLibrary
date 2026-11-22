import AppKit
import SwiftUI
import NXLibraryCore

/// The shell applies the matching blur to its live backdrop, not to the foreground controls.
enum SeleneOverlayStyle: Equatable {
    case menu, deep, options, search, dialog, profileRemoval

    var backdropBlur: CGFloat {
        switch self {
        case .deep: SeleneTokens.Effect.deepBlurPoints
        case .options: SeleneTokens.Effect.panelBlurPoints
        default: 0
        }
    }

    var veil: Color {
        switch self {
        case .menu: SeleneTheme.scrim.opacity(SeleneTokens.Effect.menuVeil)
        case .deep: SeleneTheme.scrim65
        case .options, .dialog: SeleneTheme.scrim45
        case .search: SeleneTheme.scrim.opacity(SeleneTokens.Effect.searchVeil)
        case .profileRemoval: SeleneTheme.scrim.opacity(SeleneTokens.Effect.profileRemovalVeil)
        }
    }
}

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
        if style == .search {
            style.veil.background(.ultraThinMaterial)
        } else {
            style.veil
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
