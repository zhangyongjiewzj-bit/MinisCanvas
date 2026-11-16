import Foundation
import Testing
@testable import MinisCore

@Suite("Claude Code alignment sensitive path boundaries")
struct AlignCCSensitivePathTests {
    @Test func environmentTemplatesShareTheCredentialExemption() {
        let root = "/synthetic-align-cc/project"
        let home = "/synthetic-align-cc/home"
        for name in [".env.example", ".env.production.sample", ".env.local.template"] {
            #expect(!SensitiveFilePolicy.contains(root + "/" + name))
            #expect(!SensitiveFilePolicy.isCredentialPath(root + "/" + name, home: home))
        }
        for name in [".env", ".env.production", ".env.example.local"] {
            #expect(SensitiveFilePolicy.contains(root + "/" + name))
            #expect(SensitiveFilePolicy.isCredentialPath(root + "/" + name, home: home))
        }
        // A template basename cannot exempt its enclosing credential directory.
        #expect(SensitiveFilePolicy.contains(root + "/credentials/.env.example"))
        #expect(SensitiveFilePolicy.isCredentialPath(home + "/.ssh/.env.example", home: home))
    }

    @Test func credentialComponentsDoNotBlockDocumentationNames() {
        for path in ["docs/credentials-guide.md", "docs/cookies-policy.md", "docs/keychain-notes.md"] {
            #expect(!SensitiveFilePolicy.contains("/synthetic-align-cc/" + path))
        }
        for path in ["credentials/token", "cookies/session", "Library/Keychains/login-db"] {
            #expect(SensitiveFilePolicy.contains("/synthetic-align-cc/" + path))
        }
    }

    @Test func gitControlWritesAreProtectedWithoutHidingReads() {
        for path in [".git/hooks/pre-commit", ".git/config", ".gitmodules", ".git"] {
            #expect(SensitiveFilePolicy.isProtectedGitWritePath("/synthetic-align-cc/" + path))
            #expect(SensitiveFilePolicy.isProtectedGitWritePath(path))
            #expect(!SensitiveFilePolicy.contains("/synthetic-align-cc/" + path))
        }
        for path in [".git/config.example", ".git/hooks-guide.md", "docs/.gitconfig"] {
            #expect(!SensitiveFilePolicy.isProtectedGitWritePath("/synthetic-align-cc/" + path))
        }
    }
}
