import AppKit
import GameController
import NXLibraryCore

final class GCControllerSource: ControllerSource {
    var onEvent: ((ControllerSourceEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var controller: GCController?
    private var unbind: (() -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        observers = [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        let previous = controller.map(ObjectIdentifier.init)
        tearDown()
        if let previous { onEvent?(.disconnected(previous)) }
    }

    deinit { tearDown() }

    private func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        unbind?()
        unbind = nil
        controller = nil
    }

    func refresh() {
        guard !observers.isEmpty else { return }
        // A controller without an extended profile can't drive the launcher.
        let next = GCController.controllers().first { $0.extendedGamepad != nil }
        let previous = controller
        if previous !== next {
            unbind?()
            unbind = nil
            controller = next
        }
        if let next, let pad = next.extendedGamepad {
            let name = next.vendorName ?? "Gamepad"
            let brand = Self.brand(vendor: name, category: next.productCategory)
            let face = Self.faceButtons(pad, nintendo: brand == .nintendoSwitch)
            let view = Self.viewButton(pad, brand: brand)
            if unbind == nil { bind(next, pad: pad, face: face, view: view) }
            onEvent?(.connected(ControllerIdentity(id: ObjectIdentifier(next), name: next.vendorName, brand: brand,
                                                  symbols: Self.symbols(pad, face: face, view: view))))
        }
        // Publish a replacement first so the service doesn't briefly fall back to HID.
        if let previous, previous !== next { onEvent?(.disconnected(ObjectIdentifier(previous))) }
    }

    private func bind(_ controller: GCController, pad: GCExtendedGamepad, face: FaceButtons,
                      view: GCControllerButtonInput?) {
        let id = ObjectIdentifier(controller)
        let emit: (ControllerInputChange) -> Void = { [weak self, weak controller] input in
            // GameController defaults to the main queue; also honor the source contract
            // if the handler queue has been changed.
            let deliver = { [weak self, weak controller] in
                guard let self, let controller, self.controller === controller else { return }
                self.onEvent?(.input(id, input))
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        var buttons: [(GCControllerButtonInput, ControllerButton)] = [
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
            (face.confirm, .a), (face.cancel, .b), (face.secondary, .x), (face.context, .y),
            (pad.leftShoulder, .l), (pad.rightShoulder, .r),
            (pad.leftTrigger, .zl), (pad.rightTrigger, .zr), (pad.buttonMenu, .menu),
        ]
        let gestures = [pad.buttonMenu] + (view.map { [$0] } ?? [])
        if let view { buttons.append((view, .view)) }
        var unbindHome: (() -> Void)?
        if let home = pad.buttonHome, !buttons.contains(where: { $0.0 === home }) {
            buttons.append((home, .home))
            // Arcane takes the system gesture only while it owns the foreground.
            let previous = home.preferredSystemGestureState
            home.preferredSystemGestureState = NSApp.isActive ? .disabled : previous
            let homeObservers = [
                NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                       object: nil, queue: .main) { _ in home.preferredSystemGestureState = .disabled },
                NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                       object: nil, queue: .main) { _ in home.preferredSystemGestureState = previous },
            ]
            unbindHome = {
                homeObservers.forEach(NotificationCenter.default.removeObserver)
                home.preferredSystemGestureState = previous
            }
        }
        if let click = pad.rightThumbstickButton { buttons.append((click, .r3)) }
        if let click = pad.leftThumbstickButton { buttons.append((click, .l3)) }

        let systemGestures = gestures.map { ($0, $0.preferredSystemGestureState) }
        for (button, _) in systemGestures { button.preferredSystemGestureState = .disabled }
        for (button, control) in buttons {
            button.pressedChangedHandler = { _, _, pressed in emit(.button(control, pressed)) }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in emit(.leftStick(SIMD2(x, y))) }
        unbind = {
            unbindHome?()
            for (button, _) in buttons { button.pressedChangedHandler = nil }
            for (button, state) in systemGestures { button.preferredSystemGestureState = state }
            pad.leftThumbstick.valueChangedHandler = nil
        }
    }

    private static func viewButton(_ pad: GCExtendedGamepad, brand: GamepadBrand) -> GCControllerButtonInput? {
        let button = brand == .playstation
            ? (pad as? GCDualSenseGamepad)?.touchpadButton ?? (pad as? GCDualShockGamepad)?.touchpadButton
            : pad.buttonOptions
        return button === pad.buttonMenu ? nil : button
    }

    private static func brand(vendor: String, category: String) -> GamepadBrand {
        switch category {
        case GCProductCategoryDualSense, GCProductCategoryDualShock4: return .playstation
        case GCProductCategoryXboxOne: return .xbox
        default: break
        }
        let lower = (vendor + " " + category).lowercased()
        if lower.contains("switch") || lower.contains("joy-con") || lower.contains("nintendo") {
            return .nintendoSwitch
        } else if lower.contains("xbox") || lower.contains("microsoft") {
            return .xbox
        } else if lower.contains("dualsense") || lower.contains("dualshock") || lower.contains("sony") || lower.contains("playstation") {
            return .playstation
        }
        return .generic
    }

    private struct FaceButtons {
        let confirm, cancel, secondary, context: GCControllerButtonInput
    }

    /// GameController maps by position (A = bottom). Keep a Nintendo profile
    /// already mapped by the printed A, otherwise use the right button.
    private static func faceButtons(_ pad: GCExtendedGamepad, nintendo: Bool) -> FaceButtons {
        if nintendo, pad.buttonA.unmappedSfSymbolsName?.hasPrefix("a.") != true {
            return FaceButtons(confirm: pad.buttonB, cancel: pad.buttonA,
                               secondary: pad.buttonY, context: pad.buttonX)
        }
        return FaceButtons(confirm: pad.buttonA, cancel: pad.buttonB,
                           secondary: pad.buttonX, context: pad.buttonY)
    }

    private static func symbols(_ pad: GCExtendedGamepad, face: FaceButtons,
                                view: GCControllerButtonInput?) -> [PromptButton: String] {
        let elements: [PromptButton: GCControllerElement?] = [
            .a: face.confirm, .b: face.cancel, .x: face.secondary, .y: face.context,
            .lb: pad.leftShoulder, .rb: pad.rightShoulder,
            .lt: pad.leftTrigger, .rt: pad.rightTrigger,
            .rs: pad.rightThumbstickButton, .view: view, .menu: pad.buttonMenu, .home: pad.buttonHome,
        ]
        return elements.compactMapValues { element in
            guard let name = element?.sfSymbolsName, !name.isEmpty,
                  !ButtonPrompts.isGenericShape(name) else { return nil }
            return name
        }
    }
}
