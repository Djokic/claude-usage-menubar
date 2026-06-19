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
}
