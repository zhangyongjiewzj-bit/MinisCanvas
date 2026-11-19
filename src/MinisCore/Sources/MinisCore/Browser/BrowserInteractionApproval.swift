import Foundation
import Observation

/// Intent parsed by the existing gate; no model-provided risk/domain is read.
public struct BrowserInteractionInput: Sendable, Equatable {
    public let action: String
    public let selector: String
    public let filePath: String?
    public init(action: String, selector: String, filePath: String? = nil) {
        self.action = action; self.selector = selector; self.filePath = filePath
    }
    public static func parse(tool: String, input: [String: Any]) -> Self? {
        guard BrowserSideEffectPolicy.browserToolNames.contains(tool.lowercased()),
              let action = input["action"] as? String, ["click", "type", "download", "upload"].contains(action),
              let selector = input["selector"] as? String, !selector.isEmpty else { return nil }
        if ["download", "upload"].contains(action), input["path"] as? String == nil { return nil }
        return Self(action: action, selector: selector, filePath: input["path"] as? String)
    }
    public var category: BrowserInteractionCategory { action == "upload" ? .upload : (action == "download" ? .download : (action == "type" ? .input : .click)) }
}

/// Conservative categories: even a plain-looking field/button can submit data.
public enum BrowserInteractionCategory: String, Codable, Hashable, Sendable {
    case input, click, download, upload
    public var title: String {
        switch self {
        case .input: return "输入（可能包含密码或支付信息）"
        case .click: return "点击（可能提交表单或产生不可撤销效果）"
        case .download: return "下载到指定文件（写入本机）"
        case .upload: return "上传指定文件（向网页披露文件内容）"
        }
    }
}

public struct BrowserInteractionRule: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable { case always, bypass }
    public let id: UUID
    public let origin: URL
    public var domain: String { origin.host ?? "" }
    public let category: BrowserInteractionCategory
    public let mode: Mode
    public let confirmedAt: Date
}

/// A browser-specific extension to the existing approval decision chain.
/// It never mints a write grant: the original gate/redeemer still does that.
@MainActor @Observable
public final class BrowserInteractionRuleStore {
    public private(set) var rules: [BrowserInteractionRule] = []
    private var fileURL: URL?
    public init() {}
    public func attach(fileURL: URL) {
        guard self.fileURL == nil else { return }
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([BrowserInteractionRule].self, from: data) {
            rules = loaded
        }
    }
    public func match(origin: URL, category: BrowserInteractionCategory, bypass: Bool) -> BrowserInteractionRule? {
        rules.first { BrowserNavigationPolicy.sameOrigin($0.origin, origin) && $0.category == category
            && ($0.mode == .always || bypass) }
    }
    @discardableResult
    public func confirm(origin: URL, category: BrowserInteractionCategory,
                        mode: BrowserInteractionRule.Mode) -> BrowserInteractionRule? {
        guard BrowserNavigationPolicy.isValidWebURL(origin), origin.user == nil, origin.password == nil else { return nil }
        let rule = BrowserInteractionRule(id: UUID(), origin: origin, category: category,
                                         mode: mode, confirmedAt: Date())
        let updated = rules.filter { !(BrowserNavigationPolicy.sameOrigin($0.origin, rule.origin) && $0.category == category && $0.mode == mode) } + [rule]
        guard persist(updated) else { return nil }
        rules = updated
        return rule
    }
    public func contains(_ id: UUID) -> Bool { rules.contains { $0.id == id } }
    public func revoke(_ id: UUID) {
        let updated = rules.filter { $0.id != id }
        guard persist(updated) else { return }
        rules = updated
    }
    private func persist(_ updated: [BrowserInteractionRule]) -> Bool {
        guard let fileURL else { return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            return true
        } catch { return false }
    }
}

public struct BrowserInteractionTarget: Equatable, Sendable {
    public let identity: BrowserSessionIdentity
    public let pageURL: String
    public let domain: String
    public let origin: URL
    public let fingerprint: String
    public let submissionURL: String?
    public var transferFile: BrowserTransferFileIdentity? = nil
    public var uploadFieldName: String? = nil
    public let input: BrowserInteractionInput
}

public enum BrowserInteractionError: Error { case unavailable, prohibitedTarget, changedTarget, missingApproval }

extension BrowserSession {
    /// Reads only target facts, never input values or page instructions.
    public func interactionTarget(_ input: BrowserInteractionInput, fileAccess: BrowserTransferFileAccess? = nil) async throws -> BrowserInteractionTarget {
        let expected = identity
        guard let url = currentURL(), BrowserNavigationPolicy.isValidWebURL(url),
              let domain = url.host?.lowercased(), !domain.isEmpty,
              url.user == nil, url.password == nil else { throw BrowserInteractionError.unavailable }
        var originComponents = URLComponents()
        originComponents.scheme = url.scheme?.lowercased()
        originComponents.host = domain
        originComponents.port = url.port
        guard let origin = originComponents.url else { throw BrowserInteractionError.unavailable }
        let selector = Self.interactionLiteral(input.selector)
        let action = Self.interactionLiteral(input.action)
        let transferFile: BrowserTransferFileIdentity?
        if let path = input.filePath, ["download", "upload"].contains(input.action) {
            transferFile = try await BrowserTransferFileIdentity.capture(path: path, upload: input.action == "upload", access: fileAccess ?? BrowserTransferFileAccessContext.current ?? transferFileAccess)
        } else { transferFile = nil }
        let script = """
        (() => {
          const el = document.querySelector(\(selector));
          if (!el) return JSON.stringify({denied:true});
          const chain = [el, ...Array.from((el.closest('form') || el).querySelectorAll('iframe'))];
          const metadata = chain.map(e => [e.id,e.getAttribute('name'),e.getAttribute('title'),e.getAttribute('src'),e.getAttribute('aria-label')].join(' ')).join(' ');
          const captcha = /captcha|recaptcha|hcaptcha|turnstile|人机验证|验证码/i.test(metadata);
          const type = (el.getAttribute('type') || '').toLowerCase();
          const editable = el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !['hidden','file','submit','button','image','reset','checkbox','radio'].includes(type));
          const urlField = type === 'url' || /(^|[-_])(url|uri|href|location|addressbar)([-_]|$)/i.test(el.getAttribute('name') || el.id || '');
          const link = el.closest('a[href]');
          const href = link ? new URL(link.href, location.href) : null;
          const form = el.form || el.closest('form');
          const submits = \(action) === 'click' && form && (el.tagName === 'BUTTON' || ['submit','image'].includes(type));
          const submitURL = submits ? new URL(el.getAttribute('formaction') || form.action, location.href) : null;
          const badForm = submits && ((form.method || 'get').toLowerCase() !== 'post' || submitURL.origin !== location.origin || submitURL.search || submitURL.hash || submitURL.username || submitURL.password);
          const badLink = href && (!['http:','https:'].includes(href.protocol) || href.username || href.password);
          const transfer = ['download','upload'].includes(\(action));
          // Native prototype getters in an isolated content world avoid named
          // controls such as id/name=action replacing form.action.
          const native = (proto, key, node) => Object.getOwnPropertyDescriptor(proto, key).get.call(node);
          const uploadForm = \(action) === 'upload' && el instanceof HTMLInputElement ? native(HTMLInputElement.prototype, 'form', el) : null;
          const formValue = key => uploadForm ? native(HTMLFormElement.prototype, key, uploadForm) : null;
          const uploadURL = uploadForm ? new URL(formValue('action'), location.href) : null;
          const uploadMethod = formValue('method');
          const uploadEncoding = formValue('enctype');
          const uploadTarget = formValue('target');
          const uploadName = el.getAttribute('name') || '';
          const validURL = u => u && ['http:','https:'].includes(u.protocol) && u.origin === location.origin && !u.search && !u.hash && !u.username && !u.password;
          const controls = uploadForm ? Array.from(native(HTMLFormElement.prototype, 'elements', uploadForm)) : [];
          const submitters = controls.filter(e => (e.tagName === 'BUTTON' && (e.getAttribute('type') || 'submit').toLowerCase() === 'submit') || (e.tagName === 'INPUT' && ['submit','image'].includes((e.getAttribute('type') || '').toLowerCase())));
          const overrides = submitters.map(e => [e.getAttribute('formaction'), e.getAttribute('formmethod'), e.getAttribute('formenctype'), e.getAttribute('formtarget'), e.getAttribute('name')]);
          const badSubmitter = submitters.some(e =>
            (e.hasAttribute('formaction') && (!validURL(new URL(e.getAttribute('formaction'), location.href)) || new URL(e.getAttribute('formaction'), location.href).href !== uploadURL.href)) ||
            (e.hasAttribute('formmethod') && e.getAttribute('formmethod').toLowerCase() !== 'post') ||
            (e.hasAttribute('formenctype') && e.getAttribute('formenctype').toLowerCase() !== 'multipart/form-data') ||
            (e.hasAttribute('formtarget') && !['','_self'].includes(e.getAttribute('formtarget').toLowerCase())) || e.hasAttribute('name'));
          const reservedName = /^(action|method|enctype|encoding|target|elements|submit|requestSubmit|length|name)$/i;
          const unsupportedControls = controls.some(e => e !== el && !submitters.includes(e));
          const uploadFormDenied = !uploadForm || !validURL(uploadURL) || uploadMethod !== 'post' || uploadEncoding !== 'multipart/form-data' || !['','_self'].includes(uploadTarget.toLowerCase()) ||
            !/^[A-Za-z0-9_.-]{1,128}$/.test(uploadName) || reservedName.test(uploadName) || reservedName.test(el.id) || unsupportedControls || badSubmitter;
          const badTransfer = \(action) === 'upload' ? (uploadFormDenied || !(el.tagName === 'INPUT' && type === 'file' && !el.multiple && !el.webkitdirectory && document.querySelectorAll('input[type=file]').length === 1)) : (\(action) === 'download' && (!href || href.origin !== location.origin || href.search || href.hash));
          const denied = captcha || badTransfer || (!transfer && form && form.querySelector('input[type="file"]')) || el.disabled || el.hidden || !el.getClientRects().length || badForm || badLink || (\(action) === 'type' && (!editable || el.readOnly || urlField));
          const fingerprint = \(action) === 'upload'
            ? JSON.stringify([el.tagName,type,el.id,uploadName,uploadURL && uploadURL.href,uploadMethod,uploadEncoding,uploadTarget,overrides])
            : JSON.stringify([el.tagName,type,el.id,el.getAttribute('name'),el.getAttribute('formaction'),form && form.method,form && form.action,href && href.href]);
          return JSON.stringify({denied:!!denied,url:location.href,fingerprint,uploadFieldName: uploadName, submissionURL: \(action) === 'upload' ? uploadURL && uploadURL.href : (\(action) === 'download' ? href && href.href : submitURL && submitURL.href)});
        })()
        """
        let raw: String
        if input.action == "upload" { raw = try await isolatedInteractionFacts(script) }
        else { raw = try await executeJavaScript(script) }
        guard accepts(expected), let data = raw.data(using: .utf8),
              let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              facts["denied"] as? Bool == false, facts["url"] as? String == url.absoluteString,
              let fingerprint = facts["fingerprint"] as? String else { throw BrowserInteractionError.prohibitedTarget }
        var target = BrowserInteractionTarget(identity: expected, pageURL: url.absoluteString,
                                        domain: domain, origin: origin, fingerprint: fingerprint, submissionURL: facts["submissionURL"] as? String, input: input)
        target.transferFile = transferFile
        target.uploadFieldName = input.action == "upload" ? facts["uploadFieldName"] as? String : nil
        return target
    }

    static func interactionLiteral(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}

public struct BrowserPreparedInteraction {
    let target: BrowserInteractionTarget
    let inputDigest: String
    let notice: String?
    let automaticCategory: BrowserInteractionCategory?
    let ruleID: UUID?
    let rules: BrowserInteractionRuleStore
}

/// 用户在审批卡上"本次允许"的网站（应用运行期间有效，不写设置）。
/// `GoalEnvelope.permitsNetworkDomain` 会一并认可它，所以同一次浏览器调用不会再被网站白名单拦下。
public final class BrowserDomainApproval: @unchecked Sendable {
    public static let shared = BrowserDomainApproval()
    private let lock = NSLock()
    private var hosts: Set<String> = []

    public func allow(host: String) {
        guard let normalized = BrowserNavigationPolicy.normalizedHost(host) else { return }
        lock.lock(); defer { lock.unlock() }
        hosts.insert(normalized)
    }

    public func permits(host: String) -> Bool {
        guard let normalized = BrowserNavigationPolicy.normalizedHost(host) else { return false }
        lock.lock(); defer { lock.unlock() }
        return hosts.contains(normalized)
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        hosts.removeAll()
    }
}

public enum BrowserInteractionApproval {
    /// 用户选"以后都允许该网站"时，把域名写入现有的"允许访问的网站"设置。
    /// 由 App 在装配时设置；未设置时审批卡不提供"以后都允许"。
    @MainActor public static var persistAllowedDomain: (@MainActor (String) -> Void)?

    /// 对齐 Claude Code：访问未允许的网站时弹审批卡，而不是直接拒绝。
    @MainActor
    static func decideUnlistedDomain(_ original: ApprovalRequest, destination: URL,
                                     session: BrowserSession,
                                     delegate: any ApprovalDelegate) async -> ApprovalDecision {
        guard let host = destination.host.flatMap(BrowserNavigationPolicy.normalizedHost) else {
            return ApprovalDecision(approved: false, reason: "网址缺少有效的主机名，无法访问",
                requestID: original.requestID, bindingDigest: original.identityDigest)
        }
        var request = original
        request.persistentAllowOffer = persistAllowedDomain == nil ? nil : ApprovalPersistentAllowOffer(
            capability: "browser_domain", summary: host, unavailableReason: nil)
        let decision = await delegate.requestApproval(request)
        guard decision.approved, decision.confirmed,
              decision.requestID == request.requestID,
              decision.bindingDigest == request.identityDigest,
              !Task.isCancelled else {
            return decision.approved
                ? ApprovalDecision(approved: false, reason: "审批已失效，未访问该网站",
                    requestID: original.requestID, bindingDigest: original.identityDigest)
                : decision
        }
        BrowserDomainApproval.shared.allow(host: host)
        _ = session.authorizeNavigation(to: destination)
        if decision.persistAllow { persistAllowedDomain?(host) }
        return ApprovalDecision(approved: true, reason: decision.reason, confirmed: true,
                                requestID: original.requestID, bindingDigest: original.identityDigest)
    }

    /// Runs inside the existing production delegate. Approved results still pass
    /// through gate validation, receipt publication and the original redeemer.
    @MainActor
    public static func decide(_ original: ApprovalRequest, session: BrowserSession,
                              rules: BrowserInteractionRuleStore,
                              delegate: any ApprovalDelegate) async -> ApprovalDecision {
        if let destination = original.browserNavigationDestination {
            let decision = session.navigationDecision(for: destination, source: .initial)
            if decision == .deny(.domainNotAuthorized) || decision == .deny(.crossOriginNotAuthorized) {
                return await decideUnlistedDomain(original, destination: destination,
                                                  session: session, delegate: delegate)
            }
        }
        guard let input = original.browserInteractionInput else {
            return await delegate.requestApproval(original)
        }
        func deny() -> ApprovalDecision {
            ApprovalDecision(approved: false, reason: "浏览器目标不可用、已变化或不允许操作",
                             requestID: original.requestID, bindingDigest: original.identityDigest)
        }
        guard let digest = original.inputDigest,
              let target = try? await session.interactionTarget(input) else { return deny() }
        let bypass = original.composerMode == ComposerTaskMode.bypassPermission.rawValue
        let transfer = input.category == .upload || input.category == .download
        if !transfer, !original.isHookAsk,
           let rule = rules.match(origin: target.origin, category: input.category, bypass: bypass) {
            session.prepareAutomaticInteraction(callID: original.callID, target: target,
                inputDigest: digest, rule: rule, rules: rules)
            return ApprovalDecision(approved: true, reason: "已按站点和动作类别放行", confirmed: true,
                                    requestID: original.requestID, bindingDigest: original.identityDigest)
        }
        var request = original
        request.browserRiskWarning = "之后智能体在 \(target.origin.absoluteString) 里执行\(input.category.title)时将不再询问你；页面内容可能诱导误操作；你可以随时在 设置 › 智能体运行 › 工具审批 中撤销。"
            + (bypass ? "本次确认将为此站点、此动作类别开启绕过。" : "只有选择以后都允许并确认风险才会保存放行。")
        if !transfer, !request.isHookAsk {
            request.persistentAllowOffer = ApprovalPersistentAllowOffer(
                capability: "browser", summary: "\(target.origin.absoluteString) · \(input.category.title)", unavailableReason: nil)
        }
        if let file = target.transferFile {
            request.browserRiskWarning = "\(input.category.title)：\(file.path)。文件身份：\(file.fingerprint)。"
                + (input.action == "upload" ? "仅向已批准同源标准表单发送无Cookie原生POST，文件不交给网页脚本；服务器会看到文件内容。" : "仅写入已批准的新输出文件；最终保存位置就是上面显示的路径，即使在项目目录之外，你批准后也会写到那里。")
                + "取消或失败不自动重试；POST失败仍可能已传输部分或全部字节。"
            request.persistentAllowOffer = nil
        }
        let decision = await delegate.requestApproval(request)
        guard decision.approved, decision.confirmed,
              decision.requestID == request.requestID,
              decision.bindingDigest == request.identityDigest,
              !Task.isCancelled,
              let current = try? await session.interactionTarget(input), current == target else { return deny() }
        var rule: BrowserInteractionRule?
        if !transfer && !request.isHookAsk && (decision.persistAllow || bypass) && decision.browserRiskConfirmed {
            rule = rules.confirm(origin: target.origin, category: input.category, mode: bypass ? .bypass : .always)
            guard rule != nil else { return deny() }
        }
        session.prepareInteraction(callID: original.callID, target: target, inputDigest: digest,
                                   notice: nil, rule: rule, rules: rules)
        // The browser rule was handled here; do not send it to the unrelated
        // shell/file persistent-rule matcher.
        return ApprovalDecision(approved: true, reason: decision.reason, confirmed: true,
                                requestID: original.requestID, bindingDigest: original.identityDigest)
    }
}
