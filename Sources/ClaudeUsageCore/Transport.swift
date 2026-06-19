import Foundation

/// Minimal async HTTP seam so the usage client can be tested without hitting the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Seam for running an external command (used to read the Keychain via the `security` CLI),
/// injectable for tests.
public protocol CommandRunner: Sendable {
    /// Run `executable` with `arguments`, returning stdout. Throws `commandFailed` on a non-zero
    /// exit, `commandTimedOut` on a hang.
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public struct ProcessCommandRunner: CommandRunner {
    /// Kill the subprocess and throw `commandTimedOut` if it runs longer than this.
    /// Guards against a Keychain approval prompt blocking forever.
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Drain stdout and stderr concurrently — reading one to completion before the other
        // can deadlock if the child fills the second pipe's buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let drainQueue = DispatchQueue.global()
        group.enter()
        drainQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        drainQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()  // SIGTERM
            // Escalate to SIGKILL if it doesn't exit promptly, then wait only briefly — a
            // grandchild holding the pipes open must never make run() block forever.
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = group.wait(timeout: .now() + 1)
            // Don't read outData/errData here — a bounded wait may have left a drain in flight.
            throw CredentialError.commandTimedOut
        }
        group.wait()  // ensures both reads finished before we touch the buffers

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw CredentialError.commandFailed(status: process.terminationStatus, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
