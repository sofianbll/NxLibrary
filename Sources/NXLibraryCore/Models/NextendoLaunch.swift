import Foundation

/// The build advertises modes in the same settings contract the game launcher consumes.
public enum NextendoLaunch {
    public static let networkKey = "DM_NETWORK"
    public static let clientIDKey = "DM_NEXTENDO_CLIENT_ID"

    public static func networkSetting(in settings: [LauncherSetting]) -> LauncherSetting? {
        settings.first { $0.env == networkKey && $0.kind == "choice" && $0.options?.isEmpty == false }
    }

    public static func requiresSignIn(setting: LauncherSetting?, mode: String?) -> Bool {
        mode == "nextendo" && setting?.accepts("nextendo") == true
    }

    public static func environment(setting: LauncherSetting?, mode: String?, clientID: String?,
                                   sessionAvailable: (String) async throws -> Bool) async throws -> [String: String] {
        guard requiresSignIn(setting: setting, mode: mode) else { return [:] }
        guard let clientID, NextendoAuthorization.validClientID(clientID) else { throw NextendoError.clientID }
        guard try await sessionAvailable(clientID) else { throw NextendoError.signedOut }
        return [clientIDKey: clientID]
    }

    public static func engineSupportsSignIn(at repo: URL) -> Bool {
        // Like EngineSourceCapabilities, inspect the selected checkout without executing it.
        guard let cli = try? String(contentsOf: repo.appendingPathComponent("scripts/build_ipa_from_nsp.py"), encoding: .utf8),
              cli.contains("'--nextendo'") || cli.contains("\"--nextendo\""),
              let table = try? String(contentsOf: repo.appendingPathComponent("dm/games/settings.tsv"), encoding: .utf8)
        else { return false }
        return table.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count > 2 && fields[0] == "DM_NETWORK" && fields[1] == "choice"
                && fields[2].split(separator: ",").contains { $0.hasPrefix("nextendo=") }
        }
    }

    public static var buildClientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DMNextendoClientID") as? String)
            .flatMap { NextendoAuthorization.validClientID($0) ? $0 : nil }
    }
}
