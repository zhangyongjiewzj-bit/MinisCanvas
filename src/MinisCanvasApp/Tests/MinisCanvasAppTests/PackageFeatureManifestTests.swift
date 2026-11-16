import Testing
import Foundation
@testable import MinisCanvasApp

@Suite("包功能清单阅读器")
struct PackageFeatureManifestTests {
    @Test("缺少字段时明确失败")
    func missingFieldsFailVisible() {
        var observed: PackageFeatureManifest.ReadError?
        do {
            _ = try PackageFeatureManifest(data: Data(#"{"source_sha":"sha"}"#.utf8))
        } catch let error as PackageFeatureManifest.ReadError {
            observed = error
        } catch {
            observed = .malformed
        }
        guard case .missingFields(let fields)? = observed else {
            #expect(Bool(false))
            return
        }
        #expect(fields.contains("source tree"))
        #expect(fields.contains("版本渠道"))
    }

    @Test("损坏 JSON 时明确失败")
    func malformedJSONFailsVisible() {
        var observed: PackageFeatureManifest.ReadError?
        do {
            _ = try PackageFeatureManifest(data: Data("{".utf8))
        } catch let error as PackageFeatureManifest.ReadError {
            observed = error
        } catch {
            observed = .malformed
        }
        #expect(observed == .malformed)
    }

    @Test("身份不匹配时拒绝清单")
    func identityMismatchFailsVisible() {
        var observed: PackageFeatureManifest.ReadError?
        do {
            _ = try PackageFeatureManifest(
                data: Self.validJSON(source: "source-a", tree: "tree-a"),
                expectedIdentity: .init(sourceSHA: "source-b", treeSHA: "tree-a")
            )
        } catch let error as PackageFeatureManifest.ReadError {
            observed = error
        } catch {
            observed = .malformed
        }
        #expect(observed == .identityMismatch)
    }

    @Test("有效清单保留中文能力和门禁状态")
    func validManifestProjectsReadableFields() throws {
        let manifest = try PackageFeatureManifest(
            data: Self.validJSON(source: "source-a", tree: "tree-a"),
            expectedIdentity: .init(sourceSHA: "source-a", treeSHA: "tree-a")
        )
        #expect(manifest.channel == "Preview")
        #expect(manifest.sourceSHA == "source-a")
        #expect(manifest.treeSHA == "tree-a")
        #expect(manifest.features == ["模型档位图标", "关于页清单"])
        #expect(manifest.automatedTests == "8/8")
        #expect(manifest.packagedStatus == "PACKAGED")
        #expect(!manifest.fieldVerified)
        #expect(!manifest.releaseReady)
        #expect(manifest.knownFieldIssues == ["等待现场复测"])
        #expect(manifest.artifactContractRevision == "P3-OUTPUT-01-v1")
        #expect(manifest.supportsArtifactRecovery)
    }

    private static func validJSON(source: String, tree: String) -> Data {
        Data(
            """
            {
              "channel": "Preview",
              "source_sha": "\(source)",
              "tree_sha": "\(tree)",
              "build_time": "2026-08-28T12:00:00Z",
              "features": ["模型档位图标", "关于页清单"],
              "tests": "8/8",
              "packaged": "PACKAGED",
              "field_verified": false,
              "release_ready": false,
              "known_field_issues": ["等待现场复测"],
              "artifact_contract_revision": "P3-OUTPUT-01-v1"
            }
            """.utf8
        )
    }
}
