import AppKit
import SwiftUI
import NXLibraryCore
import ArcanePorting

struct ProfilePortrait: View {
    let profile: LocalProfile
    let size: CGFloat
    var ring = false
    @Environment(\.seleneCanvas) private var canvas
    @ObservedObject private var theme = ThemeStore.shared
    static let symbols = ["person.fill", "moon.stars.fill", "hare.fill", "cat.fill", "tortoise.fill",
                          "bird.fill", "leaf.fill", "bolt.fill", "flame.fill", "drop.fill",
                          "snowflake", "sparkle", "fish.fill", "pawprint.fill", "sun.max.fill",
                          "mountain.2.fill", "cloud.fill", "heart.fill", "star.fill", "gamecontroller.fill"]
    private static let colors: [UInt32] = [0x254A71, 0x373C75, 0x6D355D, 0x713F38, 0x255B4C,
                                           0x315772, 0x48612D, 0x745A25, 0x8D4831, 0x2E5771]

    var accent: Color { Color(hex: SelenePaletteCatalog.resolve(profile.look.theme, in: theme.palettes).glyph) }

    var body: some View {
        let index = max(0, min(profile.avatar, Self.symbols.count - 1))
        let tint = Color(hex: Self.colors[index % Self.colors.count])
        ZStack {
            Circle().fill(tint.gradient)
            if let data = profile.portrait, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: Self.symbols[index])
                    .font(.system(size: canvas.u(size * 0.43), weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: canvas.u(size), height: canvas.u(size))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring ? accent : .white.opacity(0.14), lineWidth: canvas.u(ring ? 2 : 1)))
        .accessibilityHidden(true)
    }
}

struct ProfilePickerView: View {
    @ObservedObject var profiles: LocalProfileStore
    let initialSelection: UUID?
    let initialEdit: Bool
    let canClose: Bool
    let games: [PortedGame]
    let onChoose: (UUID) -> Void
    let onClose: () -> Void
    let onActiveEdited: () -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @ObservedObject private var theme = ThemeStore.shared
    @State var selected: UUID?
    @State var draft: LocalProfile?
    @State var removing: LocalProfile?
    @State var removalFocus: SeleneConfirmButton = .cancel
    @State private var appeared = false
    private var selection: UUID? { appeared ? selected : initialSelection }

    var body: some View {
        ZStack {
            SeleneBackdrop().still(true).environment(\.seleneSharesBackdrop, false)
            selector.accessibilityHidden(draft != nil || removing != nil)
                .allowsHitTesting(draft == nil && removing == nil)
            if let draft {
                ProfileEditorView(profile: draft, games: games,
                                  isNew: !profiles.profiles.contains { $0.id == draft.id },
                                  onCancel: editorClosed, onSave: save)
            }
            if let removing {
                SeleneTheme.scrim.opacity(0.72).ignoresSafeArea()
                SeleneConfirmDialog(title: L10n.format("Remove %@?", [removing.name]),
                                    message: L10n.text("This profile will lose its favorites and play time."),
                                    confirmTitle: L10n.text("Remove"), cancelTitle: L10n.text("Keep"),
                                    warningIcon: true, focus: $removalFocus,
                                    onCancel: { self.removing = nil }, onConfirm: remove)
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            selected = initialSelection
            if initialEdit { edit() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxProfileInput)) { note in
            guard draft == nil, let action = note.object as? GamepadAction else { return }
            handle(action)
        }
    }

    private var selector: some View {
        GeometryReader { geometry in
            VStack(spacing: canvas.u(60)) {
                Text(L10n.text("Who's playing?")).seleneFont(44).accessibilityAddTraits(.isHeader)
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: canvas.u(56)) {
                            ForEach(profiles.profiles) { profile in
                                tile(profile)
                            }
                            tile(nil).id("add")
                        }
                        .padding(canvas.u(18))
                        .frame(minWidth: geometry.size.width, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selected) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                        else { scroll.scrollTo("add", anchor: .center) }
                    }
                }
                if profiles.failed { Text(L10n.text("Profiles could not be saved.")).seleneFont(19) }
            }
            .foregroundStyle(SeleneTheme.ink)
            .padding(.top, geometry.size.height * 0.28)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            SeleneHintsBar(left: leftHints, right: [HintItem(.a, "Select", action: accept)])
        }
    }

    private var leftHints: [HintItem] {
        (canClose ? [HintItem(.b, "Back", action: onClose)] : [])
        + [HintItem(.menu, "Add", keyboard: .text("+"), action: add)]
        + (selection != nil ? [HintItem(.y, "Edit profile", action: edit)] : [])
        + (selection != nil && profiles.profiles.count > 1 ? [HintItem(.x, "Remove", action: askRemoval)] : [])
    }

    private func tile(_ profile: LocalProfile?) -> some View {
        let isFocused = selection == profile?.id
        let title = profile?.name ?? L10n.text("Add")
        let accent = profile.map { Color(hex: SelenePaletteCatalog.resolve($0.look.theme, in: theme.palettes).glyph) } ?? SeleneTheme.focus
        return Button {
            selected = profile?.id
            accept()
        } label: {
            VStack(spacing: canvas.u(26)) {
                Group {
                    if let profile {
                        ProfilePortrait(profile: profile, size: 170)
                    } else {
                        Circle().fill(SeleneTheme.glassLight)
                            .overlay(Circle().strokeBorder(SeleneTheme.ink15, lineWidth: canvas.u(1)))
                            .overlay { Image(systemName: "plus").font(.system(size: canvas.u(65), weight: .ultraLight))
                                .foregroundStyle(isFocused ? SeleneTheme.ink : SeleneTheme.ink25) }
                            .frame(width: canvas.u(170), height: canvas.u(170))
                    }
                }
                .overlay {
                    if isFocused {
                        Circle().strokeBorder(accent, lineWidth: canvas.u(3)).padding(-canvas.u(9))
                            .shadow(color: accent.opacity(0.8), radius: canvas.u(11))
                    }
                }
                .scaleEffect(isFocused && !reduceMotion ? 1.1 : 1)
                Text(title).seleneFont(24).lineLimit(1)
                    .foregroundStyle(isFocused ? SeleneTheme.ink : SeleneTheme.ink60)
                    .frame(width: canvas.u(170))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .animation(reduceMotion ? nil : SeleneTheme.focusIn, value: isFocused)
    }

    private func handle(_ action: GamepadAction) {
        if removing != nil {
            switch action {
            case .navigateLeft: removalFocus = .cancel
            case .navigateRight: removalFocus = .confirm
            case .confirm: if removalFocus == .confirm { remove() } else { removing = nil }
            case .cancel: removing = nil
            default: break
            }
            return
        }
        let ids = profiles.profiles.map { Optional($0.id) } + [nil]
        switch action {
        case .navigateLeft, .navigateRight:
            let current = ids.firstIndex(of: selected) ?? 0
            selected = ids[max(0, min(ids.count - 1, current + (action == .navigateLeft ? -1 : 1)))]
        case .confirm: accept()
        case .menu: add()
        case .contextAction: edit()
        case .secondaryAction: askRemoval()
        case .cancel: if canClose { onClose() }
        default: break
        }
    }

    private func accept() {
        if let selected { onChoose(selected) }
        else { add() }
    }

    private func add() { draft = LocalProfile(name: "", look: .init(AppSettings())) }

    private func edit() { draft = profiles.profiles.first { $0.id == selected } }

    private func editorClosed() {
        draft = nil
        if initialEdit { onClose() }
    }

    private func save(_ profile: LocalProfile) -> Bool {
        guard profiles.update(profile) else { return false }
        selected = profile.id
        if profiles.active?.id == profile.id { onActiveEdited() }
        editorClosed()
        return true
    }

    private func askRemoval() {
        guard profiles.profiles.count > 1 else { return }
        removalFocus = .cancel
        removing = profiles.profiles.first { $0.id == selected }
    }

    private func remove() {
        guard let removing, let index = profiles.profiles.firstIndex(where: { $0.id == removing.id }),
              profiles.remove(removing.id) else { return }
        selected = profiles.profiles[min(index, profiles.profiles.count - 1)].id
        self.removing = nil
        onActiveEdited()
    }
}
