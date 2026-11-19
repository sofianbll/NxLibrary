import SwiftUI
import NXLibraryCore
import ArcanePorting

/// General, optional connections; moving them here leaves stored credentials and provider behaviour intact.
struct SettingsAPISection: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var settings: AppSettingsStore
    let supportsNextendo: Bool
    let onActions: ([SettingsRowAction]) -> Void
    @Environment(\.seleneCanvas) private var canvas
    @Environment(\.seleneFocusedRowID) private var focusedRow
    @Environment(\.seleneFocusedButton) private var focusedButton
    @Environment(\.nxAppLocale) private var localization
    @ObservedObject private var igdb = IGDBSettings.shared
    @ObservedObject private var nextendo = NextendoSettings.shared

    private var clientID: String? { settings.settings.nextendoClientID ?? NextendoLaunch.buildClientID }
    private var maySignOut: Bool { nextendo.status != .signedOut && !nextendo.isWaitingForBrowser }
    private var canActivateNextendo: Bool { !nextendo.isBusy || nextendo.isWaitingForBrowser }
    private var nextendoAction: String {
        if nextendo.isWaitingForBrowser { return "Cancel" }
        switch nextendo.status {
        case .signedIn, .unavailable: return "Check status"
        case .signedOut, .expired: return "Sign in…"
        }
    }

    private var status: String {
        if nextendo.isWaitingForBrowser { return L10n.text("Waiting for your browser…", context: localization) }
        if nextendo.isBusy { return L10n.text("Checking…", context: localization) }
        switch nextendo.status {
        case .signedOut: return L10n.text("Signed out", context: localization)
        case .signedIn(let name): return L10n.format("Signed in as %@", [name], context: localization)
        case .expired: return L10n.text("Sign-in expired", context: localization)
        case .unavailable: return L10n.text("Could not verify sign-in", context: localization)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: canvas.u(8)) {
            Text(L10n.text("Connect optional services to enrich your library with ratings and artwork. Public sources remain available without API keys."))
                .seleneFont(16)
                .foregroundColor(SeleneTheme.ink60)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, canvas.u(8))

            SettingsSubheading(L10n.text("Ratings"))
            SeleneRow("IGDB", subtitle: igdb.message ?? (igdb.isConfigured
                      ? "IGDB connected · Wikidata is the fallback"
                      : "Optional critic scores with your own credentials")) {
                HStack(spacing: canvas.u(18)) {
                    Button(L10n.text(igdb.isConfigured ? "Edit credentials" : "Connect")) { igdb.isEditing = true }
                        .foregroundColor(SeleneTheme.glyph)
                    if igdb.isConfigured {
                        Button(L10n.text("Remove")) { Task { await igdb.remove() } }
                            .foregroundColor(SeleneTheme.ink60).disabled(igdb.isRemoving)
                    }
                }
                .buttonStyle(.plain).seleneFont(15, .semibold)
            }

            SettingsSubheading(L10n.text("Artwork"))
            SeleneButtonRow("SteamGridDB",
                            subtitle: viewModel.hasSteamGridDBKey
                                ? "Key saved · covers, backgrounds, logos and icons in Change artwork"
                                : "Add your free API key to find art in Change artwork",
                            buttonTitle: viewModel.hasSteamGridDBKey ? "Remove key" : "Add key") {
                steamGridDBAction()
            }

            if supportsNextendo { nextendoRows }
        }
        .onAppear {
            publishActions()
            if supportsNextendo { nextendo.check(clientID: clientID) }
        }
        .onChange(of: igdb.revision) { publishActions() }
        .onChange(of: supportsNextendo) { _, supported in
            if supported { nextendo.check(clientID: clientID) }
            publishActions()
        }
        .onChange(of: clientID) { _, value in
            if supportsNextendo { nextendo.check(clientID: value); publishActions() }
        }
        .onChange(of: nextendo.status) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.isBusy) { if supportsNextendo { publishActions() } }
        .onChange(of: nextendo.isWaitingForBrowser) { if supportsNextendo { publishActions() } }
        .onDisappear { nextendo.cancelBrowser() }
    }

    @ViewBuilder private var nextendoRows: some View {
        SettingsSubheading(L10n.text("Online play", context: localization))
        SeleneRow("Nextendo", subtitle: "Free community online play for compatible nxnative games. Requires a Nextendo account.") {
            VStack(alignment: .trailing, spacing: canvas.u(4)) {
                Text(status).seleneFont(15).foregroundColor(SeleneTheme.ink60)
                HStack(spacing: canvas.u(8)) {
                    connectionButton(nextendoAction, index: 0, action: activateNextendo)
                    if maySignOut {
                        connectionButton("Sign out", index: 1, action: nextendo.signOut)
                    }
                }
            }
        }
        if let failure = nextendo.failure {
            Text(failure.localizedDescription)
                .seleneFont(15)
                .foregroundColor(SeleneTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        SeleneRow("Nextendo client ID", subtitle: "Public OAuth client ID for sign-in and online play. Clear the field to use the build default.") {
            Text(clientID ?? L10n.text("Not set", context: localization))
                .seleneFont(15)
                .foregroundColor(SeleneTheme.ink60)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: canvas.u(200))
            Button(L10n.text("Edit", context: localization)) { nextendo.isEditingClient = true }
                .buttonStyle(.plain)
                .seleneFont(15, .semibold)
                .foregroundColor(SeleneTheme.glyph)
                .disabled(nextendo.isBusy)
        }
    }

    private func connectionButton(_ title: String, index: Int, action: @escaping () -> Void) -> some View {
        Button(L10n.text(title, context: localization), action: action)
            .buttonStyle(.plain)
            .seleneFont(15, .semibold)
            .foregroundColor(SeleneTheme.glyph)
            .padding(.horizontal, canvas.u(8))
            .padding(.vertical, canvas.u(4))
            .overlay(Capsule().strokeBorder(SeleneTheme.focus, lineWidth: canvas.u(2))
                .opacity(maySignOut && focusedRow == "Nextendo" && focusedButton == index ? 1 : 0))
            .disabled(!canActivateNextendo)
    }

    private func activateNextendo() {
        if nextendo.isWaitingForBrowser { nextendo.cancelBrowser(); return }
        switch nextendo.status {
        case .signedIn, .unavailable: nextendo.check(clientID: clientID)
        case .signedOut, .expired: nextendo.signIn(clientID: clientID)
        }
    }
    private func steamGridDBAction() {
        if viewModel.hasSteamGridDBKey { viewModel.removeSteamGridDBKey() }
        else { viewModel.isEditingSteamGridDBKey = true }
    }
    private func publishActions() {
        var actions: [SettingsRowAction] = [
            .init(id: "IGDB", title: "IGDB",
                  secondary: igdb.isConfigured ? (title: "Remove", activate: { Task { await igdb.remove() }; return }) : nil) {
                igdb.isEditing = true
            },
            .init(id: "SteamGridDB", title: "SteamGridDB") { steamGridDBAction() },
        ]
        if supportsNextendo {
            let secondary: (title: String, activate: () -> Void)? = maySignOut
                ? ("Sign out", { nextendo.signOut() }) : nil
            actions.append(SettingsRowAction(id: "nextendo", title: "Nextendo", isEnabled: canActivateNextendo,
                                             secondary: secondary) { activateNextendo() })
            actions.append(.init(id: "nextendoClientID", title: "Nextendo client ID", isEnabled: !nextendo.isBusy) {
                nextendo.isEditingClient = true
            })
        }
        onActions(actions)
    }
}
