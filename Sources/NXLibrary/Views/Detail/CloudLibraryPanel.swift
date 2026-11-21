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
    @Environment(\.seleneShowButtonHints) private var showHints
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var model: CloudLibraryModel
    let game: PortedGame
    @State private var focus: Control?
    @State private var refreshRevision = 0

    private struct ReadRequest: Equatable {
        let game: PortedGame
        let revision: Int
    }

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
            VStack(spacing: 0) {
                card.frame(maxWidth: .infinity, maxHeight: .infinity)
                SeleneHintsBar(left: [HintItem(.b, "Close", action: close)],
                               right: controls.isEmpty ? [] : [HintItem(.a, "Select")])
            }
        }
        .task(id: ReadRequest(game: game, revision: refreshRevision)) { await viewModel.refreshCloudLibrary(game) }
        .onChange(of: controls) { _, controls in
            if let focus, controls.contains(focus) { return }
            focus = controls.first
        }
        .onReceive(NotificationCenter.default.publisher(for: .nxCloudLibraryGamepadAction)) { note in
            if let action = note.object as? GamepadAction { handle(action) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: canvas.u(14)) {
            VStack(alignment: .leading, spacing: canvas.u(3)) {
                Text(text("Cloud library")).seleneFont(30, .semibold)
                    .foregroundColor(SeleneTheme.ink).accessibilityAddTraits(.isHeader)
                Text(game.name).seleneFont(17).foregroundColor(SeleneTheme.ink75)
                    .lineLimit(1)
            }
            if let unavailable {
                Text(text(unavailable)).seleneFont(17).foregroundColor(SeleneTheme.ink75)
            } else {
                ForEach(CloudArtifactKind.allCases, id: \.self) { kind in
                    artifactRow(kind)
                }
            }
            if let message = state.message {
                Text(message).seleneFont(15).foregroundColor(PortingPillCopy.softRed)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controls.contains(where: { [.close, .settings, .refresh, .upload].contains($0) }) {
                HStack(spacing: canvas.u(10)) {
                    if !showHints { button(.close, "Close") }
                    if controls.contains(.settings) { button(.settings, "Open settings") }
                    if controls.contains(.refresh) { button(.refresh, "Refresh") }
                    if controls.contains(.upload) { button(.upload, "Send update") }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .modifier(SeleneDialogCard())
    }

    private func artifactRow(_ kind: CloudArtifactKind) -> some View {
        let title = text(kind == .app ? "Game app" : "Build cache")
        let copy = state.copies[kind]
        let live = state.activeKind == kind
        let size = copy?.bytes.map { $0.formatted(.byteCount(style: .file).locale(localization.formatLocale)) }
        let sent = copy?.uploadedAt.map {
            L10n.format("Sent %@", [$0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)
                .locale(localization.formatLocale))],
                        context: localization)
        }
        return VStack(alignment: .leading, spacing: canvas.u(8)) {
            HStack(spacing: canvas.u(12)) {
                VStack(alignment: .leading, spacing: canvas.u(5)) {
                    Text(title).seleneFont(17, .semibold).foregroundColor(SeleneTheme.ink90)
                        .accessibilityAddTraits(.isHeader)
                    CloudLibraryIndicator(state: state, kind: kind).dot(context: localization, title: title)
                }
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: canvas.u(4)) {
                    if live, CloudLibraryProgressView.fraction(state.progress) != nil {
                        Text(CloudLibraryProgressView.summary(state.progress, context: localization, showsPhase: false))
                            .seleneFont(13).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if let size { Text(size).seleneFont(15).monospacedDigit() }
                        if let sent { Text(sent).seleneFont(13) }
                    }
                }
                .foregroundColor(SeleneTheme.ink75)
                .multilineTextAlignment(.trailing)
                if let control = artifactControl(kind) {
                    switch control {
                    case .cancel: button(.cancel, "Cancel")
                    case .free: button(control, size == nil ? "Free up space" : "Free %@", arguments: size.map { [$0] } ?? [])
                    default: button(control, "Download")
                    }
                }
            }
            if live {
                CloudLibraryProgressView(progress: state.progress, showsSummary: false)
            } else if let issue = state.issue, issue.kind == kind {
                Text(issue.message).seleneFont(15)
                    .foregroundColor(issue.failed ? PortingPillCopy.softRed : SeleneTheme.ink60)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(canvas.u(12))
        .background(SeleneTheme.glassLight, in: RoundedRectangle(cornerRadius: canvas.u(SeleneTheme.rowRadius)))
    }

    private func artifactControl(_ kind: CloudArtifactKind) -> Control? {
        if state.activeKind == kind { return .cancel }
        guard canChange else { return nil }
        switch state.copies[kind]?.state {
        case .synchronized: return .free(kind)
        case .cloudOnly: return .download(kind)
        default: return nil
        }
    }

    private var controls: [Control] {
        let close: [Control] = showHints ? [] : [.close]
        if model.archive == nil { return close + [.settings] }
        if unavailable != nil { return close }
        let artifacts = CloudArtifactKind.allCases.compactMap(artifactControl)
        if state.action != nil || state.refreshing { return artifacts + close }
        return artifacts + close + (state.message == nil ? [] : [.settings])
            + [.refresh] + (canChange && state.needsUpload ? [.upload] : [])
    }

    private func button(_ control: Control, _ key: String, arguments: [String] = []) -> some View {
        SelenePillButton(title: key, titleArguments: arguments, minWidth: 96, height: 36, horizontalPadding: 14,
                         focused: (focus ?? controls.first) == control, action: { choose(control) })
            .onHover { if $0 { focus = control } }
    }

    private func handle(_ action: GamepadAction) {
        let controls = self.controls
        if action == .cancel { close(); return }
        guard !controls.isEmpty else { return }
        let current = focus.flatMap { controls.firstIndex(of: $0) } ?? 0
        switch action {
        case .navigateUp, .navigateLeft, .navigateDown, .navigateRight:
            let direction = action == .navigateUp || action == .navigateLeft ? -1 : 1
            var index = FocusIndex(index: current)
            index.move(by: direction, count: controls.count)
            if index.index != current {
                focus = controls[index.index]
                SoundEffectService.shared.play(.focus)
            }
        case .confirm: choose(controls[current])
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
        case .refresh:
            model.update(game.id) { $0.issue = nil }
            refreshRevision += 1
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
    @Environment(\.nxAppLocale) private var localization
    @Environment(\.seleneCanvas) private var canvas
    let progress: CloudArchiveProgress?
    var showsSummary = true

    var body: some View {
        VStack(alignment: .leading, spacing: canvas.u(5)) {
            if showsSummary {
                Text(Self.summary(progress, context: localization)).seleneFont(15).monospacedDigit()
                    .foregroundColor(SeleneTheme.ink90)
            }
            if let fraction = Self.fraction(progress) {
                AchievementProgressBar(fraction: fraction, height: showsSummary ? 6 : 4)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.mini).tint(SeleneTheme.focus)
                    .accessibilityHidden(true)
            }
        }
    }

    static func fraction(_ progress: CloudArchiveProgress?) -> Double? {
        guard let transfer = progress?.transfer, transfer.totalBytes > 0 else { return nil }
        return min(1, max(0, Double(transfer.bytesTransferred) / Double(transfer.totalBytes)))
    }

    static func summary(_ progress: CloudArchiveProgress?, context: AppLocale, showsPhase: Bool = true) -> String {
        func text(_ key: String) -> String { L10n.text(key, context: context) }
        guard let progress else { return text("Preparing cloud operation…") }
        var segments = showsPhase ? [text(phaseKey(progress))] : []
        let locale = context.formatLocale
        func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file).locale(locale)) }
        if let transfer = progress.transfer, let fraction = fraction(progress) {
            segments.append(L10n.format("%@ of %@", [bytes(transfer.bytesTransferred), bytes(transfer.totalBytes)], context: context))
            if showsPhase { segments.append(percent(fraction, context: context)) }
            if let speed = transfer.bytesPerSecond, speed.isFinite, speed > 0, speed < Double(Int64.max) {
                segments.append(L10n.format("%@/s", [bytes(Int64(speed))], context: context))
            }
            if let eta = transfer.etaSeconds, eta.isFinite, eta >= 0, eta <= 86_400, fraction < 1 {
                let seconds = max(1, Int(eta.rounded()))
                let duration = seconds < 60
                    ? L10n.format("%@ s", [seconds.formatted(.number.locale(locale))], context: context)
                    : L10n.format("%@ min", [Int((Double(seconds) / 60).rounded()).formatted(.number.locale(locale))], context: context)
                segments.append(L10n.format("About %@ left", [duration], context: context))
            }
        }
        return segments.joined(separator: " · ")
    }

    static func percent(_ fraction: Double, context: AppLocale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(context.formatLocale))
    }

    static func phaseKey(_ progress: CloudArchiveProgress) -> String {
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

}

/// Shared cloud copy vocabulary. An artifact row only shows its own transfer or failure.
struct CloudLibraryIndicator {
    let state: CloudLibraryState
    var kind: CloudArtifactKind? = nil

    var progress: Bool { state.action != nil && (kind == nil || state.activeKind == kind) }
    var copy: CloudArtifactStatus.State { state.copies[kind ?? .app]?.state ?? .unknown }
    private var failed: Bool { state.issue?.failed == true && (kind == nil || state.issue?.kind == kind) }

    var color: Color {
        if progress { return SeleneTheme.ink }
        if failed { return PortingPillCopy.softRed }
        return Self.copyColor(copy)
    }

    static func copyColor(_ copy: CloudArtifactStatus.State) -> Color {
        switch copy {
        case .synchronized: return SeleneTheme.success
        case .cloudOnly: return SeleneTheme.glyph
        case .newerOnThisMac: return SeleneTheme.untested
        case .notInCloud, .unknown: return SeleneTheme.ink60
        }
    }

    func label(context: AppLocale, showingFailure: Bool = true) -> String {
        if progress {
            if let fraction = CloudLibraryProgressView.fraction(state.progress) {
                let key = state.progress?.phase == .uploading ? "Sending %@" : "Downloading %@"
                return L10n.format(key, [CloudLibraryProgressView.percent(fraction, context: context)], context: context)
            }
            return L10n.text(state.progress.map(CloudLibraryProgressView.phaseKey) ?? "Preparing cloud operation…", context: context)
        }
        if failed && showingFailure { return L10n.text("Cloud operation failed", context: context) }
        let key: String
        switch copy {
        case .synchronized: key = "Synchronized"
        case .cloudOnly: key = "Cloud only"
        case .newerOnThisMac: key = "Newer on this Mac"
        case .notInCloud: key = "Not in the cloud"
        case .unknown: key = state.refreshing ? "Checking…" : "Cloud status unknown"
        }
        return L10n.text(key, context: context)
    }

    func dot(context: AppLocale, title: String? = nil) -> some View {
        SeleneStatusDot(text: label(context: context), color: color,
                        labelColor: failed && !progress ? PortingPillCopy.softRed : SeleneTheme.ink90,
                        accessibilityTitle: title ?? L10n.text("Cloud library", context: context))
    }
}

/// A non-interactive tile overlay. The tile keeps its own accessible name and selection ring.
struct CloudLibraryTileBadge: ViewModifier {
    let state: CloudLibraryState?
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    static func artworkOpacity(_ state: CloudLibraryState?) -> Double { state?.appIsCloudOnly == true ? 0.55 : 1 }

    func body(content: Content) -> some View {
        let indicator = state.map { CloudLibraryIndicator(state: $0) }
        let symbol = indicator.flatMap { Self.symbol(for: $0.copy) }
        let visible = indicator?.progress == true || symbol != nil
        content.overlay(alignment: .topTrailing) {
            if let indicator, visible {
                badge(indicator, symbol: symbol)
                    .padding(canvas.u(10))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(visible ? indicator?.label(context: localization, showingFailure: false) ?? "" : "")
    }

    private func badge(_ indicator: CloudLibraryIndicator, symbol: String?) -> some View {
        let fraction = CloudLibraryProgressView.fraction(indicator.state.progress)
        return VStack(spacing: canvas.u(2)) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(SeleneTheme.scrim.opacity(0.94))
                if indicator.progress {
                    Circle().strokeBorder(SeleneTheme.ink25, lineWidth: canvas.u(2))
                    if let fraction {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(SeleneTheme.ink, style: StrokeStyle(lineWidth: canvas.u(2), lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(canvas.u(1))
                    }
                    Image(systemName: "icloud").font(.system(size: canvas.u(15)))
                        .foregroundColor(SeleneTheme.ink).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: canvas.u(17), weight: .medium))
                        .foregroundColor(CloudLibraryIndicator.copyColor(indicator.copy))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if indicator.copy == .synchronized {
                        Circle().fill(SeleneTheme.success).frame(width: canvas.u(6), height: canvas.u(6))
                            .padding(canvas.u(2))
                    }
                }
            }
            .frame(width: canvas.u(32), height: canvas.u(32))
            if indicator.progress, let fraction {
                Text(CloudLibraryProgressView.percent(fraction, context: localization))
                    .font(.system(size: canvas.u(11), weight: .semibold).monospacedDigit())
                    .foregroundColor(SeleneTheme.ink)
                    .padding(.horizontal, canvas.u(4)).padding(.vertical, canvas.u(2))
                    .background(SeleneTheme.scrim.opacity(0.94), in: Capsule())
                    .fixedSize()
            }
        }
    }

    static func symbol(for copy: CloudArtifactStatus.State) -> String? {
        switch copy {
        case .synchronized: return "checkmark.icloud"
        case .cloudOnly: return "icloud.and.arrow.down"
        case .newerOnThisMac: return "exclamationmark.icloud"
        case .notInCloud, .unknown: return nil
        }
    }
}
