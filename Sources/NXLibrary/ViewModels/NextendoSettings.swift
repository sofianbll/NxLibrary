import Combine
import NXLibraryCore
import ArcanePorting

/// Owns only the state of the Online services connection; tokens stay in the engine's store.
@MainActor final class NextendoSettings: ObservableObject {
    static let shared = NextendoSettings()
    enum Status: Equatable { case signedOut, signedIn(String), expired, unavailable }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var isBusy = false
    @Published private(set) var isWaitingForBrowser = false
    @Published private(set) var failure: NextendoError?
    @Published var isEditingClient = false
    private var operation: Task<Void, Never>?

    func check(clientID: String?) {
        run { model in
            let store = NextendoTokenStore()
            guard try await Task.detached(operation: { try store.hasToken() }).value else {
                model.status = .signedOut
                return
            }
            model.status = .unavailable
            guard let clientID else {
                throw NextendoError.clientID
            }
            model.status = try await NextendoOAuth(store: store).accountName(clientID: clientID)
                .map(Status.signedIn) ?? .signedOut
        }
    }

    func signIn(clientID: String?) {
        guard let clientID else { isEditingClient = true; return }
        run { model in
            let (authorization, code) = try await model.authorize(clientID: clientID)
            model.status = .signedIn(try await NextendoOAuth().signIn(authorization, code: code))
        }
    }

    func signOut() {
        run { model in
            try await NextendoOAuth().signOut()
            model.status = .signedOut
        }
    }

    func cancelBrowser() {
        if isWaitingForBrowser { operation?.cancel() }
    }

    private func authorize(clientID: String) async throws -> (NextendoAuthorization, String) {
        isWaitingForBrowser = true
        defer { isWaitingForBrowser = false }
        do { return try await NextendoBrowserSignIn.authorize(clientID: clientID) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NextendoError { throw error }
        catch { throw NextendoError.browser }
    }

    private func run(_ work: @escaping @MainActor (NextendoSettings) async throws -> Void) {
        guard !isBusy else { return }
        failure = nil
        isBusy = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.operation = nil }
            do { try await work(self) }
            catch is CancellationError {}
            catch {
                let problem = error as? NextendoError ?? .service
                if problem == .expired { self.status = .expired }
                else if case .signedIn = self.status, problem == .service { self.status = .unavailable }
                self.failure = problem
            }
        }
    }
}
