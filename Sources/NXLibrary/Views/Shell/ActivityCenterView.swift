import SwiftUI
import NXLibraryCore
import ArcanePorting

struct ActivityCenterView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var porting: PortingModel
    @ObservedObject var cloudLibrary: CloudLibraryModel
    let focus: ActivityCenterFocus
    let onFocus: (ActivityCenterFocus.Row) -> Void
    let onOpen: (ActivityCenterFocus.Row) -> Void
    let onCancel: (ActivityCenterFocus.Row) -> Void
    let onClose: () -> Void

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    static func rows(_ viewModel: AppViewModel) -> [ActivityCenterFocus.Row] {
        let cloud = viewModel.cloudLibrary
        return ActivityCenterFocus.rows(isBuilding: viewModel.isBuilding, activeBuild: viewModel.portingGameID,
                                        queuedBuilds: viewModel.buildQueue, activeCloud: cloud.active?.request.token,
                                        queuedCloud: cloud.queue.map(\.token))
    }

    var body: some View {
        let rows = Self.rows(viewModel)
        let focused = focus.current(in: rows)
        ZStack(alignment: .bottom) {
            SeleneTheme.scrim65.ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: canvas.u(20)) {
                Text(text("Activity center")).seleneFont(30, .semibold)
                    .accessibilityAddTraits(.isHeader)
                section("Compilation", empty: "No compilation", rows: rows.filter(\.opensPorting), focused: focused)
                section("Cloud", empty: "No cloud transfer", rows: rows.filter { !$0.opensPorting }, focused: focused)
            }
            .foregroundColor(SeleneTheme.ink)
            .multilineTextAlignment(.leading)
            .modifier(SeleneDialogCard(width: 920))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SeleneHintsBar(left: [HintItem(.b, "Close", action: onClose)],
                           right: hints(focused))
        }
        .accessibilityAction(.escape, onClose)
    }

    private func hints(_ row: ActivityCenterFocus.Row) -> [HintItem] {
        [
            row.opensPorting ? HintItem(.a, "Open", action: { onOpen(row) }) : nil,
            row.canCancel(isCancellingBuild: porting.isCancellingBuild) ? HintItem(.x, "Cancel", action: { onCancel(row) }) : nil
        ].compactMap { $0 }
    }

    private func section(_ key: String, empty: String, rows: [ActivityCenterFocus.Row],
                         focused: ActivityCenterFocus.Row) -> some View {
        VStack(alignment: .leading, spacing: canvas.u(8)) {
            Text(text(key)).seleneFont(12, .bold).tracking(canvas.u(1.4))
                .textCase(.uppercase).foregroundColor(SeleneTheme.ink60)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(text(empty)).seleneFont(15).foregroundColor(SeleneTheme.ink60)
                    .padding(.vertical, canvas.u(4))
            } else if rows.count <= 3 {
                rowList(rows, focused: focused)
            } else {
                ScrollViewReader { scroll in
                    ScrollView { rowList(rows, focused: focused) }
                        .frame(height: canvas.u(270))
                        .onAppear { if rows.contains(focused) { scroll.scrollTo(focused) } }
                        .onChange(of: focused) { _, row in
                            if rows.contains(row) { scroll.scrollTo(row) }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowList(_ rows: [ActivityCenterFocus.Row], focused: ActivityCenterFocus.Row) -> some View {
        VStack(spacing: canvas.u(8)) {
            ForEach(rows, id: \.self) { row in
                let job = job(row)
                ActivityRow(title: job.title, detail: job.detail, fraction: job.fraction, active: job.active,
                            focused: focused == row, canCancel: row.canCancel(isCancellingBuild: porting.isCancellingBuild),
                            open: row.opensPorting ? { onOpen(row) } : nil, cancel: { onCancel(row) })
                    .id(row)
                    .onHover { if $0 { onFocus(row) } }
            }
        }
    }

    private func job(_ row: ActivityCenterFocus.Row) -> (title: String, detail: String?, fraction: Double?, active: Bool) {
        switch row {
        case .build(let id):
            let progress = viewModel.portingProgress
            let fraction = progress?.activityFraction
            let stage = porting.isCancellingBuild ? text("Cancelling…")
                : progress?.isUpdatingShaderCache == true ? text("Updating shader cache")
                : BuildStageCopy.title(porting.currentStageName, context: localization)
            let eta = porting.isCancellingBuild ? nil : progress.flatMap {
                PortingETA.text($0, lastFinishingSeconds: viewModel.lastPortingFinishSeconds,
                                context: localization, compact: true)
            }
            return (gameName(id, fallback: "Compilation"), detail(stage, fraction, eta), fraction, true)
        case .queuedBuild(let id):
            return (gameName(id, fallback: "Compilation"), nil, nil, false)
        case .cloud:
            guard let request = cloudLibrary.active?.request else { return (text("Cloud"), nil, nil, true) }
            let progress = cloudLibrary.states[request.id]?.progress
            let fraction = CloudLibraryProgressView.fraction(progress)
            let stage = text(progress.map(CloudLibraryProgressView.phaseKey) ?? "Preparing cloud operation…")
            return (gameName(request.id, fallback: request.scope.title),
                    detail(stage, fraction, CloudLibraryProgressView.estimate(progress, context: localization, compact: true)),
                    fraction, true)
        case .queuedCloud(let token):
            guard let request = cloudLibrary.queue.first(where: { $0.token == token }) else {
                return (text("Cloud"), nil, nil, false)
            }
            return (gameName(request.id, fallback: request.scope.title), nil, nil, false)
        case .close: return ("", nil, nil, false)
        }
    }

    private func detail(_ stage: String, _ fraction: Double?, _ eta: String?) -> String {
        [stage, fraction.map { CloudLibraryProgressView.percent($0, context: localization) }, eta]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func gameName(_ id: UUID?, fallback: String) -> String {
        viewModel.libraryGames.first { $0.id == id }?.name ?? text(fallback)
    }

    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}

private struct ActivityRow: View {
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization
    let title: String
    let detail: String?
    let fraction: Double?
    let active: Bool
    let focused: Bool
    let canCancel: Bool
    let open: (() -> Void)?
    let cancel: () -> Void

    var body: some View {
        Group {
            if let open {
                Button(action: open) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.text("Open porting", context: localization))
            } else {
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            SelenePillButton.roundIcon(.close, enabled: canCancel, action: cancel)
                .disabled(!canCancel)
                .help(L10n.text("Cancel", context: localization))
                .accessibilityLabel(L10n.text("Cancel", context: localization))
                .accessibilityHint(title)
        }
        .modifier(SeleneOptionRowSurface(focused: focused))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: canvas.u(8)) {
            HStack(spacing: canvas.u(18)) {
                VStack(alignment: .leading, spacing: canvas.u(3)) {
                    Text(title).seleneFont(17, .semibold).lineLimit(1)
                    if let detail {
                        Text(detail).seleneFont(15).foregroundColor(SeleneTheme.ink60).lineLimit(1)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: .leading) {
                    status(!active).hidden().accessibilityHidden(true)
                    status(active)
                }
                .fixedSize()
            }
            .padding(.trailing, canvas.u(62))
            .frame(minHeight: canvas.u(44))
            if let fraction, fraction > 0 {
                AchievementProgressBar(fraction: fraction, height: 4)
            }
        }
        .contentShape(Rectangle())
    }

    private func status(_ active: Bool) -> some View {
        SeleneStatusDot(text: L10n.text(active ? "In progress" : "Queued", context: localization),
                        color: active ? SeleneTheme.ink : SeleneTheme.ink60)
    }
}
