import Foundation
import AppKit
import NXLibraryCore

public final class GameControllerService: ObservableObject {
    public static let shared = GameControllerService()

    @Published public var isGamepadConnected: Bool = false
    @Published public var activeControllerName: String = "No Gamepad Connected"
    @Published public var activeBrand: GamepadBrand = .generic
    /// Reported glyphs (including system remapping); the brand supplies missing glyphs.
    @Published public var buttonSymbols: [PromptButton: String] = [:]

    public var onAction: ((GamepadAction) -> Void)?

    private let deadzoneKey = "NXNative_ControllerDeadzone"
    @Published public var deadzone: Float = 0.35 {
        didSet {
            let clamped = min(max(deadzone, 0.10), 0.80)
            AppData.preferences.set(Double(clamped), forKey: deadzoneKey)
        }
    }

    public var navigationInterval: TimeInterval = 0.12
    private var isAppActive = true
    private var lastNavTime: TimeInterval = 0

    private let gcSource = GCControllerSource()
    private let hidSource = HIDControllerSource()
    private var gcPad: ControllerIdentity?
    private struct HIDPad {
        let identity: ControllerIdentity
        var admission: ControllerArbitration.HID
    }
    private var hidPads: [HIDPad] = []
    private var fallbackTimer: Timer?
    private var activePad: ControllerIdentity?
    private var inputGeneration = 0

    private var holds = ControllerHolds()
    private var holdTimer: Timer?

    private init() {
        if AppData.preferences.object(forKey: deadzoneKey) != nil {
            deadzone = min(max(Float(AppData.preferences.double(forKey: deadzoneKey)), 0.10), 0.80)
        }
        isAppActive = NSApplication.shared.isActive
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAppActive = true
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAppActive = false
        }
        gcSource.onEvent = { [weak self] in self?.handle($0, fromHID: false) }
        hidSource.onEvent = { [weak self] in self?.handle($0, fromHID: true) }
        gcSource.start()
        hidSource.start()
    }

    public func refreshControllers() {
        gcSource.refresh()
        hidSource.start()
        selectController()
    }

    private func handle(_ event: ControllerSourceEvent, fromHID: Bool) {
        switch event {
        case let .connected(identity, claimedByGC):
            if fromHID {
                hidPads.append(HIDPad(identity: identity,
                                      admission: .init(name: identity.name, claimedByGC: claimedByGC,
                                                       connectedAt: ProcessInfo.processInfo.systemUptime)))
            } else {
                gcPad = identity
            }
        case let .disconnected(id):
            if fromHID {
                hidPads.removeAll { $0.identity.id == id }
            } else {
                guard gcPad?.id == id else { return }
                gcPad = nil
            }
        case let .input(id, input):
            if activePad?.id == id { handleInput(input) }
            return
        }
        selectController()
    }

    private func selectController() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        let now = ProcessInfo.processInfo.systemUptime
        let gcNames = gcPad?.name.map { [$0] } ?? []
        var eligible: [ControllerIdentity] = []
        var deadline: TimeInterval?
        for index in hidPads.indices {
            switch hidPads[index].admission.admission(gcNames: gcNames, at: now) {
            case .gameController: break
            case .hid: eligible.append(hidPads[index].identity)
            case let .wait(until): deadline = min(deadline ?? until, until)
            }
        }
        switch ControllerArbitration.preferred(hasGameController: gcPad != nil, hasHID: !eligible.isEmpty) {
        case .gameController:
            hidSource.select(nil)
            setActive(gcPad)
            return
        case .hid:
            if let activePad, eligible.contains(activePad) { return }
            setActive(eligible.first { hidSource.select($0.id) })
        case .wait, nil:
            setActive(nil)
        }
        if activePad == nil, let deadline {
            let timer = Timer(timeInterval: max(0, deadline - now), repeats: false) { [weak self] _ in
                self?.refreshControllers()
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func setActive(_ pad: ControllerIdentity?) {
        if activePad?.id != pad?.id {
            inputGeneration += 1
            holds.reset()
            stopHoldTimerIfIdle()
            lastNavTime = 0
        }
        guard activePad != pad else { return }
        activePad = pad
        isGamepadConnected = pad != nil
        activeControllerName = pad.map { $0.name ?? L10n.text("Gamepad") } ?? "No Gamepad Connected"
        activeBrand = pad?.brand ?? .generic
        buttonSymbols = pad?.symbols ?? [:]
    }

    private func handleInput(_ input: ControllerInputChange) {
        switch input {
        case let .leftStick(stick):
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastNavTime > navigationInterval else { return }
            let action: GamepadAction
            if stick.x > deadzone { action = .navigateRight }
            else if stick.x < -deadzone { action = .navigateLeft }
            else if stick.y > deadzone { action = .navigateUp }
            else if stick.y < -deadzone { action = .navigateDown }
            else { return }
            lastNavTime = now
            triggerAction(action)
        case let .button(button, pressed):
            if button == .menu || button == .view {
                let result = holds.update(button, pressed: pressed, at: ProcessInfo.processInfo.systemUptime)
                if pressed { startHoldTimer() } else { stopHoldTimerIfIdle() }
                if let result { triggerHoldAction(button, result: result) }
                return
            }
            guard pressed else { return }
            switch button {
            case .up: triggerAction(.navigateUp)
            case .down: triggerAction(.navigateDown)
            case .left: triggerAction(.navigateLeft)
            case .right: triggerAction(.navigateRight)
            case .a: triggerAction(.confirm)
            case .b: triggerAction(.cancel)
            case .x: triggerAction(.secondaryAction)
            case .y: triggerAction(.contextAction)
            case .l: triggerAction(.tabPrevious)
            case .r: triggerAction(.tabNext)
            case .zl: triggerAction(.jumpToStart)
            case .zr: triggerAction(.jumpToEnd)
            case .r3: triggerAction(.rightStickPress)
            case .menu, .view, .l3, .home, .capture: break
            }
        }
    }

    private func triggerHoldAction(_ button: ControllerButton, result: HoldResult) {
        if button == .menu {
            triggerAction(result == .tap ? .menu : .menuHold)
        } else {
            triggerAction(result == .tap ? .view : .viewHold)
        }
    }

    private func startHoldTimer() {
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            for button in self.holds.tick(at: ProcessInfo.processInfo.systemUptime) {
                self.triggerHoldAction(button, result: .hold)
            }
            self.stopHoldTimerIfIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func stopHoldTimerIfIdle() {
        guard !holds.isPressed else { return }
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func triggerAction(_ action: GamepadAction) {
        let generation = inputGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAppActive, self.inputGeneration == generation else { return }
            self.onAction?(action)
        }
    }
}
