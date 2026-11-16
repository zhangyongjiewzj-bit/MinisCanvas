import Foundation
import Testing
@testable import MinisCore

@Suite("Cloud backend error redaction")
struct CloudBackendErrorSecurityTests {
    @Test("all ordinary error surfaces omit untrusted credential-bearing fields")
    func untrustedFieldsStayOutOfDisplayAndLogs() {
        let secret = "fixture-secret-DO-NOT-EXPOSE"
        let tainted = "Authorization: Bearer \(secret); Cookie: session=\(secret); api_key=\(secret)"
        let cases: [(CloudBackendError, String)] = [
            (.missingAPIKey(providerID: tainted, envVar: tainted), "未配置 API key"),
            (.invalidURL(providerID: tainted, url: "https://example.test/?\(tainted)"), "URL 无效"),
            (.httpError(providerID: tainted, statusCode: 401, body: tainted), "HTTP 401"),
            (.decodeFailed(providerID: tainted, detail: tainted), "响应解析失败"),
            (.taskFailed(providerID: tainted, taskID: tainted, message: tainted), "任务失败"),
            (.pollTimeout(providerID: tainted, taskID: tainted), "轮询超时"),
            (.unknownProvider(tainted), "未知云端后端"),
            (.notImplemented(providerID: tainted, detail: tainted), "尚未接入真实 API")
        ]

        for (error, category) in cases {
            let surfaces = [
                error.localizedDescription,
                error.errorDescription ?? "",
                String(describing: error),
                String(reflecting: error)
            ]
            for surface in surfaces {
                #expect(surface.contains(category))
                #expect(!surface.contains(secret))
                #expect(!surface.contains("Bearer"))
                #expect(!surface.contains("Cookie"))
            }
        }
    }
}
