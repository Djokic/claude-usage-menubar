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
    /// Run `executable` with `arguments`, returning stdout. Throws on a non-zero exit.
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw CredentialError.commandFailed(status: process.terminationStatus, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
