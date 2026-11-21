import AppKit
import NXLibraryCore
import SwiftUI

enum CloudLibraryEditor { case connect, folder }

/// Porting → Cloud library: state here is a snapshot of rclone, not a network check.
struct SettingsCloudLibrarySection: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    let onEdit: (CloudLibraryEditor) -> Void
    let onActions: ([SettingsRowAction]) -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
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
    private var canChoose: Bool { editable && !inspecting && remotes?.isEmpty == false }
    private var canConnect: Bool { editable && !inspecting && version != nil && remotes != nil }
    private var canTest: Bool { editable && !inspecting && connected != nil }
    private var canDisconnect: Bool { canTest }

    private var service: String {
        if let connected {
            return "\(connected.type == "drive" ? text("Google Drive") : connected.type) · \(connected.name)"
        }
        return selection.remote ?? text("None chosen yet.")
    }

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
            SeleneToggleRow("Enable cloud library", subtitle: "Cloud storage for ported apps and build caches, separate from saves.",
                            isOn: Binding(get: { selection.enabled }, set: setEnabled))
                .disabled(!editable)

            SeleneCycleRow("Cloud service", subtitle: serviceStatus, info: "Choose an existing rclone remote.",
                           value: service, verbatimValue: true, cycle: stepRemote)
                .disabled(!canChoose)

            SeleneButtonRow("Connect Google Drive", subtitle: "Sign in with your own Google OAuth client in your browser.",
                            buttonTitle: "Connect") { onEdit(.connect) }
                .disabled(!canConnect)

            SeleneButtonRow("Cloud folder", subtitle: selection.root, verbatimSubtitle: true,
                            buttonTitle: "Edit") { onEdit(.folder) }
                .disabled(!editable)

            SeleneButtonRow("Test connection", subtitle: testSubtitle, buttonTitle: "Test", action: test)
                .disabled(!canTest)

            SeleneRow("rclone", subtitle: toolSubtitle) {
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

            SeleneButtonRow("Disconnect", subtitle: "Removes only the local rclone connection. Cloud files stay where they are.",
                            buttonTitle: "Disconnect", action: confirmDisconnect)
                .disabled(!canDisconnect)
        }
        .task(id: Inspection(chosen: model.chosenExecutable, changing: model.isChangingConnection, attempt: inspection)) {
            if !model.isChangingConnection { await inspect() }
        }
        .onAppear(perform: publishActions)
        .onChange(of: [editable, canChoose, canConnect, canTest, model.chosenExecutable != nil, inspecting]) { publishActions() }
        .onChange(of: selection) { testPassed = nil }
        .onDisappear { testTask?.cancel() }
    }

    @Environment(\.seleneFocusedRowID) private var focusedRowID
    @Environment(\.seleneFocusedButton) private var focusedButton
    private var focusedToolButton: Int? { focusedRowID == "rclone" ? focusedButton : nil }

    private var testSubtitle: String {
        if testTask != nil { return "Checking…" }
        if let testPassed { return testPassed ? "Connection OK" : RcloneConfiguration.Failure.test.key }
        return "Lists the cloud folder without changing its files."
    }

    private func publishActions() {
        let reset: (title: String, activate: () -> Void)? = model.chosenExecutable == nil ? nil : ("Automatic", useAutomaticTool)
        let secondary = reset ?? ("Refresh", refresh)
        onActions([
            .init(id: "cloudLibraryEnabled", title: "Enable cloud library", isEnabled: editable) { setEnabled(!selection.enabled) },
            .init(id: "cloudLibraryService", title: "Cloud service", isEnabled: canChoose, cycle: stepRemote) { stepRemote(1) },
            .init(id: "cloudLibraryConnect", title: "Connect Google Drive", isEnabled: canConnect) { onEdit(.connect) },
            .init(id: "cloudLibraryFolder", title: "Cloud folder", isEnabled: editable) { onEdit(.folder) },
            .init(id: "cloudLibraryTest", title: "Test connection", isEnabled: canTest, activate: test),
            .init(id: "cloudLibraryTool", title: "rclone", isEnabled: editable,
                  secondary: secondary, additionalButtons: reset == nil ? [] : [refresh], activate: chooseTool),
            .init(id: "cloudLibraryDisconnect", title: "Disconnect", isEnabled: canDisconnect, activate: confirmDisconnect),
        ])
    }

    private func setEnabled(_ enabled: Bool) {
        guard editable else { return }
        model.configure(remote: selection.remote, root: selection.root, enabled: enabled)
    }

    private func stepRemote(_ delta: Int) {
        guard canChoose, let name = remotes?.map(\.name).stepped(from: selection.remote ?? "", delta) else { return }
        model.configure(remote: name, root: selection.root, enabled: selection.enabled)
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
            let found = await Task.detached(priority: .utility) { chosen ?? RcloneStorageBackend.findExecutable() }.value
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
        guard canDisconnect, let tool, let name = connected?.name else { return }
        viewModel.showSettingsNotice(title: text("Disconnect cloud service?"),
            message: "\(name)\n\n\(text("Removes only the local rclone connection. Cloud files stay where they are."))",
            actionTitle: "Disconnect", cancelTitle: "Cancel") {
                guard canDisconnect, model.preference.remote == name else { return }
                model.isChangingConnection = true
                Task { @MainActor in
                    defer { model.isChangingConnection = false }
                    do {
                        try await RcloneConfiguration(executable: tool).disconnect(name)
                        model.configure(remote: nil, root: selection.root, enabled: false)
                    } catch {
                        viewModel.showSettingsNotice(title: text("Disconnect"),
                                                     message: text(RcloneConfiguration.Failure.disconnect.key))
                    }
                }
            }
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}

struct CloudLibrarySettingsDialog: View {
    let editor: CloudLibraryEditor
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    let onClose: () -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    @State private var client = ""
    @State private var secret = ""
    @State private var folder = ""
    @State private var issue: RcloneConfiguration.Failure?
    @State private var task: Task<Void, Never>?
    @State private var cancelling = false
    @State private var focus: SeleneConfirmButton = .confirm
    private enum Field: Hashable { case client, secret, folder }
    @FocusState private var field: Field?

    private var normalizedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        editor == .connect ? RcloneConfiguration.validCredential(client) && RcloneConfiguration.validCredential(secret)
            : CloudLibraryPreference.validRoot(normalizedFolder)
    }

    var body: some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: cancel)
            SeleneConfirmDialog(title: editor == .connect ? "Connect Google Drive" : "Cloud folder",
                message: text(dialogMessage), confirmTitle: editor == .connect ? "Connect" : "Save",
                confirmEnabled: task == nil && valid && viewModel.canConfigureCloudLibrary,
                focus: $focus, onCancel: cancel, onConfirm: confirm) {
                    if task != nil {
                        ProgressView().tint(SeleneTheme.focus).padding(.top, canvas.u(24))
                    } else {
                        fields
                    }
                }
        }
        .onAppear {
            folder = model.preference.root
            field = editor == .connect ? .client : .folder
        }
        .onDisappear { task?.cancel(); secret = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            task?.cancel()
        }
        .onExitCommand(perform: cancel)
        .onReceive(NotificationCenter.default.publisher(for: .nxSettingsGamepadAction)) { note in
            guard let action = note.object as? GamepadAction else { return }
            switch action {
            case .navigateUp where editor == .connect && task == nil: field = .client
            case .navigateDown where editor == .connect && task == nil: field = .secret
            case .navigateLeft: focus = .cancel
            case .navigateRight where task == nil: focus = .confirm
            case .confirm where focus == .confirm: confirm()
            case .confirm, .cancel: cancel()
            default: break
            }
        }
    }

    private var dialogMessage: String {
        if cancelling { return "Cancelling connection…" }
        if task != nil { return "Waiting for Google sign-in in your browser…" }
        if editor == .connect { return "Use a Google OAuth client for a desktop app. rclone asks for full Google Drive access." }
        return "Folder for game apps and build caches."
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: canvas.u(12)) {
            if editor == .connect {
                Text(text("Google client ID")).foregroundColor(SeleneTheme.ink60)
                TextField(text("Google client ID"), text: $client).focused($field, equals: .client).onSubmit { field = .secret }
                Text(text("Google client secret")).foregroundColor(SeleneTheme.ink60)
                SecureField(text("Google client secret"), text: $secret).focused($field, equals: .secret).onSubmit(confirm)
                Button(text("Setup guide")) {
                    NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!)
                }
                .buttonStyle(.plain).foregroundColor(SeleneTheme.focus)
            } else {
                TextField(text("Cloud folder"), text: $folder).focused($field, equals: .folder).onSubmit(confirm)
                if !valid { Text(text("Enter a folder path such as Games or Archive/Games.")).foregroundColor(SeleneTheme.danger) }
            }
            if let issue {
                Text(text(issue.key)).foregroundColor(SeleneTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.plain).seleneFont(17).foregroundColor(SeleneTheme.ink)
        .padding(canvas.u(16))
        .background(RoundedRectangle(cornerRadius: canvas.u(12)).fill(SeleneTheme.glassLight))
        .padding(.top, canvas.u(24))
    }

    private func cancel() {
        if let task { cancelling = true; task.cancel() }
        else { onClose() }
    }

    private func confirm() {
        guard task == nil, valid, viewModel.canConfigureCloudLibrary else { return }
        let selection = model.preference
        if editor == .folder {
            model.configure(remote: selection.remote, root: normalizedFolder, enabled: selection.enabled)
            onClose()
            return
        }
        let chosen = model.chosenExecutable
        let client = client, password = secret
        secret = ""; issue = nil; field = nil; focus = .cancel
        model.isChangingConnection = true
        task = Task { @MainActor in
            defer { model.isChangingConnection = false; task = nil }
            do {
                guard let tool = await Task.detached(priority: .utility, operation: {
                    chosen ?? RcloneStorageBackend.findExecutable()
                }).value else { throw RcloneConfiguration.Failure.tool }
                let remote = try await RcloneConfiguration(executable: tool).connect(clientID: client, secret: password)
                try Task.checkCancellation()
                model.configure(remote: remote.name, root: selection.root, enabled: true)
                onClose()
            } catch is CancellationError {
                onClose()
            } catch {
                issue = (error as? RcloneConfiguration.Failure) ?? .connect
                focus = .confirm
                field = .secret
            }
        }
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}
