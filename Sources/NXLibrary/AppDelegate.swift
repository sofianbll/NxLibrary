import AppKit
import NXLibraryCore
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "local.nxlibrary", category: "rename")
    /// Set by the shell: true while a build, an update or a save operation still needs this bundle's path.
    @MainActor static var isBusy: () -> Bool = { false }
    /// Set when a helper will reopen this bundle at its current path after the app quits.
    @MainActor static var relaunchScheduled = false
    /// The profile's store outlives the last window so it can finish a selection write when quitting.
    @MainActor static var settingsStore: AppSettingsStore?
    @MainActor static var cloudLibrary: CloudLibraryModel?
    @MainActor static var showCloudQuit: (() -> Bool)?
    @MainActor static weak var shellWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        SeleneFonts.register()
    }

    /// A release copy still called "NX Library.app" takes its current name on its way out
    /// (`AppBundleRename`); a failure is logged and never holds up quitting.
    func applicationWillTerminate(_ notification: Notification) {
        Self.settingsStore?.flushPendingSelection()
        let bundle = Bundle.main.bundleURL
        guard let target = AppBundleRename.target(
            bundleURL: bundle,
            isRelease: AppUpdate.installability(bundle) != .developer,
            isTranslocated: AppUpdate.isTranslocated(bundle),
            isBusy: Self.relaunchScheduled || Self.isBusy()
        ) else { return }
        do {
            try AppBundleRename.perform(bundleURL: bundle, to: target)
        } catch {
            Self.log.error("Renaming the app to \(target.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cloud = Self.cloudLibrary else { return .terminateNow }
        if cloud.isQuitting { return .terminateLater }
        if cloud.isWorking {
            guard !Self.relaunchScheduled else { return .terminateCancel }
            guard let window = Self.shellWindow else { return .terminateCancel }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            guard Self.showCloudQuit?() == true else { return .terminateCancel }
            return .terminateLater
        }
        guard cloud.hasQueueWrites else { return .terminateNow }
        Self.finishCloudQuit(sender)
        return .terminateLater
    }

    @MainActor static func finishCloudQuit(_ sender: NSApplication) {
        guard let cleanup = cloudLibrary?.stopForQuit() else { return }
        Task {
            await cleanup.value
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let window = sender.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }
}
