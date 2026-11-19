import Foundation

/// 流式回复的增量脱敏。
///
/// 旧做法每个片段都把整条回复重新跑一遍全部密钥规则（整条累计 O(n²)）。这里把
/// 回复拆成三段：
/// 1. 已提交前缀 `committed`：已经脱敏、不再重扫。边界只放在换行之后，并且保证
///    没有任何规则的匹配能跨过这条边界（见 `commitOffset`）。
/// 2. 尾部 `tail`：边界之后的原文，每个片段只重扫这一小段。
/// 3. 尾部里"可能还是密钥前半段"的末端被扣住不显示（见 `analyze`），到下一个
///    边界、遇到空白或回合结束时才显示。显示出去的文字因此不含密钥前半段。
///
/// 回合结束时由调用方对整条原文做一次全量脱敏并以全量为准（`finalize` 的职责在
/// ChatCredentialBroker）；`settledProjection` 是"增量结果在全部放开后"的等价物，
/// 必须与全量脱敏逐字节一致，测试据此验证。
///
/// 为什么换行是安全边界（匹配不会跨它）：
/// - 引号值、查询参数、赋值、Cookie、URL userinfo、各 gitleaks 单词规则都不含换行；
/// - 会跨换行的只有三类：`Authorization:`/`api_key:` 头在名字与冒号、冒号与值之间的
///   `\s*`，`Bearer\s+`，以及 private key 整块。前两类用"换行前最后一个非空白字符
///   是冒号或这些关键字结尾"排除，第三类用 private key 匹配区间排除；
/// - 已知密钥值若自身含换行则不提交（始终在尾部整体处理）。
public struct IncrementalSecretRedactor: Sendable {
    public struct Update: Sendable, Equatable {
        public let text: String
        /// 新显示文本是否以上一次显示文本为前缀（决定行内工具锚点是否仍有效）。
        public let extendsPrevious: Bool

        public init(text: String, extendsPrevious: Bool) {
            self.text = text
            self.extendsPrevious = extendsPrevious
        }
    }

    /// 到目前为止收到的全部原文（回合结束做全量脱敏用）。
    public private(set) var rawText: String
    private var committed: String
    private var tail: [UInt8]
    /// 尾部里这个偏移之前的文字视为已经显示过（初始 surface、整体替换、锚点定稿）。
    private var floor: Int
    private var displayedEnd: Int
    private var tailDisplay: String
    /// 上一次 `append` 使用的已知密钥集合（中途新增时要对已提交前缀补扫）。
    private var lastKnown: [String] = []

    public init() {
        rawText = ""
        committed = ""
        tail = []
        floor = 0
        displayedEnd = 0
        tailDisplay = ""
    }

    /// 从已在界面上的（已脱敏）文本继续：`surface` 视为已显示，`withheld` 是上一段
    /// 流被终止时扣住、尚未显示的已脱敏文本。
    public init(surface: String, withheld: String = "") {
        rawText = surface + withheld
        committed = ""
        tail = Array(rawText.utf8)
        floor = surface.utf8.count
        displayedEnd = floor
        tailDisplay = surface
    }

    public var displayedText: String { committed + tailDisplay }

    public mutating func append(_ text: String, knownSecrets: [String]) -> Update {
        rawText.append(text)
        tail.append(contentsOf: text.utf8)
        let known = Self.usable(knownSecrets)
        if known != lastKnown {
            reabsorbCommitted(ifContainingNewIn: known)
            lastKnown = known
        }
        let analysis = Self.analyze(tail: tail, known: known)
        var hold = analysis.hold
        let previous = tailDisplay
        var segment = ""
        let boundary = Self.commitOffset(
            tail: tail, limit: hold, forbidden: analysis.forbidden, known: known)
        if boundary > 0 {
            segment = ContentSecretRedactor.redact(
                Self.string(tail[0..<boundary]), knownSecrets: known)
            committed.append(segment)
            tail.removeSubrange(0..<boundary)
            floor = max(0, floor - boundary)
            hold -= boundary
        }
        let end = min(tail.count, max(hold, floor))
        tailDisplay = end == 0 ? "" : ContentSecretRedactor.redact(
            Self.string(tail[0..<end]), knownSecrets: known)
        displayedEnd = end
        let extends = segment.isEmpty
            ? tailDisplay.utf8.starts(with: previous.utf8)
            : (segment + tailDisplay).utf8.starts(with: previous.utf8)
        return Update(text: committed + tailDisplay, extendsPrevious: extends)
    }

    /// 已知密钥集合在流中途新增：已提交前缀不再重扫，若其中含新值，把它并回尾部按新集合重算。
    private mutating func reabsorbCommitted(ifContainingNewIn known: [String]) {
        guard !committed.isEmpty else { return }
        let added = known.filter { !lastKnown.contains($0) }
        guard added.contains(where: { committed.contains($0) }) else { return }
        let bytes = Array(committed.utf8)
        tail = bytes + tail
        floor = bytes.count + displayedEnd
        displayedEnd = floor
        committed = ""
    }

    /// 放开尾部（工具调用边界前定稿显示位置）。之后的新文字不会把这部分再扣回去。
    /// 尾部若仍可能是密钥（前缀、未闭合的头/私钥块、已知密钥前缀），保持扣住：
    /// 锚点落在已显示文字之后，被扣住的部分留待后续片段或终态处理。
    public mutating func settle(knownSecrets: [String]) -> Update {
        let known = Self.usable(knownSecrets)
        let previous = tailDisplay
        floor = max(floor, suspectStart(known: known) ?? tail.count)
        displayedEnd = floor
        tailDisplay = floor == 0 ? "" : ContentSecretRedactor.redact(
            Self.string(tail[0..<floor]), knownSecrets: known)
        return Update(text: committed + tailDisplay,
                      extendsPrevious: tailDisplay.utf8.starts(with: previous.utf8))
    }

    /// 整体替换（进度类消息）：直接显示全量脱敏结果，不扣尾。
    public mutating func replace(with text: String, knownSecrets: [String]) -> String {
        let known = Self.usable(knownSecrets)
        rawText = text
        committed = ""
        tail = Array(text.utf8)
        floor = tail.count
        displayedEnd = tail.count
        tailDisplay = ContentSecretRedactor.redact(text, knownSecrets: known)
        return tailDisplay
    }

    /// 增量结果在全部放开之后的形态。必须与 `ContentSecretRedactor.redact(rawText)`
    /// 逐字节一致（初始为空串开始、已知密钥不变时）。
    public func settledProjection(knownSecrets: [String]) -> String {
        let known = Self.usable(knownSecrets)
        let rest = tail.isEmpty ? "" : ContentSecretRedactor.redact(
            Self.string(tail[...]), knownSecrets: known)
        return committed + rest
    }

    /// 已提交前缀（已脱敏，以换行结尾或为空）；只读访问，不改任何规则。
    public var committedText: String { committed }

    /// `settledProjection` 中除已提交前缀之外的部分：`committedText + settledTailProjection == settledProjection`。
    public func settledTailProjection(knownSecrets: [String]) -> String {
        let known = Self.usable(knownSecrets)
        return tail.isEmpty ? "" : ContentSecretRedactor.redact(
            Self.string(tail[...]), knownSecrets: known)
    }

    /// 终态投影（停止、出错、安全锁、完成共用）：与 `settledProjection` 相同，但被扣住的
    /// 尾部若可能是残缺的密钥，整段并入正文前先遮蔽为掩码；无法判断的普通文字照常放出。
    public func terminalProjection(knownSecrets: [String]) -> String {
        let known = Self.usable(knownSecrets)
        guard let start = suspectStart(known: known) else {
            return settledProjection(knownSecrets: knownSecrets)
        }
        let head = start == 0 ? "" : ContentSecretRedactor.redact(
            Self.string(tail[0..<start]), knownSecrets: known)
        return committed + head + ContentSecretRedactor.mask(Self.string(tail[start...]))
    }

    /// 尚未显示的尾部（已脱敏）。流被终止、托管撤销前取走，供后续继续拼接。
    /// 可能是残缺密钥的部分同样先遮蔽。
    public func withheldRedacted(knownSecrets: [String]) -> String {
        guard displayedEnd < tail.count else { return "" }
        let known = Self.usable(knownSecrets)
        if let start = suspectStart(known: known) {
            if start <= displayedEnd {
                return ContentSecretRedactor.mask(Self.string(tail[displayedEnd...]))
            }
            return ContentSecretRedactor.redact(
                Self.string(tail[displayedEnd..<start]), knownSecrets: known)
                + ContentSecretRedactor.mask(Self.string(tail[start...]))
        }
        return ContentSecretRedactor.redact(Self.string(tail[displayedEnd...]), knownSecrets: known)
    }

    // MARK: - 疑似密钥前缀

    /// 被扣住的尾部若可能是密钥的一部分，返回它的起点；否则 nil。
    private func suspectStart(known: [String]) -> Int? {
        guard !tail.isEmpty else { return nil }
        let hold = Self.analyze(tail: tail, known: known).hold
        guard hold < tail.count else { return nil }
        return Self.looksLikeSecretPrefix(tail: tail, hold: hold, known: known) ? hold : nil
    }

    private static let secretHeadExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(?:sk-|sk_|rk_|ghp_|gho_|ghu_|ghs_|github_pat_|AKIA|ASIA|A3T|ABIA|ACCA|xox[abeoprs]?-?|glpat-|pypi-|npm_)"#)
    private static let sensitiveAssignmentExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:api[_-]?key|apikey|key|token|auth|password|secret|cookie|session[_-]?id)[A-Za-z0-9_\-]*=."#)

    private static func looksLikeSecretPrefix(tail: [UInt8], hold: Int, known: [String]) -> Bool {
        let count = tail.count
        var run = count
        while run > 0, tail[run - 1] > 0x20, tail[run - 1] < 0x7F { run -= 1 }
        // 起点早于末尾 ASCII 串：由头部/引号值/私钥块/已知密钥跨度扣住，一律视为疑似。
        if hold < run { return true }
        // 已知密钥的前缀（≥4 字节）。
        for value in known {
            let bytes = Array(value.utf8)
            var k = min(bytes.count - 1, count)
            while k >= 4 {
                if tail[(count - k)...].elementsEqual(bytes[0..<k]) { return true }
                k -= 1
            }
        }
        guard run < count else { return false }
        let word = string(tail[run...])
        let range = NSRange(location: 0, length: word.utf16.count)
        if secretHeadExpression.firstMatch(in: word, range: range) != nil { return true }
        if sensitiveAssignmentExpression.firstMatch(in: word, range: range) != nil { return true }
        // `Bearer ` / `Basic ` 之后正在到达的值。
        var j = run
        while j > 0, isSpace(tail[j - 1]) { j -= 1 }
        if j < run {
            for name in ["bearer", "basic"].map({ Array($0.utf8) }) where j >= name.count {
                var same = true
                for n in 0..<name.count where lower(tail[j - name.count + n]) != name[n] {
                    same = false
                    break
                }
                if same { return true }
            }
        }
        return false
    }

    // MARK: - 提交边界

    private static let sensitiveEndings: [[UInt8]] = [
        "bearer", "authorization", "apikey", "api_key", "api-key",
    ].map { Array($0.utf8) }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// 以 `end` 结尾的那个 UTF-8 标量若是非 ASCII 空白，返回它的字节数，否则 0。
    private static func unicodeSpaceWidth(_ tail: [UInt8], endingAt end: Int) -> Int {
        guard end > 0, tail[end - 1] >= 0x80 else { return 0 }
        var start = end - 1
        while start > 0, end - start < 4, tail[start] & 0xC0 == 0x80 { start -= 1 }
        let scalars = String(decoding: tail[start..<end], as: UTF8.self).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, scalar.properties.isWhitespace else { return 0 }
        return end - start
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// 返回最大的可提交偏移（某个换行之后），没有则 0。
    private static func commitOffset(
        tail: [UInt8], limit: Int, forbidden: [(lo: Int, hi: Int)], known: [String]
    ) -> Int {
        if known.contains(where: { $0.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) }) { return 0 }
        var i = min(limit, tail.count) - 1
        while i >= 0 {
            if tail[i] == 0x0A, isEligible(tail: tail, newline: i, forbidden: forbidden) {
                return i + 1
            }
            i -= 1
        }
        return 0
    }

    private static func isEligible(
        tail: [UInt8], newline i: Int, forbidden: [(lo: Int, hi: Int)]
    ) -> Bool {
        let boundary = i + 1
        for block in forbidden where boundary > block.lo && boundary < block.hi { return false }
        var j = i
        while j > 0 {
            if isSpace(tail[j - 1]) { j -= 1; continue }
            // 与全量规则的 `\s` 同口径：NBSP、全角空格、U+2000–200A 等 Unicode 空白也跳过。
            let width = unicodeSpaceWidth(tail, endingAt: j)
            if width == 0 { break }
            j -= width
        }
        guard j > 0 else { return true }
        if tail[j - 1] == 0x3A { return false } // ':' —— 值可能在下一行
        for word in sensitiveEndings where j >= word.count {
            var same = true
            for n in 0..<word.count where lower(tail[j - word.count + n]) != word[n] {
                same = false
                break
            }
            if same { return false }
        }
        return true
    }

    // MARK: - 扣住尾部

    private struct Analysis {
        var hold: Int
        var forbidden: [(lo: Int, hi: Int)]
    }

    private static let headerOpener = try! NSRegularExpression(
        pattern: #"(?i)(?:api[_-]?key|x-api-key|proxy-authorization|authorization|(?<![A-Za-z0-9_])(?:set-)?cookie)\s*:\s*"#)
    private static let quotedOpener = try! NSRegularExpression(
        pattern: #"(?i)(?:key|token|auth|password|secret|cookie|session[_-]?id)[A-Za-z0-9_\-]*=["']"#)
    private static let privateKeyHeader = try! NSRegularExpression(
        pattern: #"(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----"#)

    /// 计算尾部里"从哪个偏移起的文字不能显示"，以及不可提交的跨行区间。
    private static func analyze(tail: [UInt8], known: [String]) -> Analysis {
        let count = tail.count
        guard count > 0 else { return Analysis(hold: 0, forbidden: []) }
        var forbidden: [(lo: Int, hi: Int)] = []

        // 1. 末尾连续的 ASCII 非空白串：可能是密钥正在到达（sk-…、ghp_…、Bearer 后的令牌、
        //    key=value、URL userinfo 都不含空白）。中文等非 ASCII 字符会截断这段，
        //    所以中文长段落不会被整段扣住。
        var run = count
        while run > 0, tail[run - 1] > 0x20, tail[run - 1] < 0x7F { run -= 1 }
        var hold = run

        // 2. 已知密钥值的前缀（值里可含空白或中文，上面的规则管不到）。
        for value in known {
            let bytes = Array(value.utf8)
            var k = min(bytes.count - 1, count)
            while k >= 1 {
                if tail[(count - k)...].elementsEqual(bytes[0..<k]) {
                    hold = min(hold, count - k)
                    break
                }
                k -= 1
            }
        }

        // 3. 匹配范围可以含空白的规则：值还没结束就整段扣住。
        let text = string(tail[...])
        let length = text.utf16.count
        let whole = NSRange(location: 0, length: length)
        let ascii = text.utf8.count == length
        func offset(_ utf16Location: Int) -> Int {
            if ascii { return utf16Location }
            let index = String.Index(utf16Offset: utf16Location, in: text)
            return text.utf8.distance(from: text.utf8.startIndex, to: index)
        }

        // 3. 匹配范围可以含空白的规则：只要一段这样的匹配"起点在可显示区内、终点越过
        //    显示边界"，就把显示边界退回到它的起点，直到稳定。end 是匹配的不含端点。
        var spans: [(start: Int, end: Int)] = []
        func lineEnd(from index: Int) -> Int {
            var i = index
            while i < count {
                if tail[i] == 0x0A || tail[i] == 0x0D { return i }
                i += 1
            }
            return Int.max
        }

        // 3-0. 已知密钥值本身：值里可含空白，尾部的"最后一个词"边界可能切在它中间。
        let nsText = text as NSString
        for value in known {
            var location = 0
            while location < length {
                let found = nsText.range(
                    of: value, options: .literal,
                    range: NSRange(location: location, length: length - location))
                if found.location == NSNotFound { break }
                spans.append((start: offset(found.location), end: offset(found.location + found.length)))
                location = found.location + max(found.length, 1)
            }
        }
        // 3a. `Authorization: …` / `Cookie: …`：值到行尾为止。
        for match in headerOpener.matches(in: text, range: whole) {
            let valueStart = offset(match.range.location + match.range.length)
            spans.append((start: offset(match.range.location), end: lineEnd(from: valueStart)))
        }
        // 3b. `name="…` / `name='…`：到闭合引号（含）或行尾为止。
        for match in quotedOpener.matches(in: text, range: whole) {
            let valueStart = offset(match.range.location + match.range.length)
            let quote = tail[valueStart - 1]
            var end = Int.max
            var index = valueStart
            while index < count {
                let byte = tail[index]
                if byte == quote { end = index + 1; break }
                if byte == 0x0A || byte == 0x0D { end = index; break }
                index += 1
            }
            spans.append((start: offset(match.range.location), end: end))
        }
        // 3c. private key 整块跨行：完整匹配的区间不可提交；只有头部没有结尾的整块无限扣住。
        if text.contains("-----") {
            let blocks = GitleaksSecretRules.privateKeyExpression
                .matches(in: text, range: whole)
                .map { (lo: offset($0.range.location), hi: offset($0.range.location + $0.range.length)) }
            forbidden.append(contentsOf: blocks)
            for block in blocks { spans.append((start: block.lo, end: block.hi)) }
            for header in privateKeyHeader.matches(in: text, range: whole) {
                let start = offset(header.range.location)
                if !blocks.contains(where: { $0.lo <= start && start < $0.hi }) {
                    forbidden.append((lo: start, hi: Int.max))
                    spans.append((start: start, end: Int.max))
                }
            }
        }
        var changed = true
        while changed {
            changed = false
            for span in spans where span.start < hold && span.end > hold {
                hold = span.start
                changed = true
            }
        }
        return Analysis(hold: hold, forbidden: forbidden)
    }

    private static func usable(_ values: [String]) -> [String] {
        values.filter { !$0.isEmpty }
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
