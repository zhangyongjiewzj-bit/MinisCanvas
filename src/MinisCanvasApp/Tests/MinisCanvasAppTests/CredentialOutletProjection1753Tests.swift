import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class Credential1753URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        Self.capturedBody = Self.bodyData(from: request)
        let body = Data(#"{"id":"fixture","object":"chat.completion","created":0,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"public reply"},"finish_reason":"stop"}]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body.isEmpty ? nil : body
    }
}

@Suite("1753 approved credential stays out of App outlets", .serialized)
@MainActor
struct CredentialOutletProjection1753Tests {
    private func fixture() throws -> (
        center: SettingsCenter, chat: ChatStore, backing: CredentialIsolatedBacking,
        root: URL, defaults: UserDefaults, defaultsDomain: String
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CredentialOutlet1753-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "CredentialOutlet1753." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let backing = CredentialIsolatedBacking()
        let keychain = KeychainStore(backing: backing)
        let badgeStore = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: badgeStore,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(domain)),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        #expect(chat.attachPersistence(center.sessionStore, badgeStore: badgeStore))
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        return (center, chat, backing, root, defaults, domain)
    }

    private func approvedOpaqueCredential(
        chat: ChatStore, backing: CredentialIsolatedBacking, value: String
    ) async throws {
        let session = try #require(chat.activeSessionID)
        let request = try #require(chat.credentialBroker.captureSecureField(value, sessionID: session))
        let outcome = await chat.credentialBroker.confirm(
            requestID: request.id, sessionID: session,
            providerID: "SYNTHETIC1753_API_KEY", baseURL: "https://fixture.invalid/v1",
            modelIDs: ["synthetic-model"], protocolType: .openaiCompatible,
            riskConfirmed: true
        )
        #expect(outcome == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC1753_API_KEY") == value)
        #expect(chat.credentialBroker.pending == nil)
    }

    @Test("Provider payload keeps credential only in authorization header")
    func providerPayloadDoesNotPutSavedCredentialInModelBody() async throws {
        let (center, chat, backing, root, defaults, domain) = try fixture()
        defer {
            Credential1753URLProtocol.captured = nil
            Credential1753URLProtocol.capturedBody = nil
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let value = "opaque1753" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await approvedOpaqueCredential(chat: chat, backing: backing, value: value)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [Credential1753URLProtocol.self]
        let provider = OpenAICompatibleProvider(
            apiKey: try #require(backing.get("SYNTHETIC1753_API_KEY")),
            model: .gpt4oMini, customBaseURL: "https://fixture.invalid/v1",
            session: URLSession(configuration: sessionConfig)
        )
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "ordinary question")],
            systemPrompt: nil, maxTokens: 16, temperature: nil
        )
        #expect(response.text == "public reply")
        let sent = try #require(Credential1753URLProtocol.captured)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer " + value)
        let modelBody = try #require(Credential1753URLProtocol.capturedBody)
        #expect(String(decoding: modelBody, as: UTF8.self).contains("ordinary question"))
        #expect(!String(decoding: modelBody, as: UTF8.self).contains(value))
        #expect(!chat.messages.map(\.content).joined().contains(value))
        #expect(center.logManager.recentLogsText().contains(value) == false)
    }

    @Test("confirmed opaque credential echo cannot enter transcript, log, receipt, export or backup")
    func approvedEchoIsAbsentFromDurableAndDisplayConsumers() async throws {
        let (center, chat, backing, root, defaults, domain) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let value = "opaque1753" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await approvedOpaqueCredential(chat: chat, backing: backing, value: value)
        #expect(chat.credentialBroker.protect(value) != value)
        chat.appendAssistant("provider echo " + value)
        chat.appendCanvasNotice("tool or canvas notice " + value)
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.appendAssistant("", toSession: sessionID, isStreaming: true))
        let index = chat.messages.count - 1
        #expect(chat.updateMessageContent(sessionID: sessionID, at: index, append: "stream " + value))
        chat.credentialBroker.cancel(sessionID: sessionID)
        chat.appendAssistant("late callback " + value)
        #expect(chat.messages.allSatisfy { !$0.content.contains(value) })
        #expect(chat.messages.contains { $0.content.contains("stream ") })

        let redactor = ChatTranscriptRedactor(store: center.envStore)
        let plain = ChatTranscriptFormatter.plainText(chat.messages, redactor: redactor)
        let ax = ChatTranscriptFormatter.accessibilityText(chat.messages, redactor: redactor)
        let rich = ChatTranscriptFormatter.attributedString(chat.messages, redactor: redactor).string
        let entries = ChatTranscriptFormatter.persistedEntries(chat.messages, redactor: redactor)
        for projected in [plain, ax, rich, entries.map(\.text).joined()] {
            #expect(!projected.contains(value))
        }
        #expect(plain.contains("provider echo"))
        #expect(ax.contains("tool or canvas notice"))

        center.logManager.minimumLevel = .debug
        center.logManager.error("tool result " + value, category: "Tool")
        #expect(center.logManager.recentLogs().contains { $0.category == "Tool" })
        #expect(center.logManager.recentLogs().allSatisfy { !$0.message.contains(value) })
        let canonical = try #require(center.sessionStore.loadSession(id: sessionID.uuidString))
        #expect(canonical.messages.allSatisfy { !$0.content.contains(value) })
        let backup = root.appendingPathComponent("synthetic.minissync")
        #expect(!center.exportBackup(to: backup).isError)
        #expect(!String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains(value))

        let diagnostic = DiagnosticExportController(
            healthReportProvider: {
                HealthReport(items: [
                    HealthItem(name: "provider", category: .providers, status: .error,
                               message: "echo " + value, details: ["tool " + value])
                ])
            },
            applicationInfoProvider: {
                DiagnosticApplicationInfo(version: "1", build: "1", platformVersion: "14",
                                          architecture: "arm64")
            },
            runtimeSummaryProvider: { .unknown }
        )
        let destination = root.appendingPathComponent("synthetic-diagnostics.json")
        await diagnostic.export(to: destination)
        let receipt = try #require(diagnostic.lastReceipt)
        #expect(receipt.byteCount > 0)
        #expect(!String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains(value))
        #expect(!String(describing: receipt).contains(value))
        try CredentialTestSupport.assertAbsent(value, under: root)
    }
}
