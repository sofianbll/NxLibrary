import NXLibraryCore

struct ControllerIdentity: Equatable {
    let id: ObjectIdentifier
    let name: String?
    let brand: GamepadBrand
    var symbols: [PromptButton: String] = [:]
}

enum ControllerSourceEvent {
    case connected(ControllerIdentity, claimedByGC: Bool = false)
    case disconnected(ObjectIdentifier)
    case input(ObjectIdentifier, ControllerInputChange)
}

/// Sources are started and stopped on the main thread and deliver events there.
protocol ControllerSource: AnyObject {
    var onEvent: ((ControllerSourceEvent) -> Void)? { get set }
    func start()
    func stop()
}
