import SwiftUI

/// State-driven curves. Rails use SwiftUI's replacing spring, not queued animations.
public enum Motion {
    public static let focusIn = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    public static let focusOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.20)

    public static func focus(_ reduced: Bool, entering: Bool = true) -> Animation? {
        reduced ? nil : entering ? focusIn : focusOut
    }

    public enum Rail { case spotlight, collection }

    public static func rail(_ reduced: Bool, _ rail: Rail) -> Animation? {
        reduced ? nil : .spring(response: rail == .spotlight ? 0.32 : 0.18, dampingFraction: 1)
    }

    public static let screenDuration = 0.32
    public static let screen = Animation.timingCurve(0.32, 0.72, 0, 1, duration: screenDuration)

    public static func screen(_ reduced: Bool) -> Animation? {
        reduced ? nil : screen
    }

    public static func overlay(_ reduced: Bool) -> Animation? {
        reduced ? .easeOut(duration: 0.12) : focus(false)
    }

    public static func anchoredCard(_ reduced: Bool) -> Animation? {
        overlay(reduced)
    }

    public static func toast(_ reduced: Bool) -> Animation? {
        .easeOut(duration: reduced ? 0.12 : 0.25)
    }

    public static func rowMessage(_ reduced: Bool) -> Animation? {
        reduced ? overlay(true) : .easeOut(duration: 0.30)
    }

    public static func menuIcon(_ reduced: Bool, index: Int) -> Animation? {
        reduced ? overlay(true) : .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.26)
            .delay(Double(index) * 0.025)
    }
}
