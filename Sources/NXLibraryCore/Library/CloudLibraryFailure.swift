import Foundation

/// Safe cloud recovery information. Never retain rclone output: OAuth errors can contain secrets.
public enum CloudLibraryFailure: LocalizedError, Hashable, Sendable {
    case offline, authentication, folderMissing, quotaFull, macFull, queueNotSaved, unavailable

    public enum Action: Equatable, Sendable {
        case retry, reconnect, chooseFolder, manageDriveStorage, freeMacStorage, dismiss

        public var titleKey: String {
            switch self {
            case .retry: return "Retry"
            case .reconnect: return "Reconnect"
            case .chooseFolder: return "Choose a folder"
            case .manageDriveStorage: return "Manage Google storage"
            case .freeMacStorage: return "Free up space"
            case .dismiss: return "Close"
            }
        }
    }

    public var action: Action {
        switch self {
        case .offline, .unavailable: return .retry
        case .authentication: return .reconnect
        case .folderMissing: return .chooseFolder
        case .quotaFull: return .manageDriveStorage
        case .macFull: return .freeMacStorage
        case .queueNotSaved: return .dismiss
        }
    }

    public var messageKey: String {
        switch self {
        case .offline: return "Offline — Google Drive is unreachable."
        case .authentication: return "Google Drive sign-in expired or was revoked."
        case .folderMissing: return "Cloud folder not found."
        case .quotaFull: return "Google Drive is full."
        case .macFull: return "Not enough space on this Mac."
        case .queueNotSaved: return "The cloud queue could not be saved. Transfers continue, but may not resume after quitting."
        case .unavailable: return "Cloud storage is unavailable. Check rclone and try again."
        }
    }

    public var errorDescription: String? { L10n.text(messageKey) }

    package static func rclone(_ stderr: String, status: Int32, listingFolder: Bool = false) -> Self? {
        let text = stderr.lowercased()
        func contains(_ markers: String...) -> Bool { markers.contains { text.contains($0) } }
        if contains("invalid_grant", "token expired", "token has expired", "token is expired", "token has been revoked",
                    "token revoked", "error 401", "401 unauthorized", "status code: 401", #"\"code\": 401"#) {
            return .authentication
        }
        if contains("storagequotaexceeded", "storage quota", "drive is full")
            || (text.contains("403") && text.contains("quota")
                && !contains("rate limit", "ratelimit", "downloadquota", "daily limit", "dailyquota")) {
            return .quotaFull
        }
        if contains("no such host", "network is unreachable", "network is down", "no route to host", "host is down",
                    "not connected to the internet", "connection refused", "connection reset",
                    "i/o timeout", "context deadline exceeded", "tls handshake timeout",
                    "temporary failure in name resolution", "error 502", "error 503", "error 504") {
            return .offline
        }
        if listingFolder && (status == 3 || status == 4 || text.contains("directory not found")) { return .folderMissing }
        return nil
    }
}
