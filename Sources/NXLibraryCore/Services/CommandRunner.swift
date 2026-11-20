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

public final class SystemCommandRunner: CommandRunning {
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
        // Unlike waitUntilExit(), this does not run the caller's run loop during a SwiftUI update.
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            group.leave()
            throw error
        }

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
        group.wait()
        func decode(_ data: Data) -> String {
            onLine == nil ? (String(data: data, encoding: .utf8) ?? "") : String(decoding: data, as: UTF8.self)
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: decode(collected[0]),
                             stderr: decode(collected[1]))
    }
}
