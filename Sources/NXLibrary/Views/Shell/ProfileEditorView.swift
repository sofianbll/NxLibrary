import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import NXLibraryCore
import ArcanePorting

struct ProfileEditorView: View {
    enum Step: Int, CaseIterable { case name, avatar, theme, background }
    @State var profile: LocalProfile
    let games: [PortedGame]
    let isNew: Bool
    let onCancel: () -> Void
    let onSave: (LocalProfile) -> Bool
    @State var step: Step = .name
    @State private var indexes = [10, 0, 0, 0]
    @State private var error: String?
    @State private var shift = false
    @State private var customBackground: URL?
    @State private var savedBackgroundID: String?
    @FocusState private var nameFocused: Bool
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion

    private let keys = "1234567890QWERTYUIOPASDFGHJKL'ZXCVBNM-.".map(String.init) + ["Shift", "Space", "Erase", "Done"]
    private let keyRows = [0..<10, 10..<20, 20..<30, 30..<39, 39..<43]
    private var palettes: [SelenePalette] { theme.palettes.isEmpty ? [theme.palette] : theme.palettes }
    private var wallpapers: [String?] { theme.wallpaperChoices }
    private var customBackgroundSelected: Bool { step == .background && index == wallpapers.count }
    private var index: Int { indexes[step.rawValue] }
    private var columns: Int { [10, 10, 5, 3][step.rawValue] }
    private var itemCount: Int { [keys.count, ProfilePortrait.symbols.count + 1, palettes.count, wallpapers.count + 1][step.rawValue] }

    var body: some View {
        ZStack(alignment: .top) {
            SeleneTheme.scrim.opacity(0.45).ignoresSafeArea()
            VStack(spacing: canvas.u(10)) {
                Text(L10n.text(title)).seleneFont(44).accessibilityAddTraits(.isHeader)
                Text(L10n.text(subtitle)).seleneFont(21).foregroundStyle(SeleneTheme.ink75)
            }
            .multilineTextAlignment(.center)
            .padding(.top, canvas.u(110))
            Group {
                switch step {
                case .name: nameStep
                case .avatar: avatarStep
                case .theme, .background: lookStep
                }
            }
            .padding(.top, canvas.u(step == .name ? 300 : 285))
            if let error {
                Text(L10n.text(error)).seleneFont(18)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, canvas.u(154))
            }
            HStack(spacing: canvas.u(10)) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle().fill(SeleneTheme.ink.opacity(dot == step ? 1 : 0.3))
                        .frame(width: canvas.u(8), height: canvas.u(8))
                }
            }
            .accessibilityHidden(true)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, canvas.u(124))
            SeleneHintsBar(left: [HintItem(.b, "Back", action: back), HintItem(nil, "Cancel", glyph: .close, action: onCancel)],
                           right: [HintItem(.a, customBackgroundSelected && customBackground == nil ? "Add a picture"
                            : step == .background ? (isNew ? "Create profile" : "Save") : "Next", action: advance)])
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .foregroundStyle(SeleneTheme.ink)
        .onAppear {
            indexes[Step.avatar.rawValue] = profile.portrait == nil ? profile.avatar : ProfilePortrait.symbols.count
            indexes[Step.theme.rawValue] = palettes.firstIndex { $0.id == profile.look.theme } ?? 0
            indexes[Step.background.rawValue] = wallpapers.firstIndex(of: profile.look.wallpaper) ?? 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxProfileInput)) { note in
            if let action = note.object as? GamepadAction { handle(action) }
        }
    }

    private var title: String {
        switch step {
        case .name: "What should we call you?"
        case .avatar: "Choose your avatar"
        case .theme: "Choose your theme"
        case .background: "Choose your background"
        }
    }

    private var subtitle: String {
        switch step {
        case .name: "This is the name on your profile. Type, or use the keys below."
        case .avatar: "Pick one, or use your own picture."
        case .theme: "Colors for all of Arcane. Move through them to see each one in the preview."
        case .background: "Choose the picture behind your library."
        }
    }

    private var nameStep: some View {
        VStack(spacing: canvas.u(40)) {
            TextField(L10n.text("Name"), text: $profile.name)
                .textFieldStyle(.plain)
                .seleneFont(26)
                .padding(.horizontal, canvas.u(28))
                .frame(width: canvas.u(560), height: canvas.u(68))
                .background(Capsule().fill(SeleneTheme.ink.opacity(0.10)))
                .overlay(Capsule().strokeBorder(SeleneTheme.focus, lineWidth: canvas.u(2)))
                .focused($nameFocused)
                .onSubmit(advance)
            VStack(spacing: canvas.u(9)) {
                ForEach(keyRows, id: \.lowerBound) { row in
                    HStack(spacing: canvas.u(9)) {
                        ForEach(row, id: \.self) { item in
                            button(item, label: L10n.text(keys[item]), action: { selectKey(item) }) {
                                keyFace(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func keyWidth(_ item: Int) -> CGFloat { item < 39 ? 70 : item == 40 ? 308 : 147 }

    private func keyFace(_ item: Int) -> some View {
        let key = keys[item]
        return Group {
            if key == "Erase" { Image(systemName: "delete.left") }
            else if key == "Shift" { Image(systemName: shift ? "shift.fill" : "shift") }
            else { Text(L10n.text(key)) }
        }
        .seleneFont(item < 39 ? 24 : 19)
        .frame(width: canvas.u(keyWidth(item)), height: canvas.u(64))
        .background(RoundedRectangle(cornerRadius: canvas.u(16)).fill(SeleneTheme.glass))
        .overlay(RoundedRectangle(cornerRadius: canvas.u(16)).strokeBorder(SeleneTheme.ink15, lineWidth: canvas.u(1)))
        .overlay(alignment: .topTrailing) {
            if item > 39 {
                SelenePromptBadge(button: item == 40 ? .y : item == 41 ? .x : .menu, height: 22,
                                  keyboardOverride: item == 42 ? .symbol("return") : nil)
                    .padding(canvas.u(5)).accessibilityHidden(true)
            }
        }
        .modifier(TileFocus(focused: index == item && !nameFocused, radius: 16, scale: 1.1))
    }

    private var avatarStep: some View {
        grid(count: itemCount, width: 118) { item in
            let custom = item == ProfilePortrait.symbols.count
            let face = LocalProfile(name: profile.name, avatar: item, portrait: custom ? profile.portrait : nil, look: profile.look)
            button(item, label: custom ? L10n.text("Add a picture") : L10n.format("Avatar %lld", [item + 1]),
                   action: { accept() }) {
                Group {
                    if custom && profile.portrait == nil {
                        Circle().fill(SeleneTheme.glass).overlay(MaterialIconView(.add, size: 44))
                            .frame(width: canvas.u(96), height: canvas.u(96))
                    } else {
                        ProfilePortrait(profile: face, size: 96)
                    }
                }
                .modifier(TileFocus(focused: index == item, radius: 48, scale: 1.1))
                .frame(height: canvas.u(118))
            }
        }
    }

    private var lookStep: some View {
        let palette = step == .theme ? palettes[index] : SelenePaletteCatalog.resolve(profile.look.theme, in: palettes)
        let wallpaper = step == .background && !customBackgroundSelected ? wallpapers[index] : profile.look.wallpaper
        let url = (customBackgroundSelected ? customBackground : nil)
            ?? WallpaperCatalog.resolve(wallpaper, themeID: palette.id, in: theme.wallpapers)?.url
        return HStack(alignment: .top, spacing: canvas.u(60)) {
            ScrollViewReader { scroll in
                ScrollView {
                    if step == .theme {
                        grid(count: palettes.count, width: 150) { item in
                            button(item, label: palettes[item].name, action: accept) {
                                ThemePaletteSwatch(palette: palettes[item], focused: index == item)
                            }
                            .id(item)
                        }
                    } else {
                        grid(count: wallpapers.count + 1, width: 220) { item in
                            let personal = item == wallpapers.count
                            let name = personal ? "Add a picture" : wallpaperName(wallpapers[item])
                            button(item, label: name, action: accept) {
                                ZStack(alignment: .bottomLeading) {
                                    Rectangle().fill(SeleneTheme.baseGradient(for: palette))
                                    if let url = personal ? customBackground
                                        : WallpaperCatalog.resolve(wallpapers[item], themeID: palette.id, in: theme.wallpapers)?.url {
                                        WallpaperThumb(url: url)
                                    } else if personal {
                                        MaterialIconView(.add, size: 32).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                    Text(L10n.text(name)).seleneFont(15).lineLimit(1)
                                        .padding(canvas.u(8)).background(SeleneTheme.glassSolid)
                                }
                                .frame(width: canvas.u(198), height: canvas.u(112))
                                .clipShape(RoundedRectangle(cornerRadius: canvas.u(12)))
                                .modifier(TileFocus(focused: index == item, radius: 12, scale: 1.05))
                                .padding(.vertical, canvas.u(9))
                            }
                            .id(item)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: canvas.u(step == .theme ? 770 : 680), height: canvas.u(530), alignment: .top)
                .onChange(of: index) { _, target in scroll.scrollTo(target) }
            }
            VStack(alignment: .leading, spacing: canvas.u(12)) {
                ThemePreview(palette: palette, wallpaperURL: url, games: games, width: step == .theme ? 780 : 820,
                             animated: !reduceMotion)
                Text(step == .theme ? palette.name : customBackgroundSelected
                     ? customBackground?.deletingPathExtension().lastPathComponent ?? L10n.text("Add a picture")
                     : L10n.text(wallpaperName(wallpaper)))
                    .seleneFont(21)
            }
        }
    }

    private func wallpaperName(_ id: String?) -> String {
        id == nil ? "Theme's own" : theme.wallpaperTitle(for: id)
    }

    private func grid<Cell: View>(count: Int, width: CGFloat, @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(canvas.u(width)), spacing: 0), count: columns), spacing: 0) {
            ForEach(0..<count, id: \.self, content: cell)
        }
        .padding(.vertical, canvas.u(8))
    }

    private func button<Cell: View>(_ item: Int, label: String, action: @escaping () -> Void,
                                    @ViewBuilder face: () -> Cell) -> some View {
        Button {
            indexes[step.rawValue] = item
            action()
        } label: { face() }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(index == item ? .isSelected : [])
    }

    private func handle(_ action: GamepadAction) {
        switch action {
        case .navigateLeft, .navigateRight, .navigateUp, .navigateDown:
            let next: Int
            if step == .name {
                guard let row = keyRows.firstIndex(where: { $0.contains(index) }) else { return }
                if action == .navigateUp || action == .navigateDown {
                    let target = row + (action == .navigateUp ? -1 : 1)
                    guard keyRows.indices.contains(target) else { return }
                    let x = keyCenter(index, in: keyRows[row])
                    next = keyRows[target].min { abs(keyCenter($0, in: keyRows[target]) - x)
                        < abs(keyCenter($1, in: keyRows[target]) - x) } ?? index
                } else {
                    next = index + (action == .navigateLeft ? -1 : 1)
                    guard keyRows[row].contains(next) else { return }
                }
            } else {
                let delta = action == .navigateLeft ? -1 : action == .navigateRight ? 1 : action == .navigateUp ? -columns : columns
                next = index + delta
            }
            guard (0..<itemCount).contains(next) else { return }
            nameFocused = false
            indexes[step.rawValue] = next
        case .confirm: accept()
        case .cancel: back()
        case .menu: advance()
        case .menuHold: onCancel()
        case .secondaryAction where step == .name: selectKey(keys.count - 2)
        case .contextAction where step == .name: selectKey(keys.count - 3)
        default: break
        }
    }

    private func keyCenter(_ item: Int, in row: Range<Int>) -> CGFloat {
        let total = row.reduce(CGFloat.zero) { $0 + keyWidth($1) + 9 }
        return row.prefix(while: { $0 < item }).reduce(-total / 2) { $0 + keyWidth($1) + 9 } + keyWidth(item) / 2
    }

    private func accept() {
        switch step {
        case .name: selectKey(index)
        case .avatar where index == ProfilePortrait.symbols.count:
            guard importAvatar() || profile.portrait != nil else { return }
            advance()
        default: advance()
        }
    }

    private func advance() {
        error = nil
        switch step {
        case .name:
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.name.isEmpty && profile.name.count <= 32 else { error = "Enter a name of 1 to 32 characters."; return }
            nameFocused = false
        case .avatar:
            if index < ProfilePortrait.symbols.count {
                profile.avatar = index
                profile.portrait = nil
            } else if profile.portrait == nil && !importAvatar() { return }
        case .theme:
            profile.look.theme = palettes[index].id
        case .background:
            if customBackgroundSelected {
                guard let customBackground else {
                    let picker = NSOpenPanel()
                    picker.allowedContentTypes = [.png, .jpeg, .heic, .webP]
                    if picker.runModal() == .OK { self.customBackground = picker.url }
                    return
                }
                do {
                    if savedBackgroundID == nil {
                        let oldIndex = index
                        savedBackgroundID = try theme.importWallpaper(from: customBackground)
                        if wallpapers.count != oldIndex { indexes[Step.background.rawValue] = wallpapers.count }
                    }
                    profile.look.wallpaper = savedBackgroundID
                } catch {
                    self.error = "Couldn't add the picture"
                    return
                }
            } else {
                profile.look.wallpaper = wallpapers[index]
            }
            if !onSave(profile) { error = "Profiles could not be saved." }
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    private func back() {
        error = nil
        if nameFocused { nameFocused = false; return }
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
        else { onCancel() }
    }

    private func selectKey(_ item: Int) {
        let key = keys[item]
        if key == "Done" { advance() }
        else if key == "Shift" { shift.toggle() }
        else if key == "Erase" { if !profile.name.isEmpty { profile.name.removeLast() } }
        else if profile.name.count < 32 { profile.name += key == "Space" ? " " : shift ? key : key.lowercased() }
    }

    private func importAvatar() -> Bool {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        guard picker.runModal() == .OK, let url = picker.url else { return false }
        // Decode a bounded thumbnail first, then center-crop a square for the circular portrait.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                         kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail),
              let data = Self.crop(image), data.count <= 512_000 else {
            error = "Couldn't add the picture"
            return false
        }
        profile.portrait = data
        return true
    }

    nonisolated static func crop(_ image: CGImage) -> Data? {
        let side = min(image.width, image.height)
        guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }
}
