import AppKit
import NXLibraryCore
import SwiftUI

/// Porting → Cloud library: a locally recognised connection is not a network check.
struct SettingsCloudLibrarySection: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    @ObservedObject var settings: AppSettingsStore
    @Binding var advanced: Bool
    let onEdit: () -> Void
    let onEditSources: () -> Void
    let onActions: ([SettingsRowAction]) -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    @Environment(\.seleneReduceMotion) private var reduceMotion
    @Environment(\.seleneFocusedRowID) private var focusedRowID
    @Environment(\.seleneFocusedButton) private var focusedButton
    @State private var tool: URL?
    @State private var version: String?
    @State private var remotes: [RcloneRemote]?
    @State private var issue: RcloneConfiguration.Failure?
    @State private var inspecting = true
    @State private var inspection = 0
    @State private var testTask: Task<Void, Never>?
    @State private var testPassed: Bool?

    private struct Inspection: Equatable {
        let chosen: URL?
        let changing: Bool
        let attempt: Int
    }

    private var selection: CloudLibraryPreference { model.preference }
    private var connection: CloudLibraryPreference.Connection { selection.connection(in: remotes) }
    private var connected: RcloneRemote? {
        if case .connected(let remote) = connection { return remote }
        return nil
    }
    private var editable: Bool { viewModel.canConfigureCloudLibrary && testTask == nil }
    private var canTest: Bool { editable && !inspecting && connected != nil }
    private var canImport: Bool { editable && model.archive != nil && model.importTask == nil && !viewModel.isScanningLibrary }
    private var focusedToolButton: Int? { focusedRowID == "rclone" ? focusedButton : nil }

    private var serviceStatus: String {
        switch connection {
        case .connected: return text("Connected")
        case .notConnected: return text("Not connected")
        case .unknown: return text(inspecting ? "Checking…" : "Connection status unavailable")
        }
    }

    private var toolSubtitle: String {
        if let tool {
            let path = (tool.path as NSString).abbreviatingWithTildeInPath
            return version.map { "\($0) · \(path)" } ?? path
        }
        return text(inspecting ? "Checking…" : "Install rclone from rclone.org or with Homebrew: brew install rclone.")
    }

    var body: some View {
        VStack(spacing: canvas.u(8)) {
            SettingsSubheading("Connection")
            if let remote = selection.remote {
                SeleneToggleRow("Enable cloud library", subtitle: "Cloud storage for ported apps and build caches, separate from saves.",
                                isOn: Binding(get: { selection.enabled }, set: setEnabled))
                    .disabled(!editable)

                let provider = connected.flatMap { $0.type == "drive" ? nil : $0.type } ?? text("Google Drive")
                SeleneRow("\(provider) · \(remote)", verbatimTitle: true) {
                    SeleneStatusDot(text: serviceStatus, color: connected == nil ? SeleneTheme.ink60 : SeleneTheme.statusOK)
                }

                // shortcut: the assistant starts at the account step until it accepts a folder entry point.
                SeleneButtonRow("Folder", subtitle: selection.storage, verbatimSubtitle: true, truncateSubtitleInMiddle: true,
                                buttonTitle: "Edit", action: onEdit)
                    .disabled(!editable)
                SeleneButtonRow("Game files folder", id: "cloudSourcesRoot", subtitle: selection.sourcesStorage,
                                verbatimSubtitle: true, truncateSubtitleInMiddle: true, buttonTitle: "Edit", action: onEditSources)
                    .disabled(!editable)
                SeleneButtonRow("Change Google credentials", buttonTitle: "Edit", action: onEdit)
                    .disabled(!editable)
                SeleneButtonRow("Import games from the cloud", id: "cloudLibraryImport",
                                subtitle: model.importTask == nil ? nil : "Checking…", buttonTitle: "Import", action: importGames)
                    .disabled(!canImport)
            } else {
                SeleneButtonRow("Configure cloud library", buttonTitle: "Open", action: onEdit)
                    .disabled(!editable)
            }

            SettingsSubheading("Appearance")
            SeleneToggleRow("Icon next to Play", isOn: $settings.settings.showsCloudPlayIcon)
            SeleneToggleRow("Link in Details", isOn: $settings.settings.showsCloudDetailsLink)
            SeleneCycleRow("Tile badges", value: settings.settings.cloudTileBadges.titleKey, cycle: stepBadges)

            SettingsSubheading("Advanced")
            SeleneButtonRow("Connection tools", buttonTitle: advanced ? "Hide" : "Show", action: toggleAdvanced)
                .accessibilityValue(text(advanced ? "Expanded" : "Collapsed"))
            if advanced { advancedRows }
        }
        .task(id: Inspection(chosen: model.chosenExecutable, changing: model.isChangingConnection, attempt: inspection)) {
            if !model.isChangingConnection { await inspect() }
        }
        .onAppear(perform: publishActions)
        .onChange(of: [editable, canTest, canImport, model.chosenExecutable != nil, inspecting, selection.remote != nil, advanced]) {
            publishActions()
        }
        .onChange(of: selection) { testPassed = nil }
        .onDisappear { testTask?.cancel() }
    }

    private var advancedRows: some View {
        Group {
            SeleneRow("rclone", subtitle: toolSubtitle, verbatimSubtitle: true) {
                SelenePillButton(title: "Choose…", minWidth: 96, height: 34, horizontalPadding: 14,
                                 focused: focusedToolButton == 0, enabled: editable, action: chooseTool)
                if model.chosenExecutable != nil {
                    SelenePillButton(title: "Automatic", minWidth: 96, height: 34, horizontalPadding: 14,
                                     focused: focusedToolButton == 1, enabled: editable, action: useAutomaticTool)
                }
                SelenePillButton(title: "Refresh", minWidth: 96, height: 34, horizontalPadding: 14,
                                 focused: focusedToolButton == (model.chosenExecutable == nil ? 1 : 2),
                                 enabled: editable && !inspecting, action: refresh)
            }

            if let issue {
                Text(text(issue.key)).seleneFont(15).foregroundColor(SeleneTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if selection.remote != nil {
                SeleneButtonRow("Test connection", subtitle: testSubtitle, buttonTitle: "Test", action: test)
                    .disabled(!canTest)
                SeleneButtonRow("Disconnect", subtitle: "Removes only the local connection. Cloud files stay where they are.",
                                buttonTitle: "Disconnect", action: confirmDisconnect)
                    .disabled(!canTest)
            }
        }
    }

    private var testSubtitle: String {
        if testTask != nil { return "Checking…" }
        if let testPassed { return testPassed ? "Connection OK" : RcloneConfiguration.Failure.test.key }
        return "Lists the cloud folder without changing its files."
    }

    private func toggleAdvanced() {
        withAnimation(reduceMotion ? nil : SeleneTheme.quick) { advanced.toggle() }
    }

    private func stepBadges(_ step: Int) {
        settings.settings.cloudTileBadges = settings.settings.cloudTileBadges.stepped(step)
    }

    private func publishActions() {
        var actions: [SettingsRowAction]
        if selection.remote != nil {
            actions = [
                .init(id: "cloudLibraryEnabled", title: "Enable cloud library", isEnabled: editable) { setEnabled(!selection.enabled) },
                .init(id: "cloudLibraryFolder", title: "Folder", isEnabled: editable, activate: onEdit),
                .init(id: "cloudSourcesRoot", title: "Game files folder", rowID: "cloudSourcesRoot",
                      isEnabled: editable, activate: onEditSources),
                .init(id: "cloudLibraryConnect", title: "Change Google credentials", isEnabled: editable, activate: onEdit),
                .init(id: "cloudLibraryImport", title: "Import games from the cloud", isEnabled: canImport, activate: importGames),
            ]
        } else {
            actions = [.init(id: "cloudLibrarySetup", title: "Configure cloud library", isEnabled: editable, activate: onEdit)]
        }
        actions += [
            .init(id: "showsCloudPlayIcon", title: "Icon next to Play") { settings.settings.showsCloudPlayIcon.toggle() },
            .init(id: "showsCloudDetailsLink", title: "Link in Details") { settings.settings.showsCloudDetailsLink.toggle() },
            .value("cloudTileBadges", "Tile badges", cycle: stepBadges),
            .init(id: "cloudLibraryAdvanced", title: "Connection tools", activate: toggleAdvanced),
        ]
        if advanced {
            let automatic = model.chosenExecutable != nil
            actions.append(.init(id: "cloudLibraryTool", title: "rclone", isEnabled: editable,
                                 secondary: automatic ? ("Automatic", useAutomaticTool) : ("Refresh", refresh),
                                 additionalButtons: automatic ? [refresh] : [], activate: chooseTool))
            if selection.remote != nil {
                actions.append(.init(id: "cloudLibraryTest", title: "Test connection", isEnabled: canTest, activate: test))
                actions.append(.init(id: "cloudLibraryDisconnect", title: "Disconnect", isEnabled: canTest, activate: confirmDisconnect))
            }
        }
        onActions(actions)
    }

    private func setEnabled(_ enabled: Bool) {
        guard editable else { return }
        model.configure(remote: selection.remote, root: selection.root, enabled: enabled, sourcesRoot: selection.sourcesRootOverride)
    }

    private func importGames() {
        guard canImport else { return }
        viewModel.importCloudGames(manually: true)
    }

    private func chooseTool() {
        guard editable else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = tool?.deletingLastPathComponent()
        panel.message = text("Choose the rclone executable or use the detected one.")
        guard panel.runModal() == .OK, let chosen = panel.url, editable else { return }
        guard RcloneStorageBackend.isExecutable(chosen) else { issue = .tool; return }
        model.chooseExecutable(chosen)
    }

    private func useAutomaticTool() {
        guard editable else { return }
        model.chooseExecutable(nil)
    }

    private func refresh() {
        guard editable, !inspecting else { return }
        inspection += 1
    }

    private func inspect() async {
        inspecting = true
        version = nil; remotes = nil; issue = nil; testPassed = nil
        defer { if !Task.isCancelled { inspecting = false } }
        do {
            let chosen = model.chosenExecutable
            let found = await Task.detached(priority: .utility) { RcloneStorageBackend.findExecutable(preferred: chosen) }.value
            try Task.checkCancellation()
            tool = found
            guard let found else { return }
            let config = RcloneConfiguration(executable: found)
            let detectedVersion = try await config.version()
            try Task.checkCancellation()
            version = detectedVersion
            let listed = try await config.remotes()
            try Task.checkCancellation()
            remotes = listed
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { issue = (error as? RcloneConfiguration.Failure) ?? .configuration }
        }
    }

    private func test() {
        guard canTest, let tool else { return }
        let preference = selection
        testPassed = nil
        testTask = Task { @MainActor in
            defer { testTask = nil }
            do {
                try await RcloneConfiguration(executable: tool).test(preference)
                if !Task.isCancelled { testPassed = true }
            } catch {
                if !Task.isCancelled { testPassed = false }
            }
        }
    }

    private func confirmDisconnect() {
        guard canTest, let tool, let name = connected?.name else { return }
        viewModel.showSettingsNotice(title: text("Disconnect cloud service?"),
            message: "\(name)\n\n\(text("Removes only the local connection. Cloud files stay where they are."))",
            actionTitle: "Disconnect", cancelTitle: "Cancel") {
                guard canTest, model.preference.remote == name else { return }
                model.isChangingConnection = true
                Task { @MainActor in
                    defer { model.isChangingConnection = false }
                    do {
                        try await RcloneConfiguration(executable: tool).disconnect(name)
                        model.configure(remote: nil, root: selection.root, enabled: false, sourcesRoot: selection.sourcesRootOverride)
                    } catch {
                        viewModel.showSettingsNotice(title: text("Disconnect"),
                                                     message: text(RcloneConfiguration.Failure.disconnect.key))
                    }
                }
            }
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}

struct CloudSourcesFolderDialog: View {
    @State var draft: String
    let onSave: (String) -> Void
    let onClose: () -> Void
    @State private var focus: SeleneConfirmButton = .confirm
    @FocusState private var fieldFocused: Bool
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    private var path: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { CloudLibraryPreference.validSourcesRoot(path) }

    var body: some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: onClose)
            SeleneConfirmDialog(title: text("Game files folder"),
                                message: text("Choose a path on the same cloud service. No files are moved."),
                                confirmTitle: "Save", confirmEnabled: valid, focus: $focus,
                                onCancel: onClose, onConfirm: save) {
                TextField(text("Game files folder"), text: $draft, prompt: Text(verbatim: "Games/GameFiles"))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .onExitCommand(perform: onClose)
                    .seleneFont(17)
                    .foregroundColor(SeleneTheme.ink)
                    .padding(canvas.u(16))
                    .background(RoundedRectangle(cornerRadius: canvas.u(12)).fill(SeleneTheme.glassLight))
                    .padding(.top, canvas.u(24))
                if !valid {
                    Text(text("Enter a folder path such as Games or Archive/Games."))
                        .foregroundColor(SeleneTheme.danger)
                        .seleneFont(15)
                }
            }
        }
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .nxSettingsGamepadAction)) { note in
            guard let action = note.object as? GamepadAction else { return }
            switch action {
            case .navigateLeft: focus = .cancel
            case .navigateRight: focus = .confirm
            case .confirm: focus == .confirm ? save() : onClose()
            case .cancel: onClose()
            default: break
            }
        }
    }

    private func save() {
        guard valid else { return }
        onSave(path)
        onClose()
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}
