import Foundation

// MARK: - Goal18 Hooks: scripts that live outside the hash-protected directory

/// Finds project-relative paths in a project hook command that point outside
/// `.miniscanvas/hooks/`.
///
/// The project trust hash covers `.miniscanvas/hooks.json` and every file under
/// `.miniscanvas/hooks/`. A script anywhere else in the project can be rewritten
/// by the model's file tools without changing the hash, so a hook that runs one
/// would execute unreviewed code. Such hooks are flagged and never run.
///
/// This is a best-effort syntactic check on the command text, not a sandbox: it
/// cannot see what an interpreter does with inline code. The protected
/// directory (hash coverage) is the real boundary; this check only keeps the
/// ordinary mistake and the obvious bypass (`./scripts/x.sh`, `sh scripts/x.sh`,
/// `cd scripts && ./x.sh`, `$MINISCANVAS_PROJECT_DIR/x.sh`) from running.
public enum HookScriptReferenceAnalyzer {
    public static let protectedDirectory = ".miniscanvas/hooks"
    public static let protectedConfigFile = ".miniscanvas/hooks.json"
    private static let projectDirectoryVariables = [
        "${MINISCANVAS_PROJECT_DIR}", "$MINISCANVAS_PROJECT_DIR",
        "${CLAUDE_PROJECT_DIR}", "$CLAUDE_PROJECT_DIR",
    ]
    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    private static let inlineCodeFlags: Set<String> = ["-e", "-E", "-p", "-pe", "--eval", "--print"]
    private static let maximumNesting = 3

    /// Sorted, de-duplicated display paths (relative to the project root) that a
    /// command references outside the protected directory. Empty = none found.
    ///
    /// `.miniscanvas/hooks.json` 与 `.miniscanvas/hooks/` 只在项目 Hook 的信任哈希里。
    /// Claude 格式的 settings.json 哈希只含钩子命令本身，所以它传
    /// `protectsHooksDirectory: false`：引用那个目录里的脚本同样算"哈希之外"。
    /// `homeDirectory` 非空时先把 `~`、`$HOME`、`${HOME}` 展开再判断。
    public static func outsideReferences(
        command: String,
        projectRoot: String,
        allowsProjectDirectoryReferences: Bool = true,
        protectsHooksDirectory: Bool = true,
        homeDirectory: String? = nil
    ) -> [String] {
        var found: Set<String> = []
        let options = Options(
            allowsProjectDirectoryReferences: allowsProjectDirectoryReferences,
            protectsHooksDirectory: protectsHooksDirectory,
            homeDirectory: homeDirectory)
        analyze(command, projectRoot: projectRoot, options: options, depth: 0, into: &found)
        return found.sorted()
    }

    private struct Options {
        let allowsProjectDirectoryReferences: Bool
        let protectsHooksDirectory: Bool
        let homeDirectory: String?
    }

    private struct Word {
        let text: String
        /// First word of a simple command (resolved through PATH, not the cwd).
        let isCommandPosition: Bool
    }

    private static func analyze(_ command: String, projectRoot: String, options: Options, depth: Int, into found: inout Set<String>) {
        let words = tokenize(command)
        var index = 0
        var commandIsShell = false
        var skipNext = false
        while index < words.count {
            let word = words[index]
            index += 1
            if word.isCommandPosition {
                commandIsShell = shellNames.contains((word.text as NSString).lastPathComponent)
            }
            if skipNext {
                skipNext = false
                continue
            }
            if word.text == "-c" || word.text == "--command" {
                guard index < words.count else { continue }
                // For a shell the next word is itself a command line; for any
                // other interpreter it is inline code, which is not path syntax.
                if commandIsShell, depth < maximumNesting {
                    analyze(words[index].text, projectRoot: projectRoot, options: options, depth: depth + 1, into: &found)
                }
                index += 1
                continue
            }
            if !commandIsShell, inlineCodeFlags.contains(word.text) {
                skipNext = true
                continue
            }
            classify(word, projectRoot: projectRoot, options: options, into: &found)
        }
    }

    /// `~`、`~/x`、`$HOME/x`、`${HOME}/x` → 家目录绝对路径；其它原样返回。
    private static func expandingHome(_ text: String, home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        for prefix in ["${HOME}", "$HOME", "~"] where text == prefix || text.hasPrefix(prefix + "/") {
            return base + String(text.dropFirst(prefix.count))
        }
        return text
    }

    private static func classify(_ word: Word, projectRoot: String, options: Options, into found: inout Set<String>) {
        let allowsProjectDirectoryReferences = options.allowsProjectDirectoryReferences
        var text = word.text
        guard !text.isEmpty else { return }
        // `--config=./x` and `NAME=./x`: look at the value.
        if let equals = text.firstIndex(of: "="), !text.hasPrefix("/"), !text.hasPrefix(".") {
            text = String(text[text.index(after: equals)...])
            guard !text.isEmpty else { return }
        }
        // User hook cwd/hash base is its config directory, but this environment
        // variable names the live project. Its scripts are outside that hash.
        if !allowsProjectDirectoryReferences,
           projectDirectoryVariables.contains(where: { text.contains($0) }) {
            found.insert(text)
            return
        }
        for variable in projectDirectoryVariables where text.hasPrefix(variable) {
            text = projectRoot + String(text.dropFirst(variable.count))
            break
        }
        if let home = options.homeDirectory {
            text = expandingHome(text, home: home)
        }
        // Words that carry shell syntax are not plain paths.
        if text.contains(where: { "()'\";{}$`".contains($0) }) { return }
        if text.hasPrefix("~") || text.contains("://") { return }

        let relative: String
        if text.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: text).standardizedFileURL.path
            let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
            guard standardized.hasPrefix(root + "/") else { return }
            relative = String(standardized.dropFirst(root.count + 1))
        } else if text.hasPrefix("-") {
            return
        } else if text.contains("/") || text.hasPrefix("..") {
            guard let normalized = normalizeRelative(text) else {
                found.insert(text) // climbs out of the project directory
                return
            }
            // `./x` and `../x` are always paths. A plain `a/b` (a MIME type, a
            // flag value) only counts when its first component exists in the project.
            if !text.hasPrefix("./"), let first = normalized.split(separator: "/").first,
               !FileManager.default.fileExists(
                   atPath: URL(fileURLWithPath: projectRoot).appendingPathComponent(String(first)).path) {
                return
            }
            relative = normalized
        } else {
            // A bare word is a project path only when it names something in the
            // project root and is not the command itself.
            guard !word.isCommandPosition, text != ".", text != ".." else { return }
            let candidate = URL(fileURLWithPath: projectRoot).appendingPathComponent(text).path
            guard FileManager.default.fileExists(atPath: candidate) else { return }
            relative = text
        }
        if relative == "." || (options.protectsHooksDirectory && isProtected(relative)) { return }
        found.insert(relative)
    }

    private static func isProtected(_ relative: String) -> Bool {
        relative == protectedDirectory || relative.hasPrefix(protectedDirectory + "/")
            || relative == protectedConfigFile
    }

    /// Collapses `.` and `..`; nil when the path climbs above the project root.
    private static func normalizeRelative(_ path: String) -> String? {
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default: stack.append(component)
            }
        }
        return stack.isEmpty ? "." : stack.joined(separator: "/")
    }

    /// Quote-aware split into words. `; | & ( )` and newlines end a word and the
    /// next word starts a simple command; redirection operators only end a word.
    private static func tokenize(_ command: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var atCommandStart = true
        var currentIsCommand = true

        func flush() {
            if hasCurrent {
                words.append(Word(text: current, isCommandPosition: currentIsCommand))
                atCommandStart = false
            }
            current = ""
            hasCurrent = false
        }

        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                if !hasCurrent { currentIsCommand = atCommandStart }
                hasCurrent = true
                quote = character
            case " ", "\t":
                flush()
            case ";", "|", "&", "(", ")", "\n":
                flush()
                atCommandStart = true
            case "<", ">":
                flush()
            default:
                if !hasCurrent { currentIsCommand = atCommandStart }
                hasCurrent = true
                current.append(character)
            }
        }
        flush()
        return words
    }
}
