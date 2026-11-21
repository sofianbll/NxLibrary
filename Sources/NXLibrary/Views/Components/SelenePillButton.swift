import SwiftUI
import NXLibraryCore

/// Selene's pill: glass at rest, solid focus colour with glow when focused.
struct SelenePillButton: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @Environment(\.nxAppLocale) private var localization
    @State private var hovered = false

    let title: String?
    var titleArguments: [String] = []
    var icon: MaterialIcon? = nil
    var iconSize: CGFloat = 26
    var minWidth: CGFloat = 180
    var height: CGFloat = 60
    /// Selene's Padding="36,0"; the round Favorite pill uses 0.
    var horizontalPadding: CGFloat = 36
    let focused: Bool
    /// False draws the pill dim: it still takes focus (a ring), but never the solid focus fill.
    var enabled: Bool = true
    /// Three dots after the title rising and falling like a wave ("Porting…").
    var waveDots = false
    var tint: Color? = nil
    var queuedBuild = false
    var accessory: AnyView? = nil
    var keyboardFocus: FocusState<Bool>.Binding? = nil
    let action: () -> Void

    static func roundIcon(_ icon: MaterialIcon, focused: Bool = false, enabled: Bool = true,
                          action: @escaping () -> Void) -> Self {
        Self(title: nil, icon: icon, iconSize: 22, minWidth: 44, height: 44, horizontalPadding: 0,
             focused: focused, enabled: enabled, action: action)
    }

    static func buildQueue(minWidth: CGFloat = 180, focused: Bool, action: @escaping () -> Void) -> Self {
        Self(title: "Queued", icon: .schedule, iconSize: 20, minWidth: minWidth, height: 52, horizontalPadding: 18,
             focused: focused, tint: PortingPillCopy.softRed, queuedBuild: true, action: action)
    }

    var body: some View {
        if queuedBuild {
            pill.onHover { hovered = $0 }
                .accessibilityLabel(L10n.text("Cancel queued build", context: localization))
                .accessibilityValue(L10n.text("Queued", context: localization))
        } else if let keyboardFocus {
            pill.focusable(interactions: .activate)
                .focusEffectDisabled()
                .focused(keyboardFocus)
        } else {
            pill
        }
    }

    private var pill: some View {
        let cancelling = queuedBuild && (focused || hovered)
        let focused = self.focused || cancelling
        let tint = !queuedBuild || cancelling ? self.tint : nil
        let title = cancelling ? "Cancel" : self.title
        let icon = cancelling ? MaterialIcon.close : self.icon
        let solid = focused && enabled && tint == nil
        return Button(action: action) {
            HStack(spacing: canvas.u(10)) {
                accessory
                if let icon {
                    MaterialIconView(icon, size: iconSize)
                }
                if let title {
                    // A pill's title stays on one line: the pill grows instead.
                    ZStack {
                        if queuedBuild {
                            Text(L10n.text(cancelling ? "Queued" : "Cancel", context: localization))
                                .hidden().accessibilityHidden(true)
                        }
                        Text(titleArguments.isEmpty ? L10n.text(title, context: localization)
                             : L10n.format(title, titleArguments, context: localization))
                    }
                        .seleneFont(21)
                        .lineLimit(1)
                        .fixedSize()
                }
                if waveDots {
                    WaveDots()
                        .padding(.leading, canvas.u(-4))
                }
            }
            .foregroundColor(solid ? SeleneTheme.onFocus : (enabled ? tint ?? SeleneTheme.ink : SeleneTheme.ink60))
            .padding(.horizontal, canvas.u(horizontalPadding))
            .frame(minWidth: canvas.u(minWidth), minHeight: canvas.u(height), maxHeight: canvas.u(height))
            .background(Capsule().fill(solid ? SeleneTheme.focus : SeleneTheme.glass))
            .overlay(Capsule().strokeBorder(focused && !solid ? tint ?? SeleneTheme.focus : SeleneTheme.ink15,
                                            lineWidth: solid ? 0 : max(1, canvas.u(focused && !solid ? 2 : 1))))
            .shadow(color: solid ? SeleneTheme.focus.opacity(0.4) : .clear, radius: canvas.u(22))
            .scaleEffect(focused && !reduceMotion ? 1.06 : 1)
            // Focus eases across pills; the colour change is a fade, so it stays under reduce motion.
            .animation(SeleneTheme.cubicOut(0.26), value: focused)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Three small dots, each rising and falling a little after the one before, like
/// the crest of a wave. Still with Reduce motion.
struct WaveDots: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: canvas.u(4)) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0 : max(0, sin((time / 1.1) * 2 * .pi - Double(index) * 0.9))
                    Circle()
                        .frame(width: canvas.u(5), height: canvas.u(5))
                        .offset(y: canvas.u(-5) * wave)
                        .opacity(0.55 + 0.45 * wave)
                }
            }
            .frame(height: canvas.u(14), alignment: .bottom)
            .padding(.top, canvas.u(6))
        }
        .accessibilityHidden(true)
    }
}
