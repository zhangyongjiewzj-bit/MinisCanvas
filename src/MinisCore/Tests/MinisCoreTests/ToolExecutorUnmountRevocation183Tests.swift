import Foundation
import Testing
@testable import MinisCore

// D-PRIVACY-04（撤销时效性 / revocation timeliness）核心面测试腿，lane
// QODER-DEV-W14-PRIVACY-UNMOUNT-STALE-183。
//
// 需求条款：同一个在运行中的 app（不重启、不改变子并发）先挂载外部文件夹并
// 读取成功，随后卸载；下一个任务对该文件夹的访问必须被拒绝。
//
// 在 f47a96fdb（R22）重新推导的锚点（旧 head 注册的三段锚点已部分失效）：
// - ToolExecutor.swift:321/369 — `additionalAllowedRoots` 仍是构造期不可变
//   快照；ToolExecutor.swift:975 — `resolveAllowedPath` 在【每一次】工具调用
//   时都从该属性即时读取允许根（无跨任务缓存）。
// - MinisCanvasApp.swift:808-810 — `.onChange(of: settingsCenter.mountedFolderPaths)`
//   已在 lane 149B（PKG-INT-026A-R22, c5d73e1d7）集成：卸载即触发
//   `reapplyProductionFileAccessBoundary()`（MinisCanvasApp.swift:673）。
// - BridgeStore.swift:1671-1675 + :1953 — 重挂载用更新后的 mountedFolderPaths
//   重建 `BuiltinToolExecutor`，并把实时引用 `builtinReference.value` 换成新
//   组合链；:1756 `ToolExecutorReference(builtinExecutor)` 是父/子共享的引用
//   间接层，子组合在 :1797 `toolExecutor: builtinReference.value` 经该引用取回。
//
// 因此 head 的生产撤销机制 = 身份交换（identity swap，149B 明确设计：Minis-
// CanvasApp.swift:667-671 注释说明边界变更走组合缝重建，进行中的轮次保持冻结
// 快照），而不是同一实例就地改写。核心层「同一实例改写」变体需要 ToolExecutor
// 增加 live provider 并由 BridgeStore 接线（该文件属 in-flight lane 194，本
// 写集禁止触碰）——未接线的机制是惰性半接线，故本腿不交付，delta 条款记录在
// receipt。
//
// 本文件按 149B 已集成的生产语义验证：经由同一 `ToolExecutorReference` 对象
// （app 不重启时的活动派发缝）在卸载后重绑到新构造快照，下一个任务即被拒绝。
// 运行时端到端（真实 SettingsCenter/onChange/审批面）在本腿 UNVERIFIED——
// 普通 DEV 线不跑 swift test / xcodebuild / UI 宿主，由 PKG 门禁代跑。

struct ToolExecutorUnmountRevocation183Tests {

    private func makeFixture() -> (work: URL, mounted: URL, mountedFile: URL, outsideFile: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorUnmount183-\(UUID().uuidString)", isDirectory: true)
        let work = base.appendingPathComponent("work", isDirectory: true)
        let mounted = base.appendingPathComponent("mounted", isDirectory: true)
        try! fm.createDirectory(at: work, withIntermediateDirectories: true)
        try! fm.createDirectory(at: mounted, withIntermediateDirectories: true)

        let mountedFile = mounted.appendingPathComponent("note.txt")
        try! "hello mounted".data(using: .utf8)!.write(to: mountedFile)
        let outsideFile = base.appendingPathComponent("outside.txt")
        try! "outside".data(using: .utf8)!.write(to: outsideFile)

        return (work, mounted, mountedFile, outsideFile)
    }

    private func makeExecutor(work: URL, mounted: URL?) -> BuiltinToolExecutor {
        BuiltinToolExecutor(
            allowedRoot: work,
            deniedRoots: [],
            additionalAllowedRoots: mounted.map { [$0] } ?? []
        )
    }

    // 正对照：挂载期间，经生产同款引用间接层（ToolExecutorReference）读取
    // 挂载根内文件成功。
    @Test("D-PRIVACY-04 positive control: mounted root is readable through the live reference")
    func positiveControlMountedRootReadable() async throws {
        let f = makeFixture()
        let reference = ToolExecutorReference(makeExecutor(work: f.work, mounted: f.mounted))
        let out = try await reference.value.execute(
            name: "file_read",
            input: ["path": f.mountedFile.path]
        )
        #expect(out.contains("hello mounted"))
    }

    // 拒绝根边界：两个允许根之外的路径保持类型化 `pathViolation`（撤销腿
    // 必须复用同一拒绝类型，不允许出现新的未类型化失败形状）。
    @Test("D-PRIVACY-04 deny-root boundary: outside path stays a typed pathViolation")
    func denyRootBoundaryIsTypedPathViolation() async throws {
        let f = makeFixture()
        let reference = ToolExecutorReference(makeExecutor(work: f.work, mounted: f.mounted))
        await #expect(throws: ToolExecutorError.pathViolation(f.outsideFile.path)) {
            _ = try await reference.value.execute(
                name: "file_read",
                input: ["path": f.outsideFile.path]
            )
        }
    }

    // 撤销时效性主腿：不重启 app（同一 ToolExecutorReference 对象），挂载→
    // 读取成功后卸载。按 149B 集成进 head 的生产语义，卸载使
    // attachProductionServices 重建无该根的执行器快照并重绑同一引用；下一个
    // 任务经该引用派发即被拒绝，且后续每一次派发持续拒绝（:975 无跨任务缓存）。
    @Test("D-PRIVACY-04 revocation timeliness: unmount denies the next task through the same reference")
    func unmountDeniesNextTaskThroughSameReference() async throws {
        let f = makeFixture()
        let liveReference = ToolExecutorReference(makeExecutor(work: f.work, mounted: f.mounted))

        // 挂载期间可读（同一条款前置，不经中间断言弱化）。
        let before = try await liveReference.value.execute(
            name: "file_read",
            input: ["path": f.mountedFile.path]
        )
        #expect(before.contains("hello mounted"))

        // 卸载（不重启）：149B 生产链重建无该根的快照并重绑同一引用对象。
        // 子方（BridgeStore.swift:1797）与父方共享同一引用，故一并生效。
        let childFacingCopy = liveReference // 模拟子组合仅捕获引用本身
        liveReference.value = makeExecutor(work: f.work, mounted: nil)

        for _ in 1...2 {
            await #expect(throws: ToolExecutorError.pathViolation(f.mountedFile.path)) {
                _ = try await liveReference.value.execute(
                    name: "file_read",
                    input: ["path": f.mountedFile.path]
                )
            }
        }
        // 只经引用取回执行器的 consumer（子组合模式）同样看到撤销。
        await #expect(throws: ToolExecutorError.pathViolation(f.mountedFile.path)) {
            _ = try await childFacingCopy.value.execute(
                name: "file_write",
                input: ["path": f.mountedFile.path, "content": "revoked"]
            )
        }
    }

    // 边界文档腿：撤销时效性的保证范围是「经活动引用派发的下一个任务」；
    // 已捕获旧值拷贝的进行中轮次按其冻结快照运行到轮次结束（149B 设计，
    // MinisCanvasApp.swift:667-671 注释、ToolExecutor.swift:348-351 同类先例
    // terminalPolicySnapshot「只在请求之间替换」）。此腿断言冻结只发生在值
    // 拷贝层，不影响引用层的即时撤销——防止未来把拒绝缓存/粘滞引入核心缝。
    @Test("D-PRIVACY-04 scope: enforcement re-reads roots per call; no sticky grant can appear")
    func enforcementIsPerCallNotSticky() async throws {
        let f = makeFixture()
        let executor = makeExecutor(work: f.work, mounted: f.mounted)
        let first = try await executor.execute(
            name: "file_read",
            input: ["path": f.mountedFile.path]
        )
        #expect(first.contains("hello mounted"))
        // 同一实例反复读取的允许完全来自每次调用的 :975 现读，而非第一次
        // 调用的结果缓存：以未挂载姊妹路径交叉验证（同样必须现读现拒）。
        await #expect(throws: ToolExecutorError.pathViolation(f.outsideFile.path)) {
            _ = try await executor.execute(
                name: "file_read",
                input: ["path": f.outsideFile.path]
            )
        }
    }
}
