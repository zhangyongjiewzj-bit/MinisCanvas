import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TERMINAL-08 actual ordinary submit and production boundary")
@MainActor
struct TerminalCompoundActualSubmissionCurrentConsumerTests {
    @Test func originalCompoundSyntaxRequiresApprovalWithoutEffectsAndNextLegalCommandRuns() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "TERM08-actual")
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory.appendingPathComponent("owned-project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("ACTUAL_TERM08_SYNTHETIC_ROOT=\(root.path)")
        func logProbe(_ name: String, _ command: String) {
            print("ACTUAL_TERM08_PROBE name=\(name) command=\(command)")
        }
        let preserved = root.appendingPathComponent("original.txt")
        let original = Data("owned original bytes\n".utf8)
        try original.write(to: preserved)
        let marker = root.appendingPathComponent("must-not-exist.txt")
        let snapshot = TerminalContextSnapshot(sessionID: "term08-session", turnID: "term08-turn",
            taskID: "term08-task", projectID: "term08-project", workdir: root.path)
        let store = TerminalStore(contextSnapshot: snapshot)
        defer { store.stop() }
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, policySnapshot: .default)
        let probes: [(String, String, TerminalBoundaryError)] = [
            ("semicolon", "echo harmless; touch \(marker.path)", .approvalRequired),
            ("pipeline", "echo harmless | tee \(marker.path)", .approvalRequired),
            ("redirect", "echo changed > \(preserved.path)", .approvalRequired),
            ("variable", "echo $TERM08_OWNED_VALUE > \(marker.path)", .pathViolation),
            ("command-substitution", "echo $(touch \(marker.path))", .pathViolation),
            ("backtick-substitution", "echo `touch \(marker.path)`", .pathViolation),
            ("background", "touch \(marker.path) &", .approvalRequired),
            ("env-wrapper-hard-deny", "env open \(root.path)/Synthetic.app", .denied),
            ("nice-wrapper-hard-deny", "nice -n 2 open \(root.path)/Synthetic.app", .denied)
        ]
        for (name, command, expectedError) in probes {
            logProbe(name, command)
            let denied = expectedError == .denied
            let visibleBefore = store.output
            store.input = command
            store.submit()
            #expect(!store.isRunning, "unapproved ordinary submit must not start: \(name)")
            if denied {
                #expect(store.pendingConfirmation == nil)
                #expect(store.output.contains("命令被拒绝"))
            } else {
                #expect(store.pendingConfirmation?.raw == command,
                        "exact original command must require confirmation: \(name)")
                #expect(store.output == visibleBefore, "unconfirmed input is not execution output")
            }
            let receipt = await adapter.execute(command: command, cwd: root.path, approved: false)
            #expect(receipt.error == expectedError.rawValue,
                    "actual native boundary must fail before execution: \(name)")
            #expect(receipt.exitCode == nil)
            if expectedError == .pathViolation {
                // Expansion has no statically bound path. The original policy
                // refuses it even when a caller supplies exact approval.
                let approved = await adapter.execute(command: command, cwd: root.path, approved: true)
                #expect(approved.error == TerminalBoundaryError.pathViolation.rawValue)
                #expect(approved.exitCode == nil)
            }
            #expect(receipt.sessionID == snapshot.sessionID)
            #expect(receipt.turnID == snapshot.turnID)
            #expect(receipt.taskID == snapshot.taskID)
            #expect(receipt.projectID == snapshot.projectID)
            #expect(receipt.workdir == root.path)
            #expect(!receipt.requestFingerprint.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(try Data(contentsOf: preserved) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["original.txt"])
            store.cancelPending()
            #expect(store.pendingConfirmation == nil)
            print("ACTUAL_TERM08_REJECT name=\(name) receipt=\(receipt.error ?? "nil") exit=\(receipt.exitCode.map { String($0) } ?? "nil") effects=0")
        }
        // No injected runner: the original production boundary starts and reaps
        // a real harmless command. This also witnesses that the negative matrix
        // did not depend on an unusable cwd or an empty execution capability.
        let legal = await adapter.execute(command: "echo TERM08_ACTUAL_LEGAL", cwd: root.path, approved: false)
        logProbe("native-positive", "echo TERM08_ACTUAL_LEGAL")
        #expect(legal.error == nil)
        #expect(legal.exitCode == 0)
        #expect(legal.output.contains("TERM08_ACTUAL_LEGAL"))
        store.input = "echo TERM08_VISIBLE_LEGAL"
        logProbe("visible-positive", store.input)
        store.submit()
        #expect(store.isRunning)
        var completed = false
        for _ in 0..<500 {
            if !store.isRunning { completed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed, "actual visible consumer must consume its native terminal receipt")
        #expect(store.output.contains("TERM08_VISIBLE_LEGAL"))
        #expect(store.output.contains("（退出码 0）"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: preserved) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["original.txt"])
        print("ACTUAL_TERM08_NEXT_LEGAL boundary_exit=0 visible_exit=0 original_bytes_unchanged=true")

        // An automatically allowed find must not acquire a second write action
        // through its expression. Both entry points consume the same production
        // policy; every effect here is confined to this disposable project root.
        let victim = root.appendingPathComponent("find-victim.txt")
        let victimBytes = Data("owned find victim\n".utf8)
        try victimBytes.write(to: victim)
        let deleteCommand = "find \(root.path) -maxdepth 1 -name find-victim.txt -delete"
        logProbe("find-delete", deleteCommand)
        store.input = deleteCommand
        store.submit()
        let deletePending = store.pendingConfirmation?.raw == deleteCommand
        for _ in 0..<500 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let visibleVictim = try? Data(contentsOf: victim)
        print("ACTUAL_TERM08_FIND_RED entry=visible action=delete pending=\(deletePending) victim_preserved=\(visibleVictim == victimBytes)")
        #expect(deletePending)
        #expect(visibleVictim == victimBytes)
        store.cancelPending()
        // Restore only the owned fixture so the native path independently
        // observes the same attack instead of inheriting the first effect.
        try victimBytes.write(to: victim)
        let nativeDelete = await adapter.execute(command: deleteCommand, cwd: root.path, approved: false)
        let nativeVictim = try? Data(contentsOf: victim)
        print("ACTUAL_TERM08_FIND_RED entry=native action=delete error=\(nativeDelete.error ?? "nil") exit=\(nativeDelete.exitCode.map { String($0) } ?? "nil") victim_preserved=\(nativeVictim == victimBytes)")
        #expect(nativeDelete.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(nativeDelete.exitCode == nil)
        #expect(nativeVictim == victimBytes)

        // Validated env/nice wrappers must classify the inner find expression
        // rather than inherit an automatic allow from the outer executable.
        for command in ["env \(deleteCommand)", "nice -n 2 \(deleteCommand)"] {
            logProbe(command.hasPrefix("env") ? "find-env-wrapper" : "find-nice-wrapper", command)
            store.input = command
            store.submit()
            #expect(store.pendingConfirmation?.raw == command)
            let native = await adapter.execute(command: command, cwd: root.path, approved: false)
            #expect(native.error == TerminalBoundaryError.approvalRequired.rawValue)
            #expect(native.exitCode == nil)
            #expect(try Data(contentsOf: victim) == victimBytes)
            store.cancelPending()
            print("ACTUAL_TERM08_FIND_WRAPPER command=\(command.hasPrefix("env") ? "env" : "nice") native=\(native.error ?? "nil") exit=\(native.exitCode.map { String($0) } ?? "nil") effects=0")
        }

        // A deliberate exact approval still permits the normal write action
        // within the disposable project root; confirmation is not a blanket
        // disablement of find.
        let approvedDelete = await adapter.execute(command: deleteCommand, cwd: root.path, approved: true)
        #expect(approvedDelete.error == nil)
        #expect(approvedDelete.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        try victimBytes.write(to: victim)
        print("ACTUAL_TERM08_FIND_APPROVED_DELETE exit=\(approvedDelete.exitCode ?? -1) owned_effect=true")

        let printed = root.appendingPathComponent("find-output.txt")
        let printCommand = "find \(root.path) -maxdepth 0 -fprint \(printed.path)"
        logProbe("find-fprint", printCommand)
        store.input = printCommand
        store.submit()
        let printPending = store.pendingConfirmation?.raw == printCommand
        for _ in 0..<500 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let visiblePrinted = FileManager.default.fileExists(atPath: printed.path)
        print("ACTUAL_TERM08_FIND_RED entry=visible action=fprint pending=\(printPending) output_created=\(visiblePrinted)")
        #expect(printPending)
        #expect(!visiblePrinted)
        store.cancelPending()
        try? FileManager.default.removeItem(at: printed)
        let nativePrint = await adapter.execute(command: printCommand, cwd: root.path, approved: false)
        let nativePrinted = FileManager.default.fileExists(atPath: printed.path)
        print("ACTUAL_TERM08_FIND_RED entry=native action=fprint error=\(nativePrint.error ?? "nil") exit=\(nativePrint.exitCode.map { String($0) } ?? "nil") output_created=\(nativePrinted)")
        #expect(nativePrint.error == TerminalBoundaryError.approvalRequired.rawValue)
        #expect(nativePrint.exitCode == nil)
        #expect(!nativePrinted)

        let dispatchMarker = root.appendingPathComponent("find-dispatch-must-not-exist.txt")
        for option in ["-exec", "-execdir", "-ok", "-okdir"] {
            let command = "find \(root.path) -maxdepth 0 \(option) touch \(dispatchMarker.path) {} \\;"
            logProbe("find-\(option)", command)
            store.input = command
            store.submit()
            #expect(store.pendingConfirmation == nil, "find command dispatch must be hard-denied: \(option)")
            #expect(!store.isRunning)
            let native = await adapter.execute(command: command, cwd: root.path, approved: false)
            #expect(native.error == TerminalBoundaryError.denied.rawValue)
            #expect(native.exitCode == nil)
            let approved = await adapter.execute(command: command, cwd: root.path, approved: true)
            #expect(approved.error == TerminalBoundaryError.denied.rawValue,
                    "an approval cannot authorize a second executable: \(option)")
            #expect(approved.exitCode == nil)
            #expect(!FileManager.default.fileExists(atPath: dispatchMarker.path))
            print("ACTUAL_TERM08_FIND_DISPATCH option=\(option) native=\(native.error ?? "nil") native_exit=\(native.exitCode.map { String($0) } ?? "nil") approved=\(approved.error ?? "nil") approved_exit=\(approved.exitCode.map { String($0) } ?? "nil") effects=0")
        }

        // `env -S` changes the effective executable after the lexical guard
        // has rejected the wrapper. Even an exact approval must not revive a
        // find expression that dispatches another command.
        let splitCommand = "env -S find \(root.path) -maxdepth 0 -exec touch \(dispatchMarker.path) {} +"
        logProbe("find-env-split", splitCommand)
        store.input = splitCommand
        store.submit()
        let visibleSplitDenied = store.pendingConfirmation == nil && !store.isRunning
        let splitNative = await adapter.execute(command: splitCommand, cwd: root.path, approved: false)
        let splitApproved = await adapter.execute(command: splitCommand, cwd: root.path, approved: true)
        let splitEffect = FileManager.default.fileExists(atPath: dispatchMarker.path)
        print("ACTUAL_TERM08_FIND_SPLIT visible_denied=\(visibleSplitDenied) native=\(splitNative.error ?? "nil") native_exit=\(splitNative.exitCode.map { String($0) } ?? "nil") approved=\(splitApproved.error ?? "nil") approved_exit=\(splitApproved.exitCode.map { String($0) } ?? "nil") effect=\(splitEffect)")
        #expect(visibleSplitDenied)
        #expect(splitNative.error == TerminalBoundaryError.denied.rawValue)
        #expect(splitNative.exitCode == nil)
        #expect(splitApproved.error == TerminalBoundaryError.denied.rawValue)
        #expect(splitApproved.exitCode == nil)
        #expect(!splitEffect)
        store.cancelPending()

        for option in ["-fprintf", "-fls"] {
            let command = "find \(root.path) -maxdepth 0 \(option) \(printed.path)"
            logProbe("find-\(option)", command)
            store.input = command
            store.submit()
            #expect(store.pendingConfirmation?.raw == command)
            let native = await adapter.execute(command: command, cwd: root.path, approved: false)
            #expect(native.error == TerminalBoundaryError.approvalRequired.rawValue)
            #expect(native.exitCode == nil)
            #expect(!FileManager.default.fileExists(atPath: printed.path))
            store.cancelPending()
            print("ACTUAL_TERM08_FIND_WRITE option=\(option) native=\(native.error ?? "nil") exit=\(native.exitCode.map { String($0) } ?? "nil") effects=0")
        }

        // Existing read-only find remains available to the ordinary Store and
        // native boundary; the negative matrix must not disable the command.
        let readCommand = "find \(root.path) -maxdepth 1 -name find-victim.txt"
        logProbe("find-read-positive", readCommand)
        store.input = readCommand
        store.submit()
        #expect(store.pendingConfirmation == nil)
        for _ in 0..<500 {
            if !store.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.output.contains(victim.path))
        let nativeRead = await adapter.execute(command: readCommand, cwd: root.path, approved: false)
        #expect(nativeRead.error == nil)
        #expect(nativeRead.exitCode == 0)
        #expect(nativeRead.output.contains(victim.path))
        #expect(try Data(contentsOf: victim) == victimBytes)
        print("ACTUAL_TERM08_FIND_READ visible=true native_exit=0 bytes_unchanged=true")
    }
}
