import SwiftUI
import AppKit
import NXLibraryCore
import ArcanePorting

/// Game options → Mods: RomFS applies on Play; ExeFS applies on Rebuild. Both use the same ordered list.
///
/// Input: Up/Down move, A (Return, Space) switches a mod or activates an action, Left/Right move the focused mod up or
/// down, Y (Delete, or a click on the Remove hint) moves it to the Trash after a confirmation, B (or Esc) returns. A
/// click activates a row.
struct ModsPanel: View {
    @ObservedObject var viewModel: AppViewModel
    let game: PortedGame
    let settings: GameSettingsSnapshot?
    let onRebuild: () -> Void
    let onClose: () -> Void

    @State private var mods: [LocalMod] = []
    @State private var conflicts: [ModConflict] = []
    @State private var conflictRefresh: Task<Void, Never>?
    @State private var needsRebuild = false
    @State private var importing = false
    @State private var running: Bool
    @State private var focus = 0
    @State private var confirmRemove: String?
    @State private var confirmFocus: SeleneConfirmButton = .cancel
    /// The last refusal or failed write, one sentence; cleared by the next action.
    @State private var message: String?
    @State private var keyMonitor: Any?

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @Environment(\.nxAppLocale) private var locale

    enum Row: Hashable {
        case mod(String)
        case importCode
        case openFolder
        case rebuild
    }

    init(viewModel: AppViewModel, game: PortedGame, settings: GameSettingsSnapshot?,
         onRebuild: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.game = game
        self.settings = settings
        self.onRebuild = onRebuild
        self.onClose = onClose
        _running = State(initialValue: RunningGameMonitor.runningApplication(for: game) != nil)
    }

    private var store: ModStore? { viewModel.modStore(for: game) }

    private var rows: [Row] { mods.map { .mod($0.folderName) } + [.importCode, .openFolder] + (needsRebuild ? [.rebuild] : []) }

    private var inactiveOnlineCodeMods: Set<String> {
        guard let settings, let network = NextendoLaunch.networkSetting(in: settings.settings),
              network.accepts("nextendo"), (settings.value(network.env) ?? network.defaultValue) == "nextendo"
        else { return [] }
        return Set(mods.filter { $0.isOn && $0.exefs != nil }.map(\.folderName))
    }

    private var focusedMod: LocalMod? {
        guard rows.indices.contains(focus), case .mod(let name) = rows[focus] else { return nil }
        return mods.first { $0.folderName == name }
    }

    // MARK: - Body

    var body: some View {
        let rows = self.rows
        let inactiveOnline = inactiveOnlineCodeMods
        return ZStack {
            SeleneTheme.scrim65
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text("MODS"))
                        .seleneFont(15, .semibold)
                        .foregroundColor(SeleneTheme.ink60)
                        .padding(.leading, canvas.u(8))
                    Text(game.name)
                        .seleneFont(40)
                        .foregroundColor(SeleneTheme.ink)
                        .lineLimit(1)
                        .padding(.leading, canvas.u(6))
                    Text(ModsCopy.header(on: mods.filter(\.isOn).count, total: mods.count))
                        .seleneFont(15)
                        .foregroundColor(SeleneTheme.ink60)
                        .padding(.leading, canvas.u(8))
                        .padding(.bottom, canvas.u(14))
                    noticeArea(hasInactiveOnlineMods: !inactiveOnline.isEmpty)
                    list(rows, inactiveOnline: inactiveOnline)
                }
                .frame(width: canvas.u(1040), alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, canvas.u(90))
                .padding(.bottom, canvas.u(20))
                .contentShape(Rectangle())

                SeleneHintsBar(left: [HintItem(.b, L10n.text("Back"), action: close)], right: hints,
                               bottom: SeleneBottomScrim.hintsBottom, leftInset: 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let name = confirmRemove {
                confirmOverlay(name)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : SeleneTheme.quick, value: confirmRemove)
        .onAppear {
            sync()
            installKeyMonitor()
        }
        .onDisappear {
            conflictRefresh?.cancel()
            removeKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxGameOptionsGamepadAction)) { note in
            guard let action = note.object as? GamepadAction else { return }
            handleGamepad(action)
        }
        // A mod added or removed in Finder, or the game quitting, shows when Arcane comes back.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in sync() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sync() }
    }

    private var hints: [HintItem] {
        guard let mod = focusedMod else { return [HintItem(.a, L10n.text("Select"))] }
        var items = [HintItem(nil, L10n.text("◂ ▸  Move")), HintItem(.y, L10n.text("Remove"), action: askRemove)]
        items.append(HintItem(.a, !mod.isMod ? L10n.text("Select") : mod.isOn ? L10n.text("Turn off") : L10n.text("Turn on")))
        return items
    }

    @ViewBuilder private func noticeArea(hasInactiveOnlineMods: Bool) -> some View {
        let notices = (hasInactiveOnlineMods ? [L10n.text("Nextendo online mode: Code mods don't load. Set Network to Offline to use them.", context: locale)] : [])
            + (running ? [ModsCopy.running(gameName: game.name)] : [])
            + (needsRebuild ? [L10n.text("Rebuild to apply code mod changes.", context: locale)] : [])
        if !notices.isEmpty || message != nil || !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: canvas.u(8)) {
                ForEach(notices, id: \.self) { notice in
                    Label { Text(notice).fixedSize(horizontal: false, vertical: true) } icon: { MaterialIconView(.info, size: 20) }
                        .seleneFont(16)
                        .foregroundColor(SeleneTheme.ink75)
                }
                ForEach(conflicts, id: \.message) { conflict in
                    Label { Text(conflict.message).fixedSize(horizontal: false, vertical: true) } icon: { MaterialIconView(.swap, size: 20) }
                        .seleneFont(16)
                        .foregroundColor(SeleneTheme.ink75)
                }
                if let message {
                    Text(message)
                        .seleneFont(16, .medium)
                        .foregroundColor(SeleneTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, canvas.u(10))
            .padding(.bottom, canvas.u(14))
        }
    }

    private func list(_ rows: [Row], inactiveOnline: Set<String>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: canvas.u(8)) {
                    if mods.isEmpty {
                        SeleneOptionRow(icon: nil, title: L10n.text("No mods yet"), about: ModsCopy.empty, focused: false, enabled: false) {}
                    }
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        rowView(row, focused: index == focus, inactiveOnline: inactiveOnline)
                            .id(row)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                focus = index
                                activate(row)
                            }
                    }
                    Text(ModsCopy.help)
                        .seleneFont(14)
                        .foregroundColor(SeleneTheme.ink60)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, canvas.u(10))
                        .padding(.top, canvas.u(10))
                    if mods.contains(where: { $0.exefs != nil }) {
                        Text(L10n.text("If code mods patch the main module, Nextendo mode takes priority and none of the code mods load."))
                            .seleneFont(14)
                            .foregroundColor(SeleneTheme.ink60)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, canvas.u(10))
                    }
                }
                .padding(.top, canvas.u(6))
                .padding(.bottom, canvas.u(24))
                .animation(reduceMotion ? nil : SeleneTheme.quick, value: mods)
            }
            .scrollIndicators(.hidden)
            .onChange(of: focus) { _, index in
                guard rows.indices.contains(index) else { return }
                withAnimation(reduceMotion ? nil : SeleneTheme.quick) { proxy.scrollTo(rows[index], anchor: .center) }
            }
        }
    }

    private func rowView(_ row: Row, focused: Bool, inactiveOnline: Set<String>) -> some View {
        let text = describe(row)
        let code: Bool
        let inactiveBadge: String?
        if case .mod(let name) = row {
            code = mods.first { $0.folderName == name }?.exefs != nil
            inactiveBadge = inactiveOnline.contains(name) ? L10n.text("Inactive online", context: locale) : nil
        } else {
            code = false
            inactiveBadge = nil
        }
        return SeleneOptionRow(icon: text.icon, title: text.title, about: text.about, focused: focused,
                               enabled: text.enabled) {
            if code { SeleneValueChip(text: L10n.text("Code", context: locale)) }
            if let inactiveBadge { SeleneValueChip(text: inactiveBadge) }
            if let isOn = text.isOn {
                SeleneSwitch(isOn: .constant(isOn)).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([text.title, code ? L10n.text("Code") : nil, inactiveBadge, text.about].compactMap { $0 }.joined(separator: ". "))
        .accessibilityValue(text.isOn.map { $0 ? L10n.text("On") : L10n.text("Off") } ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private func describe(_ row: Row) -> (icon: MaterialIcon?, title: String, about: String?, isOn: Bool?, enabled: Bool) {
        switch row {
        case .mod(let name):
            guard let mod = mods.first(where: { $0.folderName == name }) else { return (nil, name, nil, nil, false) }
            if !mod.isMod {
                let isFolder = (try? mod.folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return (.puzzle, name, isFolder ? ModsCopy.notAMod : ModsCopy.notAFolder, nil, false)
            }
            if name.contains(":") { return (.puzzle, name, ModsCopy.colon, nil, false) }
            return (.puzzle, name, nil, mod.isOn, !running && !importing)
        case .importCode:
            return (.folder, L10n.text("Import code mod"), L10n.text("Copy a folder with exefs patches. The original stays in place."), nil, !running && !importing)
        case .openFolder:
            return (.folder, L10n.text("Open mods folder"), L10n.text("Put each mod in its own folder here."), nil, true)
        case .rebuild:
            return (.build, L10n.text("Rebuild"), L10n.text("Build a new app; the old app stays if the build fails."), nil,
                    !running && !importing && GameResourceState.sourcesAvailable(for: game))
        }
    }

    private func confirmOverlay(_ name: String) -> some View {
        ZStack {
            SeleneTheme.scrim45
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissConfirm() }
            SeleneConfirmDialog(title: L10n.format("Move %@ to the Trash?", [String(describing: name)]),
                                message: L10n.text("The game stops loading it. You can put it back from the Trash."),
                                confirmTitle: L10n.text("Move to Trash"), focus: $confirmFocus,
                                onCancel: dismissConfirm, onConfirm: runRemove)
        }
    }

    // MARK: - Actions

    private func reload() {
        running = RunningGameMonitor.runningApplication(for: game) != nil
        let store = store
        mods = store?.mods() ?? []
        needsRebuild = store?.codeModsNeedRebuild(app: game.url, build: game.lastBuild) == true
        focus = min(focus, max(rows.count - 1, 0))
        conflictRefresh?.cancel()
        guard let store else { conflicts = []; return }
        let engineFolder = viewModel.setup.nxnativePath
        conflictRefresh = Task { @MainActor in
            let merges = await InstalledEngineCapabilities.shared.mergesTrpfd(
                in: game.url, engineFolder: engineFolder, gameData: store.supportFolder)
            guard !Task.isCancelled else { return }
            conflicts = store.conflicts(mergesTrpfd: merges)
        }
    }

    /// Re-reads the folder and lets the store drop mods that are gone (only while the game is not running).
    private func sync() {
        guard !importing else { return }
        if let store, let failure = viewModel.performModChange({ try store.sync() }) { message = failure }
        reload()
    }

    private func activate(_ row: Row) {
        message = nil
        switch row {
        case .mod(let name):
            guard let mod = mods.first(where: { $0.folderName == name }) else { return }
            change(click: true) { try $0.setOn(!mod.isOn, folderName: name) }
        case .importCode:
            importCodeMod()
        case .openFolder:
            guard let folder = store?.modsFolder else {
                SoundEffectService.shared.play(.error)
                return
            }
            SoundEffectService.shared.play(.click)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            viewModel.revealInFinder(url: folder)
        case .rebuild:
            guard !running, !importing, GameResourceState.sourcesAvailable(for: game) else {
                SoundEffectService.shared.play(.error)
                return
            }
            onRebuild()
        }
    }

    private func importCodeMod() {
        guard let store, store.isWritable, !importing else {
            SoundEffectService.shared.play(.error)
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Import code mod")
        panel.prompt = L10n.text("Add")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        importing = true
        Task { @MainActor in
            let outcome = Task.detached(priority: .userInitiated) { () -> String? in
                do { try store.importCodeMod(from: folder); return nil }
                catch let error as ModStoreError { return AppViewModel.modMessage(error) }
                catch { return ModInstallError.writeFailed(error.localizedDescription).message }
            }
            let error = await outcome.value
            importing = false
            message = error
            reload()
            if error == nil { SoundEffectService.shared.play(.success) }
            else { SoundEffectService.shared.play(.error) }
        }
    }

    private func moveFocusedMod(by offset: Int) {
        guard let mod = focusedMod else { return }
        message = nil
        let before = mods.map(\.folderName)
        guard change(click: false, { try $0.move(folderName: mod.folderName, by: offset) }) else { return }
        if mods.map(\.folderName) != before {
            focus = rows.firstIndex(of: .mod(mod.folderName)) ?? focus
            SoundEffectService.shared.play(.focus)
        }
    }

    private func askRemove() {
        guard let mod = focusedMod else { return }
        message = nil
        guard !running, !importing, RunningGameMonitor.runningApplication(for: game) == nil else {
            reload()
            SoundEffectService.shared.play(.error)
            return
        }
        confirmFocus = .cancel
        confirmRemove = mod.folderName
        SoundEffectService.shared.play(.click)
    }

    private func runRemove() {
        guard let name = confirmRemove else { return }
        confirmRemove = nil
        if change(click: false, { try $0.remove(folderName: name) }) { SoundEffectService.shared.play(.success) }
    }

    private func dismissConfirm() {
        confirmRemove = nil
        SoundEffectService.shared.play(.focus)
    }

    /// True when the change is on disk.
    @discardableResult
    private func change(click: Bool, _ edit: (ModStore) throws -> Void) -> Bool {
        guard let store, !importing else {
            SoundEffectService.shared.play(.error)
            return false
        }
        defer { reload() }
        if let failure = viewModel.performModChange({ try edit(store) }) {
            message = failure
            if failure == AppViewModel.modMessage(.notAllowed) { running = true }
            SoundEffectService.shared.play(.error)
            return false
        }
        if click { SoundEffectService.shared.play(.click) }
        return true
    }

    // MARK: - Input

    private func move(by delta: Int) {
        let next = min(max(focus + delta, 0), max(rows.count - 1, 0))
        guard next != focus else { return }
        focus = next
        SoundEffectService.shared.play(.focus)
    }

    private func close() {
        SoundEffectService.shared.play(.focus)
        onClose()
    }

    private func moveConfirmFocus(_ to: SeleneConfirmButton) {
        guard confirmFocus != to else { return }
        confirmFocus = to
        SoundEffectService.shared.play(.focus)
    }

    private func handleGamepad(_ action: GamepadAction) {
        if confirmRemove != nil {
            switch action {
            case .navigateLeft: moveConfirmFocus(.cancel)
            case .navigateRight: moveConfirmFocus(.confirm)
            case .confirm: confirmFocus == .confirm ? runRemove() : dismissConfirm()
            case .cancel, .secondaryAction, .menu: dismissConfirm()
            default: break
            }
            return
        }
        switch action {
        case .navigateUp: move(by: -1)
        case .navigateDown: move(by: 1)
        case .navigateLeft: moveFocusedMod(by: -1)
        case .navigateRight: moveFocusedMod(by: 1)
        case .confirm:
            let rows = self.rows
            if rows.indices.contains(focus) { activate(rows[focus]) }
        case .contextAction: askRemove()
        case .cancel, .secondaryAction, .menu: close()
        default: break
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard viewModel.gameForSettingsSheet?.id == game.id,
                  viewModel.gameWithInstallFailure == nil, viewModel.settingsNotice == nil,
                  let window = event.window, !window.isSheet, window.attachedSheet == nil,
                  NSApp.modalWindow == nil, !(window.firstResponder is NSText) else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let action: GamepadAction
            switch event.keyCode {
            case 126: action = .navigateUp
            case 125: action = .navigateDown
            case 123: action = .navigateLeft
            case 124: action = .navigateRight
            case 36, 76, 49: action = .confirm
            case 51, 117: action = .contextAction
            case 53: action = .cancel
            default: return event
            }
            handleGamepad(action)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The Mods panel's sentences.
enum ModsCopy {
    static func header(on: Int, total: Int) -> String {
        switch (on, total) {
        case (_, 0): return L10n.text("No mods in this game's folder")
        case (0, _): return total == 1 ? "1 mod, off" : L10n.format("%@ mods, all off", [String(describing: total)])
        default: return L10n.format("%@ of %@ on", [String(on), String(total)])
        }
    }

    static func running(gameName: String) -> String { L10n.format("%@ is running. Quit it to change its mods.", [String(describing: gameName)]) }

    static var empty: String {
        L10n.text("Open the mods folder to add RomFS mods, or import a code mod.")
    }
    static var notAMod: String {
        L10n.text("Not a mod: needs romfs or exefs patches.")
    }
    static var notAFolder: String {
        L10n.text("Not a mod: unzip it into its own folder first.")
    }
    static var colon: String {
        L10n.text("Rename this folder: its name can't contain ':'.")
    }
    static var help: String {
        L10n.text("RomFS changes apply at the next launch. Code mods apply after a rebuild.")
    }
}
