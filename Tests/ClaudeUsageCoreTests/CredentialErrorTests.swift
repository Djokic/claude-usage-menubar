import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct CredentialErrorTests {
    private let allCases: [CredentialError] = [
        .notAuthenticated,
        .commandFailed(status: 44, message: "item not found"),
        .commandTimedOut,
        .decodingFailed("boom"),
    ]

    // Covers R3: every case has actionable text and never leaks the raw enum description.
    @Test func everyCaseHasActionableDescription() {
        for error in allCases {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("CredentialError"))
            #expect(!message.lowercased().contains("error 1"))
            // Each message points the user somewhere actionable.
            #expect(message.contains("Claude Code") || message.contains("Keychain"))
        }
    }

    // Covers R3: the bridged NSError (what SwiftUI's .localizedDescription shows) is the friendly text.
    @Test func bridgedNSErrorUsesFriendlyDescription() {
        let ns = CredentialError.commandFailed(status: 1, message: "") as NSError
        #expect(ns.localizedDescription.contains("Keychain"))
        #expect(!ns.localizedDescription.contains("error 1"))
    }

    @Test func commandFailedIncludesExitStatusForDiagnosis() {
        #expect(CredentialError.commandFailed(status: 44, message: "").errorDescription?.contains("44") == true)
    }
}
