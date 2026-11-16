import Foundation
import Darwin

/// Blender 命令行白模渲染桥接（M3）。
///
/// 职责：检测本机 Blender 安装，封装 `blender -b -P <script>` 后台渲染调用，
/// 返回生成的 PNG 帧列表。脚本（白模/相机/灯光 + 渲染输出）由调用方提供，
/// Swift 侧不触碰 bpy —— 那是 Blender 进程内部的事。
public struct BlenderBridge {

    /// Blender 错误类型。
    public enum BlenderBridgeError: Error, LocalizedError, Sendable {
        /// Blender 未安装或路径不可执行。
        case notInstalled
        /// 渲染进程非 0 退出。
        case renderFailed(stderr: String)
        /// 渲染超时（默认 300 秒）。
        case timeout
        /// 渲染成功但输出目录没有 PNG。
        case noOutput(directory: String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Blender 未安装或不可执行。路径：\(BlenderBridge.blenderPath())，可用环境变量 MINISCANVAS_BLENDER 覆盖。"
            case .renderFailed(let stderr):
                return "Blender 渲染失败：\(stderr)"
            case .timeout:
                return "Blender 渲染超时（\(Int(BlenderBridge.renderTimeout)) 秒）。"
            case .noOutput(let directory):
                return "Blender 渲染结束但未在 \(directory) 生成 PNG。"
            }
        }
    }

    /// 默认 Blender 可执行文件路径（macOS .app 标准安装位置）。
    public static let defaultBlenderPath = "/Applications/Blender.app/Contents/MacOS/Blender"

    /// 覆盖 Blender 路径的环境变量名。
    public static let blenderEnvVar = "MINISCANVAS_BLENDER"

    /// 渲染超时（秒）。
    public static let renderTimeout: TimeInterval = 300

    /// 解析 Blender 可执行文件路径：优先环境变量 MINISCANVAS_BLENDER，否则用默认路径。
    public static func blenderPath() -> String {
        let env = getenv(blenderEnvVar).map { String(cString: $0) }
        if let env, !env.isEmpty {
            return env
        }
        return defaultBlenderPath
    }

    /// 检查 Blender 是否已安装（路径存在且为可执行文件）。
    public static func isInstalled() -> Bool {
        let path = blenderPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// 构造 `blender -b -P` 参数。Blender 自定义参数放在 `--` 之后，
    /// 脚本内可通过 `sys.argv` 读取（argv[0] 为脚本路径）。
    public static func renderArgs(scriptPath: String, outputDir: String) -> [String] {
        ["-b", "-P", scriptPath, "--", "--output-dir", outputDir]
    }

    /// 白模渲染：以 `blender -b -P <script>` 后台运行用户提供的 Python 脚本，
    /// 等待进程结束，返回 outputDir 下生成的 PNG 文件路径列表（按文件名排序）。
    ///
    /// - Parameters:
    ///   - script: Python 脚本内容（创建白模/相机/灯光并渲染 PNG 序列到 outputDir）。
    ///   - outputDir: 渲染输出目录（不存在会自动创建）。
    ///   - frameRange: 可选帧范围，作为 `--frame-start N --frame-end M` 传给脚本，
    ///     同时以 MINISCANVAS_FRAME_START/MINISCANVAS_FRAME_END 环境变量暴露。
    /// - Returns: 生成的 PNG 绝对路径列表，按文件名升序。
    /// - Throws: `BlenderBridgeError.notInstalled` / `.renderFailed` / `.timeout` / `.noOutput`。
    public static func renderWhitemodel(
        script: String,
        outputDir: String,
        frameRange: (Int, Int)? = nil
    ) async throws -> [String] {
        guard isInstalled() else { throw BlenderBridgeError.notInstalled }

        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // 脚本落盘到临时目录，渲染结束后清理
        let scriptURL = fileManager.temporaryDirectory
            .appendingPathComponent("miniscanvas_blender_\(UUID().uuidString).py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: scriptURL) }

        // 组装进程
        let process = Process()
        process.executableURL = URL(fileURLWithPath: blenderPath())
        var args = renderArgs(scriptPath: scriptURL.path, outputDir: outputDir)
        if let frameRange {
            args += ["--frame-start", String(frameRange.0), "--frame-end", String(frameRange.1)]
        }
        process.arguments = args

        // 通过环境变量再暴露一份输出目录与帧范围，方便脚本用 os.environ 读取
        var environment = try ChildProcessEnvironment.values()
        environment["MINISCANVAS_OUTPUT_DIR"] = outputDir
        if let frameRange {
            environment["MINISCANVAS_FRAME_START"] = String(frameRange.0)
            environment["MINISCANVAS_FRAME_END"] = String(frameRange.1)
        }
        process.environment = environment

        // 用 Pipe 捕获 stdout/stderr（readabilityHandler 持续排空，避免管道缓冲阻塞）
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class OutputAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock(); data.append(chunk); lock.unlock()
            }
            func stringValue() -> String {
                lock.lock(); defer { lock.unlock() }
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
        let stdoutAccumulator = OutputAccumulator()
        let stderrAccumulator = OutputAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stdoutAccumulator.append(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderrAccumulator.append(chunk)
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }

        // 进程退出状态盒子：terminationHandler 与 await 之间用锁消除竞态
        final class ExitBox: @unchecked Sendable {
            private let lock = NSLock()
            private var status: Int32?
            private var continuation: CheckedContinuation<Int32, Never>?

            func setTerminated(_ status: Int32) {
                lock.lock()
                self.status = status
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: status)
            }

            func awaitExit() async -> Int32 {
                await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    lock.lock()
                    if let status {
                        lock.unlock()
                        cont.resume(returning: status)
                    } else {
                        continuation = cont
                        lock.unlock()
                    }
                }
            }
        }
        let exitBox = ExitBox()
        // 必须在 run() 之前挂 terminationHandler，避免进程快速退出导致漏接
        process.terminationHandler = { proc in
            exitBox.setTerminated(proc.terminationStatus)
        }

        // 超时看门狗：到点强杀进程，随后按退出码识别为 .timeout
        final class ProcessBox: @unchecked Sendable {
            let process: Process
            init(_ process: Process) { self.process = process }
        }
        let processBox = ProcessBox(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.renderTimeout) {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
        }

        do {
            try process.run()
        } catch {
            throw BlenderBridgeError.renderFailed(stderr: "无法启动 Blender（\(blenderPath())）：\(error)")
        }

        let exitCode = await exitBox.awaitExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdout = stdoutAccumulator.stringValue()
        let stderr = stderrAccumulator.stringValue()

        if exitCode != 0 {
            if process.terminationReason == .uncaughtSignal, exitCode == SIGTERM {
                throw BlenderBridgeError.timeout
            }
            let detail = stderr.isEmpty
                ? (stdout.isEmpty ? "Blender 退出码 \(exitCode)" : stdout)
                : stderr
            throw BlenderBridgeError.renderFailed(stderr: detail)
        }

        // 收集生成的 PNG
        let pngs = ((try? fileManager.contentsOfDirectory(atPath: outputDir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()
            .map { (outputDir as NSString).appendingPathComponent($0) }
        if pngs.isEmpty {
            throw BlenderBridgeError.noOutput(directory: outputDir)
        }
        return pngs
    }
}
