import Combine
import Foundation
import NXLibraryCore

/// Owns only the state of the Online services connection; tokens stay in the engine's store.
@MainActor final class NextendoSettings: ObservableObject {
    static let shared = NextendoSettings()
    enum Status: Equatable { case signedOut, signedIn, expired, unavailable }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var account: NextendoAccountSnapshot?
    @Published private(set) var accountName: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isWaitingForBrowser = false
    @Published private(set) var failure: NextendoError?
    private(set) var revision = UUID()
    @Published var isEditingClient = false
    private var operation: Task<Void, Never>?
    private var ticket = UUID()
    private var isSigningOut = false
    private let service = NextendoAccountService()

    func check(clientID: String?) {
        run(checking: true) { model in
            if let clientID {
                try model.apply(await model.service.check(clientID: clientID))
            } else {
                let hasToken = try await Task.detached { try NextendoTokenStore().hasToken() }.value
                try Task.checkCancellation()
                if hasToken { throw NextendoError.clientID }
                try model.apply(nil)
            }
        }
    }

    func signIn(clientID: String?) {
        guard let clientID else { isEditingClient = true; return }
        run { model in
            let (authorization, code) = try await model.authorize(clientID: clientID)
            try Task.checkCancellation()
            model.isWaitingForBrowser = false
            try model.apply(await model.service.signIn(authorization, code: code))
        }
    }

    func signOut() {
        run(signingOut: true) { model in
            try await NextendoOAuth().signOut()
            try model.apply(nil)
        }
    }

    func cancelBrowser() {
        if isWaitingForBrowser { operation?.cancel() }
    }

    func endVisit() {
        if !isSigningOut {
            ticket = UUID()
            operation?.cancel()
            operation = nil
            isBusy = false
            isWaitingForBrowser = false
        }
        account = nil
        accountName = nil
        failure = nil
    }

    func clientChanged() {
        endVisit()
        if status != .signedOut { status = .unavailable }
    }

    private func apply(_ snapshot: NextendoAccountSnapshot?) throws {
        try Task.checkCancellation()
        revision = UUID()
        account = snapshot
        accountName = snapshot?.name
        status = snapshot == nil ? .signedOut : .signedIn
        failure = snapshot?.failure
    }

    private func authorize(clientID: String) async throws -> (NextendoAuthorization, String) {
        isWaitingForBrowser = true
        do { return try await NextendoBrowserSignIn.authorize(clientID: clientID) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NextendoError { throw error }
        catch { throw NextendoError.browser }
    }

    private func run(checking: Bool = false, signingOut: Bool = false,
                     _ work: @escaping @MainActor (NextendoSettings) async throws -> Void) {
        guard !isBusy else { return }
        let ticket = UUID()
        self.ticket = ticket
        isSigningOut = signingOut
        failure = nil
        isBusy = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ticket == ticket {
                    self.isBusy = false
                    self.isWaitingForBrowser = false
                    self.isSigningOut = false
                    self.operation = nil
                }
            }
            do { try await work(self) }
            catch is CancellationError {}
            catch {
                guard self.ticket == ticket, !Task.isCancelled else { return }
                let problem = error as? NextendoError ?? .service
                if problem == .expired {
                    self.status = .expired
                    self.account = nil
                } else if (checking || self.status != .signedOut),
                          problem == .service || problem == .clientID || problem == .storage {
                    self.status = .unavailable
                    self.account = nil
                }
                self.failure = problem
            }
        }
    }
}
