import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("Session package field fixture")
@MainActor
struct SessionPackageFieldFixtureTests {
    @Test("only a selected 0700 field profile seeds the real session store once")
    func preparesPersistentSyntheticSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "session-field-1566-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "session-field-1566",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: [
                "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(SessionPackageFieldFixture.isRequested(
            profile: profile,
            arguments: [SessionPackageFieldFixture.activationArgument]
        ))
        #expect(!SessionPackageFieldFixture.isRequested(profile: profile, arguments: []))

        let store = SessionStore(directory: profile.sessionDirectory)
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: store,
            arguments: [SessionPackageFieldFixture.activationArgument]
        )
        let first = store.listSessions()
        #expect(first.count == 3)
        #expect(first.contains { $0.title == "S1566 琥珀会话" && $0.messages.count == 16 })
        #expect(first.contains { $0.title == "S1566 青松会话" && $0.messages.count == 16 })
        #expect(first.contains { $0.title == "S1566 海蓝项目会话" && $0.projectID == "session-field-project-1566" })
        let alpha = try #require(first.first { $0.title == "S1566 琥珀会话" })
        try store.renameSession(id: alpha.id, title: "UI 重命名后保留")
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: store,
            arguments: [SessionPackageFieldFixture.activationArgument]
        )
        #expect(Set(store.listSessions().map(\.id)) == Set(first.map(\.id)))
        #expect(store.loadSession(id: alpha.id)?.title == "UI 重命名后保留")
    }

    @Test("explicit PERF07 field history persists exact UTF16 content sizes")
    func preparesPerformanceHistoryWithoutChangingTheDefaultFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "perf07-field-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let arguments = [
            "/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
            RuntimeIsolationProfile.fieldActivationArgument,
            SessionPackageFieldFixture.activationArgument,
            SessionPackageFieldFixture.performanceArgument
        ]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "perf07-field",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: arguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        let store = SessionStore(directory: profile.sessionDirectory)
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: store, arguments: arguments
        )
        let first = store.listSessions()
        #expect(first.count == 2)
        for size in [50_000, 100_000] {
            let session = try #require(first.first {
                $0.title == "PERF07 合成转录 \(size / 1_000)k UTF16"
            })
            #expect(session.messages.count == 20)
            #expect(session.messages.reduce(0) { $0 + $1.content.utf16.count } == size)
            #expect(session.messages.filter { $0.role == .user }.count == 10)
            #expect(session.messages.filter { $0.role == .assistant }.count == 10)
        }

        let smaller = try #require(first.first { $0.title.contains("50k") })
        try store.renameSession(id: smaller.id, title: "PERF07 UI renamed")
        let reopened = SessionStore(directory: profile.sessionDirectory)
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: reopened, arguments: arguments
        )
        #expect(Set(reopened.listSessions().map(\.id)) == Set(first.map(\.id)))
        #expect(reopened.loadSession(id: smaller.id)?.title == "PERF07 UI renamed")
        #expect(throws: SessionPackageFieldFixture.FixtureError.self) {
            try SessionPackageFieldFixture.prepare(
                profile: profile, store: reopened,
                arguments: [SessionPackageFieldFixture.activationArgument]
            )
        }
    }

    @Test("PERF07 parameter cannot be duplicated or used without field journey")
    func rejectsInvalidPerformanceArguments() {
        #expect(throws: SessionPackageFieldFixture.FixtureError.self) {
            try SessionPackageFieldFixture.performanceRequested(arguments: [
                SessionPackageFieldFixture.performanceArgument
            ])
        }
        #expect(throws: SessionPackageFieldFixture.FixtureError.self) {
            try SessionPackageFieldFixture.performanceRequested(arguments: [
                SessionPackageFieldFixture.activationArgument,
                SessionPackageFieldFixture.performanceArgument,
                SessionPackageFieldFixture.performanceArgument
            ])
        }
    }

    @Test("field fixture flags keep each production journey explicit")
    func validatesFieldFixtureCombinationsBeforeBootstrap() {
        let marker = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"]
        let field = RuntimeIsolationProfile.fieldActivationArgument
        let session = SessionPackageFieldFixture.activationArgument
        let performance = SessionPackageFieldFixture.performanceArgument
        let scroll = ChatScrollAsyncFieldFixture.activationArgument
        let task = TaskPackageFieldFixture.activationArgument
        let output = OutputPackageFieldFixture.activationArgument
        let media = MultimediaPackageFieldFixture.activationArgument
        let responsive = ResponsiveFieldScenario.activationArgument
        let valid = PackageFieldFixtureArguments.areValid

        #expect(valid([], [:]))
        #expect(valid([field, session], marker))
        #expect(valid([field, session, performance], marker))
        #expect(valid([field, session, scroll], marker))
        #expect(valid([field, session, task], marker))
        #expect(valid([field, session, output], marker))
        #expect(valid([field, media], marker))
        #expect(valid([field, responsive], marker))
        #expect(!valid([field, session], [:]))
        #expect(!valid([session], marker))
        #expect(!valid([field, performance], marker))
        #expect(!valid([field, task], marker))
        #expect(!valid([field, output], marker))
        #expect(!valid([field, session, output, task], marker))
        #expect(!valid([field, media, session], marker))
        #expect(!valid([field, responsive, media], marker))
        #expect(!valid([field, session, performance, task], marker))
        #expect(!valid([field, session, task,
                        ThemeApprovalPackageFieldFixture.activationArgument], marker))
        #expect(!valid([field, session, session], marker))
        #expect(!valid([field, field, session], marker))
        #expect(!valid([field, media, media], marker))
    }
}
