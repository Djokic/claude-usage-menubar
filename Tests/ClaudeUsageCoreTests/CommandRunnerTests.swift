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

    // Covers R5: large output on both pipes must not deadlock.
    @Test func drainsLargeStdoutAndStderrWithoutDeadlock() throws {
        let runner = ProcessCommandRunner(timeout: 20)
        // Write ~200 KB to stdout and ~200 KB to stderr (well past a single pipe buffer).
        let script = "yes ABCDEFGH | head -c 200000; yes abcdefgh | head -c 200000 1>&2"
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

    @Test func worksWithoutStdin() throws {
        let runner = ProcessCommandRunner()
        let output = try runner.run("/bin/echo", ["-n", "no-stdin"], stdin: nil)
        #expect(output == "no-stdin")
    }
}
