import Foundation
import Testing
@testable import MinisCore

// P3 live-security slice: content-level redaction of embedded secrets
// (Bearer tokens, API keys, cookies, URL userinfo) in summaries that
// concatenate free-form text — approval digests, tool history, error text.
// Requirement: embedded secret VALUES must never survive; non-secret text
// must be preserved verbatim.

@Suite("ContentSecretRedactor 内容级 secret 脱敏")
struct ContentSecretRedactorTests {

    @Test func conversationBodyKeepsPublicMarkdownURLsAndAdjacentLocalPaths() {
        let urls = ["https://example.invalid/docs(v1)/part%28a%29?lang=zh",
                    "https://example.invalid/ratio%25",
                    "http://127.0.0.1:55571/owned-emphasis"]
        for url in urls {
            let publicLink = "**[public](\(url))**"
            #expect(ProductRedactionPolicy.redactConversationBody(publicLink) == publicLink)
        }
        for input in [
            "[x](https://example.invalid/a)/Users/alice/private.txt",
            "**[x](https://example.invalid/a)**/Users/alice/private.txt",
            "[x](https://example.invalid/a\\\\)/Users/alice/private.txt",
            "https://example.invalid/a inline /Users/alice/private.txt ~/private/file.txt",
            "file:///Users/alice/private.txt",
            "http:///Users/alice/private.txt"
        ] {
            let body = ProductRedactionPolicy.redactConversationBody(input)
            #expect(body.contains("/Users/alice/private.txt"))
            #expect(!body.contains("<path>"))
        }
        let tilde = "https://example.invalid/a inline ~/private/file.txt"
        #expect(ProductRedactionPolicy.redactConversationBody(tilde) == tilde)
        let escapedClosingParenthesis = #"[x](https://example.invalid/a\)b)"#
        #expect(ProductRedactionPolicy.redactConversationBody(escapedClosingParenthesis)
            == escapedClosingParenthesis)
        let adjacent = "[a](https://example.invalid/a)[b](https://example.invalid/b)"
        #expect(ProductRedactionPolicy.redactConversationBody(adjacent) == adjacent)
    }

    @Test func conversationBodyCannotProtectCredentialURLsOrEncodedCredentials() {
        for query in ["token=abc", "token=1", "token=", "token", "%74oken=x", "%2574oken=x"] {
            let body = ProductRedactionPolicy.redactConversationBody(
                "[credential](https://example.invalid/a?" + query + ")")
            #expect(!body.contains("example.invalid"))
            #expect(body.contains("<remote-url>"))
        }
        for url in ["https://owned-user:owned-password@example.invalid/a",
                    "https://example.invalid/a?page=%73k-owned-format-123456789",
                    "https://example.invalid/a?page=%2573k-owned-format-123456789",
                    "https://example.invalid/a%ZZ"] {
            #expect(!ProductRedactionPolicy.redactConversationBody(url).contains("example.invalid"))
        }
        let known = "owned-known-secret-2441"
        let raw = "\(known) Bearer ownedBearerToken123456 sk-ownedFormatToken123456 /Users/alice/private.txt"
        let body = ProductRedactionPolicy.redactConversationBody(raw, knownSecrets: [known])
        for secret in [known, "ownedBearerToken123456", "sk-ownedFormatToken123456"] {
            #expect(!body.contains(secret))
        }
        #expect(body.contains("/Users/alice/private.txt"))
        let encodedKnown = "https://example.invalid/owned%2Dknown%2Dsecret%2D2441"
        #expect(!ProductRedactionPolicy.redactConversationBody(encodedKnown,
            knownSecrets: [known]).contains("example.invalid"))
    }

    @Test func conversationBodyIsUnboundedWhileAuditAndToolDefaultsStillMaskURLsAndPaths() {
        let link = "**[public](https://example.invalid/docs(v1))**"
        let longBody = link + String(repeating: " 普通正文", count: 2_000) + " END_OWNED_BODY"
        #expect(Data(ProductRedactionPolicy.redactConversationBody(longBody).utf8) == Data(longBody.utf8))
        #expect(ProductRedactionPolicy.redactConversationBody(longBody).count > 4_096)
        let field = "https://example.invalid/docs /Users/alice/private.txt " + longBody
        for limit in [ProductRedactionPolicy.maxAuditFieldLength, ProductRedactionPolicy.maxTranscriptFieldLength] {
            let masked = ProductRedactionPolicy.redact(field, maxLength: limit)
            #expect(masked.count <= limit)
            #expect(!masked.contains("example.invalid"))
            #expect(!masked.contains("/Users/alice"))
            #expect(masked.contains("<remote-url>") && masked.contains("<path>"))
        }
    }

    @Test func bearerTokenMaskedAndSurroundingTextPreserved() {
        let text = "curl -H 'Authorization: Bearer sk-test1234567890abcdef' https://api.example.com/v1"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("sk-test1234567890abcdef"))
        #expect(out.contains("Bearer"))
        #expect(out.contains("curl"))
        #expect(out.contains("https://api.example.com/v1"))
    }

    @Test func bearerJWTTokenMasked() {
        let text = "curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(out.contains("Authorization"))
        #expect(out.contains("Bearer"))
    }

    @Test func skApiKeyMasked() {
        let text = "export OPENAI_KEY=sk-proj-ABCDEFGHIJKLMNOPQRST"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("sk-proj-ABCDEFGHIJKLMNOPQRST"))
        #expect(out.contains("export OPENAI_KEY="))
    }

    @Test func apiKeyQueryParamMasked() {
        let text = "https://api.example.com/v1?api_key=sk-abc123def456&page=2"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("sk-abc123def456"))
        #expect(out.contains("api_key="))
        #expect(out.contains("page=2"))
        #expect(out.contains("https://api.example.com/v1"))
    }

    @Test func cookieHeaderMasked() {
        let text = "curl -H 'Cookie: session=abc123def456' https://x.com"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("abc123def456"))
        #expect(out.contains("Cookie:"))
        #expect(out.contains("https://x.com"))
    }

    @Test("D-PROVIDER-14 every cookie pair is masked, including later unclassified names")
    func laterCookiePairsCannotEscapeMasking() {
        let first = "violet-cookie-marker-123456"
        let second = "amber-cookie-marker-654321"
        let text = "curl -H 'Cookie: prefs=ordinary; sid=\(first); csrf=\(second)' https://example.test"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains(first))
        #expect(!out.contains(second))
        #expect(!out.contains("ordinary"))
        #expect(out.contains("Cookie: prefs="))
        #expect(out.contains("; sid="))
        #expect(out.contains("; csrf="))
        #expect(out.hasSuffix("' https://example.test"))
        #expect(ContentSecretRedactor.redact(out) == out)
    }

    @Test("short, quoted and empty cookie pairs retain delimiters without retaining values")
    func shortQuotedAndEmptyCookiePairs() {
        let text = #"Cookie: empty=; tiny=x ; sid="violet marker"; csrf='amber marker'"#
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("tiny=x"))
        #expect(!out.contains("violet marker"))
        #expect(!out.contains("amber marker"))
        #expect(out.contains("empty=; tiny=*"))
        #expect(out.contains(#"; sid=""#))
        #expect(out.hasSuffix("'"))
        #expect(ContentSecretRedactor.redact(out) == out)
    }

    @Test("cookie redaction ends at newlines, shell quotes and ordinary prose")
    func cookieHeaderDoesNotConsumeFollowingBody() {
        let marker = "violet-cookie-marker-123456"
        for (text, suffix) in [
            ("Cookie: sid=\(marker)\nbody=visible; example=ordinary", "\nbody=visible; example=ordinary"),
            ("Cookie: sid=\(marker) response-body-visible", " response-body-visible"),
            ("Cookie: sid=\(marker); ordinary prose remains", "; ordinary prose remains"),
            ("curl -H 'Cookie: sid=\(marker)' -H 'X-Trace: visible'", "' -H 'X-Trace: visible'"),
            ("Set-Cookie: sid=\(marker); HttpOnly\nX-Trace: visible", "; HttpOnly\nX-Trace: visible")
        ] {
            let out = ContentSecretRedactor.redact(text)
            #expect(!out.contains(marker))
            #expect(out.hasSuffix(suffix))
        }
        let ordinary = "There are cookies in this story; sid=ordinary"
        #expect(ContentSecretRedactor.redact(ordinary) == ordinary)
    }

    @Test("a header-like string inside a quoted cookie is one protected value")
    func nestedHeaderTextDoesNotCreateOverlappingEdits() {
        let text = #"Cookie: sid="violet Cookie: sid=amber-marker"; csrf=second-marker"#
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("amber-marker"))
        #expect(!out.contains("second-marker"))
        #expect(out.contains("; csrf="))
        #expect(ContentSecretRedactor.redact(out) == out)
    }

    @Test func urlUserinfoMasked() {
        let text = "https://user:secretpass@example.com/path"
        let out = ContentSecretRedactor.redact(text)
        #expect(!out.contains("user:secretpass"))
        #expect(out.contains("https://"))
        #expect(out.contains("@example.com/path"))
    }

    @Test func knownSecretValuesMaskedAndRestPreserved() {
        let text = "using SECRET_TOKEN_XYZ here with more words"
        let out = ContentSecretRedactor.redact(text, knownSecrets: ["SECRET_TOKEN_XYZ"])
        #expect(!out.contains("SECRET_TOKEN_XYZ"))
        #expect(out.contains("using"))
        #expect(out.contains("here with more words"))
    }

    @Test func nonSecretTextPreservedVerbatim() {
        let text = "echo hello world && ls -la /tmp"
        #expect(ContentSecretRedactor.redact(text) == text)
    }

    @Test func emptyAndPlainInputsUnchanged() {
        #expect(ContentSecretRedactor.redact("") == "")
        #expect(ContentSecretRedactor.redact("plain text") == "plain text")
    }

    @Test("product log policy scrubs secrets, remote URLs, paths, and newlines")
    func productLogPolicyIsBoundedAndSingleLine() {
        let event = AppLogRedactionPolicy.scrub(
            eventID: "stable-event-1",
            category: "/Users/alice/private/category",
            message: "Authorization: Bearer abcdefghijklmnop\nhttps://remote.example/body /tmp/private",
            knownSecrets: ["abcdefghijklmnop"]
        )

        #expect(event.eventID == "stable-event-1")
        #expect(event.category == "<path>")
        #expect(!event.message.contains("abcdefghijklmnop"))
        #expect(!event.message.contains("https://remote.example/body"))
        #expect(!event.message.contains("/tmp/private"))
        #expect(!event.message.contains("\n"))
        #expect(event.message.count <= AppLogRedactionPolicy.maxMessageLength)
    }

    @Test("LogEntry is the final scrub boundary and retains event identity")
    func logEntryCannotBypassScrub() {
        let entry = LogEntry(
            level: .error,
            category: "network",
            message: String(repeating: "x", count: 2_000),
            eventID: "stable-event-2"
        )

        #expect(entry.eventID == "stable-event-2")
        #expect(entry.message.count == AppLogRedactionPolicy.maxMessageLength)
        #expect(entry.formatted.contains("[stable-event-2]"))
    }

    @Test("unquoted assignment values stop at the explicitly approved full-width prose boundaries")
    func fullWidthAssignmentBoundariesPreserveFollowingFields() {
        for (raw, expected) in [
            ("SERVICE_KEY=ABCD1234efgh5678；switch_after_create=false；保留正文", "SERVICE_KEY=****************；switch_after_create=false；保留正文"),
            ("SERVICE_KEY=ABCD1234efgh5678，initial_task=原文不变", "SERVICE_KEY=****************，initial_task=原文不变"),
            ("SERVICE_KEY=ABCD1234efgh5678。后续材料逐字保留", "SERVICE_KEY=****************。后续材料逐字保留")
        ] {
            #expect(ContentSecretRedactor.redact(raw) == expected)
        }
    }

    @Test("existing real credential shapes and quoted CJK-punctuation credentials remain masked")
    func credentialShapesAndQuotedCJKValuesRemainProtected() {
        for (raw, forbidden) in [
            ("OPENAI_KEY=sk-proj-ABCDEFGHIJKLMNOPQRST；保留正文", "sk-proj-ABCDEFGHIJKLMNOPQRST"),
            ("Authorization: Bearer ABCD1234efgh5678", "ABCD1234efgh5678"),
            ("Cookie: sid=ABCD1234efgh5678; csrf=EFGH5678ijkl9012", "ABCD1234efgh5678"),
            (#"SERVICE_KEY="ABCD1234；EFGH5678"；保留正文"#, "ABCD1234；EFGH5678"),
            ("SERVICE_KEY='ABCD1234，EFGH5678'；保留正文", "ABCD1234，EFGH5678"),
            (#"SERVICE_KEY="ABCD1234。EFGH5678"；保留正文"#, "ABCD1234。EFGH5678")
        ] {
            let out = ContentSecretRedactor.redact(raw)
            #expect(!out.contains(forbidden))
            if raw.hasPrefix("SERVICE_KEY=") { #expect(!out.contains("ABCD1234") && !out.contains("EFGH5678")) }
            if raw.hasPrefix("Cookie:") { #expect(!out.contains("EFGH5678ijkl9012")) }
            if raw.hasSuffix("；保留正文") { #expect(out.hasSuffix("；保留正文")) }
        }
        #expect(ContentSecretRedactor.redact(#"SERVICE_KEY="ABCD1234；EFGH5678"；保留正文"#)
            == #"SERVICE_KEY="*****************"；保留正文"#)
    }

    @Test("unknown unquoted CJK-containing secrets expose the explicit narrowing cost")
    func unknownUnquotedSecretSuffixRiskIsNotHiddenByQuotedOrKnownSecretControls() {
        let unquoted = "SERVICE_KEY=ABCD1234；EFGH5678"
        // Without external knowledge, the same punctuation can separate prose
        // OR be part of an unknown credential. This approved boundary cannot distinguish them.
        #expect(ContentSecretRedactor.redact(unquoted) == "SERVICE_KEY=********；EFGH5678")
        // Qualification still uses the original whole token length >= 4;
        // a shorter nonempty prefix is masked, not exposed by a second minimum.
        for (raw, expected) in [
            ("SERVICE_KEY=abc；EFGH5678", "SERVICE_KEY=***；EFGH5678"),
            ("SERVICE_KEY=a；XY", "SERVICE_KEY=*；XY"),
            ("SERVICE_KEY=a；x", "SERVICE_KEY=a；x"),
            ("SERVICE_KEY=；ABCD", "SERVICE_KEY=*****"),
            ("SERVICE_KEY=，ABCD", "SERVICE_KEY=*****"),
            ("SERVICE_KEY=。ABCD", "SERVICE_KEY=*****")
        ] {
            #expect(ContentSecretRedactor.redact(raw) == expected)
        }
        #expect(ContentSecretRedactor.redact(unquoted, knownSecrets: ["ABCD1234；EFGH5678"])
            == "SERVICE_KEY=*****************")
        #expect(ContentSecretRedactor.redact(#"SERVICE_KEY="ABCD1234；EFGH5678""#)
            == #"SERVICE_KEY="*****************""#)
    }

}
