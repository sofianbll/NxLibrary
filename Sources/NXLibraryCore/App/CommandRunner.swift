import Foundation

public struct CommandResult: Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning {
    func run(_ executable: URL, _ arguments: [String],
             environment: [String: String]?,
             currentDirectory: URL?) throws -> CommandResult
}

/// Keeps no state, so the background tasks that run commands can share it.
public final class SystemCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String],
                    environment: [String: String]?,
                    currentDirectory: URL?) throws -> CommandResult {
        try execute(executable, arguments, environment: environment, currentDirectory: currentDirectory, onLine: nil)
    }

    /// Runs like `run`, and hands every line of either pipe to `onLine` as it
    /// arrives (on a background queue), for installs that report progress.
    public func stream(_ executable: URL, _ arguments: [String],
                       environment: [String: String]?, currentDirectory: URL?,
                       onLine: @escaping (String) -> Void) throws -> CommandResult {
        try execute(executable, arguments, environment: environment, currentDirectory: currentDirectory, onLine: onLine)
    }

    private func execute(_ executable: URL, _ arguments: [String],
                         environment: [String: String]?, currentDirectory: URL?,
                         onLine: ((String) -> Void)?) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let group = DispatchGroup()
        let waitForExit = try process.runWithExitWait()

        let lock = NSLock()
        var collected = [Data(), Data()]
        for (slot, pipe) in [out, err].enumerated() {
            var buffer = LineBuffer()
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    if let onLine { buffer.finish().forEach(onLine) }
                    group.leave()
                    return
                }
                lock.lock()
                collected[slot].append(chunk)
                lock.unlock()
                if let onLine { buffer.append(chunk).forEach(onLine) }
            }
        }
        waitForExit()
        group.wait()
        func decode(_ data: Data) -> String {
            onLine == nil ? (String(data: data, encoding: .utf8) ?? "") : String(decoding: data, as: UTF8.self)
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: decode(collected[0]),
                             stderr: decode(collected[1]))
    }
}

extension Process {
    /// Starts the process and returns the wait for its end, which blocks without running the current run loop.
    /// `waitUntilExit` runs it while it waits, so a command awaited inside a SwiftUI update (Game options reading the
    /// engine's ancestry) let SwiftUI start another update inside the first and abort. Call the wait once.
    public func runWithExitWait() throws -> () -> Void {
        let exited = DispatchSemaphore(value: 0)
        let previous = terminationHandler
        // Set before `run`, so an end that comes at once is never missed.
        terminationHandler = { process in
            previous?(process)
            exited.signal()
        }
        try run()
        return { exited.wait() }
    }
}
