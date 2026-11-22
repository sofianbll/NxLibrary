import Foundation
import AppKit
import NXLibraryCore

public protocol AppLaunching {
    func open(_ url: URL, environment: [String: String], onExit: (() -> Void)?,
              completion: @escaping (Bool, String?) -> Void)
}

public final class NSWorkspaceLauncher: AppLaunching {
    public init() {}

    public func open(_ url: URL, environment: [String: String], onExit: (() -> Void)?,
                     completion: @escaping (Bool, String?) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(false, "The app bundle is missing: \(url.path)")
            return
        }
        var merged = ProcessInfo.processInfo.environment
        // Arcane's host handoff is per launch, never inherited from the launcher environment.
        for key in GameOverlayLaunch.keys + [HomeMenu.launcherKey, HomeMenu.bundleIDKey, NextendoLaunch.loginDirectoryKey] {
            merged[key] = nil
        }
        for (key, value) in environment { merged[key] = value }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = merged
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                completion(false, error.localizedDescription)
            } else if let app {
                completion(true, nil)
                if let onExit {
                    DispatchQueue.main.async {
                        Self.watchExit(of: app, onExit: onExit)
                    }
                }
            } else {
                completion(false, nil)
            }
        }
    }

    private static func watchExit(of app: NSRunningApplication, onExit: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        func finish() {
            guard let token = observer else { return }
            observer = nil
            center.removeObserver(token)
            onExit()
        }
        observer = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                      object: nil, queue: .main) { note in
            guard let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  ended == app else { return }
            finish()
        }
        // The process can exit before the open completion or observer registration.
        if app.isTerminated { finish() }
    }
}

public final class LaunchService {
    private let launcher: AppLaunching

    public init(launcher: AppLaunching = NSWorkspaceLauncher()) {
        self.launcher = launcher
    }

    public func writeEnvironment(
        settings: GameRuntimeConfig,
        titleId: String,
        baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative")
    ) throws {
        let dir = baseDirectory.appendingPathComponent(titleId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envURL = dir.appendingPathComponent("env.txt")
        let existing = FileManager.default.fileExists(atPath: envURL.path)
            ? try String(contentsOf: envURL, encoding: .utf8) : nil
        try settings.mergedEnvContent(existing: existing).write(
            to: envURL, atomically: true, encoding: .utf8)
    }

    /// Set for every game Arcane starts: Game options are its settings window, so the engine's own
    /// (dm/mac/launcher.c: DM_LAUNCHER=0) does not show; the game takes Arcane's settings and starts.
    public static let launchEnvironment = ["DM_LAUNCHER": "0"]

    public func launch(appURL: URL, environment: [String: String] = [:],
                       overlay: GameOverlayLaunch? = nil, snapshot: GameOverlaySnapshot? = nil,
                       onExit: (() -> Void)? = nil,
                       completion: @escaping (Bool, String?) -> Void) {
        launch(appURL: appURL, environment: environment, overlay: overlay, snapshot: snapshot,
               temporaryDirectory: FileManager.default.temporaryDirectory, onExit: onExit, completion: completion)
    }

    func launch(appURL: URL, environment: [String: String] = [:],
                overlay: GameOverlayLaunch?, snapshot: GameOverlaySnapshot?, temporaryDirectory: URL,
                onExit: (() -> Void)? = nil,
                completion: @escaping (Bool, String?) -> Void) {
        var values = environment.merging(Self.launchEnvironment) { _, fixed in fixed }
        values[GameOverlayLaunch.dataKey] = nil
        var cleanup: (() -> Void)?
        if let overlay, let snapshot, let file = try? overlay.writeSnapshot(snapshot, in: temporaryDirectory) {
            values[GameOverlayLaunch.dataKey] = file.path
            cleanup = { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
        let afterExit: (() -> Void)? = (cleanup == nil && onExit == nil) ? nil : {
            cleanup?()
            onExit?()
        }
        launcher.open(appURL, environment: values, onExit: afterExit) { success, error in
            if !success { cleanup?() }
            completion(success, error)
        }
    }

    public func saveDirectory(for titleId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative")
            .appendingPathComponent(titleId).appendingPathComponent("save")
    }

    public func logURL(for titleId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nxnative")
            .appendingPathComponent("\(titleId).log")
    }
}
