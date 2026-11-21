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
        case upload, free(CloudArtifactKind), download(CloudArtifactKind), cancel, refresh, settings, close
    }

    private var state: CloudLibraryState { model.states[game.id] ?? CloudLibraryState() }
    private var canChange: Bool { state.action == nil && !state.refreshing && viewModel.canChangeCloudLibrary(game) }
    private var unavailable: String? {
        if model.preference.remote == nil { return "No cloud service is configured." }
        if !model.preference.enabled { return "The cloud library is turned off." }
        if game.titleId.map(SaveLocation.validID) != true { return "This game has no valid title ID." }
        return nil
    }

    var body: some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: canvas.u(16)) {
                Text(text("Cloud library"))
                    .seleneFont(30, .semibold)
                    .foregroundColor(SeleneTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let unavailable {
                    Text(text(unavailable)).seleneFont(17).foregroundColor(SeleneTheme.ink75)
                } else {
                    ForEach(CloudArtifactKind.allCases, id: \.self) { kind in
                        artifactRow(kind)
                    }
                }
                if state.action != nil {
                    CloudLibraryProgressView(progress: state.progress)
                } else if state.refreshing {
                    Text(text("Checking…")).seleneFont(15).foregroundColor(SeleneTheme.ink75)
                }
                if let message = state.operationMessage ?? state.message {
                    Text(message).seleneFont(15).foregroundColor(SeleneTheme.danger)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: canvas.u(10)) {
                    button(.close, "Close")
                    if controls.contains(.settings) { button(.settings, "Open settings") }
                    if state.action != nil {
                        button(.cancel, "Cancel transfer")
                    } else if controls.contains(.refresh) {
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
        if model.archive == nil { return [.close, .settings] }
        if unavailable != nil { return [.close] }
        if state.action != nil { return [.close, .cancel] }
        let artifacts = CloudArtifactKind.allCases.compactMap(artifactControl)
        guard !state.refreshing else { return [.close] }
        let canUpload = canChange && CloudArtifactKind.allCases.allSatisfy { state.local[$0] == true }
        return artifacts + [.close] + (state.remote == nil && (state.message != nil || state.operationMessage != nil) ? [.settings] : [])
            + [.refresh] + (canUpload ? [.upload] : [])
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
        case .settings:
            close()
            viewModel.router?.openSettings(.cloudLibrary)
        case .close: close()
        }
    }

    private func close() { viewModel.cloudLibraryGameID = nil }
    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}

/// Same labelled progress in Details and in the transfer panel; the bar uses Selene's existing fill.
struct CloudLibraryProgressView: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    let progress: CloudArchiveProgress?

    var body: some View {
        let fraction = progress?.transfer.flatMap { $0.totalBytes > 0
            ? Double($0.bytesTransferred) / Double($0.totalBytes) : nil }
        VStack(alignment: .leading, spacing: canvas.u(5)) {
            Text(summary(fraction)).seleneFont(15).monospacedDigit().foregroundColor(SeleneTheme.ink90)
            if let fraction {
                AchievementProgressBar(fraction: fraction)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(SeleneTheme.focus)
                    .accessibilityHidden(true)
            }
        }
    }

    private func summary(_ fraction: Double?) -> String {
        guard let progress else { return text("Preparing cloud operation…") }
        var segments = [text(phaseKey(progress))]
        let locale = localization.formatLocale
        if let transfer = progress.transfer, let fraction {
            segments.append(L10n.format("%@ of %@", [bytes(transfer.bytesTransferred), bytes(transfer.totalBytes)], context: localization))
            segments.append(fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
            if let speed = transfer.bytesPerSecond, speed.isFinite, speed > 0, speed < Double(Int64.max) {
                segments.append(L10n.format("%@/s", [bytes(Int64(speed))], context: localization))
            }
            if let eta = transfer.etaSeconds, eta.isFinite, eta >= 0, eta <= 86_400, fraction < 1 {
                let seconds = max(1, Int(eta.rounded()))
                let duration = seconds < 60
                    ? L10n.format("%@ s", [seconds.formatted(.number.locale(locale))], context: localization)
                    : L10n.format("%@ min", [Int((Double(seconds) / 60).rounded()).formatted(.number.locale(locale))], context: localization)
                segments.append(L10n.format("About %@ left", [duration], context: localization))
            }
        }
        return segments.joined(separator: " · ")
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(localization.formatLocale))
    }

    private func phaseKey(_ progress: CloudArchiveProgress) -> String {
        switch (progress.phase, progress.kind) {
        case (.archiving, .app): return "Archiving app"
        case (.archiving, _): return "Archiving cache"
        case (.uploading, .app): return "Uploading app"
        case (.uploading, _): return "Uploading cache"
        case (.verifying, .app): return "Verifying app"
        case (.verifying, .cache): return "Verifying cache"
        case (.verifying, nil): return "Verifying cloud copy"
        case (.downloading, .app): return "Downloading app"
        case (.downloading, _): return "Downloading cache"
        case (.restoring, .app): return "Restoring app"
        case (.restoring, _): return "Restoring cache"
        }
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}

/// A non-interactive tile overlay; only known manifest state or an active operation draws a badge.
struct CloudLibraryTileBadge: ViewModifier {
    @ObservedObject var cloud: CloudLibraryModel
    let game: PortedGame?
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    func body(content: Content) -> some View {
        let state = game.flatMap { cloud.states[$0.id] }
        let installed = game?.isPlayableLocally == true
        let label = state?.statusKey(installed: installed).map { L10n.text($0, context: localization) }
        content.overlay(alignment: .topTrailing) {
            if let label, let state {
                SeleneValueChip(text: label, symbol: symbol(state))
                .padding(canvas.u(10))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .accessibilityValue(label ?? "")
    }

    private func symbol(_ state: CloudLibraryState) -> String {
        switch state.action {
        case .upload: return "icloud.and.arrow.up"
        case .restore, .restoreBuildCache: return "icloud.and.arrow.down"
        case .free, nil: return state.appAvailability == .cloudOnly ? "icloud.and.arrow.down" : "icloud"
        }
    }
}
