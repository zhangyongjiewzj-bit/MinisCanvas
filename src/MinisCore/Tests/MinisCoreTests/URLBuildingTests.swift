import Foundation
import Testing
@testable import MinisCore

/// Boundary tests for `URLBuilding.join`/`joinURL`, focused on the `/v1`
/// version-prefix dedup fix (QC4: base `https://host/v1` + `/v1/images/...`
/// used to produce `/v1/v1/...` → 404).
struct URLBuildingTests {

    // MARK: - /v1 dedup

    @Test func v1DedupWhenBaseEndsWithV1() {
        // base already carries /v1 → duplicate must collapse
        #expect(URLBuilding.join("https://5678ai.cn/v1", "/v1/images/generations")
                == "https://5678ai.cn/v1/images/generations")
        #expect(URLBuilding.join("https://5678ai.cn/v1/", "/v1/images/generations")
                == "https://5678ai.cn/v1/images/generations")
        #expect(URLBuilding.join("https://5678ai.cn/v1", "v1/images/generations")
                == "https://5678ai.cn/v1/images/generations")
        #expect(URLBuilding.joinURL("https://5678ai.cn/v1", "/v1/images/generations")?.absoluteString
                == "https://5678ai.cn/v1/images/generations")
    }

    @Test func v1DedupDeepBasePath() {
        // last base segment is v1 even with a longer path
        #expect(URLBuilding.join("https://api.example.com/api/v1", "/v1/chat/completions")
                == "https://api.example.com/api/v1/chat/completions")
        #expect(URLBuilding.join("https://api.example.com/API/V1", "/v1/chat/completions")
                == "https://api.example.com/API/V1/chat/completions")
    }

    @Test func noDedupWhenBaseHasNoV1() {
        // base without /v1 must keep the segment's /v1
        #expect(URLBuilding.join("https://5678ai.cn", "/v1/images/generations")
                == "https://5678ai.cn/v1/images/generations")
        #expect(URLBuilding.join("https://5678ai.cn/", "/v1/images/generations")
                == "https://5678ai.cn/v1/images/generations")
        #expect(URLBuilding.join("https://api.anthropic.com", "/v1/messages")
                == "https://api.anthropic.com/v1/messages")
    }

    @Test func noDedupOnDistinctVersions() {
        // base v1 + v2 segment → untouched
        #expect(URLBuilding.join("https://host.example/v1", "/v2/models")
                == "https://host.example/v1/v2/models")
        // base v2 + v1 segment → untouched
        #expect(URLBuilding.join("https://host.example/v2", "/v1/models")
                == "https://host.example/v2/v1/models")
        // v1beta is not v1
        #expect(URLBuilding.join("https://host.example/v1beta", "/v1/models")
                == "https://host.example/v1beta/v1/models")
    }

    @Test func v1DedupPreservesQueryAndFragment() {
        #expect(URLBuilding.join("https://host.example/v1", "/v1/images/generations?size=1024")
                == "https://host.example/v1/images/generations?size=1024")
        #expect(URLBuilding.join("https://host.example/v1", "/v1/models#top")
                == "https://host.example/v1/models#top")
    }

    @Test func v1DedupEmptyTail() {
        // segment is exactly "v1" and base already ends with /v1 → tail drops
        #expect(URLBuilding.join("https://host.example/v1", "/v1")
                == "https://host.example/v1")
        #expect(URLBuilding.joinURL("https://host.example/v1", "/v1")?.absoluteString
                == "https://host.example/v1")
    }

    // MARK: - Slash normalization interplay

    @Test func v1DedupWithMessySlashes() {
        // Boundary slashes collapse + /v1 dedup; internal "///" inside a
        // single segment survive (documented B1-fix.log behavior).
        #expect(URLBuilding.join("https://host.example/v1//", "///v1///images///generations")
                == "https://host.example/v1/images///generations")
        #expect(URLBuilding.join("https://host.example/v1//", "///v1", "///images", "///generations")
                == "https://host.example/v1/images/generations")
    }

    @Test func emptyBaseStillWorks() {
        #expect(URLBuilding.join("", "/v1/chat/completions") == "/v1/chat/completions")
        #expect(URLBuilding.join("   ", "v1", "models") == "v1/models")
    }

    // MARK: - Moved from MessageModelTests (original URLBuildingTests suite)

    @Test func basicJoin() {
        #expect(URLBuilding.join("https://api.openai.com", "/v1/chat/completions")
                == "https://api.openai.com/v1/chat/completions")
    }

    @Test func trailingSlashNormalization() {
        #expect(URLBuilding.join("https://api.deepseek.com/", "/v1/chat/completions")
                == "https://api.deepseek.com/v1/chat/completions")
        #expect(URLBuilding.join("https://api.deepseek.com/v1/", "chat/completions")
                == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test func doubleSlashCollapsed() {
        // URLBuilding collapses leading/trailing slashes at *segment* boundaries;
        // internal "///" inside one segment survive (see B1-fix.log), so pass the
        // path as multiple segments to exercise collapse.
        #expect(URLBuilding.join("https://api.deepseek.com//", "//v1", "///chat/completions")
                == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test func queryPreserved() {
        #expect(URLBuilding.join("https://x.openai.azure.com?api-version=2024-06-01", "/openai/deployments/gpt-4o/chat/completions")
                == "https://x.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-06-01")
    }

    @Test func colonSurvives() {
        #expect(URLBuilding.join("https://generativelanguage.googleapis.com", "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent")
    }

    @Test func joinURL() {
        #expect(URLBuilding.joinURL("https://api.anthropic.com", "/v1/messages")?.absoluteString
                == "https://api.anthropic.com/v1/messages")
        // "not a url" is NOT rejected: URLComponents leniently percent-encodes
        // spaces in the path ("not%20a%20url/x"), so it yields a non-nil URL.
        // A space in the *host* is genuinely invalid and yields nil.
        #expect(URLBuilding.joinURL("https://exa mple.com", "/x") == nil)
    }

    @Test func endpointCannotReplaceBaseAuthority() {
        let url = URLBuilding.joinURL("https://api.example.com/prefix", "//other.example/v1/models")
        #expect(url?.host == "api.example.com")
        #expect(url?.path == "/prefix/other.example/v1/models")
    }

    @Test func encodedBasePathAndEndpointCharactersSurvive() {
        #expect(URLBuilding.join("https://api.example.com/team%2Fone", "/v1/my model")
                == "https://api.example.com/team%2Fone/v1/my%20model")
        #expect(URLBuilding.join("https://api.example.com", "/v1/models/gemini:streamGenerateContent")
                == "https://api.example.com/v1/models/gemini:streamGenerateContent")
    }

    @Test func baseQueryAndEndpointSuffixAreRetained() {
        #expect(URLBuilding.join("https://api.example.com/v1?api-version=2024-06-01",
                                 "/v1/models?size=1024#result")
                == "https://api.example.com/v1/models?api-version=2024-06-01&size=1024#result")
    }
}
