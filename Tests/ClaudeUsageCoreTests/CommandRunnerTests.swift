import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct CommandRunnerTests {
    // Covers R3: stdin is delivered to the child process.
    @Test func deliversStdinToProcess() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run("/bin/cat", [], stdin: "hello stdin")
        #expect(output == "hello stdin")
    }

    @Test func returnsStdoutForZeroExit() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run("/bin/echo", ["-n", "ok"])
        #expect(output == "ok")
    }

    @Test func throwsCommandFailedOnNonZeroExit() {
        let runner = ProcessCommandRunner()
        #expect(throws: CredentialError.self) {
            // `false` exits non-zero; stderr message may be empty but the throw is what matters.
            try runner.run("/usr/bin/false", [])
        }
    }

    // Covers R5: large output written to BOTH pipes concurrently must not deadlock.
    // The `& ... & wait` form fills stdout and stderr simultaneously (each past the ~64 KB
    // pipe buffer); a sequential single-pipe drain would deadlock here.
    @Test func drainsLargeStdoutAndStderrWithoutDeadlock() throws {
        let runner = ProcessCommandRunner(timeout: 10)
        let script = "yes ABCDEFGH | head -c 200000 & yes abcdefgh | head -c 200000 1>&2 & wait"
        let output = try runner.run("/bin/sh", ["-c", script])
        #expect(output.count == 200000)
    }

    // Covers R2: a hung command is killed and surfaces commandTimedOut.
    @Test func timesOutAndKillsHangingProcess() {
        let runner = ProcessCommandRunner(timeout: 0.5)
        let start = Date()
        #expect(throws: CredentialError.commandTimedOut) {
            try runner.run("/bin/sleep", ["5"])
        }
        // Should return at ~the timeout, not wait the full 5 seconds.
        #expect(Date().timeIntervalSince(start) < 3)
    }

    // Covers R2 robustness: a child that ignores SIGTERM is escalated to SIGKILL, and run()
    // returns (never hangs) even when a grandchild keeps the pipes open.
    @Test func timesOutEvenWhenChildIgnoresSIGTERM() {
        let runner = ProcessCommandRunner(timeout: 0.5)
        let start = Date()
        #expect(throws: CredentialError.commandTimedOut) {
            try runner.run("/bin/sh", ["-c", "trap '' TERM; sleep 5"])
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func worksWithoutStdin() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run("/bin/echo", ["-n", "no-stdin"], stdin: nil)
        #expect(output == "no-stdin")
    }
}
