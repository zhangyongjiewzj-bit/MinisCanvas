import Foundation

/// 绕过档下，`osascript ... do shell script "内层命令"` 和 `sudo <命令>` 里嵌套的命令也要过底线。
///
/// 用户 2026-11-17 决定：绕过档下 osascript、sudo 本身不询问（对齐 Claude Code），但补两条底线：
/// 1. 把 `do shell script` 引号里的内层命令、`sudo` 后面的命令取出来，过与普通命令相同的底线检查
///    （读钥匙串密码、抹盘、卸载系统服务；系统文件与已装软件；凭据与应用自身数据）。命中就拒绝。
/// 2. 静态看不清要执行什么的 osascript（脚本文件、标准输入、含 `$` 或反引号、do shell script 的参数不是
///    字面字符串、JavaScript 脚本、run script 等）在绕过档改为弹卡询问，可选"本对话内都允许"。
///
/// 2026-11-17 补：绕过档下所有 shell 命令（含直接写出的 diskutil eraseDisk、security dump-keychain）也过同一条底线。
///
/// 只在绕过档调用；非绕过档的终端策略与审批行为不变。尽力匹配，不是安全边界。
enum ShellNestedCommandInspector {
    private static let maxDepth = 4
    private static let sudoValueFlags: Set<Character> = ["u", "g", "h", "p", "C", "D", "R", "r", "t", "T", "U", "c"]
    private static let sudoValueLongOptions: Set<String> = [
        "--user", "--group", "--host", "--prompt", "--chdir", "--close-from", "--role", "--type",
        "--other-user", "--command-timeout", "--login-class",
    ]
    private static let transparentWrappers: Set<String> = ["command", "env", "nohup", "time", "exec", "builtin"]

    /// 命中底线返回原因。
    static func violation(command: String) -> String? {
        violation(command: command, depth: 0)
    }

    /// 命令里有静态看不清内容的 osascript。
    static func hasOpaqueScript(command: String) -> Bool {
        analyze(command: command, depth: 0).opaque
    }

    // MARK: - 解析

    private struct Analysis {
        /// 取出的内层命令（已还原成可再检查的文本）。
        var inner: [String] = []
        /// sudo 后面的全部词（不跳过选项），用于子命令表比对。
        var sudoWords: [[String]] = []
        var opaque = false
    }

    private static func analyze(command: String, depth: Int) -> Analysis {
        var result = Analysis()
        for segment in BypassSystemFloor.segments(command) {
            var words = segment.words
            // 前置环境变量赋值与透明包装。
            while let first = words.first {
                let base = (first as NSString).lastPathComponent
                if first.contains("="), !first.hasPrefix("/"), !first.hasPrefix("-") {
                    words.removeFirst()
                } else if transparentWrappers.contains(base) {
                    words.removeFirst()
                    while let flag = words.first, flag.hasPrefix("-") { words.removeFirst() }
                } else { break }
            }
            guard let first = words.first else { continue }
            switch (first as NSString).lastPathComponent {
            case "sudo":
                let rest = sudoCommandWords(words)
                result.sudoWords.append(Array(words.dropFirst()))
                if !rest.isEmpty {
                    let rendered = rest.map(shellQuoted).joined(separator: " ")
                    result.inner.append(rendered)
                    if depth < maxDepth, analyze(command: rendered, depth: depth + 1).opaque { result.opaque = true }
                }
            case "osascript":
                let parsed = osascriptInnerCommands(Array(words.dropFirst()))
                if parsed.opaque { result.opaque = true }
                for inner in parsed.commands {
                    result.inner.append(inner)
                    if depth < maxDepth, analyze(command: inner, depth: depth + 1).opaque { result.opaque = true }
                }
            default:
                continue
            }
        }
        return result
    }

    private static func violation(command: String, depth: Int) -> String? {
        // 绕过档下任何 shell 命令（不只 sudo、osascript 内层）都过同一条底线：
        // 读钥匙串密码、抹盘、卸载系统服务。与非绕过档终端策略共用 conditionalHardDeniedInvocation。
        for segment in BypassSystemFloor.segments(command) {
            let flattened = segment.words.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            if TerminalPolicySnapshot.conditionalHardDeniedInvocation(in: flattened) {
                return "绕过模式底线：不允许读取钥匙串密码、抹盘或卸载系统服务"
            }
        }
        let analysis = analyze(command: command, depth: depth)
        for words in analysis.sudoWords {
            let flattened = words.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            if TerminalPolicySnapshot.conditionalHardDeniedInvocation(in: flattened) {
                return "绕过模式底线：不允许经 sudo 读取钥匙串密码、抹盘或卸载系统服务"
            }
        }
        for inner in analysis.inner {
            let words = TerminalPolicySnapshot.policyWords(inner, fallback: [])
            if TerminalPolicySnapshot.conditionalHardDeniedInvocation(in: words) {
                return "绕过模式底线：不允许经 osascript 或 sudo 读取钥匙串密码、抹盘或卸载系统服务"
            }
            if let reason = SensitiveFilePolicy.protectedStateShellViolation(command: inner)
                ?? BypassSystemFloor.shellViolation(command: inner)
                ?? SensitiveFilePolicy.credentialShellViolation(command: inner)
                ?? BypassAppDataFloor.shellMentionViolation(command: inner) {
                return reason
            }
            if depth < maxDepth, let reason = violation(command: inner, depth: depth + 1) { return reason }
        }
        return nil
    }

    // MARK: - sudo

    /// `sudo [选项] [VAR=值] 命令 参数…` 里真正要执行的命令与参数。
    private static func sudoCommandWords(_ words: [String]) -> [String] {
        var index = 1
        while index < words.count {
            let word = words[index]
            if word == "--" { index += 1; break }
            if word.hasPrefix("--") {
                index += (!word.contains("=") && sudoValueLongOptions.contains(word)) ? 2 : 1
                continue
            }
            if word.hasPrefix("-"), word.count > 1 {
                // 簇里最后一个字母需要值（`-u root`）时，值在下一个词。
                index += (word.count == 2 && word.last.map(sudoValueFlags.contains) == true) ? 2 : 1
                continue
            }
            if word.contains("="), !word.hasPrefix("/") { index += 1; continue }
            break
        }
        return index < words.count ? Array(words[index...]) : []
    }

    private static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/.,:=+@%-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - osascript

    private static func osascriptInnerCommands(_ arguments: [String]) -> (commands: [String], opaque: Bool) {
        var scripts: [String] = []
        var opaque = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-e" {
                guard index < arguments.count else { opaque = true; break }
                scripts.append(arguments[index])
                index += 1
            } else if argument.hasPrefix("-e"), argument.count > 2 {
                scripts.append(String(argument.dropFirst(2)))
            } else if argument == "-l" {
                if index < arguments.count, arguments[index].lowercased() != "applescript" { opaque = true }
                index += 1
            } else if argument.hasPrefix("-l"), argument.count > 2 {
                if argument.dropFirst(2).lowercased() != "applescript" { opaque = true }
            } else if argument == "-s" {
                index += 1
            } else if argument == "-i" {
                opaque = true
            } else if argument.hasPrefix("-") {
                continue
            } else if scripts.isEmpty {
                // 没有 -e 时第一个位置参数是脚本文件。
                opaque = true
            }
        }
        // 没有 -e：脚本来自文件或标准输入。
        if scripts.isEmpty { return ([], true) }
        var commands: [String] = []
        for script in scripts {
            let parsed = shellCommands(inAppleScript: script)
            commands.append(contentsOf: parsed.commands)
            if parsed.opaque { opaque = true }
        }
        return (commands, opaque)
    }

    /// 取出 AppleScript 里 `do shell script "…"`（及 Terminal 的 `do script "…"`）的字面字符串。
    /// 参数不是字面字符串、用 `&` 拼接、脚本里含 `$`/反引号、`run script`/`load script`，都算看不清。
    private static func shellCommands(inAppleScript script: String) -> (commands: [String], opaque: Bool) {
        var commands: [String] = []
        var opaque = script.contains("$") || script.contains("`")
        let lowered = script.lowercased()
        if lowered.contains("run script") || lowered.contains("load script") { opaque = true }
        let characters = Array(script)
        let loweredCharacters = Array(lowered)
        for keyword in ["do shell script", "do script"] {
            let needle = Array(keyword)
            var start = 0
            while start + needle.count <= loweredCharacters.count {
                guard Array(loweredCharacters[start..<(start + needle.count)]) == needle else { start += 1; continue }
                var cursor = start + needle.count
                start = cursor
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                guard cursor < characters.count, characters[cursor] == "\"" else { opaque = true; continue }
                cursor += 1
                var literal = ""
                var closed = false
                while cursor < characters.count {
                    let character = characters[cursor]
                    cursor += 1
                    if character == "\\", cursor < characters.count {
                        let next = characters[cursor]
                        cursor += 1
                        switch next {
                        case "n": literal.append("\n")
                        case "t": literal.append("\t")
                        case "r": literal.append("\r")
                        default: literal.append(next)
                        }
                    } else if character == "\"" {
                        closed = true
                        break
                    } else {
                        literal.append(character)
                    }
                }
                guard closed else { opaque = true; continue }
                commands.append(literal)
                if literal.contains("$") || literal.contains("`") { opaque = true }
                var after = cursor
                while after < characters.count, characters[after].isWhitespace { after += 1 }
                if after < characters.count, characters[after] == "&" { opaque = true }
                start = cursor
            }
        }
        return (commands, opaque)
    }
}
