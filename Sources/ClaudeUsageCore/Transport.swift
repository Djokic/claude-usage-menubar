import Foundation

/// Minimal async HTTP seam so the usage client and credential refresh can be tested
/// without hitting the network.
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

/// Seam for running an external command (used to read/write the Keychain via the
/// `security` CLI), injectable for tests.
public protocol CommandRunner: Sendable {
    /// Run `executable` with `arguments`, optionally writing `stdin` to its standard input,
    /// returning stdout. Throws `commandFailed` on a non-zero exit, `commandTimedOut` on a hang.
    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String
}

public extension CommandRunner {
    /// Convenience for commands that take no stdin.
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        try run(executable, arguments, stdin: nil)
    }
}

public struct ProcessCommandRunner: CommandRunner {
    /// Kill the subprocess and throw `commandTimedOut` if it runs longer than this.
    /// Guards against a Keychain approval prompt blocking forever.
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Feed stdin (e.g. a secret) then close so the child sees EOF. Passing secrets via
        // stdin keeps them out of the process argument list (visible to other processes).
        if let stdin, let data = stdin.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Drain stdout and stderr concurrently — reading one to completion before the other
        // can deadlock if the child fills the second pipe's buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let drainQueue = DispatchQueue(label: "ClaudeUsage.command-drain", attributes: .concurrent)
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
            process.terminate()
            group.wait()
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
