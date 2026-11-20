import XCTest
@testable import NXLibraryCore

final class CommandRunnerTests: XCTestCase {
    @MainActor
    func testWaitingForExitDoesNotServiceTheMainRunLoop() throws {
        let runner = SystemCommandRunner()
        let shell = URL(fileURLWithPath: "/bin/sh")
        // Close both pipes before exiting so even the synchronous path has to wait.
        let arguments = ["-c", "printf out; printf err >&2; exec 1>&- 2>&-; /bin/sleep 0.5; exit 7"]
        for streaming in [false, true] {
            let tick = expectation(description: "main run loop timer")
            let timer = Timer(timeInterval: 0, repeats: false) { _ in tick.fulfill() }
            RunLoop.main.add(timer, forMode: .default)
            defer { timer.invalidate() }

            let result = try streaming
                ? runner.stream(shell, arguments, environment: nil, currentDirectory: nil, onLine: { _ in })
                : runner.run(shell, arguments, environment: nil, currentDirectory: nil)

            XCTAssertTrue(timer.isValid, "Main run loop serviced while waiting (streaming: \(streaming))")
            XCTAssertEqual(result, CommandResult(status: 7, stdout: "out", stderr: "err"))
            wait(for: [tick], timeout: 1)
        }
    }
}
