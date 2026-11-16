import AppKit
import ApplicationServices
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// Uses the existing 339 NSApplication.run entry, formal synthetic profile and
/// NativeTestHostLifecycle/OwnedAX. No AX substitute or request-budget mirror is
/// injected: ordinary ChatStore sends settle the shared production tracker.
@Suite("CHAT-16/19 actual budget and role consumers", .serialized)
@MainActor
struct ChatBudgetAndRole541NativeConsumerTests {
    private func makeChat(_ provider: Usage541Provider, directory: URL) -> ChatStore {
        let chat = ChatStore()
        var settings = AgentSettings.default
        // Disable automatic compaction in this accounting fixture; the warning
        // threshold still uses the production default (0.8), not a new ledger.
        settings.autoCompactThreshold = 0
        // 本夹具断言 100_000 余量与超限，不是默认值：显式钉 10 万（默认值已改为 100 万）。
        settings.maxTokensPerSession = 100_000
        chat.configureBudget(from: settings)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "owned541-policy",
            grantEpoch: "owned541-epoch", leaseID: "owned541-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let injector = SkillInjector(store: SkillStore(skillsRoot: directory.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            // Same frozen ordinary provider-route binding as Usage397: owned
            // synthetic provider, no credential/env/transport lookup.
            let snapshot = try! ProviderRuntimeSnapshot(
                providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned541")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: directory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts
        )
        chat.streamingProviderOverride = provider
        return chat
    }

    @Test("compact bar publishes real request count, remaining tokens and all three budget states")
    func compactBudgetTracksOrdinaryProviderSettlements() async throws {
        let directory = try Native541Host.ownedDirectory()
        let provider = Usage541Provider(tokens: [100, 79_900, 20_001])
        let chat = makeChat(provider, directory: directory)
        defer { chat.stopStreaming() }
        let host = try Native541Host(AnyView(TokenUsageBar(chat: chat, compact: true).padding(12)),
                                     width: 600, height: 100)
        defer { host.close() }
        let totals = [100, 80_000, 100_001]
        let status = ["预算可用", "接近上限", "预算超限"]
        for index in totals.indices {
            chat.draftText = "owned budget request \(index)"
            chat.sendDraft()
            try await host.waitUntilIdle(chat)
            let actual = await chat.budgetTracker.budget
            #expect(actual.usedRequests == index + 1)
            #expect(actual.usedTokens == totals[index])
            #expect(chat.requestBudget == actual)
            #expect(provider.callCount == index + 1)
            let pending = await chat.budgetTracker.pendingRequestCount
            #expect(pending == 0)
            try await host.settle()
            try host.expectBudget(requests: index + 1, used: totals[index],
                                  remaining: max(0, 100_000 - totals[index]), status: status[index])
            try host.capture(directory: directory, phase: "budget-\(index)")
        }
        // Existing pause enforcement, not a UI-only "red" projection.
        chat.draftText = "owned blocked fourth request"
        chat.sendDraft()
        let blockedExecution = try #require(chat.activeExecutionIdentity(for: chat.activeSessionID))
        try await host.waitUntilIdle(chat)
        let blockedTerminal = try #require(chat.terminalReceipt(for: blockedExecution))
        #expect(blockedTerminal.outcome == .failed)
        #expect(provider.callCount == 3)
        #expect(chat.budgetRequestCount == 3)
        #expect(chat.budgetUsedTokens == 100_001)
        try await host.settle()
        try host.expectBudget(requests: 3, used: 100_001, remaining: 0, status: "预算超限")
    }

    @Test("failed real provider attempt never inflates the native request counter")
    func failedAttemptKeepsAvailableBudgetUncharged() async throws {
        let directory = try Native541Host.ownedDirectory()
        let provider = Usage541Provider(tokens: [], fails: true)
        let chat = makeChat(provider, directory: directory)
        defer { chat.stopStreaming() }
        let host = try Native541Host(AnyView(TokenUsageBar(chat: chat, compact: true).padding(12)),
                                     width: 600, height: 100)
        defer { host.close() }
        chat.draftText = "owned failing request"
        chat.sendDraft()
        try await host.waitUntilIdle(chat)
        #expect(provider.callCount == 1)
        let actual = await chat.budgetTracker.budget
        #expect(actual.usedRequests == 0)
        #expect(actual.usedTokens == 0)
        #expect(chat.requestBudget == actual)
        let pending = await chat.budgetTracker.pendingRequestCount
        #expect(pending == 0)
        try await host.settle()
        try host.expectBudget(requests: 0, used: 0, remaining: 100_000, status: "预算可用")
    }

    @Test("native transcript keeps inline emphasis, code, links and local fallback without changing copy bytes")
    func nativeInlineEmphasisKeepsSemanticBoundariesAndCopy() async throws {
        let markdown = """
        # HEADING_BASE_541 *HEADING_ITALIC_541* `HEADING_CODE_541`

        NORMAL_START_541 👩🏽‍💻é **🙂STRONG_541** NORMAL_END_541 *BODY_ITALIC_541* ***BOTH_541*** `**LITERAL_541**` **`BOLD_CODE_541`**

        **BEFORE_541**

        BAD_541 unmatched `fragment

        **AFTER_541**

        **[BOLD_LINK_541](http://127.0.0.1:55571/owned-emphasis)**
        """
        let chat = ChatStore()
        chat.messages = [ChatMessageUI(role: .assistant, content: markdown)]
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let env = EnvVarStore(directory: profile.providerConfigurationDirectory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: profile.makeUserDefaults()))
        let host = try Native541Host(AnyView(Transcript541Root(chat: chat, transcriptEnvStore: env)),
                                     width: 640, height: 620)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "NORMAL_START_541")
        let storage = try #require(text.textStorage)
        func font(_ marker: String) throws -> NSFont {
            let range = try host.range(marker, in: text)
            return try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        }
        func expectTraits(_ marker: String, bold: Bool, italic: Bool) throws {
            let traits = NSFontManager.shared.traits(of: try font(marker))
            #expect(traits.contains(.boldFontMask) == bold, "bold semantics for \(marker)")
            #expect(traits.contains(.italicFontMask) == italic, "italic semantics for \(marker)")
        }
        try expectTraits("NORMAL_START_541", bold: false, italic: false)
        try expectTraits("NORMAL_END_541", bold: false, italic: false)
        try expectTraits("STRONG_541", bold: true, italic: false)
        try expectTraits("BODY_ITALIC_541", bold: false, italic: true)
        try expectTraits("BOTH_541", bold: true, italic: true)
        try expectTraits("BEFORE_541", bold: true, italic: false)
        try expectTraits("BAD_541", bold: false, italic: false)
        try expectTraits("AFTER_541", bold: true, italic: false)
        try expectTraits("LITERAL_541", bold: false, italic: false)
        try expectTraits("BOLD_CODE_541", bold: true, italic: false)
        let ordinary = try font("NORMAL_START_541")
        for marker in ["LITERAL_541", "BOLD_CODE_541"] {
            let codeFont = try font(marker)
            #expect(NSFontManager.shared.traits(of: codeFont).contains(.fixedPitchFontMask))
            #expect(codeFont.pointSize == ordinary.pointSize - 1)
        }
        #expect(text.string.contains("**LITERAL_541**"))
        let heading = try font("HEADING_BASE_541")
        #expect(heading.pointSize > ordinary.pointSize)
        try expectTraits("HEADING_BASE_541", bold: true, italic: false)
        try expectTraits("HEADING_ITALIC_541", bold: true, italic: true)
        for marker in ["HEADING_ITALIC_541", "HEADING_CODE_541"] {
            #expect(try font(marker).pointSize == heading.pointSize)
        }
        #expect(try font("HEADING_CODE_541").fontName == heading.fontName)
        let link = try host.range("BOLD_LINK_541", in: text)
        let destination = URL(string: "http://127.0.0.1:55571/owned-emphasis")!
        try expectTraits("BOLD_LINK_541", bold: true, italic: false)
        #expect(storage.attribute(TranscriptExternalLink.destination, at: link.location, effectiveRange: nil) as? URL == destination)
        #expect(storage.attribute(.link, at: link.location, effectiveRange: nil) as? URL == destination)
        #expect((storage.attribute(.underlineStyle, at: link.location, effectiveRange: nil) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue)
        #expect(text.string.contains("BAD_541 unmatched `fragment"))
        #expect(text.string.contains("Markdown 格式异常，已按纯文本显示。"))
        #expect(chat.messages.count == 1 && chat.messages[0].content == markdown)
        #expect(Data(ChatTranscriptFormatter.plainText(chat.messages).utf8)
            == Data(("【助手】\n" + markdown).utf8))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try #require(host.window.makeFirstResponder(text))
        text.selectAll(nil)
        #expect(text.selectedRange() == NSRange(location: 0, length: storage.length))
        let isNativeResponder = host.window.firstResponder === text
        try #require(isNativeResponder)
        let legacyString = NSPasteboard.PasteboardType(rawValue: "NSStringPboardType")
        let plainTextFlavor = try #require(text.writablePasteboardTypes.first {
            $0 == .string || $0 == legacyString
        })
        #expect(text.writeSelection(to: pasteboard, types: [plainTextFlavor]))
        let copied = try #require(pasteboard.string(forType: plainTextFlavor))
        #expect(Data(copied.utf8) == Data(text.string.utf8))
    }

    @Test("real transcript role geometry, background, VoiceOver and per-user action remain distinct",
          arguments: [false, true])
    func nativeRolesAndActionsRemainDistinct(assistantStreaming: Bool) async throws {
        let chat = ChatStore()
        let userOne = ChatMessageUI(role: .user, content:
            "中文与 English owned user paragraph wraps in the actual text column. "
            + String(repeating: "owned user reading content. ", count: 4)
            + "\n\n541-user-one-marker")
        let assistant = ChatMessageUI(role: .assistant, content:
            "541-assistant-one-marker\n\n"
            + String(repeating: "owned assistant reading content. ", count: 4))
        let userTwo = ChatMessageUI(role: .user, content: "541-user-two-marker")
        let tail = ChatMessageUI(role: .assistant,
                                 content: assistantStreaming ? "" : "541-assistant-final-marker",
                                 isStreaming: assistantStreaming)
        chat.messages = [userOne, assistant, userTwo, tail]
        let originalMessages = chat.messages
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let transcriptEnvStore = EnvVarStore(directory: profile.providerConfigurationDirectory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: EnvVarPrivacyStore(defaults: profile.makeUserDefaults()))
        let root = Transcript541Root(chat: chat, transcriptEnvStore: transcriptEnvStore)
        let host = try Native541Host(AnyView(root), width: 640, height: 620)
        defer { host.close() }
        try await host.settle()
        let text = try host.text(containing: "541-user-one-marker")
        let userRange = try host.range("541-user-one-marker", in: text)
        let assistantRange = try host.range("541-assistant-one-marker", in: text)
        let userStyle = try #require(text.attributedString().attribute(
            .paragraphStyle, at: userRange.location, effectiveRange: nil) as? NSParagraphStyle)
        let assistantStyle = try #require(text.attributedString().attribute(
            .paragraphStyle, at: assistantRange.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(userStyle.alignment == .right)
        #expect(assistantStyle.alignment == .left)
        let userBackground = try #require(userStyle.textBlocks.first?.backgroundColor)
        let assistantBackground = try #require(assistantStyle.textBlocks.first?.backgroundColor)
        #expect(!userBackground.isEqual(assistantBackground))
        host.observeGeometry(text: text, phase: assistantStreaming ? "roles-streaming" : "roles-final")
        let userGlyph = try host.glyphRect(userRange, text: text)
        let assistantGlyph = try host.glyphRect(assistantRange, text: text)
        #expect(userGlyph.minX > assistantGlyph.minX + 50)
        #expect(text.visibleRect.intersects(userGlyph))
        #expect(text.visibleRect.intersects(assistantGlyph))
        // Sample empty space on the marker's actual native line, not token metadata
        // or fixed screen coordinates. Capture before selection adds its own fill.
        let manager = try #require(text.layoutManager)
        let bitmap = try #require(host.controller.view.bitmapImageRepForCachingDisplay(
            in: host.controller.view.bounds))
        host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
        func roleBackgroundSample(_ range: NSRange, user: Bool) throws -> NSColor {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            try #require(glyphs.length > 0)
            let line = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            let ink = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            let blank = user
                ? NSRect(x: line.minX, y: line.minY, width: ink.minX - line.minX, height: line.height)
                : NSRect(x: ink.maxX, y: line.minY, width: line.maxX - ink.maxX, height: line.height)
            try #require(blank.width > 16 && blank.height > 0)
            let point = NSPoint(x: blank.midX, y: blank.midY)
            try #require(text.visibleRect.contains(point))
            let hostPoint = host.controller.view.convert(point, from: text)
            let bounds = host.controller.view.bounds
            try #require(bounds.contains(hostPoint))
            let x = Int((hostPoint.x - bounds.minX) * CGFloat(bitmap.pixelsWide) / bounds.width)
            let yInView = host.controller.view.isFlipped
                ? hostPoint.y - bounds.minY : bounds.maxY - hostPoint.y
            let y = Int(yInView * CGFloat(bitmap.pixelsHigh) / bounds.height)
            try #require(x >= 0 && x < bitmap.pixelsWide && y >= 0 && y < bitmap.pixelsHigh)
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let renderedUser = try roleBackgroundSample(userRange, user: true)
        let renderedAssistant = try roleBackgroundSample(assistantRange, user: false)
        let renderedDifference = abs(renderedUser.redComponent - renderedAssistant.redComponent)
            + abs(renderedUser.greenComponent - renderedAssistant.greenComponent)
            + abs(renderedUser.blueComponent - renderedAssistant.blueComponent)
        #expect(renderedDifference > 0.05,
            "Actual native role backgrounds must differ in glyph-free line space")
        #expect(text.string.contains("用户\n"))
        #expect(text.string.contains("助手\n"))
        let documentAX = try host.element(ChatTranscriptAXContract.identifier)
        let axValue = try host.value(documentAX)
        // Exercise the same public parameterized AX entry seen in the field
        // sample, rather than only the ordinary AXValue projection.
        // The SwiftUI transcript identifier carries the human AXValue, not
        // necessarily NSTextView's parameterized text interface. Bind the
        // native body by its exact displayed string in this owned window.
        let nativeBody = try #require(NativeConsumerOwnedAX.findDisplayedText(
            in: host.window, exactText: text.string))
        try #require(NativeConsumerOwnedAX.role(nativeBody) == .textArea)
        let nativeAX = try #require(NativeConsumerOwnedAX.element(nativeBody))
        var parameterizedNames: CFArray?
        let namesStatus = AXUIElementCopyParameterizedAttributeNames(nativeAX, &parameterizedNames)
        try #require(namesStatus == .success)
        let supportedNames = try #require(parameterizedNames as? [String])
        try #require(supportedNames.contains(kAXAttributedStringForRangeParameterizedAttribute as String))
        var requested = CFRange(location: 0, length: text.string.utf16.count)
        let parameter = try #require(AXValueCreate(.cfRange, &requested))
        var attributedValue: CFTypeRef?
        let attributedStatus = AXUIElementCopyParameterizedAttributeValue(nativeAX,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            parameter, &attributedValue)
        try #require(attributedStatus == .success)
        let attributedAX = try #require(attributedValue as? NSAttributedString)
        #expect(attributedAX.string == text.string)
        #expect(attributedAX.length == requested.length)
        for markerRange in [userRange, assistantRange] {
            var marker = CFRange(location: markerRange.location, length: markerRange.length)
            let markerParameter = try #require(AXValueCreate(.cfRange, &marker))
            var markerValue: CFTypeRef?
            let markerStatus = AXUIElementCopyParameterizedAttributeValue(nativeAX,
                kAXAttributedStringForRangeParameterizedAttribute as CFString,
                markerParameter, &markerValue)
            try #require(markerStatus == .success)
            let markerAX = try #require(markerValue as? NSAttributedString)
            #expect(markerAX.string == (text.string as NSString).substring(with: markerRange))
            let markerAttributes = markerAX.attributes(at: 0, effectiveRange: nil)
            #expect(!markerAttributes.isEmpty)
            let sourceFont = try #require(text.attributedString().attribute(
                .font, at: markerRange.location, effectiveRange: nil) as? NSFont)
            let axFont = try #require(markerAttributes[.accessibilityFont] as? [String: Any])
            #expect(axFont[NSAccessibility.FontAttributeKey.fontName.rawValue] as? String == sourceFont.fontName)
            #expect((axFont[NSAccessibility.FontAttributeKey.fontSize.rawValue] as? NSNumber)?.doubleValue
                == Double(sourceFont.pointSize))
            let sourceStyle = try #require(text.attributedString().attribute(
                .paragraphStyle, at: markerRange.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect((markerAttributes[.accessibilityAlignment] as? NSNumber)?.intValue
                == sourceStyle.alignment.rawValue)
            #expect(NSDictionary(dictionary: attributedAX.attributes(
                at: markerRange.location, effectiveRange: nil)).isEqual(NSDictionary(dictionary: markerAttributes)))
        }
        #expect(axValue.contains("用户：\(userOne.content)"))
        #expect(axValue.contains("助手：\(assistant.content)"))
        #expect(axValue.contains(assistantStreaming ? "助手：生成中…" : "助手：541-assistant-final-marker"))
        text.setSelectedRange(userRange)
        let prefixLength = try host.range("541-user-two-marker", in: text).location
        let history = text.attributedString().attributedSubstring(from: NSRange(location: 0, length: prefixLength))
        for message in [userOne, userTwo] {
            let edit = try host.element("chat.transcript.editMessage.\(message.id.uuidString)")
            #expect(NativeConsumerOwnedAX.role(edit) == .button)
            #expect(NativeConsumerOwnedAX.enabled(edit) == true)
            #expect(NativeConsumerOwnedAX.label(edit) == "编辑用户消息并重新发送")
            let frame = try host.appKitFrame(edit)
            #expect(!frame.isEmpty)
            #expect(host.screenBounds.intersects(frame))
            try #require(NativeConsumerOwnedAX.press(edit))
            try await host.settle()
            #expect(chat.editingMessageID == message.id)
            #expect(chat.draftText == message.content)
            #expect(chat.messages == originalMessages)
            chat.cancelEdit()
        }
        for message in [assistant, tail] {
            let absent = NativeConsumerOwnedAX.hasNoIdentifier(
                in: host.window, prefix: "chat.transcript.editMessage.\(message.id.uuidString)") == true
            try #require(absent)
            #expect(absent)
        }
        if assistantStreaming {
            var messages = chat.messages
            messages[messages.count - 1].content = "541-assistant-final-marker"
            messages[messages.count - 1].isStreaming = false
            chat.messages = messages
            try await host.settle()
            let finalText = try host.text(containing: "541-user-one-marker")
            #expect(finalText === text)
            #expect(finalText.selectedRange() == userRange)
            #expect(finalText.attributedString().attributedSubstring(
                from: NSRange(location: 0, length: prefixLength)).isEqual(to: history))
            let finalAX = try host.element(ChatTranscriptAXContract.identifier)
            let finalValue = try host.value(finalAX)
            #expect(finalValue.contains("助手：541-assistant-final-marker"))
            #expect(!finalValue.contains("生成中"))
        }
        let captureDirectory = try Native541Host.ownedDirectory()
        try host.capture(directory: captureDirectory,
                         phase: assistantStreaming ? "roles-stream-to-final" : "roles-final")
    }
}

private struct Transcript541Root: View {
    let chat: ChatStore
    let transcriptEnvStore: EnvVarStore
    var body: some View {
        ChatTranscriptView(sessionID: chat.activeSessionID, messages: chat.messages,
                           transcriptEnvStore: transcriptEnvStore,
                           onEditMessage: { chat.beginEdit(messageID: $0) })
    }
}

/// Small host following the unchanged 339/434 lifecycle; no NSApplication.run,
/// AX runtime, process control, environment rules or UI lease is created here.
@MainActor
private final class Native541Host {
    let window: NSWindow
    let controller: NSHostingController<AnyView>
    var screenBounds: CGRect {
        window.convertToScreen(controller.view.convert(controller.view.bounds, to: nil))
    }
    init(_ root: AnyView, width: CGFloat, height: CGFloat) throws {
        try #require(NSApplication.shared.isRunning, "requires existing 339 native entry and sole UI admission")
        try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer() != nil)
        let lease = NativeTestHostLifecycle.begin("ChatBudgetRole541")
        controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }
    func settle() async throws {
        for _ in 0..<30 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            try await Task.sleep(for: .milliseconds(10))
        }
        let contentView = try #require(window.contentView)
        #expect(controller.view.frame.size == contentView.bounds.size)
        NativeTestHostLifecycle.observe(window, phase: "541-sampled")
    }
    func waitUntilIdle(_ chat: ChatStore) async throws {
        for _ in 0..<200 {
            if !chat.isActiveSessionStreaming { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(!chat.isActiveSessionStreaming, "ordinary synthetic turn did not reach terminal")
    }
    func element(_ identifier: String) throws -> AnyObject {
        try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier))
    }
    func appKitFrame(_ element: AnyObject) throws -> CGRect {
        let frame = try #require(NativeConsumerOwnedAX.frame(element))
        let converted = try #require(UF03AXScreenCoordinates.appKitFrame(
            position: frame.origin, size: frame.size, zeroScreenFrame: NSScreen.screens.first?.frame))
        print("CHAT541_NATIVE_AX_GEOMETRY wire=\(frame) appKit=\(converted) hostScreen=\(screenBounds) window=\(window.frame)")
        return converted
    }
    func value(_ element: AnyObject) throws -> String {
        try #require(NativeConsumerOwnedAX.attribute(element, kAXValueAttribute as CFString) as? String)
    }
    func expectBudget(requests: Int, used: Int, remaining: Int, status: String) throws {
        let count = try element("chat.token-usage.requests")
        #expect(NativeConsumerOwnedAX.label(count) == "请求次数")
        #expect(try value(count) == String(requests))
        let countFrame = try appKitFrame(count)
        #expect(!countFrame.isEmpty && screenBounds.contains(countFrame))
        let tokens = try element("chat.token-usage.tokens")
        #expect(NativeConsumerOwnedAX.label(tokens) == "会话 Token 预算")
        let tokenValue = try value(tokens)
        #expect(tokenValue.contains(ChatStore.tokenUsageLabel(used: used, cap: 100_000)))
        #expect(tokenValue.contains("剩余 \(ChatStore.formatTokenCount(remaining)) tokens"))
        #expect(tokenValue.contains(status))
        for otherState in ["预算可用", "接近上限", "预算超限"] where otherState != status {
            #expect(!tokenValue.contains(otherState))
        }
        if status == "预算可用" {
            let absent = NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "chat.token-usage.status") == true
            try #require(absent)
            #expect(absent)
        } else {
            let state = try element("chat.token-usage.status")
            let text = NativeConsumerOwnedAX.label(state) ?? (try? value(state))
            #expect(text == status)
        }
    }
    func observeGeometry(text: NSTextView, phase: String) {
        var ancestor: NSView? = text
        var chain: [String] = []
        while let view = ancestor, chain.count < 8 {
            chain.append("type=\(type(of: view)),id=\(ObjectIdentifier(view)),frame=\(view.frame),bounds=\(view.bounds),visible=\(view.visibleRect),hidden=\(view.isHidden),ownedWindow=\(view.window === window)")
            ancestor = view.superview
        }
        print("CHAT541_NATIVE_GEOMETRY phase=\(phase) window=\(window.frame) content=\(String(describing: window.contentView?.bounds)) hostScreen=\(screenBounds) firstScreen=\(String(describing: NSScreen.screens.first?.frame)) chain=[\(chain.joined(separator: ";"))]")
    }
    func text(containing marker: String) throws -> NSTextView {
        var matches: [NSTextView] = []
        func visit(_ view: NSView) {
            if let text = view as? NSTextView, !text.isEditable, text.string.contains(marker) { matches.append(text) }
            view.subviews.forEach(visit)
        }
        visit(controller.view)
        #expect(matches.count == 1)
        return try #require(matches.count == 1 ? matches.first : nil)
    }
    func range(_ marker: String, in text: NSTextView) throws -> NSRange {
        let source = text.string as NSString
        let range = source.range(of: marker)
        try #require(range.location != NSNotFound && range.length > 0)
        #expect(source.range(of: marker, options: [], range: NSRange(
            location: NSMaxRange(range), length: source.length - NSMaxRange(range))).location == NSNotFound)
        return range
    }
    func glyphRect(_ range: NSRange, text: NSTextView) throws -> NSRect {
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        #expect(glyphs.length > 0)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        #expect(!rect.isEmpty)
        return rect
    }
    static func ownedDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat541-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func capture(directory: URL, phase: String) throws {
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(phase).png")
        try png.write(to: url)
        print("CHAT541_NATIVE bitmap=\(url.path) width=\(bitmap.pixelsWide) height=\(bitmap.pixelsHigh)")
    }
}

private final class Usage541Provider: LLMProvider, @unchecked Sendable {
    enum SyntheticFailure: Error { case rejected }
    private let lock = NSLock()
    private let tokens: [Int]
    private let fails: Bool
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var name: String { "Owned541Usage" }
    private var storedModel = LLMModel(id: "owned-541", displayName: "Owned 541", provider: "Owned541Usage")
    var model: LLMModel {
        get { lock.lock(); defer { lock.unlock() }; return storedModel }
        set { lock.lock(); defer { lock.unlock() }; storedModel = newValue }
    }
    var capabilities: Set<ProviderCapability> { [.tools] }
    init(tokens: [Int], fails: Bool = false) { self.tokens = tokens; self.fails = fails }
    private func nextResponse() throws -> LLMResponse {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        guard !fails, calls <= tokens.count else { throw SyntheticFailure.rejected }
        return LLMResponse(text: "owned-541-response-\(calls)", stopReason: "end_turn",
                           usage: LLMUsage(inputTokens: tokens[calls - 1], outputTokens: 0))
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse { try nextResponse() }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse { try nextResponse() }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        // The AgentLoop's normal provider request is the production sendMessage
        // path. This protocol requirement must not silently invent a second call.
        throw SyntheticFailure.rejected
    }
}
