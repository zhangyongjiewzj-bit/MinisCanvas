import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import MinisCore
import Testing
@testable import MinisCanvasApp

// Bounded full-entity capture reused from3122/3090; only synthetic body survives.
private final class MultimodalWire3190: @unchecked Sendable {
    struct Request: Sendable {
        let line: String
        let body: Data
    }
    private let failFirst: Bool
    private let descriptor: Int32
    private let lock = NSLock()
    private var captured: [Request] = []
    private var failure: String?
    private var stopped = false
    let port: UInt16
    var requests: [Request] { lock.withLock { captured } }
    var captureFailure: String? { lock.withLock { failure } }

    init(failFirst: Bool = false) throws {
        self.failFirst = failFirst
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            _ = Darwin.close(fd); throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else { _ = Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }
    deinit { stop() }
    func stop() {
        let shouldClose = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldClose { _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor) }
    }

    private func serve() {
        for _ in 0..<3 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let complete = serve(client: client)
            _ = Darwin.close(client)
            guard complete else { return }
        }
    }
    private func serve(client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 2_000_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failure = "incomplete HTTP entity" }; return false }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
            let lines = headers.components(separatedBy: "\r\n")
            let entityLength = lines.compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first
            guard let entityLength, entityLength > 0, entityLength < 2_000_000,
                  let requestLine = lines.first else {
                lock.withLock { failure = "missing bounded Content-Length" }; return false
            }
            let offset = boundary.upperBound
            guard received.count >= offset + entityLength else { continue }
            lock.withLock {
                captured.append(Request(line: requestLine,
                    body: received.subdata(in: offset..<(offset + entityLength))))
            }
            let json = try? JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
                "delta": ["content": "OWNED_MEDIA_REPLY_3190"], "finish_reason": "stop"]]])
            guard let json else { return false }
            let body = "data: " + String(decoding: json, as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            let rejected = failFirst && requests.count == 1
            let responseBody = rejected ? #"{"error":{"message":"owned synthetic media rejection"}}"# : body
            let status = rejected ? "400 Bad Request" : "200 OK"
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/event-stream\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)".utf8)
            return response.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return false }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, address.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { return false }
                    sent += count
                }
                return true
            }
        }
        lock.withLock { failure = "HTTP entity exceeded owned fixture bound" }
        return false
    }
}


private enum MediaImage3190 {
    static func png(color: CGFloat = 0.5, format: String = "public.png") throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: color, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, format as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        let finalized = CGImageDestinationFinalize(destination)
        #expect(finalized)
        guard finalized else { throw URLError(.cannotDecodeContentData) }
        let encoded = data as Data
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == format)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 8 && decoded.height == 8)
        return encoded
    }

}

@Suite("MULTIMODAL02/03/05 actual selected Provider SDK entity", .serialized)
@MainActor
struct MultimodalSelectedProviderWire3190Tests {
    @Test("current selected model blocks incompatible bytes before any SDK request; removal restores a real PNG send",
          arguments: ["svg", "heic", "wrong-mime", "truncated", "missing-model"])
    func incompatibleMediaBlocksBeforeActualWire(kind: String) async throws {
        let f = try Fixture()
        try await f.attach(selectModel: kind != "missing-model")
        defer { f.stop() }
        let chat = f.bridge.chat
        let bytes: Data
        let mime: String
        switch kind {
        case "svg": bytes = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#.utf8); mime = "image/svg+xml"
        case "heic": bytes = try f.image(format: "public.heic"); mime = "image/heic"
        case "wrong-mime": bytes = f.png; mime = "image/jpeg"
        case "truncated": bytes = Data(f.png.prefix(8)); mime = "image/png"
        default: bytes = f.png; mime = "image/png"
        }
        let bad = ChatAttachment(kind: .image, fileName: "blocked-" + kind, fileType: .image, mimeType: mime,
                                 size: Int64(bytes.count), data: bytes)
        chat.addComposerDraftAttachment(bad); chat.draftText = "BLOCKED_MEDIA3190"
        let frozen = chat.composerMediaReadinessSnapshot
        #expect(kind == "missing-model" ? frozen.modelID == MockProvider.shared.model.id : frozen.providerID == "LUNA" && frozen.modelID == f.model)
        #expect(kind == "missing-model" ? frozen.wireProtocol == nil : frozen.wireProtocol == .openaiCompatible)
        #expect(frozen.attachment(id: bad.id)?.readiness == (kind == "missing-model" ? .unknown : .unsupported))
        #expect(frozen.blockedReason != nil && !chat.canSubmitComposerAttachments)
        chat.submitComposer()
        for _ in 0..<10 { await Task.yield() }
        #expect(f.wire.requests.isEmpty)
        #expect(!chat.messages.contains { $0.role == .user })
        #expect(chat.pendingAttachments == [bad] && chat.draftText == "BLOCKED_MEDIA3190")
        chat.removePendingAttachment(id: bad.id)
        #expect(chat.pendingAttachments.isEmpty)
        #expect(chat.applyChatModel(providerID: "LUNA", modelID: "gpt-4o"))
        let good = f.attachment(f.png, name: "replacement.png")
        chat.addComposerDraftAttachment(good); chat.draftText = "ACCEPTED_MEDIA3190"
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: good.id)?.readiness == .supported)
        chat.submitComposer()
        #expect(await f.waitForEnd(requests: 1))
        let request = try f.request(0)
        #expect(try f.currentImageURLs(request) == ["data:image/png;base64," + f.png.base64EncodedString()])
        #expect(String(decoding: f.wire.requests[0].body, as: UTF8.self).contains("ACCEPTED_MEDIA3190"))
        #expect(!String(decoding: f.wire.requests[0].body, as: UTF8.self).contains("BLOCKED_MEDIA3190"))
    }

    @Test("failed actual image wire is quarantined while replacement/reference and later text stay independent",
          arguments: ["image", "reference"])
    func failedImageThenReplacementAndTextDoNotReplayFailedPayload(next: String) async throws {
        let f = try Fixture(failFirst: true)
        try await f.attach()
        defer { f.stop() }
        let chat = f.bridge.chat
        let failed = f.attachment(f.png, name: "failed3190.png")
        chat.addComposerDraftAttachment(failed); chat.draftText = "FAIL_FIRST3190"; chat.submitComposer()
        #expect(await f.waitForEnd(requests: 1))
        #expect(try f.currentImageURLs(f.request(0)) == ["data:image/png;base64," + f.png.base64EncodedString()])
        let original = try #require(chat.messages.first { $0.role == .user })
        #expect(original.attachments.first?.id == failed.id)
        #expect(original.attachments.first?.deliveryQuarantined == true)
        #expect(original.attachments.first?.data == f.png)
        #expect(chat.pendingAttachments.isEmpty)
        let canonicalBefore = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let recordsBefore = try #require(try ChatAttachmentPersistence.load(
            forSessionID: f.sessionID.uuidString, from: f.profile.sessionDirectory))
        let retryProjection = try ChatAttachmentPersistence.providerMediaProjection(
            canonical: canonicalBefore, records: recordsBefore)
        #expect(retryProjection.apply(canonicalBefore.messages) == canonicalBefore.messages)
        // A real failure's persisted ownership cannot authorize another body.
        let changedRecords = recordsBefore.map { record in
            ChatAttachmentPersistence.MessageRecord(messageIndex: record.messageIndex,
                contentDigest: "wrong-owned-digest3190", attachments: record.attachments)
        }
        #expect(throws: ChatSessionRuntimeError.self) {
            try ChatAttachmentPersistence.providerMediaProjection(
                canonical: canonicalBefore, records: changedRecords)
        }
        let replacementBytes = try f.image(format: "public.png", color: 0.8)
        let replacement: ChatAttachment
        if next == "image" { replacement = f.attachment(replacementBytes, name: "new3190.png") }
        else {
            let url = f.profile.rootDirectory.appendingPathComponent("owned-reference3190.bin")
            try Data([1,2,3,4]).write(to: url)
            replacement = ChatAttachment(kind: .file, fileName: url.lastPathComponent, fileType: .unknown,
                mimeType: "application/octet-stream", size: 4, fileURL: url.path)
        }
        #expect(replacement.id != failed.id)
        chat.addComposerDraftAttachment(replacement); chat.draftText = "REPLACEMENT3190"; chat.submitComposer()
        #expect(await f.waitForEnd(requests: 2))
        let second = try f.request(1)
        let expected = next == "image" ? ["data:image/png;base64," + replacementBytes.base64EncodedString()] : []
        #expect(try f.currentImageURLs(second) == expected)
        #expect(try f.allImageURLs(second) == expected)
        #expect(!String(decoding: f.wire.requests[1].body, as: UTF8.self).contains(f.png.base64EncodedString()))
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains("OWNED_MEDIA_REPLY_3190") })
        chat.draftText = "LATER_TEXT3190"; chat.submitComposer()
        #expect(await f.waitForEnd(requests: 3))
        let third = try f.request(2)
        #expect(try f.currentImageURLs(third).isEmpty)
        #expect(try f.allImageURLs(third) == expected) // A successful old image is valid history, not a current upload.
        #expect(!String(decoding: f.wire.requests[2].body, as: UTF8.self).contains(f.png.base64EncodedString()))
        let reopened = try f.reopen()
        let persisted = try #require(reopened.sessions.first { $0.id == f.sessionID })
        let old = try #require(persisted.messages.first { $0.role == .user })
        #expect(old.content == original.content)
        #expect(old.attachments.first?.deliveryQuarantined == true && old.attachments.first?.data == f.png)
        #expect(persisted.messages.filter { $0.role == .user }.count == 3)
    }

    @Test("real PDF page provenance is frozen into actual SDK text wire and survives source mutation and reload")
    func extractedPDFFrozenTextReachesActualWire() async throws {
        let f = try Fixture(); try await f.attach()
        defer { f.stop() }
        let chat = f.bridge.chat
        let bytes = pdfFixture(pages: [nil, "ALPHA_SOURCE3190", nil, "BETA_SOURCE3190"])
        #expect(!bytes.isEmpty)
        let url = f.profile.rootDirectory.appendingPathComponent("source3190.pdf")
        try bytes.write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        // Known PDF drafts are pending until the real worker publishes in place.
        // Their worker is not the unknown-ready-reference preparation handle.
        for _ in 0..<500 where chat.pendingAttachments.first(where: { $0.id == staged.id })?.status == .pending {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = try #require(chat.pendingAttachments.first)
        #expect(ready.status == .ready && ready.kind == .text && ready.mimeType == "application/pdf")
        #expect(ready.size == Int64(bytes.count))
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .referenceOnly)
        chat.draftText = "PDF_REQUEST3190"; chat.submitComposer()
        #expect(await f.waitForEnd(requests: 1))
        let request = try f.request(0)
        let users = try #require(request["messages"] as? [[String: Any]]).filter { $0["role"] as? String == "user" }
        let content = try #require(users.last?["content"] as? String)
        #expect(content.contains("source3190.pdf") && content.contains("[原文第 2 页]") && content.contains("[原文第 4 页]"))
        #expect(content.contains("ALPHA_SOURCE3190") && content.contains("BETA_SOURCE3190"))
        #expect(!content.contains("[原文第 1 页]"))
        #expect(try f.allImageURLs(request).isEmpty)
        let sent = try #require(chat.messages.first { $0.role == .user })
        let oldText = sent.content
        try pdfFixture(pages: ["CHANGED_SOURCE3190"]).write(to: url)
        chat.draftText = "PDF_NEXT_TEXT3190"; chat.submitComposer()
        #expect(await f.waitForEnd(requests: 2))
        let nextBody = String(decoding: f.wire.requests[1].body, as: UTF8.self)
        #expect(nextBody.contains("ALPHA_SOURCE3190") && !nextBody.contains("CHANGED_SOURCE3190"))
        #expect(try f.currentImageURLs(f.request(1)).isEmpty)
        let reopened = try f.reopen()
        let restored = try #require(reopened.sessions.first { $0.id == f.sessionID })
        #expect(restored.messages.first { $0.role == .user }?.content == oldText)
        #expect(restored.messages.first { $0.role == .user }?.attachments.first?.data == ready.data)
    }
    private func pdfFixture(pages: [String?]) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return Data()
        }
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: attributes)
                )
                context.textPosition = CGPoint(x: 72, y: box.height - 72)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: output as Data)?.dataRepresentation() ?? (output as Data)
    }


    @MainActor private final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let bridge: BridgeStore
        let sessionID = UUID()
        let wire: MultimodalWire3190
        let png: Data
        let model: String
        init(model: String = "gpt-4o", failFirst: Bool = false) throws {
            self.model = model
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "MultimodalSDK3190",
                processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
            wire = try MultimodalWire3190(failFirst: failFirst)
            png = try MediaImage3190.png()
            let defaults = profile.makeUserDefaults(); let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            _ = try sessions.createSession(id: sessionID.uuidString, title: "owned multimodal3190",
                workingDirectory: profile.rootDirectory.path)
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            let shortcuts = ShortcutStore(defaults: defaults)
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: readiness)
            bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults, logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks3190.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest3190.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center3190.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))

            #expect(settings.saveProvider(name: "LUNA", apiKey: "owned-synthetic-key3190",
                baseURL: "http://127.0.0.1:\(wire.port)", modelNames: ["gpt-4o"], protocolType: .openaiCompatible))
            // Exact2693/3090 owned provenance only; not remote readiness evidence.
            for id in ["gpt-4o"] {
                #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: "LUNA", modelID: id,
                    status: .passed, readinessState: .live, checkedAt: Date(),
                    evidenceID: "live-settings:" + String(repeating: "a", count: 64), isApplied: true)]))
            }
        }
        func attach(selectModel: Bool = true) async throws {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled, externalRunners: [:],
                externalNetworkAllowed: false, controlledFieldLoopbackAllowed: true,
                sessionReadSecretStore: settings.envStore).value
            #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
            #expect(!bridge.productionExternalNetworkAllowed && bridge.productionControlledFieldLoopbackAllowed)
            #expect(bridge.chat.applySwitchSession(id: sessionID))
            let settings = settings
            bridge.chat.providerRecordsSource = { settings.providerRecords }
        bridge.chat.providerCredentialPreflightSource = { [weak settings] recordID, name, revision in
            guard let settings,
                  let record = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  record.valueInKeychain,
                  settings.providerCredentialBinding(recordID: recordID)?.revision == revision,
                  case .success(let value) = await settings.providerCredentialReadAsync(named: name),
                  !value.isEmpty else { return false }
            // The async read populates EnvVarStore's in-memory value. Publish
            // that same profile-scoped record used by readiness and chat; no
            // credential bytes enter the Composer's preflight result.
            settings.reloadEnv()
            guard let current = settings.providerRecords.first(where: {
                $0.id == recordID && $0.name == name
            }),
                  current.baseURL == record.baseURL,
                  current.protocolType == record.protocolType,
                  current.modelNames == record.modelNames,
                  settings.providerCredentialBinding(recordID: recordID)?.revision == revision else {
                return false
            }
            return true
        }
        bridge.chat.providerCredentialMetadataSource = { [weak settings] recordID, name in
            guard let settings,
                  let record = settings.providerRecords.first(where: {
                      $0.id == recordID && $0.name == name
                  }),
                  let binding = await settings.providerCredentialBindingAsync(recordID: record.id),
                  binding.credentialName == name else { return nil }
            return binding.revision
        }

            bridge.chat.schedulerCredentialVersionSource = { [weak settings] name in
                guard let settings, let record = settings.providerRecords.first(where: { $0.name == name }) else { return nil }
                return settings.providerCredentialBinding(recordID: record.id)?.revision
            }
            guard selectModel else {
                #expect(bridge.chat.selectedModelID == nil)
                return
            }
            #expect(bridge.chat.applyChatModel(providerID: "LUNA", modelID: model))
            let provider = try bridge.chat.activeProvider()
            let actual = try #require(provider as? OpenAICompatibleProvider)
            #expect(actual.controlledFieldLoopbackOnly)
            #expect(bridge.chat.streamingProviderOverride == nil && bridge.chat.compactionProviderOverride == nil)
        }
        func stop() { bridge.chat.stopAllStreamingForSafety(); wire.stop(); withExtendedLifetime(settings) {} }
        func reopen() throws -> ChatStore {
            let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
            let sessions = SessionStore(directory: profile.sessionDirectory)
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            #expect(chat.attachPersistence(sessions, badgeStore: badges))
            #expect(chat.applySwitchSession(id: sessionID))
            return chat
        }

        func image(format: String, color: CGFloat = 0.5) throws -> Data { try MediaImage3190.png(color: color, format: format) }
        func attachment(_ data: Data, name: String) -> ChatAttachment {
            ChatAttachment(kind: .image, fileName: name, fileType: .image, mimeType: "image/png", size: Int64(data.count), data: data)
        }
        func waitForEnd(requests: Int) async -> Bool {
            for _ in 0..<500 {
                if wire.requests.count == requests && !bridge.chat.hasStreamingTasksForSafety { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func request(_ index: Int) throws -> [String: Any] {
            #expect(wire.captureFailure == nil)
            #expect(wire.requests.count > index)
            let capture = try #require(wire.requests.indices.contains(index) ? wire.requests[index] : nil)
            #expect(capture.line.hasPrefix("POST ") && capture.line.contains("/chat/completions"))
            let json = try #require(JSONSerialization.jsonObject(with: capture.body) as? [String: Any])
            #expect(json["model"] as? String == "gpt-4o" && json["stream"] as? Bool == true)
            print("TASK3190_ACTUAL_SDK_ENTITY index=\(index) bytes=\(capture.body.count) sha256=\(SHA256.hash(data: capture.body))")
            return json
        }
        func imageURLs(_ message: [String: Any]) -> [String] {
            (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image_url" }
                .compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        }
        func currentImageURLs(_ request: [String: Any]) throws -> [String] {
            let messages = try #require(request["messages"] as? [[String: Any]])
            let user = try #require(messages.last { $0["role"] as? String == "user" })
            return imageURLs(user)
        }
        func allImageURLs(_ request: [String: Any]) throws -> [String] {
            let messages = try #require(request["messages"] as? [[String: Any]])
            return messages.flatMap { imageURLs($0) }
        }
    }
}
