// D-SETTINGS-17 · lane QODER-DEV-W14-SETTINGS17-RESIZE-191B (bounded retry of
// 191, which died with measured ZERO writes at base d3fd00008).
//
// Authoritative clause (逐项验收清单, verbatim):
//   `- [!] SETTINGS-17 设置窗口可调整尺寸，并为新增分类和内容保留扩展空间。`
//   issues/三期初期合拢-App逐项功能验收清单-20260826.md:465
// Field defect line: 「P1 设置窗口尺寸固定且无扩展余量」
//   issues/三期初期合拢-App第二批智能体现场验收报告-20260826.md (十四 matrix).
//
// Measured counterexample (pre-191B): production entry presented SettingsView
// via .sheet with a pinned `.frame(width: 720, height: 520)`
// (MinisCanvasApp.swift:725 at d3fd00008). A fixed frame removes user
// adjustability of the presentation itself; SettingsView's internal
// responsiveness (SettingsLayoutPolicy.minimumSupportedWidth 600,
// GeometryReader at SettingsView.swift:400) does not demonstrate the window
// being adjustable — content-responsive ≠ entry-adjustable (108B erratum).
//
// Narrowest literal reading implemented: replace the pinned frame with an
// elastic frame — ideal 720×520 and max .infinity on both axes. The original
// 720pt lower width was reduced to the original 600pt contract in TASK2046;
// the 720pt initial posture remains unchanged.
//
// Verification is source-contract only. Nothing here was compiled or executed
// at authoring time; compilation belongs to the PKG GATE lane (same
// discipline as lane 155).

import Foundation
import Testing

@Suite("D-SETTINGS-17 settings sheet presentation is user-resizable 191B")
struct SettingsSheetResizable191BTests {

    /// Brace-matched content of the settings sheet, independent of the dismiss handler body.
    private static func settingsSheetRegion(appText: String) throws -> String {
        let dismissOpener = ".sheet(isPresented: $isSettingsPresented, onDismiss: {"
        guard let dismissRange = appText.range(of: dismissOpener),
              let dismissEnd = closingBrace(in: appText, from: appText.index(before: dismissRange.upperBound)),
              appText[dismissEnd...].hasPrefix("}) {") else {
            throw NSError(
                domain: "SettingsSheetResizable191BTests",
                code: 1,
                userInfo: ["message": "settings sheet opener vanished from MinisCanvasApp.swift"]
            )
        }
        let contentStart = appText.index(dismissEnd, offsetBy: 3)
        guard let contentEnd = closingBrace(in: appText, from: contentStart) else {
            throw NSError(
                domain: "SettingsSheetResizable191BTests",
                code: 2,
                userInfo: ["message": "unbalanced braces in settings sheet region"]
            )
        }
        return String(appText[appText.index(after: contentStart)..<contentEnd])
    }

    private static func closingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    @Test
    func settingsSheetHonorsAdjustabilityClause() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/MinisCanvasAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MinisCanvasApp
            .appendingPathComponent("Sources/MinisCanvasApp", isDirectory: true)
        let appText = try String(
            contentsOf: sources.appendingPathComponent("MinisCanvasApp.swift"),
            encoding: .utf8
        )
        let region = try Self.settingsSheetRegion(appText: appText)
        // Comment lines may narrate the historical fixed frame in prose; the
        // contract below is about the modifier code, so scrub `//` lines.
        let code = region
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // (1) No pinned axis: a fixed `.frame(width:…)`/`.frame(height:…)`
        // pins the sheet and contradicts 「可调整尺寸」.
        #expect(
            !code.contains(".frame(width:"),
            "D-SETTINGS-17 regression: fixed width frame pins the settings sheet"
        )
        #expect(
            !code.contains(".frame(height:"),
            "D-SETTINGS-17 regression: fixed height frame pins the settings sheet"
        )

        // (2) Both axes carry an adjustability contract: bounded lower size,
        // unbounded upper (expansion space for 新增分类和内容).
        #expect(code.contains("minWidth: 600"), "D-SETTINGS-17: 600pt width lower bound missing")
        #expect(code.contains("maxWidth: .infinity"), "D-SETTINGS-17: width not user-adjustable upward")
        #expect(code.contains("minHeight:"), "D-SETTINGS-17: height lower bound missing")
        #expect(code.contains("maxHeight: .infinity"), "D-SETTINGS-17: height not user-adjustable upward")

        // (3) Initial posture pinned to the pre-clause size: ideal 720×520 —
        // the change adds adjustability without altering first presentation.
        #expect(code.contains("idealWidth: 720"), "D-SETTINGS-17: initial width posture drifted from 720")
        #expect(code.contains("idealHeight: 520"), "D-SETTINGS-17: initial height posture drifted from 520")
    }
}
