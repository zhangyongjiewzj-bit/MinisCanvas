// Source adoption: approved internal 2383ff12 host-rule fixtures; original tests preserved.
import Foundation
import Testing
@testable import MinisCore

struct CCFinishWebHostRuleTests {
    private func facts(_ root: URL?) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(knownCapabilities: ["web_fetch"], grantedCapabilities: ["web_fetch"],
            allowedWriteRoots: root.map { [$0.path] } ?? [], workspaceID: "web-project",
            revision: "web-policy", grantEpoch: "web-epoch", leaseID: "web-lease",
            expiresAt: Date().addingTimeInterval(300))
    }

    @Test func rememberedHostPersistsAndMatchesOnlyTheSameProjectAndExactHost() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("host-rule-" + UUID().uuidString)
        let other = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rules.json")
        let store = PersistentApprovalRuleStore(fileURL: file, homeDirectory: "/synthetic-home")
        let rule = try #require(store.makeRule(capability: "web_fetch", input: ["url": "https://EXAMPLE.com/page"], facts: facts(root)))
        #expect(rule.kind == .webHost && rule.pattern == "example.com")
        #expect(store.add(rule))
        let reloaded = PersistentApprovalRuleStore(fileURL: file, homeDirectory: "/synthetic-home")
        #expect(reloaded.match(capability: "web_fetch", input: ["url": "https://example.com/another"], facts: facts(root))?.id == rule.id)
        #expect(reloaded.match(capability: "web_fetch", input: ["url": "https://child.example.com/"], facts: facts(root)) == nil)
        #expect(reloaded.match(capability: "web_fetch", input: ["url": "https://example.com/"], facts: facts(other)) == nil)
    }

    @Test func unsupportedOrCredentialedURLsCannotCreateHostPatterns() {
        for url in ["file:///synthetic/file", "https://*.example.com/", "https://name:password@example.com/"] {
            #expect(PersistentApprovalRuleMatcher.evaluateWebFetch(input: ["url": url])
                == .unavailable("网页地址无效，无法按网站记住"))
        }
    }

    @Test func projectlessCallsCannotOfferGlobalHostPermission() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("host-rule-no-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"), homeDirectory: "/synthetic-home")
        let input: [String: Any] = ["url": "https://example.com/page"]
        #expect(store.offer(capability: "web_fetch", input: input, facts: facts(nil))?.isAvailable == false)
        #expect(store.makeRule(capability: "web_fetch", input: input, facts: facts(nil)) == nil)
    }
}
