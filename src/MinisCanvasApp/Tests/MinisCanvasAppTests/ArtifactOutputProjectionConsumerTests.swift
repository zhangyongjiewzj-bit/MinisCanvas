import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("P3 artifact output user projection")
struct ArtifactOutputProjectionConsumerTests {
    @Test("ready projection exposes only approved actions")
    func readyProjectionIsActionableWithoutTargetTransport() {
        let validation = ArtifactTargetValidation(
            artifactID: "artifact-safe",
            action: .open,
            status: .ready,
            targetPath: "/private/secret/should-not-project.mp4",
            message: "raw provider response must not pass through"
        )

        let projection = validation.userProjection
        #expect(projection.state == .ready)
        #expect(projection.canOpen)
        #expect(projection.canReveal)
        #expect(!projection.canReopen)
        #expect(projection.recoveryAction == nil)
        #expect(!projection.detail.contains("secret"))
        #expect(!projection.detail.contains("raw"))
    }

    @Test("stale projection is fail-closed")
    func staleProjectionBlocksOpenAndReopen() {
        let validation = ArtifactTargetValidation(
            artifactID: "artifact-stale",
            action: .open,
            status: .stale,
            targetPath: "media/result.mp4",
            message: "untrusted target detail"
        )

        let projection = validation.userProjection
        #expect(projection.state == .stale)
        #expect(!projection.canOpen)
        #expect(!projection.canReveal)
        #expect(!projection.canReopen)
        #expect(!projection.isActionable)
        #expect(projection.detail == "文件内容已变化，已阻止打开。")
    }

    @Test("rollback available projection carries explicit reopen action")
    func rollbackProjectionOffersOnlyReopen() {
        let validation = ArtifactTargetValidation(
            artifactID: "artifact-deleted",
            action: .reveal,
            status: .rollbackAvailable,
            targetPath: "media/result.mp4",
            message: "ignored external detail"
        )

        let projection = validation.userProjection
        #expect(projection.state == .rollbackAvailable)
        #expect(!projection.canOpen)
        #expect(!projection.canReveal)
        #expect(projection.canReopen)
        #expect(projection.recoveryAction == .reopen)
        #expect(projection.detail == "可安全执行重新打开恢复。")
    }

    @Test("projection round trip keeps terminal state")
    func projectionIsCodableAndStable() throws {
        let projection = ArtifactOutputUserProjection.project(
            ArtifactTargetValidation(
                artifactID: "artifact-recovery",
                action: .open,
                status: .recoveryRequired,
                targetPath: nil,
                message: "ignored"
            )
        )
        let decoded = try JSONDecoder().decode(
            ArtifactOutputUserProjection.self,
            from: JSONEncoder().encode(projection)
        )
        #expect(decoded == projection)
        #expect(decoded.state == .recoveryRequired)
        #expect(decoded.recoveryAction == nil)
    }

    @Test("source backlink navigates current and authorized projects")
    func sourceBacklinkNavigationScopesTargets() {
        let backlink = ArtifactResultCardSourceBacklink(
            sourceArtifactID: "artifact-source",
            sourceRevision: "source-revision",
            producerRevision: "producer-revision",
            resultRevision: "result-revision"
        )
        let current = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-current",
            projectAccess: .currentProject
        ))
        #expect(current.isNavigable)
        #expect(current.projectID == "project-current")
        #expect(current.taskID == "source-task")

        let authorized = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-other",
            projectAccess: .authorizedProject,
            bookmarkAuthorized: true
        ))
        #expect(authorized.isNavigable)
        #expect(authorized.projectID == "project-other")
        #expect(authorized.sourceArtifactID == "artifact-source")
    }

    @Test("source backlink blocks deleted task and invalid bookmark")
    func sourceBacklinkNavigationFailsClosedForDeletionAndBookmark() {
        let backlink = ArtifactResultCardSourceBacklink(
            sourceArtifactID: "artifact-source",
            sourceRevision: "source-revision",
            producerRevision: "producer-revision",
            resultRevision: "result-revision"
        )
        let missingBookmark = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-other",
            projectAccess: .authorizedProject,
            bookmarkAuthorized: false
        ))
        #expect(!missingBookmark.isNavigable)
        #expect(missingBookmark.projectID == nil)
        #expect(missingBookmark.actionableError == "来源项目尚未获得书签授权，无法跳转。")

        let deletedTask = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-current",
            taskAvailability: .deleted,
            projectAccess: .currentProject
        ))
        #expect(!deletedTask.isNavigable)
        #expect(deletedTask.taskID == nil)
        #expect(deletedTask.actionableError == "来源任务已删除，无法跳转。")
    }

    @Test("source backlink requires restart identity revalidation")
    func sourceBacklinkRestartIdentityIsRequired() {
        let backlink = ArtifactResultCardSourceBacklink(
            sourceArtifactID: "artifact-source",
            sourceRevision: "source-revision",
            producerRevision: "producer-revision",
            resultRevision: "result-revision"
        )
        let mismatch = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-current",
            projectAccess: .currentProject,
            restartIdentity: .mismatch
        ))
        #expect(!mismatch.isNavigable)
        #expect(mismatch.sourceArtifactID == nil)
        #expect(mismatch.actionableError == "来源身份与重启后的记录不匹配，已阻止跳转。")

        let revalidated = backlink.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-current",
            projectAccess: .currentProject,
            restartIdentity: .revalidated
        ))
        #expect(revalidated.isNavigable)

        let missingSource = ArtifactResultCardSourceBacklink(
            sourceArtifactID: nil,
            sourceRevision: "source-revision",
            producerRevision: "producer-revision",
            resultRevision: "result-revision"
        )
        let blocked = missingSource.navigation(using: navigationContext(
            currentProjectID: "project-current",
            sourceProjectID: "project-current",
            projectAccess: .currentProject
        ))
        #expect(!blocked.isNavigable)
        #expect(blocked.actionableError == "结果没有来源 artifact，无法跳转。")
    }

    @Test("app-authored backlink card persists through restart")
    func persistedBacklinkCardRestoresSourceNavigationFacts() throws {
        let card = ArtifactResultCardProjection(
            cardID: "result-card-1",
            resultArtifactID: "artifact-result",
            sourceBacklink: ArtifactResultCardSourceBacklink(
                sourceArtifactID: "artifact-source",
                sourceRevision: "source-revision",
                producerRevision: "producer-revision",
                resultRevision: "result-revision"
            )
        )

        let restored = try JSONDecoder().decode(
            ArtifactResultCardProjection.self,
            from: JSONEncoder().encode(card)
        )
        #expect(restored == card)
        #expect(restored.schema == ArtifactResultCardProjection.serializationSchema)
        #expect(restored.revision == ArtifactResultCardProjection.serializationRevision)

        let navigation = restored.navigation(
            using: navigationContext(
                currentProjectID: "project-current",
                sourceProjectID: "project-current",
                projectAccess: .currentProject,
                restartIdentity: .revalidated
            ),
            decision: .switchToSource
        )
        #expect(navigation.isNavigable)
        #expect(navigation.projectID == "project-current")
        #expect(navigation.taskID == "source-task")
        #expect(navigation.sourceArtifactID == "artifact-source")
    }

    @Test("restored backlink card requires explicit source switch decision")
    func restoredBacklinkCardDoesNotAutoSwitch() {
        let card = ArtifactResultCardProjection(
            cardID: "result-card-1",
            sourceBacklink: ArtifactResultCardSourceBacklink(
                sourceArtifactID: "artifact-source",
                sourceRevision: "source-revision",
                producerRevision: "producer-revision",
                resultRevision: "result-revision"
            )
        )

        let current = card.navigation(
            using: navigationContext(
                currentProjectID: "project-current",
                sourceProjectID: "project-other",
                projectAccess: .authorizedProject,
                bookmarkAuthorized: true
            ),
            decision: .remainOnCurrent
        )
        #expect(!current.isNavigable)
        #expect(current.state == .notRequested)
        #expect(current.projectID == nil)
        #expect(current.taskID == nil)
        #expect(current.sourceArtifactID == nil)
        #expect(current.actionableError == nil)
        #expect(current.detail == "用户未选择切换来源。")

        let switched = card.navigation(
            using: navigationContext(
                currentProjectID: "project-current",
                sourceProjectID: "project-other",
                projectAccess: .authorizedProject,
                bookmarkAuthorized: true
            ),
            decision: .switchToSource
        )
        #expect(switched.isNavigable)
        #expect(switched.projectID == "project-other")
    }

    @Test("backlink card rejects future persistence schema and empty identity")
    func backlinkCardPersistenceFailsClosed() throws {
        let card = ArtifactResultCardProjection(
            cardID: "result-card-1",
            sourceBacklink: ArtifactResultCardSourceBacklink(
                sourceArtifactID: "artifact-source",
                sourceRevision: "source-revision",
                producerRevision: "producer-revision",
                resultRevision: "result-revision"
            )
        )
        let encoded = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(card)
            ) as? [String: Any]
        )

        var future = encoded
        future["revision"] = ArtifactResultCardProjection.serializationRevision + 1
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                ArtifactResultCardProjection.self,
                from: JSONSerialization.data(withJSONObject: future)
            )
        }

        var emptyIdentity = encoded
        emptyIdentity["cardID"] = "   "
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                ArtifactResultCardProjection.self,
                from: JSONSerialization.data(withJSONObject: emptyIdentity)
            )
        }
    }

    private func navigationContext(
        currentProjectID: String,
        sourceProjectID: String,
        sourceTaskID: String = "source-task",
        taskAvailability: ArtifactSourceTaskAvailability = .available,
        projectAccess: ArtifactSourceProjectAccess,
        bookmarkAuthorized: Bool = false,
        restartIdentity: ArtifactSourceRestartIdentity = .notRequired,
        resolvedSourceArtifactID: String? = "artifact-source",
        observedSourceRevision: String? = "source-revision"
    ) -> ArtifactSourceNavigationContext {
        ArtifactSourceNavigationContext(
            currentProjectID: currentProjectID,
            sourceProjectID: sourceProjectID,
            sourceTaskID: sourceTaskID,
            resolvedSourceArtifactID: resolvedSourceArtifactID,
            observedSourceRevision: observedSourceRevision,
            projectAccess: projectAccess,
            bookmarkAuthorized: bookmarkAuthorized,
            taskAvailability: taskAvailability,
            restartIdentity: restartIdentity
        )
    }
}
