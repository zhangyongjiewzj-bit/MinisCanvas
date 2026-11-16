import Foundation
import MinisCore

/// Package-bound starting data for the real Session sidebar journey. It never
/// performs an acceptance action; the UI operator does those in ContentView.
enum SessionPackageFieldFixture {
    static let activationArgument = "--session-field-journey"
    /// Opt-in synthetic history for D-PERF-07. It is never enabled by the
    /// ordinary session field journey or by a normal app launch.
    static let performanceArgument = "--perf07-transcript-field-fixture"
    private static let markerName = "session-field-fixture-v1.marker"
    private static let markerContents = "SESSION_FIELD_FIXTURE_V1\n"
    private static let performanceMarkerName = "perf07-transcript-field-fixture-v1.marker"
    private static let performanceMarkerContents = "PERF07_TRANSCRIPT_FIELD_FIXTURE_V1\nutf16_content_units=50000,100000\nmessages_per_session=20\n"

    enum FixtureError: LocalizedError {
        case insecureRoot
        case existingSessionsWithoutMarker
        case invalidMarker
        case invalidPerformanceArguments

        var errorDescription: String? {
            switch self {
            case .insecureRoot: "现场根权限不是 0700；拒绝准备会话数据"
            case .existingSessionsWithoutMarker: "现场根已有会话且没有夹具标记；请使用新现场根"
            case .invalidMarker: "现场根夹具标记不匹配；拒绝改写既有会话"
            case .invalidPerformanceArguments: "PERF07 夹具参数须唯一，且必须与会话现场旅程一起使用"
            }
        }
    }

    static func performanceRequested(arguments: [String]) throws -> Bool {
        let count = arguments.filter { $0 == performanceArgument }.count
        guard count <= 1,
              count == 0 || arguments.filter({ $0 == activationArgument }).count == 1 else {
            throw FixtureError.invalidPerformanceArguments
        }
        return count == 1
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        let count = arguments.filter { $0 == activationArgument }.count
        guard count > 0 else { return false }
        precondition(count == 1, "Session field journey activation must be unique")
        precondition(profile.mode == .packagedField,
                     "Session field journey requires a packaged-field profile")
        return true
    }

    /// Called before BridgeStore attaches the exact SessionStore instance.
    /// A restart on the same field root preserves UI mutations and deletions.
    static func prepare(
        profile: RuntimeIsolationProfile,
        store: SessionStore,
        arguments: [String] = CommandLine.arguments
    ) throws {
        precondition(profile.mode == .packagedField)
        precondition(store.directory == profile.sessionDirectory)
        let performanceFixture = try performanceRequested(arguments: arguments)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: profile.rootDirectory.path
        )
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700 else {
            throw FixtureError.insecureRoot
        }
        if performanceFixture {
            try preparePerformance(profile: profile, store: store)
            return
        }
        guard !FileManager.default.fileExists(atPath: profile.minisCanvasDirectory
            .appendingPathComponent(performanceMarkerName).path) else {
            throw FixtureError.invalidMarker
        }
        let marker = profile.minisCanvasDirectory.appendingPathComponent(
            markerName, isDirectory: false
        )
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let contents = try? String(contentsOf: marker, encoding: .utf8),
                  contents == markerContents else {
                throw FixtureError.invalidMarker
            }
            return
        }
        guard store.listSessions().isEmpty else {
            throw FixtureError.existingSessionsWithoutMarker
        }

        let projectDirectory = profile.rootDirectory.appendingPathComponent(
            "session-field-project", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        // One creation instant is shared by the whole fresh fixture batch.
        // Separate createSession calls each call Date(), leaving A/B only
        // visually tied while their persisted timestamps differ.
        let sharedCreatedAt = Date()
        let alpha = ChatSession(
            title: "S1566 琥珀会话", createdAt: sharedCreatedAt, updatedAt: sharedCreatedAt
        )
        let beta = ChatSession(
            title: "S1566 青松会话", createdAt: sharedCreatedAt, updatedAt: sharedCreatedAt
        )
        let project = ChatSession(
            title: "S1566 海蓝项目会话",
            createdAt: sharedCreatedAt,
            updatedAt: sharedCreatedAt,
            projectID: "session-field-project-1566",
            projectName: "S1566 现场项目",
            workingDirectory: projectDirectory.path
        )
        for session in [alpha, beta, project] {
            try store.updateSession(session)
        }
        for (index, session) in [alpha, beta].enumerated() {
            let token = index == 0 ? "琥珀" : "青松"
            for turn in 1...8 {
                try store.saveMessage(
                    LLMMessage(role: .user,
                               content: "\(token)用户第\(turn)条：隔离会话内容，供切换与滚动位置观察。"),
                    sessionID: session.id
                )
                try store.saveMessage(
                    LLMMessage(role: .assistant,
                               content: "\(token)助手第\(turn)条：这是合成现场文本，不会调用模型或网络。"),
                    sessionID: session.id
                )
            }
        }
        try store.saveMessage(
            LLMMessage(role: .user, content: "海蓝项目的独立合成内容。"),
            sessionID: project.id
        )
        try markerContents.write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: marker.path)
    }

    /// Seeds the exact production SessionStore that BridgeStore attaches.
    /// Character counts refer to message content only; role labels and
    /// transcript separators add rendered UTF-16 units in the formatter.
    private static func preparePerformance(
        profile: RuntimeIsolationProfile,
        store: SessionStore
    ) throws {
        guard !FileManager.default.fileExists(atPath: profile.minisCanvasDirectory
            .appendingPathComponent(markerName).path) else {
            throw FixtureError.invalidMarker
        }
        let marker = profile.minisCanvasDirectory.appendingPathComponent(
            performanceMarkerName, isDirectory: false
        )
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let contents = try? String(contentsOf: marker, encoding: .utf8),
                  contents == performanceMarkerContents else {
                throw FixtureError.invalidMarker
            }
            return
        }
        guard store.listSessions().isEmpty else {
            throw FixtureError.existingSessionsWithoutMarker
        }

        let createdAt = Date()
        for size in [50_000, 100_000] {
            let session = ChatSession(
                title: "PERF07 合成转录 \(size / 1_000)k UTF16",
                createdAt: createdAt,
                updatedAt: createdAt
            )
            try store.updateSession(session)
            let unitsPerMessage = size / 20
            for index in 1...20 {
                let prefix = "PERF07 synthetic \(size) UTF16 message \(index): "
                let content = prefix + String(
                    repeating: "文", count: unitsPerMessage - prefix.utf16.count
                )
                precondition(content.utf16.count == unitsPerMessage)
                try store.saveMessage(
                    LLMMessage(role: index.isMultiple(of: 2) ? .assistant : .user,
                               content: content),
                    sessionID: session.id
                )
            }
        }
        try performanceMarkerContents.write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: marker.path)
    }
}
