import Foundation
import NXLibraryCore

/// Launch-only data. Each exact, NUL-terminated key in dmhost advertises its own reader.
public struct GameOverlayLaunch {
    static let themeKey = "DM_OVERLAY_THEME_V1"
    static let playtimeKey = "DM_OVERLAY_PLAYTIME_MIN"
    static let coverKey = "DM_OVERLAY_COVER"
    static let keys = [themeKey, playtimeKey, coverKey]

    private let supported: Set<String>

    public init(app: URL) {
        let host = try? Data(contentsOf: HomeMenu.hostExecutable(in: app), options: [.mappedIfSafe])
        supported = Set(Self.keys.filter { host?.range(of: Data("\($0)\0".utf8)) != nil })
    }

    public var supportsCover: Bool { supported.contains(Self.coverKey) }

    public func environment(palette: SelenePalette, playtime: TimeInterval?, cover: URL?) -> [String: String] {
        var values: [String: String] = [:]
        if supported.contains(Self.themeKey) {
            values[Self.themeKey] = Self.theme(palette)
        }
        if supported.contains(Self.playtimeKey), let playtime, playtime >= 0,
           let minutes = Int(exactly: (playtime / 60).rounded(.down)) {
            values[Self.playtimeKey] = String(minutes)
        }
        if supportsCover, let cover, cover.isFileURL,
           (try? cover.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            values[Self.coverKey] = cover.path
        }
        return values
    }

    static func theme(_ palette: SelenePalette) -> String? {
        let fields = [("ink", palette.ink), ("surface", palette.glass), ("scrim", palette.scrim),
                      ("focus", palette.focus), ("onFocus", palette.onFocus)]
        // Solid surface and text provide a known contrast regardless of the frame behind them.
        guard fields.allSatisfy({ $0.1 <= 0xFFFFFF }),
              contrast(palette.ink, palette.glass) >= 4.5,
              contrast(palette.onFocus, palette.focus) >= 4.5,
              contrast(palette.focus, palette.glass) >= 3 else { return nil }
        return fields.map { key, rgb in "\(key)=#\(String(format: "%06X", rgb))FF" }.joined(separator: ";")
    }

    private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ rgb: UInt32) -> Double {
            func component(_ shift: UInt32) -> Double {
                let value = Double((rgb >> shift) & 0xFF) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * component(16) + 0.7152 * component(8) + 0.0722 * component(0)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
