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
    @State private var freeSelection: CloudFreeSelection?
    @State private var freeFocus: FreeControl = .cancel

    private struct ReadRequest: Equatable {
        let game: PortedGame
        let revision: Int
    }

    private enum Control: Hashable {
        case upload(CloudArtifactKind?), download(CloudArtifactKind), uploadSources, downloadSources
        case free, cancel, refresh, settings, close
    }

    private enum FreeControl: Equatable { case item(CloudLibraryItem), cancel, confirm }

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
            .allowsHitTesting(freeSelection == nil)
            .accessibilityHidden(freeSelection != nil)
            if let freeSelection { freeDialog(freeSelection) }
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
                ForEach(CloudLibraryItem.allCases, id: \.self) { item in
                    artifactRow(item)
                }
            }
            if let message = state.message {
                Text(message).seleneFont(15).foregroundColor(PortingPillCopy.softRed)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controls.contains(where: { [.close, .settings, .refresh, .free, .upload(nil)].contains($0) }) {
                HStack(spacing: canvas.u(10)) {
                    if !showHints { button(.close, "Close") }
                    if controls.contains(.settings) { button(.settings, "Open settings") }
                    if controls.contains(.refresh) { button(.refresh, "Refresh") }
                    if controls.contains(.free) { button(.free, "Free up space") }
                    if controls.contains(.upload(nil)) {
                        button(.upload(nil), state.needsCombinedUpload ? "Send the app and cache" : "Send update")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .modifier(SeleneDialogCard())
    }

    private func artifactRow(_ item: CloudLibraryItem) -> some View {
        let title = text(item.title)
        let copy = item.artifact.flatMap { state.copies[$0] }
        let live = state.activeItem == item && !state.queued
        let size = state.bytes(item).map(formattedBytes)
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
                    CloudLibraryIndicator(state: state, item: item).dot(context: localization, title: title)
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
                if let control = artifactControl(item) {
                    switch control {
                    case .cancel: button(.cancel, "Cancel")
                    case .upload, .uploadSources: button(control, "Send")
                    default: button(control, "Download")
                    }
                }
            }
            if let path = cloudPath(item) {
                Text(verbatim: path)
                    .seleneFont(13)
                    .foregroundColor(SeleneTheme.ink60)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            }
            if live {
                CloudLibraryProgressView(progress: state.progress, showsSummary: false)
            } else if let issue = state.issue, issue.item == item {
                Text(issue.message).seleneFont(15)
                    .foregroundColor(issue.failed ? PortingPillCopy.softRed : SeleneTheme.ink60)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item == .sources, let message = state.sourcesMessage {
                Text(message).seleneFont(15).foregroundColor(PortingPillCopy.softRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(canvas.u(12))
        .background(SeleneTheme.glassLight, in: RoundedRectangle(cornerRadius: canvas.u(SeleneTheme.rowRadius)))
    }

    private func cloudPath(_ item: CloudLibraryItem) -> String? {
        let base: String, folder: String
        if let kind = item.artifact {
            guard let storage = model.preference.storage, let title = game.titleId else { return nil }
            base = storage
            folder = "\(title.uppercased())/\(kind.rawValue)"
        } else {
            guard let storage = model.preference.sourcesStorage, let files = CloudSourceFiles(game) else { return nil }
            base = storage
            folder = files.folderName
        }
        return base + (base.hasSuffix("/") ? "" : "/") + folder + "/"
    }

    private func artifactControl(_ item: CloudLibraryItem) -> Control? {
        if state.activeItem == item { return .cancel }
        guard canChange else { return nil }
        guard let kind = item.artifact else {
            switch state.sources?.state {
            case .notInCloud: return GameResourceState.sourcesAvailable(for: game) ? .uploadSources : nil
            case .cloudOnly: return .downloadSources
            default: return nil
            }
        }
        switch state.copies[kind]?.state {
        case .cloudOnly: return .download(kind)
        default: return state.canUpload(kind) ? .upload(kind) : nil
        }
    }

    private var controls: [Control] {
        let close: [Control] = showHints ? [] : [.close]
        if model.archive == nil { return close + [.settings] }
        if unavailable != nil { return close }
        let artifacts = CloudLibraryItem.allCases.compactMap(artifactControl)
        if state.action != nil || state.refreshing { return artifacts + close }
        var buttons = artifacts + close
        if state.message != nil || state.sourcesMessage != nil { buttons.append(.settings) }
        buttons.append(.refresh)
        if canChange && !CloudFreeSelection(state: state).available.isEmpty { buttons.append(.free) }
        if canChange && state.canUploadBoth { buttons.append(.upload(nil)) }
        return buttons
    }

    private func button(_ control: Control, _ key: String) -> some View {
        SelenePillButton(title: key, minWidth: 96, height: 36, horizontalPadding: 14,
                         focused: (focus ?? controls.first) == control, action: { choose(control) })
            .onHover { if $0 { focus = control } }
    }

    private func handle(_ action: GamepadAction) {
        if let freeSelection { handleFree(action, selection: freeSelection); return }
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
        case .upload(let kind): viewModel.performCloudLibrary(.upload(kind), for: game)
        case .uploadSources: viewModel.performCloudLibrary(.uploadSources, for: game)
        case .downloadSources: viewModel.performCloudLibrary(.downloadSources, for: game)
        case .free:
            freeFocus = .cancel
            freeSelection = CloudFreeSelection(state: state)
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

    private func freeDialog(_ selection: CloudFreeSelection) -> some View {
        ZStack {
            SeleneTheme.scrim45.ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { freeSelection = nil }
            SeleneConfirmDialog(title: "Free up space",
                message: text("Moves to the Trash. Empty it to reclaim space. Everything stays available to download."),
                confirmTitle: "Free up space", confirmEnabled: !selection.selected.isEmpty,
                highlightsPills: freeFocus == .cancel || freeFocus == .confirm,
                focus: Binding(get: { freeFocus == .confirm ? .confirm : .cancel },
                               set: { freeFocus = $0 == .cancel ? .cancel : .confirm }),
                onCancel: { freeSelection = nil }, onConfirm: confirmFree) {
                VStack(spacing: canvas.u(6)) {
                    ForEach(CloudLibraryItem.allCases, id: \.self) { item in
                        let size = selection.sizes[item].map(formattedBytes) ?? "—"
                        SeleneRow(item.title, subtitle: size, verbatimSubtitle: true) {
                            SeleneSwitch(isOn: Binding(get: { freeSelection?.selected.contains(item) == true },
                                                       set: { _ in freeSelection?.toggle(item) }))
                                .disabled(!selection.allows(item))
                                .accessibilityLabel(text(item.title))
                        }
                        .environment(\.seleneFocusedRowID, freeFocus == .item(item) ? item.title : nil)
                        .onHover { if $0 && selection.allows(item) { freeFocus = .item(item) } }
                    }
                }
                .padding(.top, canvas.u(18))
            }
        }
    }

    private func handleFree(_ action: GamepadAction, selection: CloudFreeSelection) {
        let choices = CloudLibraryItem.allCases.filter(selection.allows).map(FreeControl.item)
            + [.cancel] + (selection.selected.isEmpty ? [] : [.confirm])
        switch action {
        case .cancel: freeSelection = nil
        case .confirm:
            switch freeFocus {
            case .cancel: freeSelection = nil
            case .confirm: confirmFree()
            case .item(let item):
                freeSelection?.toggle(item)
                SoundEffectService.shared.play(.key)
            }
        case .navigateLeft, .navigateUp, .navigateRight, .navigateDown:
            var index = FocusIndex(index: choices.firstIndex(of: freeFocus) ?? (choices.count - 1))
            index.move(by: action == .navigateLeft || action == .navigateUp ? -1 : 1, count: choices.count)
            let next = choices[index.index]
            if next != freeFocus { SoundEffectService.shared.play(.focus); freeFocus = next }
        default: break
        }
    }

    private func confirmFree() {
        guard let selection = freeSelection, !selection.selected.isEmpty else { return }
        freeSelection = nil
        viewModel.performCloudLibrary(.free(selection.selected), for: game)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(localization.formatLocale))
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
        case (.uploading, .cache): return "Uploading cache"
        case (.uploading, nil): return "Uploading game files"
        case (.verifying, .app): return "Verifying app"
        case (.verifying, .cache): return "Verifying cache"
        case (.verifying, nil): return "Verifying cloud copy"
        case (.downloading, .app): return "Downloading app"
        case (.downloading, .cache): return "Downloading cache"
        case (.downloading, nil): return "Downloading game files"
        case (.restoring, .app): return "Restoring app"
        case (.restoring, _): return "Restoring cache"
        }
    }

}

/// Shared cloud copy vocabulary. An artifact row only shows its own transfer or failure.
struct CloudLibraryIndicator {
    let state: CloudLibraryState
    var item: CloudLibraryItem? = nil

    private var showsAction: Bool {
        guard let active = state.activeItem else { return false }
        return item.map { $0 == active } ?? (active != .sources)
    }
    var progress: Bool { (showsAction || sentAwaitingPublish) && !state.queued }
    /// A full upload sends the app, then the cache; the app becomes the cloud copy only when the manifest is published at the end.
    private var sentAwaitingPublish: Bool {
        item == .app && state.action == .upload(nil) && state.activeItem == .cache
    }
    var queued: Bool { showsAction && state.queued }
    var copy: CloudArtifactStatus.State { state.copy(item ?? .app) ?? .unknown }
    // Bound once: comparing two optional-chained tuple fields crashes Swift 6.4.2's Release optimizer (SemanticARCOpts).
    private var failed: Bool {
        guard let issue = state.issue, issue.failed else { return false }
        return item.map { $0 == issue.item } ?? (issue.item != .sources)
    }

    var color: Color {
        if queued { return SeleneTheme.ink60 }
        if progress { return SeleneTheme.ink }
        if failed { return PortingPillCopy.softRed }
        return Self.copyColor(copy)
    }

    /// The Details and Spotlight pill: one Material glyph drawn like the favorite heart (white, dark when focused).
    var pillIcon: MaterialIcon {
        if queued { return .cloudQueue }
        if progress {
            switch state.action {
            case .upload, .uploadSources: return .cloudUpload
            default: return .cloudDownload
            }
        }
        switch copy {
        case .synchronized: return .cloudDone
        case .cloudOnly: return .cloudDownload
        case .newerOnThisMac: return .cloudUpload
        case .notInCloud, .unknown: return .cloud
        }
    }

    static func copyColor(_ copy: CloudArtifactStatus.State) -> Color {
        switch copy {
        case .synchronized: return SeleneTheme.statusOK
        case .cloudOnly: return SeleneTheme.statusCloud
        case .newerOnThisMac: return SeleneTheme.untested
        case .notInCloud, .unknown: return SeleneTheme.ink60
        }
    }

    func label(context: AppLocale, showingFailure: Bool = true) -> String {
        if queued { return L10n.text("Queued", context: context) }
        if progress {
            if sentAwaitingPublish { return L10n.text("Sent · published when the upload ends", context: context) }
            if let fraction = CloudLibraryProgressView.fraction(state.progress) {
                let key = state.progress?.phase == .uploading || state.action == .uploadSources ? "Sending %@" : "Downloading %@"
                return L10n.format(key, [CloudLibraryProgressView.percent(fraction, context: context)], context: context)
            }
            return L10n.text(state.progress.map(CloudLibraryProgressView.phaseKey) ?? "Preparing cloud operation…", context: context)
        }
        if failed && showingFailure { return L10n.text("Cloud operation failed", context: context) }
        let key: String
        switch copy {
        case .synchronized: key = "Synchronized"
        case .cloudOnly: key = "Cloud only"
        case .newerOnThisMac:
            key = item == .sources ? "Different in the cloud. Nothing is overwritten." : "Newer on this Mac"
        case .notInCloud: key = "Not in the cloud"
        case .unknown: key = state.refreshing ? "Checking…" : "Cloud status unknown"
        }
        return L10n.text(key, context: context)
    }

    func dot(context: AppLocale, title: String? = nil) -> some View {
        SeleneStatusDot(text: label(context: context), color: color,
                        labelColor: failed && !progress && !queued ? PortingPillCopy.softRed : SeleneTheme.ink90,
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
        let badge = state.map { CloudLibraryBadge(indicator: CloudLibraryIndicator(state: $0)) }
        content.overlay(alignment: .topTrailing) {
            if let badge, badge.isVisibleOnTile {
                badge
                    .padding(canvas.u(10))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(badge?.isVisibleOnTile == true
                            ? badge?.indicator.label(context: localization, showingFailure: false) ?? "" : "")
    }
}

/// Same glyph, ring and percentage on tiles and in the Details pill.
struct CloudLibraryBadge: View {
    let indicator: CloudLibraryIndicator
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    var isVisibleOnTile: Bool { indicator.progress || indicator.queued || symbol != nil }

    var body: some View {
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
                } else if indicator.queued {
                    Image(systemName: "clock").font(.system(size: canvas.u(15)))
                        .foregroundColor(indicator.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: symbol ?? "icloud").font(.system(size: canvas.u(17), weight: .medium))
                        .foregroundColor(CloudLibraryIndicator.copyColor(indicator.copy))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if indicator.copy == .synchronized {
                        Circle().fill(SeleneTheme.statusOK).frame(width: canvas.u(6), height: canvas.u(6))
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

    private var symbol: String? {
        switch indicator.copy {
        case .synchronized: return "checkmark.icloud"
        case .cloudOnly: return "icloud.and.arrow.down"
        case .newerOnThisMac: return "exclamationmark.icloud"
        case .notInCloud, .unknown: return nil
        }
    }
}
