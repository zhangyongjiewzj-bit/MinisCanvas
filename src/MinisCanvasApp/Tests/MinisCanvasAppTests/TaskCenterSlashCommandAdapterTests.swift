import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center slash read contract")
struct TaskCenterSlashCommandAdapterTests {
    @Test func handlesOnlyTaskCenterSlashNames() {
        #expect(TaskCenterSlashCommandAdapter.handles("/status"))
        #expect(TaskCenterSlashCommandAdapter.handles("  /tasks status=queued"))
        #expect(!TaskCenterSlashCommandAdapter.handles("/compact"))
        #expect(!TaskCenterSlashCommandAdapter.handles("/workflow draft"))
        #expect(!TaskCenterSlashCommandAdapter.handles("普通消息"))
    }

    @Test func allCommandsProduceStableRedactedJSON() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "task-a",
            parentID: "parent-a",
            providerID: "provider-a",
            modelID: "model-a",
            configurationFingerprint: "secret-config-fingerprint",
            routeReceiptID: "route-a"
        )
        _ = try store.enqueue(
            taskID: "task-b",
            parentID: "parent-a",
            providerID: "provider-b",
            modelID: "model-b",
            routeReceiptID: "route-b"
        )
        let adapter = TaskCenterSlashCommandAdapter(
            observation: TaskCenterObservationSnapshot(taskStore: store)
        )

        let commands = ["/status", "/tasks", "/boundary", "/provider"]
        for command in commands {
            let first = adapter.execute(command)
            let second = adapter.execute(command)
            #expect(first == second)
            let object = try jsonObject(first)
            #expect(object["ok"] as? Bool == true)
            #expect(object["schema_version"] as? Int == 1)
        }

        let tasks = try jsonObject(adapter.execute("/tasks"))
        let taskJSON = try JSONSerialization.data(withJSONObject: tasks["payload"] as Any)
        let taskText = String(data: taskJSON, encoding: .utf8) ?? ""
        #expect(taskText.contains("secret-config-fingerprint") == false)
        #expect(taskText.contains("configuration") == false)
    }

    @Test func taskFiltersAreReadOnlyAndDeterministicallySorted() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "task-b", parentID: "parent-a", providerID: "provider-a", modelID: "model-a")
        _ = try store.enqueue(taskID: "task-a", parentID: "parent-a", providerID: "provider-a", modelID: "model-a")
        _ = try store.enqueue(taskID: "task-c", parentID: "parent-b", providerID: "provider-b", modelID: "model-b")
        let before = store.taskCenterSnapshots()
        let adapter = TaskCenterSlashCommandAdapter(observation: TaskCenterObservationSnapshot(taskStore: store))

        let output = adapter.execute("/tasks status=queued provider_id=provider-a")
        let payload = try jsonObject(output)["payload"] as? [String: Any]
        let rows = payload?["tasks"] as? [[String: Any]]
        #expect(rows?.compactMap { $0["task_id"] as? String } == ["task-a", "task-b"])
        #expect(store.taskCenterSnapshots() == before)
    }

    @Test func viewModelInitializerRetainsTaskRowsForTasksCommand() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "task-from-view-model",
            parentID: "parent",
            providerID: "provider",
            modelID: "model"
        )
        let adapter = TaskCenterSlashCommandAdapter(
            viewModel: TaskCenterViewModel(taskStore: store)
        )

        let payload = try #require(
            jsonObject(adapter.execute("/tasks"))["payload"] as? [String: Any]
        )
        let rows = try #require(payload["tasks"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["task_id"] as? String == "task-from-view-model")
    }

    @Test func providerAndBoundaryExposeOnlyReadModelFacts() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(taskID: "task-a", parentID: "parent-a", providerID: "provider-a", modelID: "model-a", routeReceiptID: "route-a")
        let adapter = TaskCenterSlashCommandAdapter(observation: TaskCenterObservationSnapshot(taskStore: store))

        let boundary = try jsonObject(adapter.execute("/boundary"))["payload"] as? [String: Any]
        #expect(boundary?["mutations"] as? String == "forbidden")
        #expect(boundary?["provider_calls"] as? Int == 0)
        #expect(boundary?["transcript_included"] as? Bool == false)

        let provider = try jsonObject(adapter.execute("/provider"))["payload"] as? [String: Any]
        let bindings = provider?["bindings"] as? [[String: Any]]
        #expect(bindings?.first?["provider_id"] as? String == "provider-a")
        #expect((bindings?.first?["model_id"] as? String) == "model-a")
    }

    @Test func compactIsNotOwnedByObservationAdapter() throws {
        let calls = LockedInt()
        let adapter = TaskCenterSlashCommandAdapter {
            calls.increment()
            return TaskCenterObservationSnapshot(snapshots: [])
        }

        #expect(!TaskCenterSlashCommandAdapter.handles("/compact"))
        _ = adapter.execute("/compact")
        #expect(calls.value == 0)
    }

    @Test func unknownRepeatedSensitiveAndMalformedParametersFailClosedWithoutReading() throws {
        let calls = LockedInt()
        let adapter = TaskCenterSlashCommandAdapter {
            calls.increment()
            return TaskCenterObservationSnapshot(snapshots: [])
        }
        let rejected = [
            "/unknown",
            "/status extra=1",
            "/tasks nope=value",
            "/tasks status=queued status=failed",
            "/tasks api_key=not-to-be-read",
            "/compact token=not-to-be-read",
            "/tasks status=not-a-status",
            "/tasks status='unterminated"
        ]

        for input in rejected {
            let output = adapter.execute(input)
            let root = try jsonObject(output)
            #expect(root["ok"] as? Bool == false)
            #expect(root["command"] is NSNull)
            #expect(root["payload"] is NSNull)
            #expect(output.contains("not-to-be-read") == false)
        }
        #expect(calls.value == 0)
    }

    @Test func sensitiveObservationIdentifiersAreRedacted() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "task-with-secret-token",
            parentID: "parent",
            providerID: "provider",
            modelID: "model"
        )
        let output = TaskCenterSlashCommandAdapter(
            observation: TaskCenterObservationSnapshot(taskStore: store)
        ).execute("/tasks")
        #expect(output.contains("task-with-secret-token") == false)
        #expect(output.contains("redacted") == true)
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        let data = try #require(string.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
