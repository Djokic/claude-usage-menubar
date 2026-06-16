import Testing
@testable import ClaudeUsageCore

@Suite struct SmokeTests {
    @Test func userAgentConstant() {
        #expect(AppInfo.userAgent == "claude-code/2.0.67")
    }
}
