import AppKit
import NXLibraryCore
import ArcanePorting
import SwiftUI

struct CloudSetupAssistant: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    let onClose: () -> Void

    init(viewModel: AppViewModel, model: CloudLibraryModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.model = model
        self.onClose = onClose
    }

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    @State var focus = CloudSetupAssistantFocus()
    @State var keyMonitor: Any?
    @State private var draft = CloudSetupAssistantDraft()
    @State private var tool: URL?
    @State private var version: String?
    @State private var remotes: [RcloneRemote]?
    @State private var editingCredentials = false
    @State private var client = ""
    @State private var secret = ""
    @State private var replacement: CloudDriveCredentialChange?
    @State private var listing: CloudDriveFolders.Listing?
    @State private var folderMissing = false
    @State private var count: Int?
    @State private var countUnknown = false
    @State private var movePlan: CloudDriveFolders.MovePlan?
    @State private var checkingMove = false
    @State private var moveUnavailable = false
    @State private var confirmingMove = false
    @State private var stopMove = false
    @State private var moveProgress = 0.0
    @State private var moveConflicts: [String] = []
    @State private var issue: String?
    @State private var work: (id: UUID, kind: Work, task: Task<Void, Never>)?
    @State private var folderName: String?
    @State private var creation: String?
    @State private var activated = false
    @FocusState private var field: CloudSetupAssistantFocus.Target?

    typealias Target = CloudSetupAssistantFocus.Target
    private enum Work { case inspect, connect, browse, create, verify, move }
    private var existing: RcloneRemote? {
        remotes?.first { $0.type == "drive" && $0.name == model.preference.remote }
            ?? remotes?.first { $0.type == "drive" }
    }
    private var canEdit: Bool { viewModel.canConfigureCloudLibrary }
    private var showCredentials: Bool { remotes != nil && (existing == nil || editingCredentials) }
    private var validID: Bool { CloudSetupAssistantDraft.validGoogleClientID(client) }
    private var folderReady: Bool { listing != nil && draft.candidate != nil }
    private var folderControlsReady: Bool { work?.kind != .create && canEdit }
    private var folderNames: [String] { listing?.names ?? [] }
    private var moveOffered: Bool {
        guard let movePlan, movePlan.games > 0 else { return false }
        return folderReady && folderControlsReady && CloudDriveFolders.canMove(from: movePlan.source, to: draft.path)
    }
    private var service: CloudDriveFolders? {
        guard let remote = draft.remote, let tool else { return nil }
        return CloudDriveFolders(remote: remote, executable: tool, config: replacement?.config)
    }
    private var breadcrumbs: [String] {
        var path = ""
        return [""] + draft.path.split(separator: "/").map {
            path = CloudDriveFolders.joining(path, String($0))
            return path
        }
    }
    private var primaryTitle: String {
        switch draft.step {
        case .account: return showCredentials ? "Sign in" : "Keep this account"
        case .folder: return "Use this folder"
        case .verify: return "Activate"
        }
    }
    private var primaryEnabled: Bool {
        guard canEdit, !activated else { return false }
        switch draft.step {
        case .account:
            return work == nil && remotes != nil && (showCredentials
                ? validID && RcloneConfiguration.validCredential(secret) : existing != nil)
        case .folder: return folderReady && folderControlsReady && !checkingMove
        case .verify: return work == nil && draft.verified
        }
    }

    var body: some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: cancel)
            if let creation {
                SeleneConfirmDialog(title: format("Create “%@”?", [creation]),
                                    message: text("Existing files stay where they are."),
                                    confirmTitle: "Create", focus: Binding(get: { focus.target == .create ? .confirm : .cancel },
                                        set: { focus.select($0 == .confirm ? .create : .cancel) }),
                                    onCancel: cancel, onConfirm: { create(creation) })
            } else if confirmingMove, let movePlan {
                let size = movePlan.bytes.formatted(.byteCount(style: .file).locale(localization.formatLocale))
                SeleneConfirmDialog(title: format(movePlan.games == 1
                    ? "Move %d game (%@) to %@?" : "Move %d games (%@) to %@?", [movePlan.games, size, draft.path]),
                    message: text("Nothing is downloaded again."), confirmTitle: "Move",
                    focus: Binding(get: { focus.target == .confirmMove ? .confirm : .cancel },
                                   set: { focus.select($0 == .confirm ? .confirmMove : .cancel) }),
                    onCancel: cancel, onConfirm: moveGames)
            } else {
                VStack(spacing: canvas.u(18)) {
                    Text(text("Set up cloud library")).seleneFont(30, .semibold)
                        .foregroundColor(SeleneTheme.ink).accessibilityAddTraits(.isHeader)
                    stepper
                    switch draft.step {
                    case .account: account
                    case .folder: folders
                    case .verify: verification
                    }
                    if let issue {
                        Text(text(issue)).seleneFont(16).foregroundColor(SeleneTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let first = moveConflicts.first {
                        Text(format(moveConflicts.count == 1 ? "%d file has a conflict: %@"
                                    : "%d files have conflicts. First: %@", [moveConflicts.count, first]))
                            .seleneFont(16).foregroundColor(SeleneTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: canvas.u(14)) {
                        pill(.cancel, work?.kind == .move ? "Cancel" : draft.step == .verify || folderName != nil ? "Back" : "Cancel",
                             enabled: !stopMove, action: cancel)
                        if folderName != nil {
                            pill(.create, "Continue", enabled: folderName.map(CloudDriveFolders.validName) == true,
                                 action: proposeCreation)
                        } else if draft.step != .account || remotes != nil {
                            pill(.primary, primaryTitle, enabled: primaryEnabled, action: primary)
                        }
                    }
                }
                .modifier(SeleneDialogCard())
            }
        }
        .onAppear { inspect(); installAssistantKeys() }
        .onDisappear { work?.task.cancel(); removeAssistantKeys(); secret = ""; replacement = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            work?.task.cancel()
        }
        .onExitCommand(perform: cancel)
        .onReceive(NotificationCenter.default.publisher(for: .nxSettingsGamepadAction)) { note in
            if let action = note.object as? GamepadAction { handleAssistantInput(action) }
        }
        .onChange(of: focusRows) { focus.settle(in: $0) }
        .onChange(of: field) { if let target = $0 { focus.select(target) } }
    }

    private var stepper: some View {
        let labels = ["Google account", "Folder", "Verify"]
        return HStack(spacing: canvas.u(10)) {
            ForEach(CloudSetupAssistantDraft.Step.allCases, id: \.rawValue) { step in
                let active = draft.step == step
                if step != .account {
                    Capsule().fill(SeleneTheme.ink15).frame(width: canvas.u(22), height: canvas.u(1))
                }
                HStack(spacing: canvas.u(6)) {
                    Text(String(step.rawValue + 1)).seleneFont(13, .semibold)
                        .foregroundColor(active ? SeleneTheme.onFocus : SeleneTheme.ink60)
                        .frame(width: canvas.u(24), height: canvas.u(24))
                        .background(Circle().fill(active ? SeleneTheme.focus : SeleneTheme.glass))
                    Text(text(labels[step.rawValue])).seleneFont(14, .semibold)
                        .foregroundColor(active ? SeleneTheme.ink : SeleneTheme.ink60)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(format("Step %d of 3: %@", [draft.step.rawValue + 1, text(labels[draft.step.rawValue])]))
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: canvas.u(10)) {
            if let version { SeleneStatusDot(text: format("rclone detected · %@", [version]), color: SeleneTheme.success) }
            if work?.kind == .inspect { progress("Checking…") }
            else if work?.kind == .connect { progress("Waiting for Google sign-in in your browser…") }
            else if tool == nil {
                Text(text("Install rclone: brew install rclone"))
                pill(.retry, "Try again", action: inspect)
            } else if remotes == nil {
                pill(.retry, "Try again", action: inspect)
            } else if !showCredentials, let existing {
                Text(verbatim: "\(text("Google Drive")) · \(existing.name)").seleneFont(19, .semibold)
                option(.changeCredentials, text("Change credentials")) { editingCredentials = true }
            } else {
                Text(text("Use a Google OAuth client for a desktop app. rclone asks for full Google Drive access."))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: canvas.u(12)) {
                    option(.console, text("Google Console")) { openConsole() }
                    option(.guide, text("Setup guide")) { openGuide() }
                }
                Text(text("Google client ID"))
                input(.client) {
                    TextField(text("Google client ID"), text: $client).focused($field, equals: .client)
                        .onSubmit { field = .secret }
                }
                if !client.isEmpty {
                    SeleneStatusDot(text: text(validID ? "Valid format" : "Use an ID ending in .apps.googleusercontent.com"),
                                    color: validID ? SeleneTheme.success : SeleneTheme.danger)
                }
                Text(text("Google client secret"))
                input(.secret) {
                    SecureField(text("Google client secret"), text: $secret).focused($field, equals: .secret)
                        .onSubmit(primary)
                }
            }
        }
        .seleneFont(16).foregroundColor(SeleneTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: canvas.u(10)) {
            if folderName != nil {
                Text(text("Folder name")).seleneFont(17)
                input(.folderName) {
                    TextField(text("Folder name"), text: Binding(get: { folderName ?? "" }, set: { folderName = $0 }))
                        .focused($field, equals: .folderName).onSubmit(proposeCreation)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: canvas.u(5)) {
                        ForEach(breadcrumbs, id: \.self) { path in
                            if !path.isEmpty { MaterialIconView(.chevron, size: 13).accessibilityHidden(true) }
                            if path == draft.path { Text(folderLabel(path)).seleneFont(17, .semibold) }
                            else { option(.breadcrumb(path), folderLabel(path), enabled: folderControlsReady) { browse(path) } }
                        }
                    }
                }
                if listing != nil {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: canvas.u(5)) {
                                ForEach(folderNames, id: \.self) { name in
                                    option(.folder(name), name, icon: .folder, enabled: folderControlsReady, wide: true) {
                                        browse(CloudDriveFolders.joining(draft.path, name))
                                    }
                                    .id(Target.folder(name))
                                }
                            }
                        }
                        .frame(height: canvas.u(CGFloat(min(folderNames.count * 39, 185))))
                        .onChange(of: focus.target) { if case .folder = $0 { proxy.scrollTo($0) } }
                    }
                    option(.newFolder, text("New folder…"), enabled: folderControlsReady && !checkingMove,
                           wide: true, action: nameFolder)
                }
                if listing == nil && work?.kind == .browse || work?.kind == .create { progress("Checking…") }
                if listing == nil && work == nil { pill(.retry, "Try again") { browse(draft.path) } }
                if folderMissing { option(.newFolder, text("New folder…"), action: nameFolder) }
                if let count, count > 0 {
                    SeleneStatusDot(text: format(count == 1 ? "Arcane library found: %d game" : "Arcane library found: %d games", [count]),
                                    color: SeleneTheme.success)
                } else if countUnknown {
                    SeleneStatusDot(text: text("Arcane library status unavailable"), color: SeleneTheme.ink60)
                }
                if checkingMove { progress("Checking the old folder…") }
                else if moveUnavailable {
                    SeleneStatusDot(text: text("Could not check the old folder."), color: SeleneTheme.ink60)
                } else if let movePlan, movePlan.games > 0 {
                    SeleneStatusDot(text: format(movePlan.games == 1 ? "%d game in %@" : "%d games in %@",
                                                 [movePlan.games, movePlan.source]), color: SeleneTheme.success)
                    if moveOffered {
                        option(.moveGames, text("Move my games here"), checked: draft.wantsMove,
                               wide: true) { draft.toggleMove() }
                            .accessibilityValue(text(draft.wantsMove ? "On" : "Off"))
                    }
                }
            }
        }
        .foregroundColor(SeleneTheme.ink)
    }

    private var verification: some View {
        VStack(spacing: canvas.u(10)) {
            Text(verbatim: "\(draft.remote ?? ""):/\(draft.path)").seleneFont(18).foregroundColor(SeleneTheme.ink)
            if work?.kind == .move {
                SeleneStatusDot(text: text(stopMove ? "Cancelling…" : "Moving games…"), color: SeleneTheme.focus)
                ProgressView(value: moveProgress).tint(SeleneTheme.focus).accessibilityLabel(text("Moving games…"))
            } else if work != nil { progress("Checking…") }
            else if draft.verified { SeleneStatusDot(text: text("Connection OK"), color: SeleneTheme.success) }
            else { pill(.retry, "Try again", action: verify) }
        }
    }

    private func progress(_ key: String) -> some View {
        HStack(spacing: canvas.u(10)) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(text(key)).seleneFont(16).foregroundColor(SeleneTheme.ink75)
        }
    }

    private func input<V: View>(_ target: Target, @ViewBuilder content: () -> V) -> some View {
        content().textFieldStyle(.plain).seleneFont(17).padding(canvas.u(8))
            .background(RoundedRectangle(cornerRadius: canvas.u(7)).fill(SeleneTheme.glassLight))
            .overlay(RoundedRectangle(cornerRadius: canvas.u(7))
                .strokeBorder(focus.target == target ? SeleneTheme.focus : SeleneTheme.ink15))
    }

    private func option(_ target: Target, _ title: String, icon: MaterialIcon? = nil, checked: Bool? = nil, enabled: Bool = true,
                        wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: canvas.u(8)) {
                if let icon { MaterialIconView(icon, size: 20).accessibilityHidden(true) }
                if let checked { Image(systemName: checked ? "checkmark.square.fill" : "square").accessibilityHidden(true) }
                Text(verbatim: title).seleneFont(16).lineLimit(1)
                if wide { Spacer(minLength: 0) }
            }
            .foregroundColor(focus.target == target ? SeleneTheme.onFocus : SeleneTheme.ink)
            .padding(.horizontal, canvas.u(9)).frame(minHeight: canvas.u(34))
            .background(RoundedRectangle(cornerRadius: canvas.u(8))
                .fill(focus.target == target ? SeleneTheme.focus : SeleneTheme.glass))
        }
        .buttonStyle(.plain).disabled(!enabled).onHover { if $0 && enabled { focus.select(target) } }
    }

    private func pill(_ target: Target, _ key: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        SelenePillButton(title: key, minWidth: 115, height: 48, horizontalPadding: 17,
                         focused: focus.target == target, enabled: enabled, action: action)
            .disabled(!enabled).onHover { if $0 && enabled { focus.select(target) } }
    }

    private func folderLabel(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? text("My Drive") }
    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
    private func format(_ key: String, _ arguments: [CVarArg]) -> String {
        L10n.format(key, arguments, context: localization)
    }

    private func start(_ kind: Work, _ operation: @escaping @MainActor () async throws -> Void) {
        work?.task.cancel()
        issue = nil
        let id = UUID()
        work = (id, kind, Task { @MainActor in
            defer { if work?.id == id { work = nil } }
            do { try await operation() }
            catch is CancellationError {}
            catch {
                if !Task.isCancelled && work?.id == id {
                    issue = (error as? RcloneConfiguration.Failure)?.key ?? RcloneConfiguration.Failure.test.key
                }
            }
        })
    }

    private func inspect() {
        let chosen = model.chosenExecutable
        tool = nil; version = nil; remotes = nil
        start(.inspect) {
            let found = await Task.detached(priority: .utility) { chosen ?? RcloneStorageBackend.findExecutable() }.value
            try Task.checkCancellation()
            guard let found, RcloneStorageBackend.isExecutable(found) else { return }
            tool = found
            let config = RcloneConfiguration(executable: found)
            let detected = try await config.version()
            try Task.checkCancellation()
            version = detected.replacingOccurrences(of: "rclone ", with: "", options: .anchored)
            let listed = try await config.remotes()
            try Task.checkCancellation()
            remotes = listed
        }
    }

    private func selectAccount(_ name: String) {
        draft.chooseAccount(name)
        let root = model.preference.remote == name ? model.preference.root : ""
        browse(root.split(separator: "/").joined(separator: "/"))
    }

    private func connect() {
        guard let tool else { return }
        let id = client, password = secret, target = existing?.name
        field = nil; secret = ""; focus.reset()
        model.isChangingConnection = true
        start(.connect) {
            defer { model.isChangingConnection = false }
            if let target {
                let staged = try await CloudDriveCredentialChange.prepare(remote: target, executable: tool,
                                                                          clientID: id, secret: password)
                try Task.checkCancellation()
                replacement = staged
                selectAccount(target)
            } else {
                let remote = try await RcloneConfiguration(executable: tool).connect(clientID: id, secret: password)
                try Task.checkCancellation()
                selectAccount(remote.name)
            }
        }
    }

    private func browse(_ path: String) {
        guard let service else { return }
        let ticket = draft.browse(path)
        listing = nil; count = nil; countUnknown = false; folderMissing = false
        movePlan = nil; moveUnavailable = false; checkingMove = false; moveConflicts = []
        let old = model.preference.root.split(separator: "/").joined(separator: "/")
        let checkOld = model.preference.remote == draft.remote && replacement == nil
            && CloudDriveFolders.canMove(from: old, to: path)
        focus.reset()
        start(.browse) {
            let result: CloudDriveFolders.Listing
            do { result = try await service.list(path, ticket: ticket) }
            catch StorageBackendError.notFound {
                if !Task.isCancelled && draft.matches(ticket) { folderMissing = !path.isEmpty }
                throw RcloneConfiguration.Failure.test
            }
            guard !Task.isCancelled, draft.matches(result.ticket) else { return }
            checkingMove = checkOld
            listing = result
            if checkOld {
                do {
                    let plan = try await service.movePlan(from: old)
                    if !Task.isCancelled && draft.matches(ticket) { movePlan = plan }
                } catch {
                    if !Task.isCancelled && draft.matches(ticket) { moveUnavailable = true }
                }
                guard !Task.isCancelled, draft.matches(ticket) else { return }
                checkingMove = false
            }
            guard !path.isEmpty else { return }
            do {
                let games = try await service.libraryCount(in: path, folders: result.names)
                if !Task.isCancelled && draft.matches(ticket) { count = games }
            } catch {
                if !Task.isCancelled && draft.matches(ticket) { countUnknown = true }
            }
        }
    }

    private func nameFolder() {
        guard folderControlsReady, !checkingMove else { return }
        if folderMissing, let name = draft.path.split(separator: "/").last {
            focus.reset()
            creation = String(name)
            return
        }
        guard listing != nil else { return }
        folderName = ""; focus.select(.folderName); field = .folderName
    }

    private func proposeCreation() {
        guard let name = folderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              CloudDriveFolders.validName(name), folderControlsReady else { return }
        folderName = nil; field = nil; focus.reset()
        if folderNames.contains(name) { browse(CloudDriveFolders.joining(draft.path, name)) }
        else { creation = name }
    }

    private func create(_ name: String) {
        guard creation == name, folderControlsReady, let service else { return }
        let parent = folderMissing ? draft.path.split(separator: "/").dropLast().joined(separator: "/") : draft.path
        let ticket = draft.ticket
        creation = nil; focus.reset()
        start(.create) {
            try await service.create(name, in: parent)
            if !Task.isCancelled && draft.matches(ticket) { browse(CloudDriveFolders.joining(parent, name)) }
        }
    }

    private func verify() {
        guard let service, draft.step == .verify else { return }
        let path = draft.path, ticket = draft.renewTicket()
        start(.verify) {
            try await service.verifyAccess(to: path)
            if !Task.isCancelled { draft.acceptAccessCheck(ticket) }
        }
    }

    private func activate() {
        guard let preference = draft.activation else { return }
        do {
            let replaced = replacement != nil
            try replacement?.apply()
            activated = true
            model.configure(remote: preference.remote, root: preference.root, enabled: true, reload: replaced)
            onClose()
        } catch {
            issue = RcloneConfiguration.Failure.configuration.key
        }
    }

    private func moveGames() {
        guard confirmingMove, draft.wantsMove, primaryEnabled, let movePlan, let service else { return }
        let ticket = draft.ticket, path = draft.path
        confirmingMove = false; focus.reset(); moveConflicts = []; moveProgress = 0
        model.isChangingConnection = true
        start(.move) {
            defer { model.isChangingConnection = false; stopMove = false }
            let conflicts: [String]
            do {
                conflicts = try await service.move(movePlan, to: path) { done, total in
                    if stopMove && done < total { throw CancellationError() }
                    moveProgress = total > 0 ? Double(done) / Double(total) : 0
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                if !Task.isCancelled { issue = "Move stopped. Try again to move the remaining files." }
                return
            } catch {
                issue = "Could not finish moving games. Try again to move the remaining files."
                return
            }
            moveConflicts = conflicts
            guard conflicts.isEmpty else { return }
            draft.acceptMove(ticket)
            activate()
        }
    }

    func cancel() {
        field = nil; focus.reset()
        if creation != nil { creation = nil; return }
        if confirmingMove { confirmingMove = false; return }
        if work?.kind == .move { stopMove = true; return }
        if folderName != nil { folderName = nil; return }
        if work?.kind == .create { return }
        if draft.step == .verify {
            draft.backToFolders()
            browse(draft.path)
            return
        }
        if draft.step == .account && editingCredentials && work == nil {
            editingCredentials = false; client = ""; secret = ""; issue = nil
            return
        }
        work?.task.cancel()
        onClose()
    }

    private func primary() {
        guard primaryEnabled else { return }
        switch draft.step {
        case .account:
            if showCredentials { connect() }
            else if let existing { selectAccount(existing.name) }
        case .folder:
            if draft.useFolder() { focus.reset(); verify() }
        case .verify:
            if draft.activation != nil { activate() }
            else if draft.wantsMove { focus.reset(); confirmingMove = true }
        }
    }

    var focusRows: [[Target]] {
        if creation != nil { return [[.cancel, .create]] }
        if confirmingMove { return [[.cancel, .confirmMove]] }
        if folderName != nil { return [[.folderName], [.cancel] + (folderName.map(CloudDriveFolders.validName) == true ? [.create] : [])] }
        var rows: [[Target]] = []
        switch draft.step {
        case .account:
            if work == nil {
                if remotes == nil { rows = [[.retry]] }
                else if showCredentials { rows = [[.console, .guide], [.client], [.secret]] }
                else { rows = [[.changeCredentials]] }
            }
        case .folder:
            if folderControlsReady {
                rows = [breadcrumbs.dropLast().map(Target.breadcrumb)]
                rows += folderNames.map { [.folder($0)] }
                if listing != nil && !checkingMove { rows.append([.newFolder]) }
                else if work == nil { rows.append([.retry]) }
                if folderMissing { rows.append([.newFolder]) }
                if moveOffered { rows.append([.moveGames]) }
            }
        case .verify:
            if work == nil && !draft.verified { rows = [[.retry]] }
        }
        return rows + [(stopMove ? [] : [.cancel]) + (primaryEnabled ? [.primary] : [])]
    }

    func perform(_ target: Target) {
        guard focusRows.contains(where: { $0.contains(target) }) else { return }
        switch target {
        case .cancel: cancel()
        case .primary: primary()
        case .changeCredentials: editingCredentials = true
        case .client, .secret, .folderName: field = target
        case .console: openConsole()
        case .guide: openGuide()
        case .retry:
            switch draft.step {
            case .account: inspect()
            case .folder: browse(draft.path)
            case .verify: verify()
            }
        case .breadcrumb(let path): browse(path)
        case .folder(let name): browse(CloudDriveFolders.joining(draft.path, name))
        case .newFolder: nameFolder()
        case .moveGames: draft.toggleMove()
        case .confirmMove: moveGames()
        case .create:
            if let creation { create(creation) }
            else { proposeCreation() }
        }
    }

    func moveAssistantFocus(_ direction: CloudSetupAssistantFocus.Direction) {
        focus.move(direction, in: focusRows)
        switch focus.target {
        case .client, .secret, .folderName: field = focus.target
        default: field = nil
        }
    }

    private func openConsole() { NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!) }
    private func openGuide() { NSWorkspace.shared.open(URL(string: "https://rclone.org/drive/#making-your-own-client-id")!) }
}
