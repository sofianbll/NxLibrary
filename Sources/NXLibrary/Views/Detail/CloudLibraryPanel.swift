import SwiftUI
import NXLibraryCore
import ArcanePorting

extension Notification.Name {
    static let nxCloudLibraryGamepadAction = Notification.Name("nxCloudLibraryGamepadAction")
}

/// The Details link opens the existing Selene card treatment; both representations of the game share the same job.
struct CloudLibraryPanel: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    let game: PortedGame
    @State private var focus: Control = .close

    private enum Control: Hashable {
        case upload, free(CloudArtifactKind), download(CloudArtifactKind), cancel, refresh, close
    }

    private var state: CloudLibraryState { model.states[game.id] ?? CloudLibraryState() }
    private var canChange: Bool { state.action == nil && !state.refreshing && viewModel.canChangeCloudLibrary(game) }

    var body: some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: canvas.u(16)) {
                Text(text("Cloud library"))
                    .seleneFont(30, .semibold)
                    .foregroundColor(SeleneTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                ForEach(CloudArtifactKind.allCases, id: \.self) { kind in
                    artifactRow(kind)
                }
                if state.action != nil || state.refreshing {
                    HStack(spacing: canvas.u(10)) {
                        SeleneValueChip(text: text("In progress"))
                        if let progress = state.progress {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(SeleneTheme.focus)
                        } else {
                            ProgressView().controlSize(.mini).tint(SeleneTheme.focus)
                        }
                    }
                }
                if let message = state.message {
                    Text(message).seleneFont(15).foregroundColor(SeleneTheme.danger)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: canvas.u(10)) {
                    button(.close, "Close")
                    if state.action != nil {
                        button(.cancel, "Cancel transfer")
                    } else if !state.refreshing {
                        button(.refresh, "Refresh")
                        if controls.contains(.upload) { button(.upload, "Send") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .modifier(SeleneDialogCard())
        }
        .task(id: game.id) { await viewModel.refreshCloudLibrary(game) }
        .onChange(of: controls) { _, controls in if !controls.contains(focus) { focus = .close } }
        .onReceive(NotificationCenter.default.publisher(for: .nxCloudLibraryGamepadAction)) { note in
            if let action = note.object as? GamepadAction { handle(action) }
        }
    }

    private func artifactRow(_ kind: CloudArtifactKind) -> some View {
        let control = artifactControl(kind)
        return HStack(spacing: canvas.u(10)) {
            VStack(alignment: .leading, spacing: canvas.u(5)) {
                Text(text(kind == .app ? "Game app" : "Build cache"))
                    .seleneFont(17, .semibold)
                    .foregroundColor(SeleneTheme.ink90)
                HStack(spacing: canvas.u(7)) {
                    if state.local[kind] == true {
                        SeleneValueChip(text: text(kind == .app ? "App installed" : "On this Mac"))
                    } else if state.local[kind] == nil, !state.refreshing {
                        SeleneValueChip(text: text("Local folder unavailable"))
                    }
                    if state.remote?.contains(kind) == true {
                        SeleneValueChip(text: text("In the cloud"))
                    } else if state.remote == nil, !state.refreshing {
                        SeleneValueChip(text: text("Cloud status unknown"))
                    } else if !state.refreshing {
                        SeleneValueChip(text: text("Not saved in the cloud"))
                    }
                }
            }
            Spacer(minLength: 0)
            if let control {
                button(control, control == .free(kind) ? "Free up space" : "Download")
            }
        }
    }

    private func artifactControl(_ kind: CloudArtifactKind) -> Control? {
        guard canChange, state.remote?.contains(kind) == true, let present = state.local[kind] else { return nil }
        return present ? .free(kind) : .download(kind)
    }

    private var controls: [Control] {
        if state.action != nil { return [.close, .cancel] }
        let artifacts = CloudArtifactKind.allCases.compactMap(artifactControl)
        guard !state.refreshing else { return [.close] }
        let canUpload = canChange && CloudArtifactKind.allCases.allSatisfy { state.local[$0] == true }
        return artifacts + [.close, .refresh] + (canUpload ? [.upload] : [])
    }

    private func button(_ control: Control, _ key: String) -> some View {
        SelenePillButton(title: key, minWidth: 96, height: 36, horizontalPadding: 14,
                         focused: focus == control, action: { choose(control) })
            .onHover { if $0 { focus = control } }
    }

    private func handle(_ action: GamepadAction) {
        let controls = self.controls
        let current = controls.firstIndex(of: focus) ?? controls.firstIndex(of: .close) ?? 0
        switch action {
        case .navigateUp, .navigateLeft, .navigateDown, .navigateRight:
            let direction = action == .navigateUp || action == .navigateLeft ? -1 : 1
            let next = min(max(current + direction, 0), controls.count - 1)
            if next != current {
                focus = controls[next]
                SoundEffectService.shared.play(.focus)
            }
        case .confirm: choose(controls[current])
        case .cancel: close()
        default: break
        }
    }

    private func choose(_ control: Control) {
        guard controls.contains(control) else { return }
        switch control {
        case .upload: viewModel.performCloudLibrary(.upload, for: game)
        case .free(let kind): viewModel.confirmCloudFree(kind, for: game)
        case .download(let kind): viewModel.performCloudLibrary(.restore(kind), for: game)
        case .cancel: viewModel.cancelCloudLibrary(game)
        case .refresh: Task { await viewModel.refreshCloudLibrary(game) }
        case .close: close()
        }
    }

    private func close() { viewModel.cloudLibraryGameID = nil }
    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}
