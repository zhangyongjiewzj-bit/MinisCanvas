import Foundation
import Testing
@testable import MinisCore

// MARK: - ToolLoopDetector

struct ToolLoopDetectorTests {

    @Test func repeatedIdenticalSignatureTriggersLoop() {
        let detector = ToolLoopDetector()
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(!detector.isLooping())
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(!detector.isLooping())
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(detector.isLooping())
    }

    @Test func twoRepetitionsBelowThresholdNotLooping() {
        let detector = ToolLoopDetector()
        detector.recordInvocation(tool: "file_read", input: ["path": "/a.txt"])
        detector.recordInvocation(tool: "file_read", input: ["path": "/a.txt"])
        #expect(!detector.isLooping())
    }

    @Test func differentSignatureBreaksStreak() {
        let detector = ToolLoopDetector()
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo one"])
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo two"]) // 不同参数
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo one"])
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo one"])
        // 尾部连续只有 2 次 "echo one"（中间被 "echo two" 打断），不算循环
        #expect(!detector.isLooping())
    }

    @Test func differentToolBreaksStreak() {
        let detector = ToolLoopDetector()
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        detector.recordInvocation(tool: "file_read", input: ["path": "/a.txt"])
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(!detector.isLooping())
    }

    @Test func resetClearsHistory() {
        let detector = ToolLoopDetector()
        for _ in 0..<3 {
            detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        }
        #expect(detector.isLooping())
        detector.reset()
        #expect(!detector.isLooping())
        #expect(detector.historySnapshot().isEmpty)
    }

    @Test func dictKeyOrderDoesNotChangeSignature() {
        let detector = ToolLoopDetector()
        let a: [String: Any] = ["command": "echo hi", "timeout": 30]
        let b: [String: Any] = ["timeout": 30, "command": "echo hi"]
        #expect(ToolLoopDetector.signature(tool: "shell_execute", input: a)
            == ToolLoopDetector.signature(tool: "shell_execute", input: b))
        detector.recordInvocation(tool: "shell_execute", input: a)
        detector.recordInvocation(tool: "shell_execute", input: b)
        detector.recordInvocation(tool: "shell_execute", input: a)
        #expect(detector.isLooping())
    }

    @Test func nestedValuesStableSignature() {
        let a: [String: Any] = ["command": "ls", "opts": ["-l", "-a"]]
        let b: [String: Any] = ["command": "ls", "opts": ["-l", "-a"]]
        #expect(ToolLoopDetector.signature(tool: "shell_execute", input: a)
            == ToolLoopDetector.signature(tool: "shell_execute", input: b))
    }

    @Test func historyLimitTruncatesWindowKeepingMostRecent() {
        // 窗口截断：只保留最近 historyLimit 条，最旧的被丢弃
        let detector = ToolLoopDetector(historyLimit: 3)
        detector.recordInvocation(tool: "file_read", input: ["path": "/old.txt"]) // 将被挤出窗口
        for _ in 0..<4 {
            detector.recordInvocation(tool: "file_read", input: ["path": "/hot.txt"])
        }
        let snapshot = detector.historySnapshot()
        #expect(snapshot.count == 3)
        // 窗口里全是最近的热签名（旧的 /old.txt 已被截断）
        #expect(snapshot.allSatisfy { $0.input["path"] as? String == "/hot.txt" })
        #expect(detector.isLooping())
    }

    @Test func loopThresholdOneTriggersImmediately() {
        // loopThreshold=1：一次调用即判定死循环；clamp 保证不为 0
        let detector = ToolLoopDetector(loopThreshold: 1)
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(detector.isLooping())
        // 一次后窗口内即达阈值，lastSignature 可读
        #expect(detector.lastSignature() == "shell_execute:{\"command\":\"echo hi\"}")
        // 阈值被 clamp 到 >= 1（0 不合法）
        detector.loopThreshold = 0
        #expect(detector.loopThreshold == 1)
    }

    @Test func thresholdChangeAtRuntimeReevaluates() {
        // 运行中调低阈值立即生效（isLooping 读当前阈值）
        let detector = ToolLoopDetector() // 默认 3
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        detector.recordInvocation(tool: "shell_execute", input: ["command": "echo hi"])
        #expect(!detector.isLooping())
        detector.loopThreshold = 2
        #expect(detector.isLooping())
    }

    @Test func signatureDistinguishesToolName() {
        // 相同参数 + 不同工具 → 不同签名（同签名才算循环）
        let input: [String: Any] = ["path": "/a.txt"]
        #expect(ToolLoopDetector.signature(tool: "file_read", input: input)
            != ToolLoopDetector.signature(tool: "file_write", input: input))
    }

    @Test func historyLimitClampsToLoopThreshold() {
        // historyLimit 低于 loopThreshold 时被 clamp 到阈值（窗口至少要能装下判定所需记录）
        let detector = ToolLoopDetector(loopThreshold: 5, historyLimit: 100)
        detector.historyLimit = 2
        #expect(detector.historyLimit == 5)
        #expect(detector.loopThreshold == 5)
    }

    @Test func recordInvocationReturnsSignature() {
        // @discardableResult：返回值 = 该调用的稳定签名，与 lastSignature 一致
        let detector = ToolLoopDetector()
        let sig = detector.recordInvocation(tool: "file_read", input: ["path": "/a.txt"])
        #expect(sig == detector.lastSignature())
        #expect(sig.hasPrefix("file_read:"))
    }
}

// MARK: - BashismDetector

struct BashismDetectorTests {

    @Test func doubleBracketTestHit() {
        let warnings = BashismDetector.detect("if [[ -f /tmp/x ]]; then echo yes; fi")
        #expect(warnings.contains { $0.ruleName == "doubleBracketTest" })
    }

    @Test func regexMatchOperatorHit() {
        let warnings = BashismDetector.detect("[[ \"$x\" =~ ^a[0-9]+$ ]] && echo match")
        #expect(warnings.contains { $0.ruleName == "regexMatchOperator" })
    }

    @Test func bothStreamRedirectHit() {
        let warnings = BashismDetector.detect("make build &> build.log")
        #expect(warnings.contains { $0.ruleName == "bothStreamRedirect" })
    }

    @Test func posixRedirectIsClean() {
        let warnings = BashismDetector.detect("make build > build.log 2>&1")
        #expect(warnings.isEmpty)
    }

    @Test func nestedCommandSubstitutionHit() {
        let warnings = BashismDetector.detect("echo \"$(basename $(pwd))\"")
        #expect(warnings.contains { $0.ruleName == "nestedCommandSubstitution" })
    }

    @Test func plainCommandSubstitutionIsClean() {
        let warnings = BashismDetector.detect("echo \"$(pwd)\"")
        #expect(warnings.isEmpty)
    }

    @Test func functionKeywordHit() {
        let warnings = BashismDetector.detect("function greet {\n  echo hi\n}")
        #expect(warnings.contains { $0.ruleName == "functionKeyword" })
    }

    @Test func posixFunctionDeclarationIsClean() {
        let warnings = BashismDetector.detect("greet() {\n  echo hi\n}")
        #expect(warnings.isEmpty)
    }

    @Test func hereStringHit() {
        let warnings = BashismDetector.detect("grep foo <<< \"$text\"")
        #expect(warnings.contains { $0.ruleName == "hereString" })
    }

    @Test func arithmeticForLoopHit() {
        let warnings = BashismDetector.detect("for ((i = 0; i < 10; i++)); do echo $i; done")
        #expect(warnings.contains { $0.ruleName == "arithmeticForLoop" })
    }

    @Test func cleanCommandHasZeroWarnings() {
        let warnings = BashismDetector.detect("echo hello && ls -la /tmp | grep txt")
        #expect(warnings.isEmpty)
    }

    @Test func commentLineWithBashSyntaxIsSkipped() {
        let warnings = BashismDetector.detect("# [[ -f x ]] && &> note\n echo ok")
        #expect(warnings.isEmpty)
    }

    @Test func heredocBodyIsNotScanned() {
        let script = """
        cat <<EOF
        if [[ $x =~ abc ]]; then
          python3 -c "print('&> not shell')"
        fi
        EOF
        echo done
        """
        let warnings = BashismDetector.detect(script)
        // heredoc 正文里的 [[ / =~ / &> 不应命中；shell 层只有 echo done
        #expect(warnings.isEmpty)
    }

    @Test func warningCarriesZshCompatNoteAndLineNumber() {
        let warnings = BashismDetector.detect("if [[ -f x ]]; then :; fi")
        guard let hit = warnings.first(where: { $0.ruleName == "doubleBracketTest" }) else {
            Issue.record("expected doubleBracketTest hit")
            return
        }
        #expect(hit.line == 1)
        #expect(hit.message.contains("zsh"))
        #expect(!hit.fixHint.isEmpty)
    }
}
