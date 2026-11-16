import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PROVIDER-14 ordinary error, log and transcript projections", .serialized)
@MainActor
struct PrivacyErrorProjection297Tests {
    @Test("later cookie values are absent from log ring, log file and ordinary chat writes")
    func multipleCookiesStayOutOfProductSinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyError297-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PrivacyError297.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let logger = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: logger)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        #expect(chat.attachPersistence(sessions))
        let first = "violet-cookie-marker-\(UUID().uuidString)"
        let second = "amber-cookie-marker-\(UUID().uuidString)"
        let tainted = "Cookie: prefs=ordinary; sid=\(first); csrf=\(second)\nvisible-context"
        logger.error(tainted, category: "SyntheticError", eventID: "privacy-cookie-297")
        chat.appendAssistant(tainted)
        let sessionID = try #require(chat.activeSessionID)
        #expect(chat.appendAssistant(tainted, toSession: sessionID))
        #expect(chat.replaceMessageContent(sessionID: sessionID, at: chat.messages.count - 1, with: tainted))
        let logFile = try #require(logger.logFileURL())
        let persisted = try #require(SessionStore(directory: sessions.directory).loadSession(id: sessionID.uuidString))
        let surfaces = [
            logger.recentLogsText(),
            try String(contentsOf: logFile, encoding: .utf8),
            chat.messages.map(\.content).joined(separator: "\n"),
            persisted.messages.map(\.content).joined(separator: "\n")
        ]
        for surface in surfaces {
            #expect(!surface.contains(first))
            #expect(!surface.contains(second))
            #expect(surface.contains("visible-context"))
        }
        let ordinary = "ordinary response remains readable"
        chat.appendAssistant(ordinary)
        #expect(chat.messages.last?.content == ordinary)
    }

    @Test("cloud error categories survive the UI message, log and chat projections without credentials")
    func cloudErrorsUsePayloadFreeProductSurfaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyCloud297-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PrivacyCloud297.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let logger = LogManager(directory: root, ringCapacity: 20)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: logger)
        let value = "violet-synthetic-cloud-marker-\(UUID().uuidString)"
        let tainted = "api_key=\(value); Authorization: Bearer \(value); Cookie: sid=\(value)"
        let cases: [(CloudBackendError, String)] = [
            (.missingAPIKey(providerID: tainted, envVar: tainted), "未配置 API key"),
            (.invalidURL(providerID: tainted, url: tainted), "URL 无效"),
            (.httpError(providerID: tainted, statusCode: 401, body: tainted), "HTTP 401"),
            (.decodeFailed(providerID: tainted, detail: tainted), "响应解析失败"),
            (.taskFailed(providerID: tainted, taskID: tainted, message: tainted), "任务失败"),
            (.pollTimeout(providerID: tainted, taskID: tainted), "轮询超时"),
            (.unknownProvider(tainted), "未知云端后端"),
            (.notImplemented(providerID: tainted, detail: tainted), "尚未接入真实 API")
        ]
        for (error, category) in cases {
            let ui = ChatStore.userErrorMessage(error)
            #expect(ui.contains(category))
            #expect(!ui.contains(value))
            #expect(!ui.contains("Bearer"))
            #expect(!ui.contains("Cookie"))
            logger.error(ui, category: "SyntheticCloud")
            chat.appendAssistant(ui)
        }
        let file = try #require(logger.logFileURL())
        #expect(!logger.recentLogsText().contains(value))
        #expect(try !String(contentsOf: file, encoding: .utf8).contains(value))
        #expect(chat.messages.allSatisfy { !$0.content.contains(value) })
    }
}
