import Foundation
import AppKit
import NXLibraryCore

final class GameControllerService: ObservableObject {
    static let shared = GameControllerService()

    @Published var isGamepadConnected: Bool = false
    @Published var activeControllerName: String = "No Gamepad Connected"
    @Published var activeBrand: GamepadBrand = .generic
    /// Reported glyphs (including system remapping); the brand supplies missing glyphs.
    @Published var buttonSymbols: [PromptButton: String] = [:]
    @Published private(set) var menuHoldStartedAt: TimeInterval?

    var onAction: ((GamepadAction) -> Void)?

    private let deadzoneKey = "NXNative_ControllerDeadzone"
    @Published var deadzone: Float = 0.35 {
        didSet {
            let clamped = min(max(deadzone, 0.10), 0.80)
            AppData.preferences.set(Double(clamped), forKey: deadzoneKey)
        }
    }

    var navigationInterval: TimeInterval = 0.12
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

    private var menuHold = HoldDetector()
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
            self?.resetInput()
        }
        gcSource.onEvent = { [weak self] in self?.handle($0, fromHID: false) }
        hidSource.onEvent = { [weak self] in self?.handle($0, fromHID: true) }
        gcSource.start()
        hidSource.start()
    }

    func refreshControllers() {
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
            resetInput()
        }
        guard activePad != pad else { return }
        activePad = pad
        isGamepadConnected = pad != nil
        activeControllerName = pad.map { $0.name ?? L10n.text("Gamepad") } ?? "No Gamepad Connected"
        activeBrand = pad?.brand ?? .generic
        buttonSymbols = pad?.symbols ?? [:]
    }

    private func handleInput(_ input: ControllerInputChange) {
        guard isAppActive else { return }
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
            if button == .menu {
                handleMenu(pressed: pressed)
            } else if pressed, let action = GamepadAction.onPress(button) {
                triggerAction(action)
            }
        }
    }

    private func handleMenu(pressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard pressed else {
            let action = menuHold.release(at: now).map(GamepadAction.menuAction)
            stopHoldTimer()
            if let action { triggerAction(action) }
            return
        }
        guard !menuHold.isPressed else { return }
        menuHold.press(at: now)
        menuHoldStartedAt = now
        let timer = Timer(timeInterval: menuHold.threshold, repeats: false) { [weak self] _ in
            guard let self, let result = self.menuHold.tick(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.stopHoldTimer()
            self.triggerAction(GamepadAction.menuAction(result))
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
        menuHoldStartedAt = nil
    }

    private func resetInput() {
        inputGeneration += 1
        menuHold.reset()
        stopHoldTimer()
        lastNavTime = 0
    }

    private func triggerAction(_ action: GamepadAction) {
        let generation = inputGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAppActive, self.inputGeneration == generation else { return }
            self.onAction?(action)
        }
    }
}
