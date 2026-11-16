import Foundation
import Testing
@testable import MinisCore

private actor PSTCTestHandler: ProjectSessionProductionHandler {
    enum Mode: Sendable, Equatable { case committed, partial, wrongReceipt }

    let project = ProjectSessionAuthorizedProject(
        projectID: "project-1",
        displayName: "项目一",
        workdirReference: "bookmark:project-1"
    )
    let mode: Mode
    private(set) var listCalls = 0
    private(set) var resolveCalls = 0
    private(set) var authorizeCalls = 0
    private(set) var createCalls = 0
    private(set) var lastRequest: ProjectSessionCreateRequest?

    init(mode: Mode = .committed) { self.mode = mode }

    func listProjects(source: ProjectSessionTrustedSource) async throws -> [ProjectSessionAuthorizedProject] {
        listCalls += 1
        return [project]
    }

    func resolveProject(id: String, source: ProjectSessionTrustedSource) async throws -> ProjectSessionAuthorizedProject {
        resolveCalls += 1
        guard id == project.projectID else { throw ProjectSessionToolContractError.unauthorizedProject }
        return project
    }

    func authorizeCreate(_ request: ProjectSessionCreateRequest) async throws -> Bool {
        authorizeCalls += 1
        return !request.switchAfterCreate
    }

    func createSession(_ request: ProjectSessionCreateRequest) async throws -> ProjectSessionCreateOutcome {
        createCalls += 1
        lastRequest = request
        if mode == .partial {
            return .partial(.init(
                source: request.source.identity,
                projectID: project.projectID,
                idempotencyKey: request.idempotencyKey,
                recoveryReceiptID: "partial-1"
            ))
        }
        let store = AgentTaskStore()
        let consumer = AgentTaskCreationConsumer(
            store: store,
            knownProjectIDs: [project.projectID],
            authorizedScopeIDs: ["scope-1"]
        )
        let creation = try consumer.consume(AgentTaskCreationRequest(
            taskID: "child-1",
            parentID: request.source.identity.taskID,
            source: request.source.identity,
            title: request.title,
            projectID: project.projectID,
            workingDirectory: "/authorized/project-1",
            scopeID: "scope-1",
            idempotencyKey: mode == .wrongReceipt ? "wrong-key" : request.idempotencyKey
        ))
        return .committed(.init(
            targetSessionID: "target-session-1",
            runID: "run-1",
            sourceBacklinkID: "backlink-1",
            creationReceipt: creation,
            didSwitch: request.switchAfterCreate
        ))
    }
}

// A context placeholder only: no provider request is made by these dispatcher
// tests. The App handler is still a Core test double, not native bookmark proof.
private struct PSTCUnusedProvider: LLMProvider {
    var name: String { "unused-project-context" }
    var model = LLMModel(id: "unused", displayName: "Unused", provider: "Test")
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        throw ProjectSessionToolContractError.untrustedSource
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw ProjectSessionToolContractError.untrustedSource
    }
}

@Suite("Hidden project/session tool contract")
struct ProjectSessionToolContractTests {
    private var source: ProjectSessionTrustedSource {
        .init(identity: ParentRuntimeIdentity(
            sessionID: "source-session-1",
            conversationID: "source-conversation-1",
            turnID: "turn-handle:7",
            taskID: "parent-task-1",
            actorID: "agent-1"
        ))
    }

    private var createInput: [String: Any] {
        [
            "input_version": 1,
            "source_session_id": "source-session-1",
            "source_turn_id": "turn-handle:7",
            "project_id": "project-1",
            "workdir_reference": "bookmark:project-1",
            "title": "新任务",
            "initial_task": "完成指定工作",
            "idempotency_key": "source-turn-create-1"
        ]
    }

    @Test("all native project tool schemas reject undeclared keys on the wire")
    func nativeWireSchemasMatchClosedProjectParser() throws {
        for definition in ProjectSessionToolContract.definitions {
            let function = try #require(definition.providerOpenAIFunctionDict["function"] as? [String: Any])
            let schemas = [try #require(function["parameters"] as? [String: Any]),
                try #require(definition.providerAnthropicToolDict["input_schema"] as? [String: Any]),
                try #require(definition.responsesToolDict["parameters"] as? [String: Any])]
            for schema in schemas {
                #expect(schema["additionalProperties"] as? Bool == false)
                let properties = try #require(schema["properties"] as? [String: Any])
                #expect(Set(properties.keys) == Set(definition.parameters.keys))
                #expect(properties["tool_title"] == nil)
                #expect(schema["required"] as? [String] == definition.required)
            }
        }
        let unrelated = AgentToolDefinition(name: "unrelated", description: "unchanged",
            parameters: [:], required: [])
        let function = try #require(unrelated.providerOpenAIFunctionDict["function"] as? [String: Any])
        let schema = try #require(function["parameters"] as? [String: Any])
        #expect(schema["additionalProperties"] == nil)
    }

    @Test("project list still rejects title and permission metadata before handler")
    func projectListDoesNotAdmitUndeclaredMetadata() async throws {
        let handler = PSTCTestHandler()
        let executor = ProjectSessionToolExecutor(handler: handler)
        for metadata in ["tool_title", "grant", "absolute_path"] {
            do {
                _ = try await executor.executeValidated(name: ProjectSessionToolContract.projectList,
                    input: ["input_version": 1, metadata: "untrusted"], source: source, handler: handler)
                Issue.record("Undeclared project metadata unexpectedly executed")
            } catch let error as ProjectSessionToolContractError {
                #expect(error == .invalidInput("unknown_key"))
            }
        }
        #expect(await handler.listCalls == 0)
        _ = try await executor.executeValidated(name: ProjectSessionToolContract.projectList,
            input: ["input_version": 1], source: source, handler: handler)
        #expect(await handler.listCalls == 1)
    }

    @Test("definitions stay hidden until App composition")
    func hiddenByDefault() {
        #expect(Set(ProjectSessionToolContract.definitions.map(\.name)) == ProjectSessionToolContract.toolNames)
        #expect(ProjectSessionToolContract.toolNames.isDisjoint(
            with: Set(AgentToolCatalog.makeTools().map(\.name))
        ))
        #expect(ProjectSessionToolContract.toolNames.isDisjoint(
            with: BuiltinToolExecutor.defaultRegisteredToolNames()
        ))
    }

    @Test("unbound and untrusted dispatch cannot call a production handler")
    func rejectsUnboundAndUntrusted() async {
        do {
            _ = try await ProjectSessionToolExecutor(handler: nil).execute(
                name: ProjectSessionToolContract.projectList,
                input: ["input_version": 1]
            )
            Issue.record("Unbound project tool unexpectedly executed")
        } catch let error as ProjectSessionToolContractError {
            #expect(error == .handlerUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let handler = PSTCTestHandler()
        do {
            _ = try await ProjectSessionToolExecutor(handler: handler).execute(
                name: ProjectSessionToolContract.projectList,
                input: ["input_version": 1]
            )
            Issue.record("Missing trusted runtime unexpectedly executed")
        } catch let error as ProjectSessionToolContractError {
            #expect(error == .untrustedSource)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await handler.listCalls == 0)
    }

    @Test("strict parser and source match reject before App effect")
    func rejectsModelForgedFacts() async {
        let handler = PSTCTestHandler()
        let executor = ProjectSessionToolExecutor(handler: handler)
        var extra = createInput
        extra["absolute_path"] = "/tmp/elsewhere"
        await expectFailure(.invalidInput("unknown_key"), executor: executor, input: extra, handler: handler)

        var sourceMismatch = createInput
        sourceMismatch["source_turn_id"] = "forged-turn"
        await expectFailure(.sourceMismatch, executor: executor, input: sourceMismatch, handler: handler)

        var unknown = createInput
        unknown["project_id"] = "ungranted"
        await expectFailure(.unauthorizedProject, executor: executor, input: unknown, handler: handler)

        var unapprovedSwitch = createInput
        unapprovedSwitch["switch_after_create"] = true
        await expectFailure(.creationNotAuthorized, executor: executor, input: unapprovedSwitch, handler: handler)
    }

    @Test("authorized handler receives trusted source and returns canonical receipt")
    func delegatesWithTrustedIdentity() async throws {
        let handler = PSTCTestHandler()
        let executor = ProjectSessionToolExecutor(handler: handler)
        let list = try await executor.executeValidated(
            name: ProjectSessionToolContract.projectList,
            input: ["input_version": 1], source: source, handler: handler
        )
        #expect(list.contains("bookmark:project-1"))
        let resolved = try await executor.executeValidated(
            name: ProjectSessionToolContract.projectResolve,
            input: ["input_version": 1, "project_id": "project-1"],
            source: source, handler: handler
        )
        #expect(resolved.contains("项目一"))
        let created = try await executor.executeValidated(
            name: ProjectSessionToolContract.sessionCreate,
            input: createInput, source: source, handler: handler
        )
        #expect(created.contains("\"status\":\"committed\""))
        #expect(created.contains("\"task_id\":\"child-1\""))
        let request = await handler.lastRequest
        #expect(request?.source.identity == source.identity)
        #expect(request?.switchAfterCreate == false)
        #expect(await handler.createCalls == 1)
    }

    @Test("invalid committed result cannot become success; partial remains explicit")
    func checksProductionResult() async throws {
        let wrong = PSTCTestHandler(mode: .wrongReceipt)
        do {
            _ = try await ProjectSessionToolExecutor(handler: wrong).executeValidated(
                name: ProjectSessionToolContract.sessionCreate,
                input: createInput, source: source, handler: wrong
            )
            Issue.record("Changed receipt unexpectedly accepted")
        } catch let error as ProjectSessionToolContractError {
            #expect(error == .invalidProductionReceipt)
        }

        let partial = PSTCTestHandler(mode: .partial)
        let result = try await ProjectSessionToolExecutor(handler: partial).executeValidated(
            name: ProjectSessionToolContract.sessionCreate,
            input: createInput, source: source, handler: partial
        )
        #expect(result.contains("\"ok\":false"))
        #expect(result.contains("\"status\":\"partial\""))
        #expect(result.contains("partial-1"))
    }

    private func realTurnContext() async throws -> (TurnController.TurnHandle, AgentExecutionContextSnapshot) {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let seed = ParentRuntimeIdentitySeed(sessionID: "runtime-session", conversationID: "runtime-session",
            taskID: "runtime-parent", actorID: "app")
        let identity = try seed.makeIdentity(using: handle)
        return (handle, AgentExecutionContextSnapshot(provider: PSTCUnusedProvider(), approvalGate: nil,
            turnController: controller, currentConversationID: seed.conversationID,
            makeChildBudget: nil, deadline: nil, parentTurnHandle: handle, parentRuntimeIdentity: identity))
    }

    private var runtimeCreateInput: [String: Any] {
        var input = createInput
        input.removeValue(forKey: "source_session_id")
        input.removeValue(forKey: "source_turn_id")
        return input
    }

    @Test("model may omit source bindings; actual live turn supplies them without changing raw arguments")
    func liveRuntimeBindsMissingSource() async throws {
        let (handle, context) = try await realTurnContext()
        let handler = PSTCTestHandler()
        let executor = ProjectSessionToolExecutor(handler: handler)
        let modelInput = runtimeCreateInput
        let frozenRaw = try JSONSerialization.data(withJSONObject: modelInput, options: [.sortedKeys])
        let output = try await AgentExecutionContext.$current.withValue(context) {
            // Real list/resolve receipts remain the project authority boundary.
            let list = try await executor.execute(name: ProjectSessionToolContract.projectList,
                input: ["input_version": 1])
            #expect(list.contains("project-1"))
            _ = try await executor.execute(name: ProjectSessionToolContract.projectResolve,
                input: ["input_version": 1, "project_id": "project-1"])
            return try await executor.execute(name: ProjectSessionToolContract.sessionCreate, input: modelInput)
        }
        let request = try #require(await handler.lastRequest)
        #expect(output.contains("\"status\":\"committed\""))
        #expect(request.source.identity == context.parentRuntimeIdentity)
        #expect(request.source.identity.turnID == "turn-handle:\(handle.turnID)")
        #expect(request.source.identity.taskID == "runtime-parent")
        #expect(await handler.authorizeCalls == 1)
        #expect(await handler.createCalls == 1)
        #expect(try JSONSerialization.data(withJSONObject: modelInput, options: [.sortedKeys]) == frozenRaw)
        #expect(!modelInput.keys.contains("source_session_id"))
        #expect(!modelInput.keys.contains("source_turn_id"))
        await handle.finish()
    }

    @Test("either single missing source field binds independently", arguments: ["source_session_id", "source_turn_id"])
    func liveRuntimeBindsOneMissingSource(missing: String) async throws {
        let (handle, context) = try await realTurnContext()
        let handler = PSTCTestHandler()
        var input = runtimeCreateInput
        input["source_session_id"] = context.parentRuntimeIdentity?.sessionID
        input["source_turn_id"] = context.parentRuntimeIdentity?.turnID
        input.removeValue(forKey: missing)
        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await ProjectSessionToolExecutor(handler: handler).execute(
                name: ProjectSessionToolContract.sessionCreate, input: input)
        }
        #expect(await handler.lastRequest?.source.identity == context.parentRuntimeIdentity)
        await handle.finish()
    }

    @Test("explicit source errors cannot be overwritten by trusted defaults",
          arguments: ["source_session_id", "source_turn_id"], ["wrong-id", "empty", "null", "number"])
    func liveRuntimeRejectsExplicitSource(field: String, kind: String) async throws {
        let (handle, context) = try await realTurnContext()
        let handler = PSTCTestHandler()
        var input = runtimeCreateInput
        switch kind {
        case "empty": input[field] = ""
        case "null": input[field] = NSNull()
        case "number": input[field] = 42
        default: input[field] = "foreign-runtime-id"
        }
        do {
            _ = try await AgentExecutionContext.$current.withValue(context) {
                try await ProjectSessionToolExecutor(handler: handler).execute(
                    name: ProjectSessionToolContract.sessionCreate, input: input)
            }
            Issue.record("Explicit invalid source unexpectedly reached creation")
        } catch let error as ProjectSessionToolContractError {
            #expect(error == (kind == "wrong-id" ? .sourceMismatch : .invalidInput(field)))
        }
        #expect(await handler.resolveCalls == 0)
        #expect(await handler.authorizeCalls == 0)
        #expect(await handler.createCalls == 0)
        await handle.finish()
    }

    @Test("absent runtime cannot gain authority from omitted source parameters")
    func missingRuntimeCannotBindSource() async throws {
        let handler = PSTCTestHandler()
        do {
            _ = try await AgentExecutionContext.$current.withValue(nil) {
                try await ProjectSessionToolExecutor(handler: handler).execute(
                    name: ProjectSessionToolContract.sessionCreate, input: runtimeCreateInput)
            }
            Issue.record("Absent runtime unexpectedly created task")
        } catch let error as ProjectSessionToolContractError { #expect(error == .untrustedSource) }
        #expect(await handler.resolveCalls == 0)
        #expect(await handler.createCalls == 0)
    }

    @Test("finished and interrupted real turns reject missing source arguments", arguments: [false, true])
    func endedRuntimeCannotBindSource(interrupted: Bool) async throws {
        let (handle, context) = try await realTurnContext()
        if interrupted { await handle.interrupt() } else { await handle.finish() }
        let handler = PSTCTestHandler()
        do {
            _ = try await AgentExecutionContext.$current.withValue(context) {
                try await ProjectSessionToolExecutor(handler: handler).execute(
                    name: ProjectSessionToolContract.sessionCreate, input: runtimeCreateInput)
            }
            Issue.record("Ended runtime unexpectedly created task")
        } catch let error as ProjectSessionToolContractError { #expect(error == .untrustedSource) }
        #expect(await handler.resolveCalls == 0)
        #expect(await handler.createCalls == 0)
        await handle.finish()
    }

    @Test("cancelled Swift task cannot use an otherwise live parent turn")
    func cancelledTaskCannotBindSource() async throws {
        let (handle, context) = try await realTurnContext()
        let handler = PSTCTestHandler()
        let child = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await AgentExecutionContext.$current.withValue(context) {
                    try await ProjectSessionToolExecutor(handler: handler).execute(
                        name: ProjectSessionToolContract.sessionCreate, input: runtimeCreateInput)
                }
                Issue.record("Cancelled task unexpectedly created task")
            } catch let error as ProjectSessionToolContractError { #expect(error == .untrustedSource) }
        }
        try await child.value
        #expect(await handler.resolveCalls == 0)
        #expect(await handler.createCalls == 0)
        await handle.finish()
    }

    @Test("session-create schema makes only runtime source bindings optional")
    func schemaAllowsRuntimeBindings() throws {
        let definition = try #require(ProjectSessionToolContract.definitions.first {
            $0.name == ProjectSessionToolContract.sessionCreate
        })
        #expect(!definition.required.contains("source_session_id"))
        #expect(!definition.required.contains("source_turn_id"))
        #expect(definition.required == ["input_version", "project_id", "workdir_reference", "title", "initial_task", "idempotency_key"])
    }

    private func expectFailure(
        _ expected: ProjectSessionToolContractError,
        executor: ProjectSessionToolExecutor,
        input: [String: Any],
        handler: PSTCTestHandler
    ) async {
        let before = await handler.createCalls
        do {
            _ = try await executor.executeValidated(
                name: ProjectSessionToolContract.sessionCreate,
                input: input, source: source, handler: handler
            )
            Issue.record("Invalid input unexpectedly created a task")
        } catch let error as ProjectSessionToolContractError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await handler.createCalls == before)
    }
}
