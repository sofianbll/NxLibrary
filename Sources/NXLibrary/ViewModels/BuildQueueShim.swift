import Foundation

// BUILD-QUEUE-SHIM
extension AppViewModel {
    var buildQueue: [UUID] { [] }
    func cancelQueuedBuild(_ id: UUID) {}
}
