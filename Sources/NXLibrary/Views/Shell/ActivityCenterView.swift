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

    private var focusedRow: ActivityCenterFocus.Row {
        focus.current(in: ActivityCenterFocus.rows(isBuilding: viewModel.isBuilding, queued: cloudLibrary.queue.map(\.token)))
    }

    var body: some View {
        let focused = focusedRow
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
                    } else {
                        caption(text("No compilation"))
                    }
                    Divider()
                    heading("Cloud")
                    if let request = cloudLibrary.active?.request {
                        let progress = cloudLibrary.states[request.id]?.progress
                        Text(gameName(request)).seleneFont(19, .semibold).lineLimit(1)
                        SeleneStatusDot(text: text("Activity in progress"), color: SeleneTheme.ink)
                        CloudLibraryProgressView(progress: progress)
                    } else if cloudLibrary.queue.isEmpty {
                        caption(text("No cloud transfer"))
                    }
                    if !cloudLibrary.queue.isEmpty { queue(focused: focused) }
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
                if let game = viewModel.libraryGames.first(where: { $0.id == viewModel.portingGameID }) {
                    Text(game.name).seleneFont(19, .semibold).lineLimit(1)
                }
                let stage = viewModel.isCancellingBuild ? text("Cancelling…")
                    : viewModel.buildStages.isEmpty ? text("Preparing") : viewModel.currentStageName
                let fraction = viewModel.portingProgress?.overall ?? 0
                let percent = fraction.formatted(.percent.precision(.fractionLength(0)).locale(localization.formatLocale))
                caption("\(stage) · \(percent)")
                if let eta = viewModel.portingETAText { caption(eta) }
                AchievementProgressBar(fraction: fraction, height: 6)
            }
            button("Open porting", row: .porting, focused: focused)
        }
    }

    private func queue(focused: ActivityCenterFocus.Row) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: canvas.u(8)) {
                    ForEach(cloudLibrary.queue, id: \.token) { request in
                        let name = gameName(request)
                        HStack(spacing: canvas.u(20)) {
                            VStack(alignment: .leading, spacing: canvas.u(4)) {
                                Text(name).seleneFont(18, .semibold).lineLimit(1)
                                SeleneStatusDot(text: text("Queued"), color: SeleneTheme.ink60)
                            }
                            Spacer()
                            button("Cancel", row: .queued(request.token), focused: focused).accessibilityHint(name)
                        }
                        .padding(.horizontal, canvas.u(12))
                        .frame(height: canvas.u(62))
                        .id(ActivityCenterFocus.Row.queued(request.token))
                    }
                }
            }
            .frame(height: canvas.u(CGFloat(min(cloudLibrary.queue.count, 4) * 70 - 8)))
            .onChange(of: focused) { row in
                if case .queued = row { scroll.scrollTo(row) }
            }
        }
    }

    private func button(_ title: String, row: ActivityCenterFocus.Row, focused: ActivityCenterFocus.Row) -> some View {
        SelenePillButton(title: title, height: 48, focused: focused == row) { onSelect(row) }
            .onHover { if $0 { onFocus(row) } }
    }

    private func gameName(_ request: CloudLibraryModel.Request) -> String {
        viewModel.libraryGames.first { $0.id == request.id }?.name ?? request.scope.title
    }

    private func heading(_ key: String) -> some View { Text(text(key)).seleneFont(23, .semibold) }
    private func caption(_ value: String) -> some View {
        Text(value).seleneFont(16).foregroundColor(SeleneTheme.ink75)
    }
    private func text(_ key: String) -> String { L10n.text(key, context: localization) }
}
