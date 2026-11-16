import Testing
import MinisCore

@Suite("Agent 回合控制注册表")
struct AgentTurnRegistryTests {
    @Test func interruptTargetsOnlyTheRequestedTurn() async {
        let registry = AgentTurnRegistry()
        let controllerA = TurnController()
        let controllerB = TurnController()
        let turnA = await controllerA.beginTurn()
        let turnB = await controllerB.beginTurn()

        await registry.register(controllerA, for: 101)
        await registry.register(controllerB, for: 202)
        await registry.interrupt(turnID: 101)

        #expect(await turnA.isCancelled())
        #expect(!(await turnB.isCancelled()))

        await registry.finish(turnID: 101)
        #expect(!(await registry.contains(turnID: 101)))
        #expect(await registry.contains(turnID: 202))
        await controllerA.finish(turnID: turnA.turnID)
        await controllerB.finish(turnID: turnB.turnID)
    }

    @Test func identityInterruptDoesNotAliasSameTurnAcrossSessions() async {
        let registry = AgentTurnRegistry()
        let controllerA = TurnController()
        let controllerB = TurnController()
        let turnA = await controllerA.beginTurn()
        let turnB = await controllerB.beginTurn()
        let identityA = AgentTurnIdentity(sessionID: "session-a", turnID: 1, messageID: "message-a")
        let identityB = AgentTurnIdentity(sessionID: "session-b", turnID: 1, messageID: "message-b")

        await registry.register(controllerA, identity: identityA)
        await registry.register(controllerB, identity: identityB)
        await registry.interrupt(identity: identityA)

        #expect(await turnA.isCancelled())
        #expect(!(await turnB.isCancelled()))

        await controllerA.finish(turnID: turnA.turnID)
        await controllerB.finish(turnID: turnB.turnID)
    }

    @Test func finishedIdentityCannotBeReRegistered() async {
        let registry = AgentTurnRegistry()
        let controller = TurnController()
        let turn = await controller.beginTurn()
        let identity = AgentTurnIdentity(sessionID: "session-a", turnID: 1, messageID: "message-a")

        await registry.register(controller, identity: identity)
        await registry.finish(identity: identity)
        await registry.register(controller, identity: identity)

        #expect(await registry.contains(identity: identity) == false)
        await controller.finish(turnID: turn.turnID)
    }

    @Test func sessionScopedTurnIDsDoNotAliasAndBareLookupFailsClosed() async {
        let registry = AgentTurnRegistry()
        let controllerA = TurnController()
        let controllerB = TurnController()
        let turnA = await controllerA.beginTurn()
        let turnB = await controllerB.beginTurn()

        await registry.register(controllerA, for: 7, sessionID: "child-a")
        await registry.register(controllerB, for: 7, sessionID: "child-b")
        await registry.interrupt(turnID: 7)

        #expect(!(await turnA.isCancelled()))
        #expect(!(await turnB.isCancelled()))
        await registry.interrupt(turnID: 7, sessionID: "child-a")
        #expect(await turnA.isCancelled())
        #expect(!(await turnB.isCancelled()))
        #expect(await registry.contains(turnID: 7, sessionID: "child-b"))
    }

    @Test func lateLegacySessionCommandsCannotClearIdentityRegistration() async {
        let registry = AgentTurnRegistry()
        let legacyController = TurnController()
        let identityController = TurnController()
        let legacyTurn = await legacyController.beginTurn()
        await registry.register(legacyController, for: 7, sessionID: "child")
        await registry.finish(turnID: 7, sessionID: "child")
        await legacyController.finish(turnID: legacyTurn.turnID)

        let identityTurn = await identityController.beginTurn()
        let identity = AgentTurnIdentity(
            sessionID: "child",
            turnID: 7,
            messageID: "message-after-restart"
        )
        let fact = await registry.register(
            identityController,
            identity: identity,
            transcriptRevision: 2
        )
        #expect(fact != nil)
        guard let fact else {
            Issue.record("lateLegacySessionCommandsCannotClearIdentityRegistration: register returned nil, remaining assertions never ran")
            return
        }

        await registry.interrupt(turnID: 7, sessionID: "child")
        #expect(!(await identityTurn.isCancelled()))
        await registry.finish(turnID: 7, sessionID: "child")
        #expect(await registry.accepts(fact))

        await registry.finish(fact)
        await identityController.finish(turnID: identityTurn.turnID)
    }

    @Test func newerRevisionRebindsAndLateTerminalFactCannotClearCurrent() async {
        let registry = AgentTurnRegistry()
        let firstController = TurnController()
        let reboundController = TurnController()
        _ = await firstController.beginTurn()
        _ = await reboundController.beginTurn()
        let firstIdentity = AgentTurnIdentity(
            sessionID: "session-a",
            turnID: 3,
            messageID: "message-a"
        )
        let reboundIdentity = AgentTurnIdentity(
            sessionID: "session-a",
            turnID: 3,
            messageID: "message-b"
        )

        let first = await registry.register(
            firstController,
            identity: firstIdentity,
            transcriptRevision: 10
        )
        #expect(first?.generation == 1)
        #expect(await registry.register(
            reboundController,
            identity: reboundIdentity,
            transcriptRevision: 10
        ) == nil)
        let rebound = await registry.register(
            reboundController,
            identity: reboundIdentity,
            transcriptRevision: 11
        )
        #expect(rebound?.generation == 2)

        guard let first, let rebound else {
            Issue.record("newerRevisionRebindsAndLateTerminalFactCannotClearCurrent: first/rebound registration is nil, remaining assertions never ran")
            return
        }
        #expect(!(await registry.accepts(first)))
        #expect(await registry.accepts(rebound))
        await registry.finish(first)
        #expect(await registry.accepts(rebound))
        await registry.finish(identity: firstIdentity)
        #expect(await registry.accepts(rebound))
    }

    @Test func resetRetiresStaleRevisionButAllowsStrictlyNewerResume() async {
        let registry = AgentTurnRegistry()
        let controller = TurnController()
        _ = await controller.beginTurn()
        let identity = AgentTurnIdentity(
            sessionID: "session-restart",
            turnID: 0,
            messageID: "message-restart"
        )

        let first = await registry.register(
            controller,
            identity: identity,
            transcriptRevision: 4
        )
        #expect(first != nil)
        await registry.reset()
        #expect(!(await registry.contains(identity: identity)))
        #expect(await registry.register(
            controller,
            identity: identity,
            transcriptRevision: 4
        ) == nil)
        let resumed = await registry.register(
            controller,
            identity: identity,
            transcriptRevision: 5
        )
        #expect(resumed?.generation == 2)
        #expect(await registry.contains(identity: identity))
    }

    @Test func metadataCapacitySaturatesClosedInsteadOfEvictingTombstones() async {
        let registry = AgentTurnRegistry()
        for index in 0..<512 {
            let identity = AgentTurnIdentity(
                sessionID: "bounded-session-\(index)",
                turnID: 0,
                messageID: "message-\(index)"
            )
            let fact = await registry.register(
                TurnController(),
                identity: identity,
                transcriptRevision: 1
            )
            #expect(fact != nil)
            if let fact {
                await registry.finish(fact)
            }
        }

        let saturated = AgentTurnIdentity(
            sessionID: "bounded-session-overflow",
            turnID: 0,
            messageID: "message-overflow"
        )
        #expect(await registry.register(
            TurnController(),
            identity: saturated,
            transcriptRevision: 1
        ) == nil)
    }
}
