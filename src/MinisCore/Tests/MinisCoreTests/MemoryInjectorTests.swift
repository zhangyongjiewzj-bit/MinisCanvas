import Foundation
import Testing
@testable import MinisCore

private func makeInjectorScopeTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MemoryInjectorScope-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct MemoryClassifiedInjectorTests {
    @Test func globalInstructionsUseTheirOwnBudgetAndPreserveTheSourceDocument() throws {
        let root = try makeInjectorScopeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MemoryFileStore(directory: root)
        let injector = MemoryInjector(store: MemoryStore(directory: root), maxTotalCharacters: 0, fileStore: files)

        func inject() throws -> MemoryInjectionResult {
            try injector.userLevelInjection(base: "base", userMessage: "ordinary", trustedPrincipal: nil)
        }

        let fallback = try inject()
        #expect(fallback.prompt.contains("最小改动"))
        #expect(fallback.injectedFactIDs.isEmpty)
        #expect(files.readGlobal().isEmpty)

        let boundary = String(repeating: "甲", count: MemoryInjector.maxGlobalInstructionCharacters - 1) + "乙"
        #expect(boundary.count == MemoryInjector.maxGlobalInstructionCharacters)
        for original in [boundary, boundary + "丙"] {
            try files.writeGlobal(original)
            let current = try inject()
            #expect(current.prompt.contains(boundary))
            #expect(!current.prompt.contains("丙"))
            #expect(!current.prompt.contains("最小改动"))
            #expect(current.injectedFactIDs.isEmpty)
            #expect(files.readGlobal() == original)
        }
    }

    @Test func sameKeywordChoicesStayInTheirAuthorizedScopesAfterReload() throws {
        let directory = try makeInjectorScopeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeA = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let scopeB = MemoryScope(sessionID: "session-b", projectID: "project-a")
        let otherProject = MemoryScope(sessionID: "session-c", projectID: "project-b")
        let validatedPrincipalA = MemoryTrustedPrincipal.validated(
            userID: "user-a", by: { $0 == "user-a" }
        )
        let principalA = try #require(validatedPrincipalA)
        let validatedPrincipalB = MemoryTrustedPrincipal.validated(
            userID: "user-b", by: { $0 == "user-b" }
        )
        let principalB = try #require(validatedPrincipalB)
        let writer = MemoryStore(directory: directory)
        let personalA = try writer.addFact(
            "晴天 personal-a", memoryScope: scopeA, ownerUserID: "user-a",
            visibility: .personal, trustedPrincipal: principalA
        )
        let personalB = try writer.addFact(
            "晴天 personal-b", memoryScope: scopeA, ownerUserID: "user-b",
            visibility: .personal, trustedPrincipal: principalB
        )
        let syntheticSecret = "synthetic-private-7392"
        let projectA = try writer.addFact(
            "晴天 project-a api_key=" + syntheticSecret, memoryScope: scopeB, visibility: .project
        )
        let projectB = try writer.addFact(
            "晴天 project-b", memoryScope: otherProject, visibility: .project
        )
        let temporaryA = try writer.addFact(
            "晴天 temporary-a", memoryScope: scopeA, visibility: .temporary,
            temporaryLifetimeID: "lifetime-a"
        )
        _ = try writer.addFact(
            "晴天 temporary-b", memoryScope: scopeA, visibility: .temporary,
            temporaryLifetimeID: "lifetime-b"
        )
        let legacyExact = try writer.addFact("晴天 legacy-exact", memoryScope: scopeA)
        _ = try writer.addFact("晴天 legacy-unscoped", sourceSessionID: scopeA.sessionID)

        let injector = MemoryInjector(store: MemoryStore(directory: directory), maxFacts: 10)
        let result = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: scopeA, trustedPrincipal: principalA,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(Set(result.injectedFactIDs) == Set([
            personalA.id, projectA.id, temporaryA.id, legacyExact.id
        ]))
        #expect(result.projectFactDisplayInputs.keys.sorted() == [projectA.id])
        let summary = try #require(result.projectFactDisplayInputs[projectA.id])
        #expect(summary == projectA.text)
        #expect(result.holds.contains(.legacyAuthorizationPending))
        #expect(!result.prompt.contains("personal-b"))
        #expect(!result.prompt.contains("project-b"))
        #expect(!result.prompt.contains("temporary-b"))
        #expect(!result.prompt.contains("legacy-unscoped"))

        let withoutPrincipal = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: scopeA,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(withoutPrincipal.holds.contains(.personalPrincipalUnavailable))
        #expect(!withoutPrincipal.prompt.contains("personal-a"))

        let otherSession = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: scopeB,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(otherSession.injectedFactIDs == [projectA.id])
        let otherProjectResult = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(scope: otherProject)
        )
        #expect(otherProjectResult.injectedFactIDs == [projectB.id])
        #expect(!otherProjectResult.prompt.contains("project-a"))
        #expect(!otherProjectResult.prompt.contains("legacy-exact"))
        #expect(!otherProjectResult.prompt.contains("temporary-a"))
        #expect(!otherProjectResult.prompt.contains("personal-a"))

        // Personal follows the verified owner across projects. Temporary is
        // still bound to its exact session/project and lifetime, even when the
        // same owner and lifetime are supplied after the project switch.
        let projectBForOwnerA = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: otherProject, trustedPrincipal: principalA,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(Set(projectBForOwnerA.injectedFactIDs) == Set([personalA.id, projectB.id]))
        #expect(!projectBForOwnerA.prompt.contains("temporary-a"))
        #expect(!projectBForOwnerA.prompt.contains("personal-b"))
        #expect(!projectBForOwnerA.prompt.contains("project-a"))

        let projectBForOwnerB = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(
                scope: otherProject, trustedPrincipal: principalB,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        #expect(Set(projectBForOwnerB.injectedFactIDs) == Set([personalB.id, projectB.id]))
        #expect(!projectBForOwnerB.prompt.contains("temporary-a"))
        #expect(!projectBForOwnerB.prompt.contains("personal-a"))

        // The old exact-scope prompt API remains limited to pre-classification
        // facts, so App consumers cannot inject a new class by accident.
        #expect(try injector.relevantFacts(for: "晴天", in: scopeA).map(\.id) == [legacyExact.id])
    }

    // 第 5、6 项：本人个人事实与 GLOBAL 每回合常驻，项目事实仍按关键词；事实块开头带"可能过时"提示。
    @Test func personalProjectFactsAndGlobalStayWithoutKeywordHit() throws {
        let directory = try makeInjectorScopeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeA = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let otherProject = MemoryScope(sessionID: "session-c", projectID: "project-b")
        let validatedPrincipalA = MemoryTrustedPrincipal.validated(userID: "user-a", by: { $0 == "user-a" })
        let principalA = try #require(validatedPrincipalA)
        let validatedPrincipalB = MemoryTrustedPrincipal.validated(userID: "user-b", by: { $0 == "user-b" })
        let principalB = try #require(validatedPrincipalB)
        let writer = MemoryStore(directory: directory)
        let personalA = try writer.addFact(
            "回答用中文 personal-a", memoryScope: scopeA, ownerUserID: "user-a",
            visibility: .personal, trustedPrincipal: principalA
        )
        _ = try writer.addFact(
            "回答用中文 personal-b", memoryScope: scopeA, ownerUserID: "user-b",
            visibility: .personal, trustedPrincipal: principalB
        )
        _ = try writer.addFact("晴天 project-a", memoryScope: scopeA, visibility: .project)
        _ = try writer.addFact("晴天 project-b", memoryScope: otherProject, visibility: .project)
        _ = try writer.addFact(
            "晴天 temporary-a", memoryScope: scopeA, visibility: .temporary,
            temporaryLifetimeID: "lifetime-a"
        )
        let files = MemoryFileStore(directory: directory)
        try files.writeGlobal("GLOBAL_STANDING")
        let injector = MemoryInjector(store: MemoryStore(directory: directory), maxFacts: 10, fileStore: files)

        let unrelated = "zzz unrelated"
        let projectTurn = try injector.injection(
            base: "base", userMessage: unrelated,
            context: MemoryInjectionContext(
                scope: scopeA, trustedPrincipal: principalA,
                temporaryLifetime: MemoryTemporaryLifetime(id: "lifetime-a")
            )
        )
        // 本人偏好与本项目已批准记忆都常驻；他人、外项目、临时仍不注入。
        #expect(projectTurn.injectedFactIDs.first == personalA.id)
        #expect(projectTurn.injectedFactIDs.count == 2)
        #expect(projectTurn.prompt.contains("GLOBAL_STANDING"))
        #expect(projectTurn.prompt.contains("personal-a"))
        #expect(projectTurn.prompt.contains("project-a"))
        #expect(projectTurn.prompt.contains("这些记忆可能已过时；涉及具体文件、命令或数据时先核实再用。"))
        for excluded in ["personal-b", "project-b", "temporary-a"] {
            #expect(!projectTurn.prompt.contains(excluded))
        }

        // 关键词命中时项目事实照旧进入，本人个人事实不重复。
        let keywordTurn = try injector.injection(
            base: "base", userMessage: "晴天",
            context: MemoryInjectionContext(scope: scopeA, trustedPrincipal: principalA)
        )
        #expect(keywordTurn.injectedFactIDs.filter { $0 == personalA.id }.count == 1)
        #expect(keywordTurn.prompt.contains("project-a"))
        #expect(!keywordTurn.prompt.contains("project-b"))

        // 没有可信身份时不带任何个人事实，GLOBAL 仍在。
        let noPrincipal = try injector.injection(
            base: "base", userMessage: unrelated,
            context: MemoryInjectionContext(scope: scopeA)
        )
        #expect(noPrincipal.injectedFactIDs.count == 1)
        #expect(noPrincipal.prompt.contains("project-a"))
        #expect(noPrincipal.prompt.contains("GLOBAL_STANDING"))
        #expect(!noPrincipal.prompt.contains("personal-"))

        // 无项目路径同样常驻：只有本人个人事实与 GLOBAL。
        let userLevel = try injector.userLevelInjection(
            base: "base", userMessage: unrelated, trustedPrincipal: principalA
        )
        #expect(userLevel.injectedFactIDs == [personalA.id])
        #expect(userLevel.prompt.contains("GLOBAL_STANDING"))
        #expect(userLevel.prompt.contains("这些记忆可能已过时"))
        for excluded in ["personal-b", "project-a", "project-b", "temporary-a"] {
            #expect(!userLevel.prompt.contains(excluded))
        }
        let userLevelOtherOwner = try injector.userLevelInjection(
            base: "base", userMessage: unrelated, trustedPrincipal: principalB
        )
        #expect(!userLevelOtherOwner.prompt.contains("personal-a"))
        #expect(userLevelOtherOwner.prompt.contains("personal-b"))
    }
}

struct CCRound2MemoryLimitTests {
    @Test func defaultRecallLimits() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc2-memory-unused-" + UUID().uuidString)
        let injector = MemoryInjector(store: MemoryStore(directory: root))
        #expect(injector.maxFacts == 10)
        #expect(injector.maxFactLength == 400)
        #expect(injector.maxTotalCharacters == 4000)
    }
}
