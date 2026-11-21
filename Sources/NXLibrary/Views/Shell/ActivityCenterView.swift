import SwiftUI
import NXLibraryCore

struct ActivityCenterView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var cloudLibrary: CloudLibraryModel
    let focus: ActivityCenterFocus
    let onFocus: (ActivityCenterFocus.Row) -> Void
    let onSelect: (ActivityCenterFocus.Row) -> Void

    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.nxAppLocale) private var localization

    static func rows(_ viewModel: AppViewModel) -> [ActivityCenterFocus.Row] {
        let cloud = viewModel.cloudLibrary
        return ActivityCenterFocus.rows(isBuilding: viewModel.isBuilding, activeBuild: viewModel.portingGameID,
                                        queuedBuilds: viewModel.buildQueue, activeCloud: cloud.active?.request.token,
                                        queuedCloud: cloud.queue.map(\.token))
    }

    var body: some View {
        let focused = focus.current(in: Self.rows(viewModel))
        ZStack(alignment: .bottom) {
            SeleneTheme.scrim.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onSelect(.close) }
            VStack(spacing: canvas.u(22)) {
                Text(text("Activity center")).seleneFont(34, .semibold)
                VStack(alignment: .leading, spacing: canvas.u(14)) {
                    heading("Compilation")
                    if viewModel.isBuilding {
                        porting(focused: focused)
                    } else if viewModel.buildQueue.isEmpty {
                        caption(text("No compilation"))
                    }
                    if !viewModel.buildQueue.isEmpty {
                        queue(viewModel.buildQueue.map { (.queuedBuild($0), gameName($0)) }, focused: focused)
                    }
                    Divider()
                    heading("Cloud")
                    if let request = cloudLibrary.active?.request {
                        HStack(spacing: canvas.u(22)) {
                            VStack(alignment: .leading, spacing: canvas.u(5)) {
                                Text(gameName(request.id, fallback: request.scope.title)).seleneFont(19, .semibold).lineLimit(1)
                                SeleneStatusDot(text: text("Activity in progress"), color: SeleneTheme.ink)
                                CloudLibraryProgressView(progress: cloudLibrary.states[request.id]?.progress)
                            }
                            button("Cancel", row: .cancelCloud(request.token), focused: focused)
                        }
                    } else if cloudLibrary.queue.isEmpty {
                        caption(text("No cloud transfer"))
                    }
                    if !cloudLibrary.queue.isEmpty {
                        queue(cloudLibrary.queue.map { (.queuedCloud($0.token), gameName($0.id, fallback: $0.scope.title)) },
                              focused: focused)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                button("Close", row: .close, focused: focused)
            }
            .foregroundColor(SeleneTheme.ink)
            .modifier(SeleneDialogCard(width: 920))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SeleneHintsBar(left: [HintItem(.b, text("Close"), action: { onSelect(.close) })],
                           right: [HintItem(.a, text("Select"))])
        }
    }

    private func porting(focused: ActivityCenterFocus.Row) -> some View {
        HStack(spacing: canvas.u(22)) {
            VStack(alignment: .leading, spacing: canvas.u(5)) {
                if let id = viewModel.portingGameID {
                    Text(gameName(id)).seleneFont(19, .semibold).lineLimit(1)
                }
                let stage = viewModel.isCancellingBuild ? text("Cancelling…")
                    : viewModel.buildStages.isEmpty ? text("Preparing") : viewModel.currentStageName
                let fraction = viewModel.portingProgress?.overall ?? 0
                let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(localization.formatLocale))
                caption("\(stage) · \(percent)")
                if let eta = viewModel.portingETAText { caption(eta) }
                AchievementProgressBar(fraction: fraction, height: 6)
            }
            VStack(spacing: canvas.u(8)) {
                button("Open porting", row: .porting, focused: focused)
                if let id = viewModel.portingGameID {
                    button("Cancel", row: .cancelBuild(id), focused: focused, enabled: !viewModel.isCancellingBuild)
                }
            }
        }
    }

    private func queue(_ entries: [(id: ActivityCenterFocus.Row, name: String)], focused: ActivityCenterFocus.Row) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(entries, id: \.id) { entry in
                        HStack(spacing: canvas.u(20)) {
                            VStack(alignment: .leading, spacing: canvas.u(4)) {
                                Text(entry.name).seleneFont(18, .semibold).lineLimit(1)
                                SeleneStatusDot(text: text("Queued"), color: SeleneTheme.ink60)
                            }
                            Spacer()
                            button("Cancel", row: entry.id, focused: focused).accessibilityHint(entry.name)
                        }
                        .padding(.horizontal, canvas.u(12))
                        .frame(height: canvas.u(62))
                        .id(entry.id)
                    }
                }
            }
            .frame(height: canvas.u(CGFloat(min(entries.count, 3) * 70 - 8)))
            .onChange(of: focused) { row in
                if entries.contains(where: { $0.id == row }) { scroll.scrollTo(row) }
            }
        }
    }

    private func button(_ title: String, row: ActivityCenterFocus.Row, focused: ActivityCenterFocus.Row,
                        enabled: Bool = true) -> some View {
        SelenePillButton(title: title, height: 48, focused: focused == row, enabled: enabled) {
            if enabled { onSelect(row) }
        }
            .onHover { if $0 { onFocus(row) } }
    }

    private func gameName(_ id: UUID, fallback: String = "") -> String {
        viewModel.libraryGames.first { $0.id == id }?.name ?? fallback
    }

    private func heading(_ key: String) -> some View { Text(text(key)).seleneFont(23, .semibold) }
    private func caption(_ value: String) -> some View {
        Text(value).seleneFont(16).foregroundColor(SeleneTheme.ink75)
    }
    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}
