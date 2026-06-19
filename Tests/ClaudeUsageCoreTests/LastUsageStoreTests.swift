import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct LastUsageStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lastusage-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-usage.json")
    }

    @Test func roundTripsUsageAndTimestamp() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LastUsageStore(fileURL: url)
        let usage = ClaudeUsage.sample(fiveHour: 42, sevenDay: 8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        store.save(usage, at: date)
        let loaded = store.load()

        #expect(loaded?.usage == usage)
        #expect(loaded?.savedAt == date)
    }

    @Test func missingFileReturnsNil() {
        let store = LastUsageStore(fileURL: tempURL())
        #expect(store.load() == nil)
    }

    @Test func corruptFileReturnsNil() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "not valid json".data(using: .utf8)!.write(to: url)

        let store = LastUsageStore(fileURL: url)
        #expect(store.load() == nil)
    }

    @Test func saveCreatesMissingDirectory() {
        let url = tempURL()  // parent directory does not exist yet
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LastUsageStore(fileURL: url)

        store.save(ClaudeUsage.sample(), at: Date(timeIntervalSince1970: 5))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.load() != nil)
    }
}
