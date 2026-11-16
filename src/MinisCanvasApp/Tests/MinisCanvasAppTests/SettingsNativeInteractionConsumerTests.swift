import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
import MinisCore

@testable import MinisCanvasApp

@Suite("Settings and MCP native interaction consumers", .serialized)
@MainActor
struct SettingsNativeInteractionConsumerTests {
    @Test func builtInSkillImportOpensExistingExplicitReview() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let center = fixture.makeCenter()
            let host = makeSettingsWindow(center: center)
            defer { closeSettingsWindow(host) }
            if !host.window.isVisible || !host.window.isKeyWindow || !NSApp.isActive {
                _ = NSRunningApplication.current.activate(options: [])
                host.window.makeKeyAndOrderFront(nil)
                for _ in 0..<8 {
                    if host.window.isVisible && host.window.isKeyWindow && NSApp.isActive { break }
                    pumpSettingsRunLoop()
                }
            }
            try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive)
            let skills = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings-tab-skills"))
            try #require(settingsAXPress(skills, in: host.window))
            for _ in 0..<8 {
                if NativeConsumerOwnedAX.find(in: host.window, identifier: "settings.skills.import-local") != nil { break }
                pumpSettingsRunLoop()
            }
            try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings.skills.import-local") != nil)
            let localImport = try #require(NativeConsumerOwnedAX.find(in: host.window,
                label: "导入本地技能…", pressable: true))
            try #require(NativeConsumerOwnedAX.enabled(localImport) == true)
            let localImportElement = try #require(NativeConsumerOwnedAX.element(localImport))
            var actions: CFArray?
            try #require(AXUIElementCopyActionNames(localImportElement, &actions) == .success)
            try #require((actions as? [String])?.contains(kAXPressAction as String) == true)
            let defaults = try #require(findSettingsAX(in: host.window, label: "导入内置技能…", pressable: true))
            try #require(settingsAXPress(defaults, in: host.window))
            pumpSettingsRunLoop()
            let planning = try #require(findSettingsAX(in: host.window, label: "planning-playbook", pressable: true))
            try #require(settingsAXPress(planning, in: host.window))
            pumpSettingsRunLoop()
            try #require(host.window.attachedSheet != nil)
            #expect(findSettingsAX(in: host.window, label: "明确批准并启用", pressable: true) != nil)
        }
    }

    @Test("Memory fact confirmation advances without retyping the complete text")
    func memoryFactFirstConfirmationAcceptsNonemptyAcknowledgment() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let center = fixture.makeCenter()
            let fact = try center.memoryStore.addFact(
                "合成记忆：只用于验证删除预览的确认输入",
                sourceSessionID: "owned-session",
                memoryScope: MemoryScope(sessionID: "owned-session", projectID: "owned-project"))
            center.reloadStorage()
            try #require(center.memoryFacts.contains { $0.id == fact.id },
                "The reloaded memory list must contain the exact fixture fact")
            let host = makeSettingsWindow(center: center)
            defer { closeSettingsWindow(host) }
            if !host.window.isVisible || !host.window.isKeyWindow || !NSApp.isActive {
                _ = NSRunningApplication.current.activate(options: [])
                host.window.makeKeyAndOrderFront(nil)
                for _ in 0..<8 {
                    if host.window.isVisible && host.window.isKeyWindow && NSApp.isActive { break }
                    pumpSettingsRunLoop()
                }
            }
            try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive,
                "The owned memory settings window must be visible, key and active before AX entry")
            let memoryTab = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings-tab-memory"))
            try #require(settingsAXPress(memoryTab, in: host.window))
            let memorySearch = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings.memory.search"),
                "The selected memory page must expose its public search field")
            let deleteID = "settings.memory.delete-fact.\(fact.id)"
            for _ in 0..<8 {
                if NativeConsumerOwnedAX.find(in: host.window, identifier: deleteID) != nil { break }
                pumpSettingsRunLoop()
            }
            if NativeConsumerOwnedAX.find(in: host.window, identifier: deleteID) == nil {
                let scrollBar = try #require(memoryPaneVerticalScrollBar(containing: memorySearch),
                    "The public memory search field must have an owned scroll-area ancestor with a vertical scrollbar")
                let valueAttribute = kAXValueAttribute as CFString
                var settable = DarwinBoolean(false)
                try #require(AXUIElementIsAttributeSettable(scrollBar, valueAttribute, &settable) == .success
                    && settable.boolValue, "The owned memory scrollbar must expose a settable AXValue")
                let before = try #require(NativeConsumerOwnedAX.attribute(scrollBar, valueAttribute) as? NSNumber)
                try #require((0..<1).contains(before.doubleValue), "The scrollbar must expose a normalized value below its end")
                try #require(AXUIElementSetAttributeValue(scrollBar, valueAttribute, NSNumber(value: 1)) == .success)
                pumpSettingsRunLoop()
                let after = try #require(NativeConsumerOwnedAX.attribute(scrollBar, valueAttribute) as? NSNumber)
                try #require(after.doubleValue > before.doubleValue && after.doubleValue <= 1,
                    "The memory pane viewport must actually move")
            }
            let delete = try #require(NativeConsumerOwnedAX.find(in: host.window, identifier: deleteID),
                "The selected memory page must expose the fixture fact's delete button")
            try #require(settingsAXPress(delete, in: host.window))
            pumpSettingsRunLoop()
            let first = try #require(findSettingsAX(in: host.window,
                label: "输入第一确认文字", textField: true))
            try #require(replaceSettingsText("已核对", in: first, host: host.window))
            let next = try #require(findSettingsAX(in: host.window, label: "下一步", pressable: true))
            try #require(settingsAXPress(next, in: host.window))
            pumpSettingsRunLoop()
            try #require(findSettingsAX(in: host.window, label: "永久删除", textField: true) != nil)
            let cancel = try #require(findSettingsAX(in: host.window, label: "取消", pressable: true))
            try #require(settingsAXPress(cancel, in: host.window))
            #expect(try center.memoryStore.activeFacts().contains { $0.id == fact.id })
        }
    }

    private func memoryPaneVerticalScrollBar(containing field: AnyObject) -> AXUIElement? {
        guard let element = NativeConsumerOwnedAX.element(field) else { return nil }
        var node = element
        for _ in 0..<12 {
            guard let parent = NativeConsumerOwnedAX.attribute(node, kAXParentAttribute as CFString),
                  let ancestor = NativeConsumerOwnedAX.element(parent) else { return nil }
            if NativeConsumerOwnedAX.role(ancestor) == .scrollArea {
                guard let bar = NativeConsumerOwnedAX.attribute(ancestor, kAXVerticalScrollBarAttribute as CFString),
                      let element = NativeConsumerOwnedAX.element(bar),
                      NativeConsumerOwnedAX.role(element) == .scrollBar else { return nil }
                return element
            }
            if NativeConsumerOwnedAX.role(ancestor) == .window { return nil }
            node = ancestor
        }
        return nil
    }

    @Test("Owned supplier confirmation cancels and requires both typed steps")
    func supplierRemovalNativeAlertReachesGate() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let center = fixture.makeCenter()
            let target = "G23_NATIVE_SUPPLIER_TARGET"
            let sentinel = "G23_NATIVE_SUPPLIER_SENTINEL"
            for name in [target, sentinel] {
                try #require(center.saveProvider(name: name, apiKey: "synthetic-only",
                    baseURL: nil, modelNames: ["synthetic-model"], protocolType: .other))
            }
            let host = makeSettingsWindow(center: center, initialPageID: "环境变量")
            defer { closeSettingsWindow(host) }
            if !host.window.isVisible || !host.window.isKeyWindow || !NSApp.isActive {
                _ = NSRunningApplication.current.activate(options: [])
                host.window.makeKeyAndOrderFront(nil)
                for _ in 0..<8 {
                    if host.window.isVisible && host.window.isKeyWindow && NSApp.isActive { break }
                    pumpSettingsRunLoop()
                }
            }
            try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive,
                "The owned supplier settings window must be visible, key and active before AX entry")

            @MainActor
            func presentRemoval() throws {
                let rowButton = try #require(findSettingsAX(in: host.window,
                    label: "删除供应商 " + target, pressable: true))
                try #require(settingsAXPress(rowButton, in: host.window))
                pumpSettingsRunLoop()
            }

            try presentRemoval()
            let cancel = try #require(findSettingsAX(in: host.window, label: "取消", pressable: true))
            try #require(settingsAXPress(cancel, in: host.window))
            pumpSettingsRunLoop()
            #expect(fixture.makeCenter().providerExists(named: target))

            try presentRemoval()
            let sheet = try #require(host.window.attachedSheet)
            try #require(sheet.sheetParent === host.window && host.window.sheets.count == 1)
            let first = try #require(findSettingsAX(in: host.window, label: "输入「\(target)」", textField: true))
            #expect(fixture.makeCenter().providerExists(named: target))
            try #require(replaceSettingsText(target, in: first, host: host.window))
            let next = try #require(findSettingsAX(in: host.window, label: "下一步", pressable: true))
            try #require(settingsAXPress(next, in: host.window))
            pumpSettingsRunLoop()
            #expect(fixture.makeCenter().providerExists(named: target))
            let second = try #require(findSettingsAX(in: host.window, label: "永久删除", textField: true))
            try #require(replaceSettingsText("永久删除", in: second, host: host.window))
            let confirm = try #require(findSettingsAX(in: host.window, label: "永久删除", pressable: true))
            try #require(settingsAXPress(confirm, in: host.window))
            pumpSettingsRunLoop()
            let cold = fixture.makeCenter()
            #expect(!cold.providerExists(named: target))
            #expect(cold.providerExists(named: sentinel))
        }
    }

    @Test("Settings application banner announces its visible text")
    func settingsAppliedStateBannerAnnouncesVisibleText() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let host = makeSettingsWindow(center: fixture.makeCenter())
            defer { closeSettingsWindow(host) }
            let banner = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings.applied-state"))
            let value = NativeConsumerOwnedAX.attribute(banner, kAXValueAttribute as CFString) as? String
            #expect(value == "部分设置在下一次运行时生效")
        }
    }

    @Test("Owned plain environment entry exposes native edit and confirmed deletion without changing its sentinel")
    func plainEnvironmentNativeActionsReachSheetsAndColdStore() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let ownName = "G22_NATIVE_PLAIN_OWN"
            let sentinelName = "G22_NATIVE_PLAIN_SENTINEL"
            let ownValue = "owned-only"
            let center = fixture.makeCenter()
            try #require(center.setEnvVar(name: sentinelName, value: "sentinel-unchanged", isSecret: false))
            do {
                let host = makeSettingsWindow(center: center, initialPageID: "环境变量")
                defer { closeSettingsWindow(host) }
                try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive,
                    "Owned settings host must be active and key before native entry")
                let add = try #require(NativeConsumerOwnedAX.find(in: host.window,
                    identifier: "settings.environment.add-variable"), "Environment add action must be independently exposed")
                try #require(NativeConsumerOwnedAX.role(add) == .button)
                try #require(settingsAXPress(add, in: host.window))
                pumpSettingsRunLoop()
                try #require(host.window.attachedSheet != nil, "Native add must present its editor")
                let name = try #require(findSettingsAX(in: host.window, label: "如 OPENAI_API_KEY", textField: true))
                let value = try #require(findSettingsAX(in: host.window, label: "变量值", textField: true))
                try #require(replaceSettingsText(ownName, in: name, host: host.window))
                try #require(replaceSettingsText(ownValue, in: value, host: host.window))
                let save = try #require(findSettingsAX(in: host.window, label: "保存为非敏感", pressable: true))
                try #require(settingsAXPress(save, in: host.window))
                pumpSettingsRunLoop()
                try #require(host.window.attachedSheet == nil, "Native save must dismiss the editor")
            }
            // A fresh store reads the real metadata written by the public editor.
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            let before = EnvVarStore(directory: fixture.root, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: fixture.defaults))
            let own = try #require(before.entry(name: ownName))
            let sentinel = try #require(before.entry(name: sentinelName))
            try #require(!own.isSecret && !own.valueInKeychain && own.value == ownValue)
            try #require(!sentinel.isSecret && !sentinel.valueInKeychain)
            let unchangedEntries = before.allEnvVars.filter { $0.name != ownName }
            let coldCenter = fixture.makeCenter()
            let host = makeSettingsWindow(center: coldCenter, initialPageID: "环境变量")
            defer { closeSettingsWindow(host) }
            try #require(host.window.isVisible && host.window.isKeyWindow && NSApp.isActive,
                "Cold owned settings host must retain native action qualification")
            let component = ownName // This ASCII name is the existing production AX component unchanged.
            let edit = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings.environment.edit." + component),
                "Plain entry must expose its own independent edit button")
            try #require(NativeConsumerOwnedAX.role(edit) == .button)
            #expect(NativeConsumerOwnedAX.label(edit) == "编辑变量 " + ownName)
            try #require(settingsAXPress(edit, in: host.window), "Native edit AXPress must be accepted")
            pumpSettingsRunLoop()
            try #require(host.window.attachedSheet != nil, "Accepted edit must actually present the editor")
            let existingValue = try #require(findSettingsAX(in: host.window, label: "变量值", textField: true))
            let displayedValue = (existingValue as? NSTextField)?.stringValue
                ?? (NativeConsumerOwnedAX.attribute(existingValue, kAXValueAttribute as CFString) as? String)
            #expect(displayedValue == ownValue)
            let cancel = try #require(findSettingsAX(in: host.window, label: "取消", pressable: true))
            try #require(settingsAXPress(cancel, in: host.window))
            pumpSettingsRunLoop()
            try #require(host.window.attachedSheet == nil, "Edit cancellation must close the editor")
            let afterCancel = EnvVarStore(directory: fixture.root, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: fixture.defaults))
            #expect(afterCancel.entry(name: ownName) == own)
            let delete = try #require(NativeConsumerOwnedAX.find(in: host.window,
                identifier: "settings.environment.delete." + component),
                "Plain entry must expose its own independent delete button")
            try #require(NativeConsumerOwnedAX.role(delete) == .button)
            #expect(NativeConsumerOwnedAX.label(delete) == "删除变量 " + ownName)
            try #require(settingsAXPress(delete, in: host.window), "Native delete AXPress must be accepted")
            pumpSettingsRunLoop()
            try #require(host.window.attachedSheet != nil, "Accepted delete must present the original confirmation")
            let beforeConfirmation = EnvVarStore(directory: fixture.root, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: fixture.defaults))
            #expect(beforeConfirmation.entry(name: ownName) == own)
            let first = try #require(findSettingsAX(in: host.window, label: "输入「\(ownName)」", textField: true))
            try #require(replaceSettingsText(ownName, in: first, host: host.window))
            let next = try #require(findSettingsAX(in: host.window, label: "下一步", pressable: true))
            try #require(settingsAXPress(next, in: host.window))
            pumpSettingsRunLoop()
            let second = try #require(findSettingsAX(in: host.window, label: "永久删除", textField: true))
            try #require(replaceSettingsText("永久删除", in: second, host: host.window))
            let execute = try #require(findSettingsAX(in: host.window, label: "永久删除", pressable: true))
            try #require(settingsAXPress(execute, in: host.window))
            pumpSettingsRunLoop()
            try #require(host.window.attachedSheet == nil, "Confirmed deletion must finish its original sheet")
            let after = EnvVarStore(directory: fixture.root, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: fixture.defaults))
            #expect(after.entry(name: ownName) == nil, "Confirmed native deletion must reach cold disk")
            #expect(after.entry(name: sentinelName) == sentinel)
            #expect(after.allEnvVars == unchangedEntries)
        }
    }

    @Test("MCP tool authorization expands through its real native action without granting tools", arguments: [12, 16])
    func mcpToolAuthorizationNativeExpansionDoesNotGrant3013(fontSize: Int) async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
        _ = NSApplication.shared
        let root = fixture.root
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: fixture.defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: fixture.badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: manager,
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: fixture.usage,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        center.uiBaseFontSize = fontSize
        let server = MCPServer(id: "native-mcp3013", name: "3013 合成 MCP", type: .stdio,
                               enabled: true, command: "/usr/bin/false")
        try manager.addServer(server)
        center.reloadMCP()
        let host = makeSettingsWindow(center: center)
        defer { closeSettingsWindow(host) }
        @MainActor func press(_ identifier: String) throws {
            let control = try #require(findSettingsAX(in: host.window, identifier: identifier))
            try #require(settingsAXPress(control, in: host.window), "Native action refused: \(identifier)")
            pumpSettingsRunLoop()
        }
        @MainActor func disclosureValue(_ identifier: String) throws -> String {
            let control = try #require(findSettingsAX(in: host.window, identifier: identifier))
            let value = (control as? NSAccessibilityProtocol)?.accessibilityValue() as? String
                ?? SettingsNativePublicAXBridge.stateValue(control, in: host.window, identifier: identifier)
            return try #require(value)
        }
        try press("settings-tab-mcp")
        let component = server.id.utf8.map { String($0, radix: 16) }.joined(separator: "-")
        let prefix = "mcp.server.\(component)"
        let disclosureID = prefix + ".tools.disclosure"
        #expect(!manager.isServerAuthorized(server))
        #expect(findSettingsAX(in: host.window, identifier: disclosureID) == nil)
        // The actual server toggle supplies the existing authorization. No
        // test setup calls authorizeServer/authorizeTool or edits a grant.
        try press(prefix + ".authorization")
        try #require(manager.isServerAuthorized(server))
        let beforeExpansion = try #require(manager.authorization(serverID: server.id))
        let open = try #require(findSettingsAX(in: host.window, identifier: disclosureID))
        let role = (open as? NSAccessibilityProtocol)?.accessibilityRole() ?? NativeConsumerOwnedAX.role(open)
        #expect(role == .button)
        #expect(try disclosureValue(disclosureID) == "已收起")
        #expect(findSettingsAX(in: host.window, identifier: prefix + ".tools.refresh") == nil)
        try press(disclosureID)
        #expect(try disclosureValue(disclosureID) == "已展开")
        let refresh = try #require(findSettingsAX(in: host.window, identifier: prefix + ".tools.refresh"))
        let refreshRole = (refresh as? NSAccessibilityProtocol)?.accessibilityRole() ?? NativeConsumerOwnedAX.role(refresh)
        #expect(refreshRole == .button)
        if refreshRole != .button {
            // Failure-only B2 diagnostic: original returned object, no new lookup/RPC/action.
            let localProtocol = refresh as? NSAccessibilityProtocol
            let directRole = localProtocol?.accessibilityRole()
            let record: [String: Any] = [
                "identifier": prefix + ".tools.refresh",
                "found": true,
                "returnedObjectClass": String(reflecting: type(of: refresh)),
                "conformsNSAccessibilityProtocol": localProtocol != nil,
                "directPublicRoleType": directRole.map { String(reflecting: type(of: $0)) } ?? "nil",
                "directPublicRoleValue": directRole.map { $0.rawValue as Any } ?? NSNull(),
                "originalRoleWasNil": refreshRole == nil,
                "windowNumber": host.window.windowNumber,
                "ownPID": getpid(),
                "noNewLookupRPCOrAction": true
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print("SETTINGS_REFRESH_ROLE_FAILURE_ONLY=" + line)
            }
        }
        #expect(findSettingsAX(in: host.window, identifier: prefix + ".tools.empty") != nil)
        #expect(manager.authorization(serverID: server.id) == beforeExpansion)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
        #expect(!center.isMCPToolAuthorized(serverID: server.id, toolName: "greet"))
        try press(disclosureID)
        #expect(try disclosureValue(disclosureID) == "已收起")
        #expect(findSettingsAX(in: host.window, identifier: prefix + ".tools.refresh") == nil)
        #expect(manager.authorization(serverID: server.id) == beforeExpansion)
        // Reopening is a real second press; expansion never starts the stdio
        // command or mints a capability merely to expose the refresh control.
        try press(disclosureID)
        #expect(findSettingsAX(in: host.window, identifier: prefix + ".tools.refresh") != nil)
        #expect(manager.authorization(serverID: server.id) == beforeExpansion)
        }
    }

    @Test("A deleted MCP server exposes a native recovery action")
    func mcpDeletedServerOffersNativeRecoveryWithoutGrant() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let center = fixture.makeCenter()
            let manager = center.mcpManager
            let server = MCPServer(id: "native-mcp-recovery", name: "合成恢复服务器",
                                   type: .stdio, enabled: false, command: "/usr/bin/false")
            try manager.addServer(server)
            center.reloadMCP()
            try #require(center.removeMCPServer(id: server.id), "Synthetic trash setup must succeed")
            try #require(manager.trashedServers().map(\.id) == [server.id])
            let host = makeSettingsWindow(center: center)
            defer { closeSettingsWindow(host) }
            let tab = try #require(findSettingsAX(in: host.window, identifier: "settings-tab-mcp"),
                                   "Owned Settings MCP tab must be reachable")
            try #require(settingsAXPress(tab, in: host.window), "Owned Settings MCP tab must open")
            pumpSettingsRunLoop()
            let component = server.id.utf8.map { String($0, radix: 16) }.joined(separator: "-")
            let restoreID = "mcp.server.\(component).restore"
            let restore = try #require(findSettingsAX(in: host.window, identifier: restoreID),
                                       "Deleted server must have a public recovery action")
            try #require(settingsAXPress(restore, in: host.window))
            pumpSettingsRunLoop()
            let restored = try #require(manager.server(id: server.id))
            #expect(restored == server)
            #expect(!manager.isServerAuthorized(restored))
            #expect(manager.trashedServers().isEmpty)
        }
    }

    @Test("MCP native hosting keeps identity and action rows measurable at 600...1600pt")
    func mcpHostingGeometryUsesAdaptiveRows() throws {
        let center = makeSettingsCenter()
        let server = MCPServer(
            id: "native-mcp",
            name: "Native MCP server",
            type: .stdio,
            enabled: true,
            command: "echo"
        )
        try center.mcpManager.addServer(server)
        center.reloadMCP()

        let hostingController = NSHostingController(
            rootView: AnyView(
                MCPManagerView(center: center)
                    .environment(\.typographyTokens, TypographyTokenProvider(center: center))
            )
        )
        let host = hostingController.view
        for width in [CGFloat(600), 800, 1_100, 1_400, 1_600] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 640)
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == width)
            #expect(host.frame.height == 640)
            #expect(host.fittingSize.width > 0)
            #expect(host.fittingSize.height > 0)
        }

        let source = try source(named: "src/MinisCanvasApp/Sources/MinisCanvasApp/MCPManagerView.swift")
        #expect(source.contains("AdaptiveLayoutPolicy.widthClass(for: geometry.size.width)"))
        #expect(source.contains("serverActionRow(\n                server: server,"))
        #expect(source.contains("private func serverActionRow(\n        server: MCPServer,\n        authorized: Bool,\n        widthClass: AdaptiveWidthClass"))
        #expect(source.contains("Task { @MainActor in"))
        #expect(source.contains("@ViewBuilder"))
        #expect(source.contains("mcp.server.\\(accessibilityComponent(server.id)).connection-test"))
        #expect(source.contains("accessibilityHint(\"测试 \\(server.name) 的握手与 tools/list，不授予工具权限\")"))
        #expect(source.contains("mcp.server.\\(accessibilityComponent(server.id)).delete"))
    }

    @Test("Settings native hosting accepts 16pt and 20pt typography at compact and wide sizes")
    func settingsHostingGeometryPreservesTypographyScale() {
        let center = makeSettingsCenter()
        let suite = "settings-native-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutStore(defaults: defaults)
        let skills = SkillsStore(
            appStore: center.skillStore,
            stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("settings-native-skills-\(UUID().uuidString).json"),
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(defaults: defaults)
        let controller = NSHostingController(
            rootView: AnyView(
                SettingsView(
                    center: center,
                    shortcutStore: shortcuts,
                    skillsStore: skills,
                    schedulerStore: scheduler
                )
                .environment(\.typographyTokens, TypographyTokenProvider(center: center))
            )
        )
        let host = controller.view
        for fontSize in [16, 20] {
            center.uiBaseFontSize = fontSize
            #expect(center.uiBaseFontSize == fontSize)
            for width in [CGFloat(600), 1_600] {
                host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                host.layoutSubtreeIfNeeded()
                #expect(host.frame.width == width)
                #expect(host.frame.height == 700)
                #expect(host.fittingSize.width > 0)
                #expect(host.fittingSize.height > 0)
            }
        }
    }

    @Test("Shortcut settings native controls persist rebind, clear, conflict and restores")
    func shortcutSettingsNativeControlsReachTheSharedStore() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
        let center = fixture.makeCenter()
        let host = makeSettingsWindow(center: center)
        defer { closeSettingsWindow(host) }
// B1325_HANDOFF_BEGIN
#if MINISCANVAS_SHORTCUT_TITLEBAR_HANDOFF
        try await ShortcutNativePassiveDiagnostics.awaitValidatedTitlebarPost(window: host.window)
#endif
// B1325_HANDOFF_END
        let defaults = try #require(UserDefaults(suiteName: host.suite))

        @MainActor func binding() -> ShortcutBinding {
            ShortcutStore(defaults: defaults).binding(for: .newSession)
        }
        @MainActor func press(_ identifier: String) throws {
// B1555_DUAL_BEGIN
#if MINISCANVAS_SHORTCUT_DUAL_READONLY_FOCUS_B1555
            try ShortcutNativePassiveDiagnostics.requireB1555FocusIfSelected(window: host.window)
#endif
// B1555_DUAL_END
            let button = try #require(findSettingsAX(in: host.window, identifier: identifier))
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
            ShortcutNativePassiveDiagnostics.found(button, identifier: identifier, window: host.window)
#endif
// B1213_DIAGNOSTIC_END
            #expect(settingsAXPress(button, in: host.window), "Native shortcut control did not accept press: \(identifier)")
            pumpSettingsRunLoop()
        }
        @MainActor func postKey(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) throws {
// B1555_DUAL_BEGIN
#if MINISCANVAS_SHORTCUT_DUAL_READONLY_FOCUS_B1555
            try ShortcutNativePassiveDiagnostics.requireB1555FocusIfSelected(window: host.window)
#endif
// B1555_DUAL_END
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
            ShortcutNativePassiveDiagnostics.key(event, phase: "will-enqueue")
#endif
// B1213_DIAGNOSTIC_END
            NSApp.postEvent(event, atStart: true)
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
            ShortcutNativePassiveDiagnostics.key(event, phase: "postEvent-returned-void-not-dispatched-ack")
#endif
// B1213_DIAGNOSTIC_END
            pumpSettingsRunLoop()
        }

        try press("settings-tab-shortcuts")
        let search = try #require(findSettingsAX(in: host.window, identifier: "settings.shortcuts.search"))
        #expect(replaceSettingsText("新建会话", in: search, host: host.window))
        #expect(binding() == ShortcutAction.newSession.defaultBinding)

        let changed = ShortcutBinding(
            key: "g", modifiers: ShortcutModifiers(control: true, option: true, shift: true)
        )
        try press("settings.shortcuts.newSession.record")
        try postKey(5, characters: "g", modifiers: [.control, .option, .shift])
        #expect(binding() == changed)
        let command = BridgeStore(
            shortcutStore: host.shortcuts,
            preferencesDefaults: fixture.defaults,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: fixture.root.appendingPathComponent("workflows")),
            sessionBadgeStore: fixture.badges,
            sessionDocumentStore: SessionDocumentStore(directory: fixture.root.appendingPathComponent("documents")),
            sessionStore: center.sessionStore,
            canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(),
            memoryStore: center.memoryStore,
            commandEnvStore: center.envStore,
            canonicalMCPManager: center.mcpManager,
            providerReadinessStore: ProviderReadinessStore(directory: fixture.root.appendingPathComponent("bridge-readiness")),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(command.paletteDisplay["session.new"]?.shortcut == changed.displayString)

        try press("settings.shortcuts.newSession.clear")
        #expect(binding().isEmpty)
        #expect(command.paletteDisplay["session.new"]?.shortcut == "无")
        try press("settings.shortcuts.newSession.restore")
        #expect(binding() == ShortcutAction.newSession.defaultBinding)
        #expect(command.paletteDisplay["session.new"]?.shortcut == "⌘N")

        try press("settings.shortcuts.newSession.record")
        try postKey(5, characters: "g", modifiers: [.control, .option, .shift])
        #expect(binding() == changed)
        try press("settings.shortcuts.restore-all")
        #expect(binding() == ShortcutAction.newSession.defaultBinding)
        #expect(command.paletteDisplay["session.new"]?.shortcut == "⌘N")

        try press("settings.shortcuts.newSession.record")
        try postKey(43, characters: ",", modifiers: .command)
        #expect(binding() == ShortcutAction.newSession.defaultBinding)
// B2207_ATTACHED_SHEET_BEGIN
#if MINISCANVAS_SHORTCUT_ATTACHED_SHEET_B2207
        observeB2207AttachedSheet(in: host.window)
#endif
// B2207_ATTACHED_SHEET_END
        #expect(findSettingsAX(in: host.window, label: "快捷键冲突") != nil)
        }
    }

    @Test("Command-/ clear and restore reaches the real shortcut settings consumer")
    func restoredShortcutReferenceDispatchesAfterClear() async throws {
        try await withQualifiedSettingsNativeFixture { fixture in
            let center = fixture.makeCenter()
            let shortcuts = ShortcutStore(defaults: fixture.defaults)
            let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: fixture.defaults,
                logManager: center.logManager,
                workflowStore: WorkflowStore(storeDirectory: fixture.root.appendingPathComponent("command04-workflows")),
                sessionBadgeStore: fixture.badges, sessionStore: center.sessionStore,
                canvasRuntimeState: .disabled, memoryStore: center.memoryStore,
                canvasFeatureLane: .phase3NonCanvas)
            var opened: (window: NSWindow, suite: String, shortcuts: ShortcutStore)?
            bridge.deepLinkHandler.onOpenSettings = { page in
                opened = makeSettingsWindow(center: center, initialPageID: page)
            }
            let lease = NativeTestHostLifecycle.begin("Command04Restore")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            NativeTestHostLifecycle.bind(lease, to: window)
            let controller = NSHostingController(rootView: Command04ShortcutReferenceHost(
                shortcuts: shortcuts, open: { bridge.deepLinkHandler.handle(.openSettings(id: "快捷键")) }))
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer {
                if let opened { closeSettingsWindow(opened) }
                bridge.deepLinkHandler.onOpenSettings = nil
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
                NativeTestHostLifecycle.end(window)
            }
            @MainActor func settle() {
                for _ in 0..<6 {
                    window.layoutIfNeeded()
                    controller.view.layoutSubtreeIfNeeded()
                    pumpSettingsRunLoop()
                }
            }
            @MainActor func sendReferenceKey() throws {
                try #require(window.isKeyWindow, "key dispatch requires the owned source window")
                try #require(window.firstResponder != nil, "key dispatch requires an owned first responder")
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "/",
                    charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
                NSApp.sendEvent(event)
                settle()
            }
            settle()
            try sendReferenceKey()
            let initial = try #require(opened, "the original binding must dispatch before mutation")
            _ = try #require(findSettingsAX(in: initial.window, identifier: "settings.shortcuts.search"))
            closeSettingsWindow(initial)
            opened = nil
            window.orderFrontRegardless()
            _ = NSRunningApplication.current.activate(options: [])
            window.makeKeyAndOrderFront(nil)
            try #require(shortcuts.setBinding(ShortcutBinding(key: "", modifiers: .none),
                for: .openShortcutReference) == nil)
            settle()
            try sendReferenceKey()
            try #require(opened == nil, "cleared shortcut must not open settings")
            try #require(shortcuts.reset(for: .openShortcutReference) == nil)
            try #require(shortcuts.binding(for: .openShortcutReference) == ShortcutAction.openShortcutReference.defaultBinding)
            settle()
            try sendReferenceKey()
            let restored = try #require(opened, "restored binding must dispatch to the actual settings page")
            #expect(findSettingsAX(in: restored.window, identifier: "settings.shortcuts.search") != nil)
        }
    }

    @Test("Settings reset requires native confirmation and preserves cancel paths")
    func settingsResetConfirmationRequiresExplicitNativeConfirm() throws {
        let center = makeSettingsCenter()
        let settingsDirectory = center.settingsDirectory
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }

        center.appearance = .dark
        center.maxLoopIterations = 99
        let beforeSettings = center.settingsStore.settings
        let beforeData = try Data(contentsOf: center.settingsStore.fileURL)
        var resetCallbackCount = 0
        center.onComposerPolicyChanged = { _ in resetCallbackCount += 1 }

        let host = makeSettingsWindow(center: center)
        defer { closeSettingsWindow(host) }

        guard let resetButton = findSettingsAX(
            in: host.window,
            identifier: "settings.reset.defaults"
        ) else {
            #expect(Bool(false), "native reset button was not exposed")
            return
        }
        #expect(settingsAXPress(resetButton, in: host.window))
        pumpSettingsRunLoop()

        // Opening the confirmation must not touch the store or its bytes.
        #expect(center.settingsStore.settings == beforeSettings)
        let openedData = try Data(contentsOf: center.settingsStore.fileURL)
        #expect(openedData == beforeData)

        // Escape/close cancellation is handled by the confirmation dialog's
        // native cancel responder and must leave the persisted snapshot intact.
        _ = NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
        pumpSettingsRunLoop()
        #expect(center.settingsStore.settings == beforeSettings)
        let escapedData = try Data(contentsOf: center.settingsStore.fileURL)
        #expect(escapedData == beforeData)

        guard let resetAgain = findSettingsAX(
            in: host.window,
            identifier: "settings.reset.defaults"
        ) else {
            #expect(Bool(false), "native reset button disappeared after cancellation")
            return
        }
        #expect(settingsAXPress(resetAgain, in: host.window))
        pumpSettingsRunLoop()
        guard let cancelButton = findSettingsAX(
            in: host.window,
            identifier: "settings.reset.defaults.cancel"
        ) else {
            #expect(Bool(false), "native reset cancel action was not exposed")
            return
        }
        #expect(settingsAXPress(cancelButton, in: host.window))
        pumpSettingsRunLoop()
        #expect(center.settingsStore.settings == beforeSettings)
        let cancelledData = try Data(contentsOf: center.settingsStore.fileURL)
        #expect(cancelledData == beforeData)

        guard let resetForConfirmation = findSettingsAX(
            in: host.window,
            identifier: "settings.reset.defaults"
        ) else {
            #expect(Bool(false), "native reset button disappeared after explicit cancel")
            return
        }
        #expect(settingsAXPress(resetForConfirmation, in: host.window))
        pumpSettingsRunLoop()
        guard let confirmButton = findSettingsAX(
            in: host.window,
            identifier: "settings.reset.defaults.confirm"
        ) else {
            #expect(Bool(false), "native reset confirmation action was not exposed")
            return
        }
        #expect(settingsAXPress(confirmButton, in: host.window))
        pumpSettingsRunLoop()

        #expect(center.settingsStore.settings == .defaults)
        #expect(center.settingsStore.settings.general.appearance == .system)
        #expect(center.settingsStore.settings.agent.maxLoopIterations == AppSettings.defaults.agent.maxLoopIterations)
        #expect(resetCallbackCount == 1)
        let confirmedData = try Data(contentsOf: center.settingsStore.fileURL)
        #expect(confirmedData != beforeData)
    }

    @Test("Logs clear requires explicit confirmation and preserves disk logs")
    func settingsLogClearRequiresExplicitConfirmationAndPreservesDisk() async throws {
        try await S20OriginalOwnedFixture.withFixture { center in
        center.liveLogLevel = .info
        center.logManager.debug("filtered", category: "NativeLogs")
        center.logManager.info("before-clear", category: "NativeLogs")
        center.reloadLogs()
        #expect(center.logEntries.map(\.message) == ["before-clear"])

        guard let logFileURL = center.logManager.logFileURL() else {
            #expect(Bool(false), "native log fixture did not create its temporary app.log")
            return
        }
        let beforeClearDisk = try Data(contentsOf: logFileURL)
        let host = makeSettingsWindow(center: center)
        defer { closeSettingsWindow(host) }

        guard let logsPage = findSettingsAX(
            in: host.window,
            identifier: "settings-tab-logs"
        ) else {
            #expect(Bool(false), "native logs settings page was not exposed")
            return
        }
        #expect(settingsAXPress(logsPage, in: host.window))
        pumpSettingsRunLoop()

        guard let clearButton = findSettingsAX(
            in: host.window,
            identifier: "settings.logs.clear"
        ) else {
            #expect(Bool(false), "native logs clear action was not exposed")
            return
        }
        #expect(settingsAXPress(clearButton, in: host.window))
        pumpSettingsRunLoop()

        // Opening the deletion prompt is preview-only; the ring and disk stay intact.
        #expect(center.logManager.recentLogs(limit: nil).map(\.message) == ["before-clear"])
        #expect(try Data(contentsOf: logFileURL) == beforeClearDisk)

        guard let cancelButton = findSettingsAX(in: host.window, label: "取消", pressable: true) else {
            #expect(Bool(false), "native log deletion cancel action was not exposed")
            return
        }
        #expect(settingsAXPress(cancelButton, in: host.window))
        pumpSettingsRunLoop()
        #expect(center.logManager.recentLogs(limit: nil).map(\.message) == ["before-clear"])

        guard let clearAgain = findSettingsAX(
            in: host.window,
            identifier: "settings.logs.clear"
        ) else {
            #expect(Bool(false), "native logs clear action disappeared after cancellation")
            return
        }
        #expect(settingsAXPress(clearAgain, in: host.window))
        pumpSettingsRunLoop()

        guard let firstFieldObject = findSettingsAX(
                in: host.window,
                label: "输入第一确认文字",
                textField: true
              ),
              replaceSettingsText("我已核对这份精确预览", in: firstFieldObject, host: host.window),
              let nextButton = findSettingsAX(in: host.window, label: "下一步", pressable: true) else {
            #expect(Bool(false), "native log deletion first confirmation controls were not exposed")
            return
        }
        #expect(settingsAXPress(nextButton, in: host.window))
        pumpSettingsRunLoop()

        guard let secondFieldObject = findSettingsAX(
                in: host.window,
                label: "永久删除",
                textField: true
              ),
              replaceSettingsText("永久删除", in: secondFieldObject, host: host.window),
              let executeButton = findSettingsAX(in: host.window, label: "永久删除", pressable: true) else {
            #expect(Bool(false), "native log deletion second confirmation controls were not exposed")
            return
        }
        #expect(settingsAXPress(executeButton, in: host.window))
        pumpSettingsRunLoop()

        #expect(center.logManager.recentLogs(limit: nil).isEmpty)
        #expect(try Data(contentsOf: logFileURL) == beforeClearDisk)

        // Accepted logs continue after the ring-only clear and reach the same file.
        center.logManager.info("after-clear", category: "NativeLogs")
        center.reloadLogs()
        #expect(center.logEntries.map(\.message) == ["after-clear"])
        #expect(try Data(contentsOf: logFileURL) != beforeClearDisk)

        // A preview made before a new entry must not be allowed to clear that entry.
        let staleIntent = try center.previewLogClear()
        center.logManager.info("after-stale-preview", category: "NativeLogs")
        var staleRejected = false
        do {
            _ = try center.clearLogs(intent: staleIntent)
        } catch {
            staleRejected = true
        }
        #expect(staleRejected)
        center.reloadLogs()
        #expect(center.logEntries.map(\.message) == ["after-stale-preview", "after-clear"])
        }
    }

    /// 原生 AX 验收宿主：沿用本仓库已被 SchedulerControlSettingsTests /
    /// AdaptiveDividerNativeConsumerTests / ValidatedNumericSettingNativeConsumerTests
    /// 验证过的同一套宿主合同 —— 宿主租约 + `sizingOptions = []` + 显式
    /// `setContentSize` + 多轮 layout/display 泵。
    ///
    /// 这里必须显式关掉 `preferredContentSize` 尺寸选项：NSHostingController 默认会把
    /// 窗口收缩到 SwiftUI 内容的固有尺寸，而 SettingsView 以 GeometryReader 打头，
    /// 固有尺寸近乎 10×10。窗口一旦塌成 10×10，位于内容底部的元素（侧栏尾部页签、
    /// 底部常驻条里的「恢复全部默认设置」）就落在窗口边界之外，SwiftUI 不再向可访问性
    /// 树投射它们，findSettingsAX 只能返回 nil。086 把触发元素移出滚动容器之后仍测不到，
    /// 正是因为塌陷的宿主，而不是产品没有曝光；所以修的是宿主轴，任何断言都未放宽。
    @MainActor
    func makeSettingsWindow(center: SettingsCenter, initialPageID: String? = nil) -> (
        window: NSWindow, suite: String, shortcuts: ShortcutStore
    ) {
        let suite = "settings-native-reset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let shortcuts = ShortcutStore(defaults: defaults)
        let skills = SkillsStore(
            appStore: center.skillStore,
            stateFileURL: center.settingsDirectory.appendingPathComponent("native-skills.json"),
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(defaults: defaults)
        let controller = NSHostingController(
            rootView: AnyView(
                SettingsView(
                    center: center,
                    shortcutStore: shortcuts,
                    skillsStore: skills,
                    schedulerStore: scheduler, initialPageID: initialPageID
                )
                .environment(\.typographyTokens, TypographyTokenProvider(center: center))
            )
        )
        controller.sizingOptions = []
        let hostLease = NativeTestHostLifecycle.begin("SettingsNative")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        NativeTestHostLifecycle.bind(hostLease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 700))
        window.orderFrontRegardless()
        _ = NSRunningApplication.current.activate(options: [])
        window.makeKeyAndOrderFront(nil)
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        ShortcutNativePassiveDiagnostics.install(window: window)
#endif
// B1213_DIAGNOSTIC_END
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        // 宿主轴的单变量修复（settings-residual-043 首错 :113/:205 诊断）。R18C
        // 原始日志：30 轮就绪轮询后 surfaceProjected=false、visited=215 仍无任何
        // SwiftUI 节点 —— 本宿主从未向进程内 selector 遍历 vend 可访问性子树，
        // settings.surface / settings.reset.defaults / settings-tab-logs 的缺失
        // 是投影未建立，而不是产品未曝光（三者在 SettingsView.swift :422/:931/:290
        // 无条件挂载）。仓库实测成功路径（SchedulerControlSettingsTests :573-597、
        // TypographyPackageFieldJourney.exposeOwnedWindow :3429-3521）：给自家窗口
        // 唯一 accessibilityIdentifier 后做一次有界、只读、仅针对本进程 pid 的公共
        // AXUIElement 曝光读取，随后同形本地遍历立即 vend SwiftUI.AccessibilityNode。
        // 只补这次宿主曝光读取；任何断言、标识符、遍历条件均未放宽。
        let ownerIdentifier = "settings-native-host-163-" + UUID().uuidString
        window.setAccessibilityIdentifier(ownerIdentifier)
        for _ in 0..<6 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        let exposureStatus = exposeOwnedWindowForAccessibility(
            window, ownerIdentifier: ownerIdentifier
        )
        print("SETTINGS_NATIVE_HOST_EXPOSURE \(exposureStatus)")
        // 等真实的根表面进入可访问性树再交给用例，避免把宿主时序误判成产品缺口。
        var surfaceProjected = false
        for _ in 0..<30 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            var readinessVisited = Set<ObjectIdentifier>()
            if findSettingsAX(window, identifier: "settings.surface", visited: &readinessVisited) != nil {
                surfaceProjected = true
                if NSApp.isActive && window.isKeyWindow && window.isVisible { break }
            }
        }
        NativeTestHostLifecycle.observe(window, phase: "sampled")
        let contentFrame = window.contentView?.frame
        print(
            "SETTINGS_NATIVE_HOST contentFrame=\(String(describing: contentFrame)) "
                + "hostFrame=\(controller.view.frame) visible=\(window.isVisible) "
                + "key=\(window.isKeyWindow) surfaceProjected=\(surfaceProjected)"
        )
        return (window, suite, shortcuts)
    }

    @MainActor
    func closeSettingsWindow(_ host: (window: NSWindow, suite: String, shortcuts: ShortcutStore)) {
        SettingsNativePublicAXBridge.invalidate()
        host.window.orderOut(nil)
        host.window.contentViewController = nil
        host.window.close()
        NativeTestHostLifecycle.end(host.window)
        UserDefaults(suiteName: host.suite)?.removePersistentDomain(forName: host.suite)
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        ShortcutNativePassiveDiagnostics.finish()
#endif
// B1213_DIAGNOSTIC_END
    }

    /// 只读、有界、仅针对本进程自家 pid 的公共 AXUIElement 曝光：
    /// app 元素 → kAXWindowsAttribute → 按窗口 accessibilityIdentifier 唯一匹配自家
    /// 宿主 → 对其做一次 kAXChildrenAttribute 读取。仿照
    /// TypographyPackageFieldJourney.exposeOwnedWindow（:3429-3521）与
    /// SchedulerControlSettingsTests 宿主的同款读取序。该读取永不向遍历提供替代
    /// 节点、不放宽任何断言：若曝光失败，findSettingsAX 仍返回 nil，用例如实失败。
    @MainActor
    private func exposeOwnedWindowForAccessibility(
        _ window: NSWindow, ownerIdentifier: String
    ) -> String {
        let application = AXUIElementCreateApplication(getpid())
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success else {
            return "status=APP_MESSAGING_TIMEOUT_UNSET"
        }
        var windowCount = 0
        guard AXUIElementGetAttributeValueCount(
            application, kAXWindowsAttribute as CFString, &windowCount
        ) == .success, (1...16).contains(windowCount) else {
            return "status=OWN_WINDOWS_UNREADABLE windowCount=\(windowCount)"
        }
        var rawWindows: CFArray?
        guard AXUIElementCopyAttributeValues(
            application, kAXWindowsAttribute as CFString, 0, windowCount, &rawWindows
        ) == .success, let windows = rawWindows as? [AXUIElement] else {
            return "status=OWN_WINDOWS_COPY_FAILED"
        }
        var owner: AXUIElement?
        var matches = 0
        for element in windows.prefix(16) {
            _ = AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXIdentifierAttribute as CFString, &value
            ) == .success, (value as? String) == ownerIdentifier {
                matches += 1
                owner = element
            }
        }
        guard matches == 1, let owner else {
            return "status=OWNER_NOT_UNIQUE matches=\(matches) windows=\(windows.count)"
        }
        var childCount = 0
        guard AXUIElementGetAttributeValueCount(
            owner, kAXChildrenAttribute as CFString, &childCount
        ) == .success else {
            return "status=OWNER_CHILDREN_UNREADABLE ownerMatches=\(matches)"
        }
        if childCount > 0 {
            var children: CFArray?
            _ = AXUIElementCopyAttributeValues(
                owner, kAXChildrenAttribute as CFString, 0, min(childCount, 4), &children
            )
        }
        return "status=EXPOSED children=\(childCount) windows=\(windows.count)"
    }

    @MainActor
    func pumpSettingsRunLoop() {
        // B1959: drain the original NSApp queue; no new events or direct recorder/store calls.
        let deadline = Date(timeIntervalSinceNow: 0.12)
        for _ in 0..<64 {
            guard Date() < deadline else { break }
            let sliceEnd = min(Date(timeIntervalSinceNow: 0.02), deadline)
            if let event = NSApp.nextEvent(matching: .any, until: sliceEnd, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    @MainActor
    private func traceSettingsFinderClass(_ object: AnyObject, identifier: String, channel: String, window: NSWindow) {
        guard identifier == "settings.shortcuts.search"
            || (identifier.hasPrefix("mcp.server.") && identifier.hasSuffix(".tools.disclosure")) else { return }
        let localObject = object as? NSObject
        let record: [String: Any] = [
            "identifier": identifier, "channel": channel,
            "actualClass": String(reflecting: type(of: object)),
            "CFTypeID": CFGetTypeID(object),
            "isAXUIElement": CFGetTypeID(object) == AXUIElementGetTypeID(),
            "conformsNSAccessibilityProtocol": object is NSAccessibilityProtocol,
            "isNSTextField": object is NSTextField, "isNSTextFieldCell": object is NSTextFieldCell,
            "respondsAccessibilityRole": localObject?.responds(to: NSSelectorFromString("accessibilityRole")) ?? false,
            "respondsAccessibilityValue": localObject?.responds(to: NSSelectorFromString("accessibilityValue")) ?? false,
            "windowNumber": window.windowNumber, "windowIdentifier": window.accessibilityIdentifier(),
            "isActive": NSApplication.shared.isActive, "isKey": window.isKeyWindow,
            "observationalOnlyNoExtraAXRPC": true
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("SETTINGS_NATIVE_FINDER_CLASS_CAPTURE=" + text)
        }
    }

    @MainActor
    func findSettingsAX(in window: NSWindow, identifier: String) -> AnyObject? {
        SettingsNativePublicAXBridge.invalidate()
        var visited = Set<ObjectIdentifier>()
        var roots: [AnyObject] = [window]
        roots.append(contentsOf: window.sheets)
        for root in roots {
            if let result = findSettingsAX(
                root,
                identifier: identifier,
                visited: &visited
            ) {
                traceSettingsFinderClass(result, identifier: identifier, channel: "local", window: window)
                // B0013: only the actually observed non-protocol/non-AX proxy,
                // and only where both original role/String channels are nil.
                if String(reflecting: type(of: result)) == "SwiftUI.AccessibilityNode",
                   !(result is NSAccessibilityProtocol), NativeConsumerOwnedAX.element(result) == nil,
                   identifier.hasPrefix("mcp.server."), identifier.hasSuffix(".tools.disclosure"),
                   NativeConsumerOwnedAX.role(result) == nil,
                   NativeConsumerOwnedAX.attribute(result, kAXValueAttribute as CFString) as? String == nil,
                   let publicNode = SettingsNativePublicAXBridge.disclosure(in: window, identifier: identifier) {
                    return publicNode
                }
                // Actual74774: refresh finder returned this nonprotocol proxy.
                // Map only its original ID to the real complete owned public AX
                // element; the original role getter/assertion stays unchanged.
                if String(reflecting: type(of: result)) == "SwiftUI.AccessibilityNode",
                   !(result is NSAccessibilityProtocol), NativeConsumerOwnedAX.element(result) == nil,
                   SettingsNativePublicAXGate.admitsIdentifier(identifier, refreshRoleOnly: true),
                   NativeConsumerOwnedAX.role(result) == nil,
                   let publicNode = SettingsNativePublicAXBridge.refresh(in: window, identifier: identifier) {
                    return publicNode
                }
                // B0013 Shortcut channel only: original search failure was
                // a SwiftUI _SystemTextFieldCell, not an NSTextField. Only
                // this exact ID's unsupported local input receiver is mapped.
                // Original public role/settable/write/readback checks remain.
                if identifier == "settings.shortcuts.search",
                   !(result is NSTextField), NativeConsumerOwnedAX.element(result) == nil,
                   let publicNode = SettingsNativePublicAXBridge.shortcutSearch(in: window, identifier: identifier) {
                    return publicNode
                }
                return result
            }
        }
        // Preserve the local walk, then read the existing public AX channel.
        // The shared helper requires exactly one node in this host/attached sheet.
        let localVisitedCount = visited.count
        if let publicElement = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
            print(
                "SETTINGS_NATIVE_AX_PUBLIC identifier=\(identifier) "
                    + "localVisited=\(localVisitedCount) hit=true"
            )
            traceSettingsFinderClass(publicElement as AnyObject, identifier: identifier, channel: "public-owned-AX", window: window)
            return publicElement as AnyObject
        }
        print(
            "SETTINGS_NATIVE_AX_PUBLIC identifier=\(identifier) "
                + "localVisited=\(localVisitedCount) hit=false"
        )
        // 与 TaskCenter/Scheduler 宿主同一套可判别诊断：缺元素时留下遍历规模，
        // 便于区分「产品未曝光」与「宿主未投射可访问性树」，不改变任何断言。
        print(
            "SETTINGS_NATIVE_AX_MISSING identifier=\(identifier) "
                + "visited=\(visited.count) roots=\(roots.count) visible=\(window.isVisible)"
        )
        return nil
    }

    @MainActor
    private func findSettingsAX(
        _ object: AnyObject,
        identifier: String,
        visited: inout Set<ObjectIdentifier>
    ) -> AnyObject? {
        let objectID = ObjectIdentifier(object)
        guard visited.insert(objectID).inserted else { return nil }
        if settingsAXIdentifier(object) == identifier { return object }

        var children = settingsAXChildren(of: object)
        if let view = object as? NSView { children += view.subviews }
        if let childWindow = object as? NSWindow, let content = childWindow.contentView {
            children.append(content.superview ?? content)
        }
        for child in settingsAXFlatten(children) {
            let childObject = child as AnyObject
            if let result = findSettingsAX(
                childObject,
                identifier: identifier,
                visited: &visited
            ) {
                return result
            }
        }
        return nil
    }

    @MainActor
    private func findSettingsAX(
        in window: NSWindow,
        label: String,
        pressable: Bool = false,
        textField: Bool = false
    ) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        var roots: [AnyObject] = [window]
        roots.append(contentsOf: window.sheets)
        for root in roots {
            if let result = findSettingsAX(
                root,
                label: label,
                pressable: pressable,
                textField: textField,
                visited: &visited
            ) {
                return result
            }
        }
        // The identifier finder already uses public AX; sheet labels need the
        // same channel, constrained to this host and exactly one matching role.
        if let original = NativeConsumerOwnedAX.find(
            in: window, label: label, pressable: pressable, textField: textField
        ) { return original }
        // B2257: only the original fixed conflict-title lookup, after all old channels.
        return findB2257FixedConflictTitle(
            in: window, label: label, pressable: pressable, textField: textField
        )
    }

    /// Local text-entry matches remain NSTextField; the public fallback requires
    /// AXTextField and writes/readbacks its real value. Static prompt text cannot match.
    @MainActor
    private func findSettingsAX(
        _ object: AnyObject,
        label: String,
        pressable: Bool,
        textField: Bool,
        visited: inout Set<ObjectIdentifier>
    ) -> AnyObject? {
        let objectID = ObjectIdentifier(object)
        guard visited.insert(objectID).inserted else { return nil }
        if settingsAXLabel(object)?.contains(label) == true,
           !pressable || settingsAXCanPress(object),
           !textField || object is NSTextField {
            return object
        }

        var children = settingsAXChildren(of: object)
        if let view = object as? NSView { children += view.subviews }
        if let childWindow = object as? NSWindow, let content = childWindow.contentView {
            children.append(content.superview ?? content)
        }
        for child in settingsAXFlatten(children) {
            let childObject = child as AnyObject
            if let result = findSettingsAX(
                childObject,
                label: label,
                pressable: pressable,
                textField: textField,
                visited: &visited
            ) {
                return result
            }
        }
        return nil
    }

    @MainActor
    private func settingsAXChildren(of object: AnyObject) -> [Any] {
        let unignored = NSAccessibility.unignoredChildrenForOnlyChild(from: object)
        // SwiftUI vends its leaf accessibility elements as private proxies on the
        // navigation-order attribute, while the plain accessibilityChildren getter can
        // return empty for those backing containers. Enumerate the ordered attribute too
        // — the same child source the green TaskCenter/Scheduler/ValidatedNumeric native-AX
        // finders already rely on — so the walk can descend from the settings.surface root
        // into the same reset/logs controls. This widens only the tree traversal: no
        // assertion, identifier or target control changes.
        var children: [Any] = []
        let ordered = settingsAXGetter(object, selectorName: "accessibilityChildrenInNavigationOrder")
        if let orderedValues = ordered as? NSArray {
            children += orderedValues.map { $0 }
        } else if let orderedSingle = ordered {
            children += [orderedSingle] + NSAccessibility.unignoredChildrenForOnlyChild(from: orderedSingle)
        }
        let value = settingsAXGetter(object, selectorName: "accessibilityChildren")
            ?? UF03LegacyAttribute(object as? NSObject, .children)
        if let values = value as? NSArray {
            children += values.map { $0 }
        } else if let single = value {
            children += [single] + NSAccessibility.unignoredChildrenForOnlyChild(from: single)
        }
        return children + NSAccessibility.unignoredChildren(from: children) + unignored
    }

    private func settingsAXFlatten(_ children: [Any]) -> [Any] {
        children.flatMap { child in
            if let nested = child as? [Any] { return settingsAXFlatten(nested) }
            if let nested = child as? NSArray { return settingsAXFlatten(nested.map { $0 }) }
            return [child]
        }
    }

    @MainActor
    private func settingsAXIdentifier(_ object: AnyObject) -> String? {
        if let identifier = settingsAXGetter(object, selectorName: "accessibilityIdentifier") as? String,
           !identifier.isEmpty {
            return identifier
        }
        if let identifier = UF03LegacyAttribute(object as? NSObject, .identifier) as? String,
           !identifier.isEmpty {
            return identifier
        }
        if let identifier = (object as? NSAccessibilityProtocol)?.accessibilityIdentifier(),
           !identifier.isEmpty {
            return identifier
        }
        return nil
    }

    @MainActor
    private func settingsAXLabel(_ object: AnyObject) -> String? {
        let dynamicLabel = settingsAXGetter(object, selectorName: "accessibilityLabel") as? String
        let title = settingsAXGetter(object, selectorName: "accessibilityTitle") as? String
        let placeholder = settingsAXGetter(object, selectorName: "accessibilityPlaceholderValue") as? String
        let legacyLabel = UF03LegacyAttribute(object as? NSObject, .description) as? String
        return [dynamicLabel, title, placeholder, legacyLabel]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    @MainActor
    private func settingsAXCanPress(_ object: AnyObject) -> Bool {
        if let role = (object as? NSAccessibilityProtocol)?.accessibilityRole(),
           role == .button {
            return true
        }
        return (settingsAXGetter(object, selectorName: "accessibilityActionNames") as? [String])?.contains(NSAccessibility.Action.press.rawValue) == true
    }

    @MainActor
    private func settingsAXGetter(_ object: AnyObject, selectorName: String) -> Any? {
        guard let object = object as? NSObject else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector), let result = object.perform(selector) else { return nil }
        return result.takeUnretainedValue()
    }

    @MainActor
    func settingsAXPress(_ object: AnyObject, in window: NSWindow) -> Bool {
        SettingsNativePublicAXBridge.invalidate()
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        if NativeConsumerOwnedAX.element(object) != nil {
            ShortcutNativePassiveDiagnostics.pressBranch(object, branch: "real-AXUIElement-original-helper")
            return NativeConsumerOwnedAX.press(object)
        }
#else
        if NativeConsumerOwnedAX.element(object) != nil { return NativeConsumerOwnedAX.press(object) }
#endif
// B1213_DIAGNOSTIC_END
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        if let accessibilityObject = object as? NSAccessibilityProtocol {
            let accepted = accessibilityObject.accessibilityPerformPress()
            ShortcutNativePassiveDiagnostics.protocolPress(object, accepted: accepted)
            if accepted { return true }
        }
#else
        if let accessibilityObject = object as? NSAccessibilityProtocol,
           accessibilityObject.accessibilityPerformPress() {
            return true
        }
#endif
// B1213_DIAGNOSTIC_END
        guard let object = object as? NSObject,
              (object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String])?.contains(NSAccessibility.Action.press.rawValue) == true else {
            // settings-residual-043 第三通道：分支 1（NSAccessibilityProtocol 静态通道）
            // 与分支 2（NSObject 遗留 actionNames 列表）都未接住的节点，此前唯一出口
            // 就是这里的 return false；现在该出口改为落入公共 AX 兜底。分支 1、2 的
            // 判定顺序与行为一字未动 —— 本分支只在原 `return false` 处执行，只可能把
            // "按不动"变成"按动"，不可能削弱既有 PASS。
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
            ShortcutNativePassiveDiagnostics.pressBranch(object, branch: "original-public-channel-fallback")
#endif
// B1213_DIAGNOSTIC_END
            return settingsAXPressViaPublicChannel(object, in: window)
        }
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        ShortcutNativePassiveDiagnostics.pressBranch(object, branch: "original-legacy-action-selector-no-typed-status")
#endif
// B1213_DIAGNOSTIC_END
        _ = object.perform(NSSelectorFromString("accessibilityPerformAction:"), with: NSAccessibility.Action.press.rawValue)
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        ShortcutNativePassiveDiagnostics.legacyPressReturned()
#endif
// B1213_DIAGNOSTIC_END
        return true
    }

    /// 末位兜底：对本仓库两类既有本地通道都按不动的节点，通过 VoiceOver 实际使用的
    /// 公共可访问性 API 尝试一次按动。镜像 schedulerAXPress 的第一分支
    /// （SchedulerControlSettingsTests.swift:905-908，AXUIElementPerformAction +
    /// kAXPressAction == .success）：公共调用未报 success 即返回 false，RED 依旧如实 RED。
    /// 只在 settingsAXPress 原本 `return false` 的路径上被调用（append-only，见调用点注释）。
    @MainActor
    private func settingsAXPressViaPublicChannel(_ object: AnyObject, in window: NSWindow) -> Bool {
        // lane 179 教训：对 CFType  receivers 发未证实的遗留非正式协议 selector 会
        // 让进程 abort；而 `object as? AXUIElement` 是恒成功的空判（gate2 编译器诊断
        // 原文）。用仓库实测唯一的判别写法 CFGetTypeID + unsafeDowncast
        // （SchedulerControlSettingsTests.swift:837-838）先做可失败的运行时类型闸。
        if CFGetTypeID(object) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(object, to: AXUIElement.self)
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
            let originalStatus = AXUIElementPerformAction(element, kAXPressAction as CFString)
            ShortcutNativePassiveDiagnostics.publicPress(object, status: originalStatus.rawValue, branch: "already-real-public-element")
            return originalStatus == .success
#else
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
#endif
// B1213_DIAGNOSTIC_END
        }
        // 本地遍历命中并匹配过 identifier 的 SwiftUI.AccessibilityNode 是进程内私有
        // 代理：先用本文件已被本地通道证实可用的 settingsAXIdentifier 读出其标识符，
        // 再按 schedulerPublicFindAX（SchedulerControlSettingsTests.swift:694-742）的
        // 纪律在自家 pid 的公共树上精确匹配 kAXIdentifierAttribute 映射到公共元素。
        // 读不到标识符或公共树未命中同样返回 false —— 不引入 label/位置等替代语义。
        guard let identifier = settingsAXIdentifier(object), !identifier.isEmpty,
              let publicObject = NativeConsumerOwnedAX.find(in: window, identifier: identifier),
              let element = NativeConsumerOwnedAX.element(publicObject) else {
            return false
        }
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
        let originalStatus = AXUIElementPerformAction(element, kAXPressAction as CFString)
        ShortcutNativePassiveDiagnostics.publicPress(object, status: originalStatus.rawValue, branch: "same-ID-owned-public-fallback")
        return originalStatus == .success
#else
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
#endif
// B1213_DIAGNOSTIC_END
    }

    @MainActor
    private func replaceSettingsText(_ text: String, in object: AnyObject, host: NSWindow) -> Bool {
        if let element = NativeConsumerOwnedAX.element(object) {
            guard NativeConsumerOwnedAX.role(object) == .textField else { return false }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue,
                  AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
                return false
            }
            pumpSettingsRunLoop()
            return (NativeConsumerOwnedAX.attribute(object, kAXValueAttribute as CFString) as? String) == text
        }
        guard let field = object as? NSTextField, host.makeFirstResponder(field) else { return false }
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else {
            field.stringValue = text
            _ = host.makeFirstResponder(nil)
            pumpSettingsRunLoop()
            return field.stringValue == text
        }
        editor.insertText(
            text,
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
        )
        _ = host.makeFirstResponder(nil)
        pumpSettingsRunLoop()
        return field.stringValue == text
    }

    private func source(named path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func makeSettingsCenter(rootDirectory: URL? = nil) -> SettingsCenter {
        _ = NSApplication.shared
        let root = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-native-\(UUID().uuidString)", isDirectory: true)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root, keychain: KeychainStore(backing: InMemoryKeychainBacking())),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        )
    }
}

// Tests-only ownership for the two original native methods. No business action is added.
@MainActor
final class QualifiedSettingsNativeFixture {
    let lease: MEMAOwnedRootLease
    let defaults: UserDefaults
    let suite: String
    let usage: UsageStore
    var root: URL { lease.root }
    lazy var badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))

    init() throws {
        let lease = try MEMAOwnedRootLease.formal(label: "SettingsNative")
        do {
            let suite = "SettingsNative-owned-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            try #require(defaults.persistentDomain(forName: suite) == nil)
            self.lease = lease
            self.defaults = defaults
            self.suite = suite
            self.usage = UsageStore(domain: .suite(suite))
        } catch {
            try lease.finish(error)
            throw error
        }
    }

    func makeCenter() -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root, keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root),
            sessionBadgeStore: badges,
            logManager: LogManager(directory: root, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: usage,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
    }
}

// B1325_ASYNC_FIXTURE_BEGIN
#if MINISCANVAS_SHORTCUT_TITLEBAR_HANDOFF
@MainActor
func withQualifiedSettingsNativeFixture(
    _ body: @MainActor (QualifiedSettingsNativeFixture) async throws -> Void
) async throws {
    let fixture = try QualifiedSettingsNativeFixture()
    var businessFailure: (any Error)?
    // B1325: the original per-window defer still finishes before awaiting Usage persistence.
    do { try await body(fixture) } catch { businessFailure = error }
    let joined = await fixture.usage.waitForPersistence()
    print("SETTINGS_NATIVE_OWNED_USAGE_JOIN joined=\(joined) root=\(fixture.root.path) suite=\(fixture.suite)")
    guard joined else {
        let cleanup = NSError(domain: "SettingsNativeOwnedFixture", code: 1)
        if let businessFailure {
            throw MEMAOwnedRootLease.Failure.businessAndCleanup(
                String(reflecting: businessFailure), String(reflecting: cleanup))
        }
        throw cleanup
    }
    // No further Usage writes exist in either selected Edit-free interaction path.
    // The unique private domain/lock are retained as diagnostics; no daemon-reap claim.
    try fixture.lease.finish(businessFailure)
}
#else
@MainActor
func withQualifiedSettingsNativeFixture(
    _ body: @MainActor (QualifiedSettingsNativeFixture) throws -> Void
) async throws {
    let fixture = try QualifiedSettingsNativeFixture()
    var businessFailure: (any Error)?
    // Synchronous body guarantees its original deferred window close finishes before awaiting persistence.
    do { try body(fixture) } catch { businessFailure = error }
    let joined = await fixture.usage.waitForPersistence()
    print("SETTINGS_NATIVE_OWNED_USAGE_JOIN joined=\(joined) root=\(fixture.root.path) suite=\(fixture.suite)")
    guard joined else {
        let cleanup = NSError(domain: "SettingsNativeOwnedFixture", code: 1)
        if let businessFailure {
            throw MEMAOwnedRootLease.Failure.businessAndCleanup(
                String(reflecting: businessFailure), String(reflecting: cleanup))
        }
        throw cleanup
    }
    // No further Usage writes exist in either selected Edit-free interaction path.
    // The unique private domain/lock are retained as diagnostics; no daemon-reap claim.
    try fixture.lease.finish(businessFailure)
}
#endif
// B1325_ASYNC_FIXTURE_END

// B2207_ATTACHED_SHEET_BEGIN
#if MINISCANVAS_SHORTCUT_ATTACHED_SHEET_B2207
// Source0 only. Supplemental StaticText Value gate is NOT B-approved yet.
@MainActor
private extension SettingsNativeInteractionConsumerTests {
    func observeB2207AttachedSheet(in host: NSWindow) {
        func emit(_ fields: [String: Any]) {
            guard let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let text = String(data: bytes, encoding: .utf8) else { return }
            print("SHORTCUT_B2207_ATTACHED_SHEET=" + text)
        }
        // Typed in-process ownership. No AXIdentifier/AXParent fallback or name guess.
        guard let sheet = host.attachedSheet else {
            emit(["kind": "attached-sheet", "pid": getpid(), "hostWindowNumber": host.windowNumber,
                  "attachedSheetNonNil": false, "presentedSheetObserved": false,
                  "handler_conflictError": "UNKNOWN_NOT_EXPOSED",
                  "status": "NO_ATTACHED_SHEET_AT_THIS_INSTANT_NOT_HANDLER_VERDICT"])
            return
        }
        let member = host.sheets.contains { $0 === sheet }
        let number = sheet.windowNumber
        let localSameObject = NSApp.window(withWindowNumber: number) === sheet
        emit(["kind": "attached-sheet", "pid": getpid(), "hostWindowNumber": host.windowNumber,
              "attachedSheetNonNil": true, "sheetWindowNumber": number,
              "memberOfSameHostSheets": member, "sameNSAppWindowObject": localSameObject,
              "sheetParentIsHost": sheet.sheetParent === host,
              "sheetIdentifierEmpty": sheet.accessibilityIdentifier().isEmpty,
              "source": "host.attachedSheet typed NSWindow", "no_AXIdentifier_or_AXParent_requirement": true])
        guard member, number > 0, localSameObject, host.attachedSheet === sheet else {
            emit(["kind": "end", "complete": false, "status": "TYPED_SHEET_OWNERSHIP_UNKNOWN"])
            return
        }
        // Reads once, distinguishes unsupported/nil/type without exporting arbitrary content.
        func read(_ object: AnyObject, selectorName: String) -> (Any?, String) {
            guard let ns = object as? NSObject else { return (nil, "NOT_NSOBJECT") }
            let selector = NSSelectorFromString(selectorName)
            guard ns.responds(to: selector) else { return (nil, "SELECTOR_UNSUPPORTED") }
            guard let result = ns.perform(selector) else { return (nil, "RETURNED_NIL") }
            return (result.takeUnretainedValue(), "RETURNED_OBJECT")
        }
        func readRole(_ object: AnyObject) -> String? {
            if let role = (object as? NSAccessibilityProtocol)?.accessibilityRole() { return role.rawValue }
            return read(object, selectorName: "accessibilityRole").0 as? String
        }
        var queue: [(AnyObject, Int, Bool)] = [(sheet, 0, false)]
        var visited = Set<ObjectIdentifier>()
        var index = 0
        var complete = true
        var unknownRoles = 0
        var protectedNodes = 0
        var staticTitleMatches = 0
        var buttonTitleMatches = 0
        var actualTitleGetterCalls = 0
#if MINISCANVAS_SHORTCUT_ATTACHED_STATIC_VALUE_SUPPLEMENT
        var staticValueMatches = 0
        var actualStaticValueGetterCalls = 0
#else
        let staticValueMatches = 0
        let actualStaticValueGetterCalls = 0
#endif
        let anonymousAndSecretScalarGetterCalls = 0
        let buttonValueGetterCalls = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        while index < queue.count && visited.count < 2048 && ProcessInfo.processInfo.systemUptime < deadline {
            let (object, depth, inheritedProtected) = queue[index]
            index += 1
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let otherWindow = object as? NSWindow, otherWindow !== sheet {
                complete = false
                continue
            }
            let role = readRole(object)
            let identifier = settingsAXIdentifier(object)
            let protected = inheritedProtected || role == nil
                || role == "AXTextField" || role == "AXTextArea" || role == "AXSecureTextField"
                || identifier?.lowercased().contains("apikey") == true
                || identifier?.contains("ProviderEditSheet") == true
            if role == nil { unknownRoles += 1; complete = false }
            if protected { protectedNodes += 1 }
            // B2207 only permits role/identifier/title. Every input (not just anonymous)
            // and its descendants is excluded before any of the four scalar getters.
            if !protected && (role == "AXStaticText" || role == "AXButton") {
                actualTitleGetterCalls += 1
                let titleRead = read(object, selectorName: "accessibilityTitle")
                let title = titleRead.0 as? String
                let target = role == "AXStaticText" ? "快捷键冲突" : "知道了"
                let titleMatches = title == target
                if role == "AXStaticText" && titleMatches { staticTitleMatches += 1 }
                if role == "AXButton" && titleMatches { buttonTitleMatches += 1 }
                var fields: [String: Any] = ["kind": "typed-sheet-target-role", "pid": getpid(),
                    "hostWindowNumber": host.windowNumber, "sheetWindowNumber": number,
                    "role": role ?? "UNKNOWN", "identifier": identifier ?? "UNOBSERVED",
                    "titleGetterStatus": titleRead.1,
                    "titleType": titleRead.0 == nil ? "NIL_OR_UNSUPPORTED" : (title == nil ? "NON_STRING" : "STRING"),
                    "titleEqualsFixedTarget": titleMatches, "depth": depth,
                    "staticValueReadStatus": "UNOBSERVED_SCOPE_NOT_GRANTED"]
                // Pending narrow B supplement. Not enabled by the B2207 flag alone.
#if MINISCANVAS_SHORTCUT_ATTACHED_STATIC_VALUE_SUPPLEMENT
                if role == "AXStaticText" {
                    actualStaticValueGetterCalls += 1
                    let valueRead = read(object, selectorName: "accessibilityValue")
                    let value = valueRead.0 as? String
                    let matches = value == "快捷键冲突"
                    if matches { staticValueMatches += 1 }
                    fields["staticValueReadStatus"] = valueRead.1
                    fields["staticValueType"] = valueRead.0 == nil ? "NIL_OR_UNSUPPORTED" : (value == nil ? "NON_STRING" : "STRING")
                    fields["staticValueEqualsFixedTitle"] = matches
                    // NEVER export the actual value, including a nonmatching String.
                }
#endif
                emit(fields)
            }
            var children = settingsAXChildren(of: object)
            if let view = object as? NSView { children += view.subviews }
            if let ownSheet = object as? NSWindow, ownSheet === sheet, let content = ownSheet.contentView {
                children.append(content.superview ?? content)
            }
            let flat = settingsAXFlatten(children)
            guard depth < 24 || flat.isEmpty else { complete = false; continue }
            queue.append(contentsOf: flat.map { ($0 as AnyObject, depth + 1, protected) })
        }
        complete = complete && index == queue.count && host.attachedSheet === sheet
            && sheet.windowNumber == number && host.sheets.contains { $0 === sheet }
            && NSApp.window(withWindowNumber: number) === sheet
        emit(["kind": "end", "pid": getpid(), "hostWindowNumber": host.windowNumber,
              "sheetWindowNumber": number, "localTraversalWithinBounds": complete, "visited": visited.count,
              "publicAXCompleteness": "UNPROVEN_LOCAL_TYPED_READ_CHANNEL",
              "unknownRoles": unknownRoles, "protectedNodes": protectedNodes,
              "staticTitleMatches": staticTitleMatches, "buttonTitleMatches": buttonTitleMatches,
              "staticValueMatches": staticValueMatches, "actualTitleGetterCalls": actualTitleGetterCalls,
              "actualStaticValueGetterCalls": actualStaticValueGetterCalls,
              "anonymousAndSecretFourGetterCalls": anonymousAndSecretScalarGetterCalls,
              "buttonValueGetterCalls": buttonValueGetterCalls,
              "handler_conflictError": "UNKNOWN_NOT_EXPOSED",
              "status": complete ? "READONLY_OBSERVATION_NOT_BUSINESS_PASS" : "INCOMPLETE_UNKNOWN",
              "negativeTitleOrValueResultIsHandlerNil": false])
    }
}
#endif
// B2207_ATTACHED_SHEET_END

// BEGIN_B2257_SHARED_PURE_IMPLEMENTATION
// No AppKit or NSApp. This exact block is also compiled by the no-GUI controls.
private enum B2257FixedConflictTitlePolicy {
    static let fixedTitle = "快捷键冲突"
    struct SheetFacts {
        let attached: Bool
        let windowNumber: Int
        let memberOfHostSheets: Bool
        let sameNSAppWindowObject: Bool
        let sameAttachedObject: Bool
    }
    static func allowsLookup(label: String, pressable: Bool, textField: Bool) -> Bool {
        label == fixedTitle && !pressable && !textField
    }
    static func allowsSheet(_ facts: SheetFacts) -> Bool {
        facts.attached && facts.windowNumber > 0 && facts.memberOfHostSheets
            && facts.sameNSAppWindowObject && facts.sameAttachedObject
    }
    static func matchesValue(role: String?, protected: Bool, read: () -> Any?) -> Bool {
        guard role == "AXStaticText", !protected else { return false }
        guard let text = read() as? String else { return false }
        return text == fixedTitle
    }
    static func selectUnique<Node>(lookupAllowed: Bool, before: SheetFacts,
                                   after: SheetFacts, traversalWithinBounds: Bool,
                                   hits: [Node]) -> Node? {
        guard lookupAllowed, allowsSheet(before), allowsSheet(after),
              before.windowNumber == after.windowNumber,
              traversalWithinBounds, hits.count == 1 else { return nil }
        return hits[0]
    }
}
// END_B2257_SHARED_PURE_IMPLEMENTATION

// B2257_FIXED_TITLE_RUNTIME_BEGIN
@MainActor
private extension SettingsNativeInteractionConsumerTests {
    func findB2257FixedConflictTitle(in host: NSWindow, label: String,
                                     pressable: Bool, textField: Bool) -> AnyObject? {
        let lookupAllowed = B2257FixedConflictTitlePolicy.allowsLookup(
            label: label, pressable: pressable, textField: textField)
        guard lookupAllowed, let sheet = host.attachedSheet else { return nil }
        let capturedNumber = sheet.windowNumber
        func facts() -> B2257FixedConflictTitlePolicy.SheetFacts {
            .init(attached: host.attachedSheet != nil, windowNumber: sheet.windowNumber,
                  memberOfHostSheets: host.sheets.contains { $0 === sheet },
                  sameNSAppWindowObject: NSApp.window(withWindowNumber: sheet.windowNumber) === sheet,
                  sameAttachedObject: host.attachedSheet === sheet)
        }
        let before = facts()
        guard B2257FixedConflictTitlePolicy.allowsSheet(before) else { return nil }
        func roleOf(_ object: AnyObject) -> String? {
            if let role = (object as? NSAccessibilityProtocol)?.accessibilityRole() { return role.rawValue }
            return settingsAXGetter(object, selectorName: "accessibilityRole") as? String
        }
        var queue: [(AnyObject, Int, Bool)] = [(sheet, 0, false)]
        var visited = Set<ObjectIdentifier>()
        var index = 0
        var withinBounds = true
        var hits: [AnyObject] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        while index < queue.count && visited.count < 2048 && ProcessInfo.processInfo.systemUptime < deadline {
            let (object, depth, inheritedProtected) = queue[index]
            index += 1
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let otherWindow = object as? NSWindow, otherWindow !== sheet {
                withinBounds = false
                continue
            }
            let role = roleOf(object)
            let identifier = settingsAXIdentifier(object)
            let protected = inheritedProtected || role == nil
                || role == "AXTextField" || role == "AXTextArea" || role == "AXSecureTextField"
                || identifier?.lowercased().contains("apikey") == true
                || identifier?.contains("ProviderEditSheet") == true
            if role == nil { withinBounds = false }
            // The shared pure implementation excludes every non-StaticText role
            // before the real Value getter, including buttons and all protected descendants.
            if B2257FixedConflictTitlePolicy.matchesValue(role: role, protected: protected, read: {
                settingsAXGetter(object, selectorName: "accessibilityValue")
            }) { hits.append(object) }
            var children = settingsAXChildren(of: object)
            if let view = object as? NSView { children += view.subviews }
            if let ownSheet = object as? NSWindow, ownSheet === sheet, let content = ownSheet.contentView {
                children.append(content.superview ?? content)
            }
            let flat = settingsAXFlatten(children)
            guard depth < 24 || flat.isEmpty else { withinBounds = false; continue }
            queue.append(contentsOf: flat.map { ($0 as AnyObject, depth + 1, protected) })
        }
        withinBounds = withinBounds && index == queue.count && sheet.windowNumber == capturedNumber
        // No cache or diagnostic Boolean is returned as a target. A fresh exact,
        // unique hit returns only the actual observed StaticText object.
        return B2257FixedConflictTitlePolicy.selectUnique(
            lookupAllowed: lookupAllowed, before: before, after: facts(),
            traversalWithinBounds: withinBounds, hits: hits)
    }
}
// B2257_FIXED_TITLE_RUNTIME_END

@MainActor
private struct Command04ShortcutReferenceHost: View {
    let shortcuts: ShortcutStore
    let open: () -> Void
    var body: some View {
        Button("查看快捷键…", action: open)
            .shortcutKey(shortcuts.binding(for: .openShortcutReference))
    }
}
