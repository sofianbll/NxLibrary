import Foundation

public enum ControllerButton: CaseIterable, Hashable {
    case up, down, left, right
    case a, b, x, y, l, r, zl, zr, menu, view, l3, r3, home, capture
}

public enum ControllerInputChange: Equatable {
    case button(ControllerButton, Bool)
    case leftStick(SIMD2<Float>)
}

public struct ControllerInputState: Equatable {
    public var buttons: Set<ControllerButton> = []
    public var leftStick: SIMD2<Float> = .zero
    public var rightStick: SIMD2<Float> = .zero

    public init() {}

    public func changes(from previous: Self) -> [ControllerInputChange] {
        var changes: [ControllerInputChange] = []
        if buttons != previous.buttons {
            for button in ControllerButton.allCases {
                let pressed = buttons.contains(button)
                if pressed != previous.buttons.contains(button) { changes.append(.button(button, pressed)) }
            }
        }
        if leftStick != previous.leftStick { changes.append(.leftStick(leftStick)) }
        return changes
    }
}

/// Nintendo's simple input report and the raw-stick calibration used by nxnative (`pad_hid.h`).
public struct NintendoHIDInput {
    private static let buttonBits: [ControllerButton] = [
        .b, .a, .y, .x, .l, .r, .zl, .zr, .view, .menu, .l3, .r3, .home, .capture,
    ]
    private static let hatDirections: [[ControllerButton]] = [
        [.up], [.up, .right], [.right], [.right, .down],
        [.down], [.down, .left], [.left], [.left, .up],
    ]
    private var axes = Array(repeating: Axis(), count: 4)

    public init() {}

    public mutating func decode<Bytes: RandomAccessCollection>(reportID: UInt32, bytes: Bytes) -> ControllerInputState?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard reportID == 0x3f else { return nil }
        // Exactly 11 bytes is a bare payload: 0x3f can also be its first button byte.
        let offset = bytes.count > 11 && bytes.first == 0x3f ? 1 : 0
        guard bytes.count - offset >= 11 else { return nil }
        let base = bytes.startIndex + offset
        let buttonWord = UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
        var input = ControllerInputState()
        for (bit, button) in Self.buttonBits.enumerated() where buttonWord & (1 << bit) != 0 {
            input.buttons.insert(button)
        }
        let hat = Int(bytes[base + 2])
        if Self.hatDirections.indices.contains(hat) { input.buttons.formUnion(Self.hatDirections[hat]) }

        func axis(_ index: Int) -> Float {
            let start = base + 3 + 2 * index
            let raw = UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8
            return Float(raw) / 32_767.5 - 1
        }
        input.leftStick = Self.stick(axes[0].normalize(axis(0)), -axes[1].normalize(axis(1)))
        input.rightStick = Self.stick(axes[2].normalize(axis(2)), -axes[3].normalize(axis(3)))
        return input
    }

    private struct Axis {
        var rest: Float?
        var negativeReach: Float = 0.7
        var positiveReach: Float = 0.7

        mutating func normalize(_ value: Float) -> Float {
            let center = rest ?? (abs(value) < 0.25 ? value : 0)
            rest = center
            let delta = value - center
            if delta > 0 {
                positiveReach = max(positiveReach, delta)
                return delta / positiveReach
            }
            negativeReach = max(negativeReach, -delta)
            return delta / negativeReach
        }
    }

    private static func stick(_ x: Float, _ y: Float) -> SIMD2<Float> {
        let radius = (x * x + y * y).squareRoot()
        let dead: Float = 0.12
        let outer: Float = 0.9
        guard radius > dead else { return .zero }
        let scale = (radius - dead) / (outer - dead) / radius
        return SIMD2(min(1, max(-1, x * scale)), min(1, max(-1, y * scale)))
    }
}

public struct ControllerHolds {
    private var detectors: [ControllerButton: HoldDetector] = [:]

    public init() {}

    public var isPressed: Bool { detectors.values.contains(where: \.isPressed) }

    public mutating func update(_ button: ControllerButton, pressed: Bool, at time: TimeInterval) -> HoldResult? {
        if pressed {
            detectors[button, default: HoldDetector()].press(at: time)
            return nil
        }
        guard var detector = detectors.removeValue(forKey: button) else { return nil }
        return detector.release(at: time)
    }

    public mutating func tick(at time: TimeInterval) -> [ControllerButton] {
        detectors.keys.filter { detectors[$0]?.tick(at: time) == .hold }
    }

    /// A disconnect or source switch is not a release, and must not fire a tap or hold.
    public mutating func reset() { detectors.removeAll() }
}

public enum ControllerArbitration: Equatable {
    case gameController, wait(until: TimeInterval), hid

    public struct HID {
        private let name: String?
        private let claimedByGC: Bool
        private var fallbackAt: TimeInterval

        public init(name: String?, claimedByGC: Bool, connectedAt: TimeInterval) {
            self.name = name
            self.claimedByGC = claimedByGC
            fallbackAt = connectedAt + 2
        }

        public mutating func admission(gcNames: [String], at time: TimeInterval) -> ControllerArbitration {
            // shortcut: identical product names cannot distinguish physical twins; use a shared ID if the OS exposes one.
            if let name, gcNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                fallbackAt = min(fallbackAt, time)
                return .gameController
            }
            return claimedByGC && time < fallbackAt ? .wait(until: fallbackAt) : .hid
        }
    }

    public static func preferred(hasGameController: Bool, hasHID: Bool) -> Self? {
        if hasGameController { return .gameController }
        return hasHID ? .hid : nil
    }
}
