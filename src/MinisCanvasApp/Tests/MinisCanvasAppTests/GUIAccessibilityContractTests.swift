import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("MinisCanvas GUI accessibility and startup contracts")
struct GUIAccessibilityContractTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source binding plus actual registered metadata, not a native AX probe.
    /// A label on an unrelated button cannot satisfy this stop-control contract.
    @MainActor
    private func registeredStopAXSource(in viewSource: String) throws -> String {
        let spec = AppCommandCatalog.stopGenerationSpec(
            activeSessionID: { nil },
            stopStreaming: { Issue.record("AX metadata projection must not execute stop") }
        )
        let registry = CommandRegistry(commands: [spec.definition])
        let command = try #require(AppCommandMenuBuilder.command(
            id: "ui.chat.stop", registry: registry, display: [:]
        ))
        #expect(spec.definition.id == "ui.chat.stop")
        #expect(command.id == spec.definition.id)
        #expect(command.title == spec.definition.title)
        #expect(command.title == "停止生成")

        let start = try #require(viewSource.range(of: "if chat.isActiveSessionStreaming {"))
        let end = try #require(viewSource.range(
            of: "} else {", range: start.upperBound..<viewSource.endIndex
        ))
        let stop = String(viewSource[start.lowerBound..<end.lowerBound])
        #expect(stop.contains("if let stopCommand = AppCommandMenuBuilder.command("))
        #expect(stop.contains("id: \"ui.chat.stop\", registry: bridge.commandRegistry"))
        #expect(stop.contains("display: bridge.paletteDisplay"))
        #expect(stop.contains(".accessibilityLabel(stopCommand.title)"))
        #expect(stop.contains(".disabled(!stopCommand.isEnabled)"))
        #expect(stop.contains("bridge.runCommand(id: stopCommand.id, args:"))
        return stop
    }

    @Test("visible icon controls have stable VoiceOver names")
    @MainActor
    func criticalControlsExposeAccessibleNames() throws {
        let content = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")
        let canvas = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift")
        let chat = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")
        let assets = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift")
        let context = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift")

        for contract in [
            ".accessibilityLabel(\"返回\")",
            ".accessibilityLabel(\"前进\")",
            ".accessibilityLabel(\"打开设置中心\")",
            ".accessibilityLabel(\"资产预览区\")"
        ] {
            #expect(content.contains(contract), "Missing ContentView accessibility contract: \(contract)")
        }

        for contract in [
            ".accessibilityLabel(\"显示迷你地图\")",
            ".accessibilityLabel(\"预览图片\")",
            ".accessibilityLabel(\"导入图片\")",
            ".accessibilityLabel(\"播放视频\")",
            ".accessibilityLabel(\"导入视频\")",
            ".accessibilityAction"
        ] {
            #expect(canvas.contains(contract), "Missing CanvasView accessibility contract: \(contract)")
        }

        // This verifies source-level label wiring only; the native AX tree is unverified and must be checked on a packaged UI.
        for contract in [
            ".accessibilityLabel(\"添加附件\")",
            ".accessibilityLabel(\"选择插件或技能\")",
            ".accessibilityLabel(\"发送\")",
            "let indicator = item.indicator",
            "for: item, source: indicator",
            "let badge = projection.presentation",
            "item.retryIdentity",
            "retryFailedSession",
            ".accessibilityLabel(runtime?.title ?? badge.accessibilityLabel)",
            ".accessibilityIdentifier(\"chat.session.retry.",
            ".accessibilityIdentifier(\"chat.message.metadata.",
            "ChatMessageMetadata.elapsedText",
            ".accessibilityValue(elapsedText)",
            ".frame(width: 18, height: 16)",
            "chat.session.indicator."
        ] {
            #expect(chat.contains(contract), "Missing ChatSidebarView accessibility contract: \(contract)")
        }
        _ = try registeredStopAXSource(in: chat)
        #expect(!chat.contains("if item.session.unread {"),
                "The legacy unread dot must not duplicate the single indicator slot")

        for contract in [
            ".accessibilityLabel(\"关闭资产预览\")",
            ".accessibilityLabel(\"返回素材网格\")",
            ".accessibilityLabel(\"在系统中打开素材\")"
        ] {
            #expect(assets.contains(contract), "Missing AssetPanelView accessibility contract: \(contract)")
        }

        for contract in [
            ".accessibilityLabel(\"折叠上下文面板\")",
            ".accessibilityLabel(\"刷新目录\")",
            ".accessibilityLabel(\"浏览器后退\")"
        ] {
            #expect(context.contains(contract), "Missing ContextPanelView accessibility contract: \(contract)")
        }
        let terminal = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/TerminalPTYPanel.swift")
        #expect(context.contains("TerminalPTYHostView("))
        #expect(context.contains(".accessibilityIdentifier(\"terminal.pty.host\")"))
        #expect(terminal.contains("let terminalView = LocalProcessTerminalView("))
        #expect(terminal.contains("terminalView.setAccessibilityIdentifier(\"terminal.pty.view\")"))
        #expect(terminal.contains("terminalView.setAccessibilityLabel(\"终端\")"))
        for (title, action, identifier) in [
            ("清屏", "clearScreen", "clear"),
            ("复制", "copySelection", "copy"),
            ("粘贴", "pasteFromClipboard", "paste"),
            ("重新启动", "restart", "restart")
        ] {
            let button = "Button(\"\(title)\") { session.\(action)() }"
            let identifier = ".accessibilityIdentifier(\"terminal.pty.\(identifier)\")"
            let suffix = context.range(of: button).map { context[$0.upperBound...] }
            let modifiers = suffix?.prefix { $0 != "}" }
            #expect(modifiers?.contains(identifier) == true, "Missing PTY button accessibility contract: \(title)")
        }
    }

    @Test("hidden keyboard registration controls do not add VoiceOver stops")
    func shortcutOnlyControlsAreHiddenFromAccessibility() throws {
        let content = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")
        let canvas = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift")

        #expect(content.contains("Button(\"\") { pushPane(.chat) }"))
        #expect(content.contains("Button(\"\") { pushPane(.canvas) }"))
        #expect(content.contains(".accessibilityHidden(true)"))
        #expect(canvas.contains("Button(\"\") { showMinimap.toggle() }"))
        #expect(canvas.contains(".keyboardShortcut(\"m\", modifiers: .command)"))
        #expect(canvas.contains(".accessibilityHidden(true)"))
    }

    @Test("settings close and provider key controls have stable AX contracts")
    func settingsCloseAndProviderKeyControlsExposeStableAXContracts() throws {
        let settings = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift")

        for contract in [
            ".accessibilityIdentifier(\"settings.close\")",
            ".accessibilityIdentifier(\"settings.provider.apiKey\")",
            ".accessibilityIdentifier(\"settings.provider.apiKey.reference-note\")",
            ".accessibilityLabel(\"API Key（仅输入或替换，不读取旧值）\")",
            ".accessibilityHint(\"编辑已有供应商时留空表示保留 Keychain 引用\")",
            ".accessibilityIdentifier(\"settings.provider.cancel\")",
            ".accessibilityIdentifier(\"settings.provider.save\")"
        ] {
            #expect(settings.contains(contract), "Missing SettingsView AX/visibility contract: \(contract)")
        }
        #expect(!settings.contains("settings.provider.apiKey.reveal"))
        #expect(!settings.contains(".task(id: isRevealed)"))
    }

    @Test("approval deny, allow, and confirm actions expose stable semantic AX contracts")
    func approvalPromptActionsExposeStableAXContracts() throws {
        let approval = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ApprovalPromptCenter.swift"
        )

        for contract in [
            ".accessibilityLabel(\"拒绝\")",
            ".accessibilityLabel(approvalButtonTitle)",
            "return center.awaitingConfirmation ? \"确认执行\" : \"允许\"",
            "if center.awaitingConfirmation, request?.browserRiskWarning != nil { return \"仅允许本次\" }",
            ".accessibilityIdentifier(\"approval.deny\")",
            "center.awaitingConfirmation ? \"approval.confirm\" : \"approval.allow\""
        ] {
            #expect(approval.contains(contract), "Missing ApprovalPromptView AX contract: \(contract)")
        }

        for selector in ["approval.deny", "approval.allow", "approval.confirm"] {
            #expect(
                approval.components(separatedBy: selector).count > 1,
                "Approval selector must have a nonzero expected count: \(selector)"
            )
        }
    }

    @Test("app startup wires background restore and clean-exit handling")
    func startupRecoveryContractIsConnected() throws {
        let app = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift")

        for contract in [
            "@main",
            "WindowGroup(\"MinisCanvas\", id: \"miniscanvas.main\")",
            "let lastExitClean = lifecycle.beginSession()",
            "Task.detached(priority: .userInitiated)",
            "AppLifecycleGuard.autoRestoreCanvasDraft(",
            "lifecycle.bind(appDelegate: appDelegate, bridge: bridge)",
            "if didAutoRestoreCanvas {",
            "bridge.canvasIfAvailable?.noteGraphChanged()"
        ] {
            #expect(app.contains(contract), "Missing startup recovery contract: \(contract)")
        }
    }

    @Test("window and content minimums keep the narrow-window layout bounded")
    func narrowWindowLayoutContractIsConnected() throws {
        let app = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift")
        let content = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")

        // This is a source contract, not a GUI screenshot: the AppKit floor,
        // SwiftUI content floor, and default launch size must remain explicit.
        for contract in [
            "width: CGFloat(AdaptiveLayoutPolicy.minimumSupportedWidth), height: 620",
            "WindowEdgeClamp.applyMinimumContentSize(to: window)",
            ".defaultSize(width: 1280, height: 800)"
        ] {
            #expect(app.contains(contract), "Missing window sizing contract: \(contract)")
        }

        for contract in [
            ".frame(minWidth: AdaptiveLayoutPolicy.minimumSupportedWidth, minHeight: 620)",
            "mainMinWidth: 320",
            "minWidth: companionCollapsed ? 0",
            "idealWidth: companionCollapsed ? 0",
            "maxWidth: companionCollapsed ? 0"
        ] {
            #expect(content.contains(contract), "Missing narrow-window layout contract: \(contract)")
        }

        // Keep the restore affordance tied to the split-mode, non-overlay
        // decision even when source formatting or line wrapping changes.
        let restoreStart = try #require(content.range(of: "if sessionSidebarCollapsed,"))
        let restoreEnd = try #require(content.range(
            of: "sidebarRestoreFloatingButton",
            range: restoreStart.upperBound..<content.endIndex
        ))
        let restoreBody = String(content[restoreStart.lowerBound..<restoreEnd.upperBound])
        #expect(restoreBody.contains("visibleLayoutMode == .split"))
        #expect(restoreBody.contains("decision.leftPanel != .overlay"))
    }

    @Test("keyboard routes and visible AX targets remain paired")
    @MainActor
    func keyboardAndAccessibilityTargetsStayPaired() throws {
        let app = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift")
        let content = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift")
        let chat = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")
        let globalComposer = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift")
        let canvas = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift")

        // Keyboard paths are registered at the production consumer; visible
        // controls keep a stable label/identifier for AX traversal.
        for contract in [
            ".shortcutKey(bridge.shortcutStore.binding(for: .commandPalette))",
            ".shortcutKey(bridge.shortcutStore.binding(for: .newSession))",
            ".accessibilityLabel(taskCenterOpenCommand?.title ?? \"打开任务中心\")",
            ".accessibilityIdentifier(\"open-task-center\")",
            ".accessibilityLabel(\"打开设置中心\")"
        ] {
            #expect(content.contains(contract) || app.contains(contract),
                    "Missing app/content keyboard or AX contract: \(contract)")
        }
        // The task button now takes its visible AX name and availability from
        // the same registered command that its button and AX actions dispatch.
        #expect(content.contains("id: \"ui.taskcenter.open\", registry: bridge.commandRegistry"))
        #expect(content.contains("bridge.runCommand(id: \"ui.taskcenter.open\", args: [\"opener\": \"toolbar\"])"))

        for contract in [
            "static let identifier = \"chat.transcript\"",
            ".accessibilityIdentifier(ChatTranscriptAXContract.identifier)",
            ".accessibilityIdentifier(\"composer.send\")"
        ] {
            #expect(chat.contains(contract), "Missing chat AX contract: \(contract)")
        }
        _ = try registeredStopAXSource(in: chat)

        for contract in [
            ".accessibilityIdentifier(\"composer.stop\")"
        ] {
            #expect(globalComposer.contains(contract), "Missing global composer AX contract: \(contract)")
        }
        _ = try registeredStopAXSource(in: globalComposer)
        let keyboardStart = try #require(globalComposer.range(of: "Button(\"\") { stopFocusedObject() }"))
        let keyboardEnd = try #require(globalComposer.range(
            of: ".accessibilityHidden(true)",
            range: keyboardStart.upperBound..<globalComposer.endIndex
        ))
        let keyboardStop = String(globalComposer[keyboardStart.lowerBound..<keyboardEnd.upperBound])
        #expect(keyboardStop.contains(".shortcutKey(bridge.shortcutStore.binding(for: .stopGeneration))"))

        for contract in [
            ".accessibilityLabel(\"显示迷你地图\")",
            ".keyboardShortcut(\"m\", modifiers: .command)",
            ".accessibilityHidden(true)"
        ] {
            #expect(canvas.contains(contract), "Missing canvas keyboard/AX contract: \(contract)")
        }
    }

    @Test("chat VoiceOver counts use runtime interpolation")
    func chatVoiceOverCountsUseRuntimeInterpolation() throws {
        let chat = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")

        #expect(chat.contains(#""，有 \(scrollState.pendingNewMessageCount) 条新消息""#))
        #expect(chat.contains(#"ChatTranscriptAccessibility.announce("有 \(count) 条新消息")"#))
        #expect(!chat.contains(#""，有 (scrollState.pendingNewMessageCount) 条新消息""#))
        #expect(!chat.contains(#"ChatTranscriptAccessibility.announce("有 (count) 条新消息")"#))
    }

    @Test("chat transcript resets scroll intent when the session changes")
    func chatTranscriptResetsScrollIntentWhenSessionChanges() throws {
        let chat = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")

        #expect(chat.contains(".onChange(of: sessionID)"))
        #expect(chat.contains("scrollState.resetForSession(currentSessionID)"))
        #expect(chat.contains("didAppear = false"))
    }
}
