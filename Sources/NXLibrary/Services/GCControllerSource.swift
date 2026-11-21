import Foundation
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
        let available = GCController.controllers()
        let next = available.first { $0.extendedGamepad != nil } ?? available.first
        let previous = controller
        if previous !== next {
            unbind?()
            unbind = nil
            controller = next
        }
        if let next {
            let name = next.vendorName ?? "Gamepad"
            let brand = Self.brand(vendor: name, category: next.productCategory)
            var symbols: [PromptButton: String] = [:]
            if let pad = next.extendedGamepad {
                let face = Self.faceButtons(pad, nintendo: brand == .nintendoSwitch)
                if unbind == nil { bind(next, pad: pad, face: face) }
                symbols = Self.symbols(pad, face: face)
            }
            onEvent?(.connected(ControllerIdentity(id: ObjectIdentifier(next), name: next.vendorName, brand: brand,
                                                  symbols: symbols)))
        }
        // Publish a replacement first so the service doesn't briefly fall back to HID.
        if let previous, previous !== next { onEvent?(.disconnected(ObjectIdentifier(previous))) }
    }

    private func bind(_ controller: GCController, pad: GCExtendedGamepad, face: FaceButtons) {
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
        var gestures = [pad.buttonMenu]
        if let options = pad.buttonOptions {
            buttons.append((options, .view))
            gestures.append(options)
        }
        if let touchpad = (pad as? GCDualShockGamepad)?.touchpadButton ?? (pad as? GCDualSenseGamepad)?.touchpadButton {
            buttons.append((touchpad, .view))
            gestures.append(touchpad)
        }
        if let share = controller.physicalInputProfile.buttons[GCInputButtonShare] {
            gestures.append(share)
            if pad.buttonOptions != share { buttons.append((share, .view)) }
        }
        if let options = controller.physicalInputProfile.buttons[GCInputButtonOptions] { gestures.append(options) }
        if let click = pad.rightThumbstickButton { buttons.append((click, .r3)) }
        if let click = pad.leftThumbstickButton { buttons.append((click, .l3)) }

        var seen: Set<ObjectIdentifier> = []
        let systemGestures = gestures.filter { seen.insert(ObjectIdentifier($0)).inserted }
            .map { ($0, $0.preferredSystemGestureState) }
        for (button, _) in systemGestures { button.preferredSystemGestureState = .disabled }
        for (button, control) in buttons {
            button.pressedChangedHandler = { _, _, pressed in emit(.button(control, pressed)) }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in emit(.leftStick(SIMD2(x, y))) }
        unbind = {
            for (button, _) in buttons { button.pressedChangedHandler = nil }
            for (button, state) in systemGestures { button.preferredSystemGestureState = state }
            pad.leftThumbstick.valueChangedHandler = nil
        }
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

    /// The framework usually maps by position (A = bottom). Swap if that button
    /// is printed B; do not swap a Nintendo pad already mapped by label.
    private static func faceButtons(_ pad: GCExtendedGamepad, nintendo: Bool) -> FaceButtons {
        if nintendo, pad.buttonA.unmappedSfSymbolsName?.hasPrefix("b.") == true {
            return FaceButtons(confirm: pad.buttonB, cancel: pad.buttonA,
                               secondary: pad.buttonY, context: pad.buttonX)
        }
        return FaceButtons(confirm: pad.buttonA, cancel: pad.buttonB,
                           secondary: pad.buttonX, context: pad.buttonY)
    }

    private static func symbols(_ pad: GCExtendedGamepad, face: FaceButtons) -> [PromptButton: String] {
        let elements: [PromptButton: GCControllerElement?] = [
            .a: face.confirm, .b: face.cancel, .x: face.secondary, .y: face.context,
            .lb: pad.leftShoulder, .rb: pad.rightShoulder,
            .lt: pad.leftTrigger, .rt: pad.rightTrigger,
            .rs: pad.rightThumbstickButton, .view: pad.buttonOptions, .menu: pad.buttonMenu,
        ]
        return elements.compactMapValues { element in
            guard let name = element?.sfSymbolsName, !name.isEmpty,
                  !ButtonPrompts.isGenericShape(name) else { return nil }
            return name
        }
    }
}
