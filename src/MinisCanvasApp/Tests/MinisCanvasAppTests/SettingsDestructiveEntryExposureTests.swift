import XCTest
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 破坏性设置动作的原生确认与入口曝光契约（W5-086）
//
// 覆盖两个层面，全部同步、无 UI 时序：
// 1. 门禁缝：日志清空预览必须只读且如实申报不可逆；缺任一步确认文字，DeletionGate
//    直接拒绝且环形缓冲/磁盘文件零改动；两步确认后仅清空进程内缓冲，磁盘 app.log
//    原字节保留且可继续追加；过期预览（目标已变化）拒绝执行。
// 2. 结构契约：破坏性动作的原生 AX 触发元素不得埋在按视口节奏物化的容器里
//    （侧栏 LazyVStack / grouped Form 超长滚动尾部），否则可访问性树中不存在该
//    元素，真实确认对话框永远无法被到达。SettingsNativeInteractionConsumerTests
//    负责原生 AX 旅程；本文件在源码结构层防回归，两者不互相替代。
@MainActor
final class SettingsDestructiveEntryExposureTests: XCTestCase {

    private func makeCenter() -> (center: SettingsCenter, directory: URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("W5086-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 50)
        )
        return (center, directory)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    private func seededCenter() throws -> (center: SettingsCenter, directory: URL, logURL: URL, disk: Data) {
        let (center, directory) = makeCenter()
        center.liveLogLevel = .info
        center.logManager.info("before-clear", category: "NativeLogs")
        center.reloadLogs()
        let logURL = try XCTUnwrap(center.logManager.logFileURL())
        let disk = try Data(contentsOf: logURL)
        return (center, directory, logURL, disk)
    }

    // MARK: - 1. 门禁缝

    func testLogClearPreviewIsReadOnlyAndDeclaredIrreversible() throws {
        let (center, directory, logURL, disk) = try seededCenter()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ringBefore = center.logManager.recentLogs(limit: nil)
        let intent = try center.previewLogClear()
        XCTAssertEqual(intent.targetID, "logs.ring")
        XCTAssertEqual(intent.targetType, "logs.clear")
        XCTAssertEqual(intent.affectedCount, ringBefore.count)
        // 缓冲清空在进程内不可恢复；若申报 reversible=true，第二步门禁会放行
        // 「移入回收站」话术，验收侧的真实确认文字即被错位。
        XCTAssertFalse(intent.reversible)

        XCTAssertEqual(center.logManager.recentLogs(limit: nil).map(\.message), ringBefore.map(\.message))
        XCTAssertTrue(center.logManager.recentLogs(limit: nil).map(\.message).contains("before-clear"))
        XCTAssertEqual(try Data(contentsOf: logURL), disk)
    }

    func testMissingStepConfirmationsAreRejectedWithoutWritingAnything() throws {
        let (center, directory, logURL, disk) = try seededCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ringBefore = center.logManager.recentLogs(limit: nil).map(\.message)

        // 零确认直取执行 → 第一步即被拒。
        let bare = try center.previewLogClear()
        do {
            _ = try center.clearLogs(intent: bare)
            XCTFail("无确认文字的意图不得执行")
        } catch let error as DeletionGateError {
            XCTAssertEqual(error, .firstConfirmationRequired)
        }

        // 只填第一步 → 第二步门禁仍拒。
        let firstOnly = try center.previewLogClear().withFirstConfirmation("我已核对这份精确预览")
        do {
            _ = try center.clearLogs(intent: firstOnly)
            XCTFail("缺第二确认的意图不得执行")
        } catch let error as DeletionGateError {
            XCTAssertEqual(error, .secondConfirmationRequired)
        }

        XCTAssertEqual(center.logManager.recentLogs(limit: nil).map(\.message), ringBefore)
        XCTAssertEqual(try Data(contentsOf: logURL), disk)
    }

    func testConfirmedClearEmptiesRingButPreservesDiskFile() throws {
        let (center, directory, logURL, disk) = try seededCenter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ringCount = center.logManager.recentLogs(limit: nil).count

        let intent = try center.previewLogClear()
        let receipt = try center.clearLogs(intent: confirmed(intent))
        XCTAssertEqual(receipt.affectedCount, ringCount)
        XCTAssertTrue(center.logManager.recentLogs(limit: nil).isEmpty)

        // 磁盘日志一个字节都不能少，且之后接受的新日志继续写进同一文件。
        XCTAssertEqual(try Data(contentsOf: logURL), disk)
        center.logManager.info("after-clear", category: "NativeLogs")
        center.reloadLogs()
        XCTAssertTrue(center.logEntries.map(\.message).contains("after-clear"))
        XCTAssertNotEqual(try Data(contentsOf: logURL), disk)

        // 同一意图单次消费：重放被拒，不得二次生效。
        XCTAssertThrowsError(try center.clearLogs(intent: confirmed(intent)))
    }

    func testStalePreviewCannotClearNewerEntries() throws {
        let (center, directory, logURL, disk) = try seededCenter()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ringBefore = center.logManager.recentLogs(limit: nil).map(\.message)
        let stale = try center.previewLogClear()
        center.logManager.info("after-stale-preview", category: "NativeLogs")
        // 拒绝动作之前先取当前磁盘字节：LogManager 对每条被接受的日志都无条件落盘
        // （log → appendToFile，MinisCore/Sources/MinisCore/Support/LogManager.swift:146/170/212），
        // 所以上一行那条新日志必然让文件比 seededCenter 的快照更长；被拒的旧预览
        // 唯一的契约是“一个字节的既有内容都不改”，这里把它钉成逐字相等。
        let diskAfterAppend = try Data(contentsOf: logURL)
        do {
            _ = try center.clearLogs(intent: confirmed(stale))
            XCTFail("预览之后新增的缓冲条目不得被旧预览清掉")
        } catch let error as DeletionGateError {
            XCTAssertEqual(error, .targetChanged)
        }
        let ringAfter = center.logManager.recentLogs(limit: nil).map(\.message)
        XCTAssertEqual(ringAfter.count, ringBefore.count + 1)
        XCTAssertTrue(ringAfter.contains("after-stale-preview"))
        XCTAssertTrue(Set(ringBefore).isSubset(of: Set(ringAfter)))
        // 磁盘日志原字节必须保留：被拒的旧预览不得删除、截断或重写已有日志。
        // 与 seededCenter 快照的“逐字相等”（R10 前形态）在本用例里算术上不可能成立：
        // 用例自身在上一行（本文件第 124 行）刚写入一条新日志，R10 实测 195 vs 94 字节的
        // 增量正是这条合法追加。因此这里改成同时成立的两条更严格断言：既有字节仍是当前文件前缀
        // （不截断、不重写），且拒绝动作前后文件逐字相等（零改动）。整文件对 seededCenter
        // 快照的逐字相等仍由 testLogClearPreviewIsReadOnlyAndDeclaredIrreversible:67、
        // testMissingStepConfirmationsAreRejectedWithoutWritingAnything:94、
        // testConfirmedClearEmptiesRingButPreservesDiskFile:108 三处精确断言守着，未被放宽。
        let diskAfterRejection = try Data(contentsOf: logURL)
        XCTAssertTrue(
            diskAfterRejection.starts(with: disk),
            "被拒绝的旧预览不得改动磁盘日志的既有字节"
        )
        XCTAssertGreaterThan(diskAfterRejection.count, disk.count)
        XCTAssertEqual(
            diskAfterRejection,
            diskAfterAppend,
            "被拒绝的旧预览对磁盘日志必须零改动"
        )
    }

    // MARK: - 2. 入口曝光结构契约

    private func settingsViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
    }

    func testSidebarNavigationUsesNonLazyStackSoEveryTabEntryStaysExposed() throws {
        let source = try settingsViewSource()
        let start = try XCTUnwrap(source.range(of: "private func settingsSidebar"))
        let end = try XCTUnwrap(
            source.range(of: "@ViewBuilder", range: start.upperBound..<source.endIndex)
        )
        // 结构契约必须匹配真实代码，而不是注释文本：本区域的历史注释里出现过
        // "LazyVStack" 字面量（描述为何移除懒物化），裸 grep 会把解释文档的注释
        // 误判成容器本身，制造与产品曝光状态无关的假 RED。这里先剔除整行注释，
        // 再对剩余代码行做同一条断言——任何真实的懒物化容器仍会命中并失败。
        let sidebarCode = source[start.lowerBound..<end.lowerBound]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            sidebarCode.contains("LazyVStack"),
            "侧栏页签必须全部常驻物化：懒物化会让视口外的「日志」入口从可访问性树中消失"
        )
        XCTAssertTrue(sidebarCode.contains("VStack(spacing: 4)"))
        XCTAssertTrue(sidebarCode.contains(".accessibilityIdentifier(page.accessibilityIdentifier)"))
    }

    func testResetDefaultsTriggerIsPinnedOutsideTheScrollingForm() throws {
        let source = try settingsViewSource()
        let tabStart = try XCTUnwrap(source.range(of: "private struct GeneralSettingsTab"))
        let tabEnd = try XCTUnwrap(
            source.range(of: "// MARK: - 排版（UX-01）", range: tabStart.upperBound..<source.endIndex)
        )
        let tab = source[tabStart.lowerBound..<tabEnd.lowerBound]

        let formClose = try XCTUnwrap(tab.range(of: ".formStyle(.grouped)"))
        let resetID = try XCTUnwrap(tab.range(of: "settings.reset.defaults"))
        XCTAssertGreaterThan(
            resetID.lowerBound,
            formClose.lowerBound,
            "「恢复全部默认设置」触发元素不得留在 grouped Form 的滚动内容里"
        )
        XCTAssertNotNil(
            tab.range(of: "safeAreaInset(edge: .bottom", range: formClose.lowerBound..<resetID.lowerBound),
            "触发元素必须固定在 Form 之外的常驻底部条内"
        )
        // 唯一权威入口 + 真实原生确认面（确认/取消两个显式动作都在）。
        XCTAssertEqual(
            tab.components(separatedBy: "accessibilityIdentifier(\"settings.reset.defaults\")").count - 1,
            1
        )
        XCTAssertTrue(tab.contains("confirmationDialog("))
        XCTAssertTrue(tab.contains("settings.reset.defaults.confirm"))
        XCTAssertTrue(tab.contains("settings.reset.defaults.cancel"))
    }

    func testLogClearEntryRoutesThroughTheSharedTwoStepDeletionPrompt() throws {
        let source = try settingsViewSource()
        let tabStart = try XCTUnwrap(source.range(of: "private struct LogsSettingsTab"))
        let tabEnd = try XCTUnwrap(
            source.range(of: "// MARK: - 关于（About）", range: tabStart.upperBound..<source.endIndex)
        )
        let tab = source[tabStart.lowerBound..<tabEnd.lowerBound]
        XCTAssertTrue(tab.contains(".accessibilityIdentifier(\"settings.logs.clear\")"))
        XCTAssertTrue(tab.contains("beginClearLogs()"))
        XCTAssertTrue(tab.contains("intent: try center.previewLogClear()"))
        XCTAssertTrue(tab.contains("execute: { try center.clearLogs(intent: $0) }"))
        XCTAssertTrue(
            tab.contains(".sheet(item: $pendingDeletion)"),
            "清空日志必须经共享的原生两步确认面，不得旁路执行"
        )
    }
}
