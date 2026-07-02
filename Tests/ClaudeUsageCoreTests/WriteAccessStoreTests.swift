import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct WriteAccessStoreTests {
    private func store() -> WriteAccessStore {
        WriteAccessStore(defaults: UserDefaults(suiteName: "was-\(UUID().uuidString)")!, key: "granted")
    }

    @Test func defaultsToNilWhenUnprobed() {
        #expect(store().granted == nil)
    }

    @Test func roundTripsTrueAndFalse() {
        let s = store()
        s.granted = true
        #expect(s.granted == true)
        s.granted = false
        #expect(s.granted == false)
    }

    @Test func persistsAcrossInstancesOverSameSuite() {
        let defaults = UserDefaults(suiteName: "was-shared-\(UUID().uuidString)")!
        WriteAccessStore(defaults: defaults, key: "g").granted = true
        #expect(WriteAccessStore(defaults: defaults, key: "g").granted == true)
    }

    @Test func clearingResetsToNil() {
        let s = store()
        s.granted = true
        s.granted = nil
        #expect(s.granted == nil)
    }

    // The v1 probe could truncate what it wrote, so a v1 grant is untrustworthy: creating the
    // store must drop the legacy flag (forcing a re-probe under the verified v2 key).
    @Test func initDropsLegacyV1Grant() {
        let defaults = UserDefaults(suiteName: "was-legacy-\(UUID().uuidString)")!
        defaults.set(true, forKey: "ClaudeUsage.keychainWriteGranted")
        let s = WriteAccessStore(defaults: defaults)
        #expect(defaults.object(forKey: "ClaudeUsage.keychainWriteGranted") == nil)
        #expect(s.granted == nil)  // v2 key starts unprobed
    }
}
