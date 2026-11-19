import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore

/// SwiftUI 拖放落地的内容：本地文件优先，其次图片数据（浏览器拖图），最后才是网页链接。
enum ComposerDropItem: Transferable, Sendable {
    case fileURL(URL)
    case imageData(Data)
    case webURL(URL)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { (data: Data) -> ComposerDropItem in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ComposerDropItem.fileURL(url)
        }
        DataRepresentation(importedContentType: .image) { (data: Data) -> ComposerDropItem in
            ComposerDropItem.imageData(data)
        }
        DataRepresentation(importedContentType: .url) { (data: Data) -> ComposerDropItem in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ComposerDropItem.webURL(url)
        }
    }
}

extension ComposerPasteboardAttachments {
    /// 把拖来的图片数据写成临时 PNG（与粘贴图片同一目录，落地时统一编号）。
    static func stageImageData(_ datas: [Data], imageDirectory: URL = defaultImageDirectory()) -> [URL] {
        guard !datas.isEmpty else { return [] }
        removeStaleImagesIfDue(in: imageDirectory)
        let directory = imageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return [] }
        var urls: [URL] = []
        for (index, data) in datas.enumerated() {
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            else { continue }
            let destination = directory.appendingPathComponent("粘贴的图片 \(index + 1).png", isDirectory: false)
            if (try? png.write(to: destination, options: .atomic)) != nil { urls.append(destination) }
        }
        return urls
    }
}

extension ChatStore {
    /// SwiftUI 拖放入口（主输入框、侧栏输入区）：和粘贴共用 addDroppedURLs。
    @MainActor
    @discardableResult
    func addDroppedItems(_ items: [ComposerDropItem]) -> Bool {
        var urls: [URL] = []
        var images: [Data] = []
        for item in items {
            switch item {
            case .fileURL(let url), .webURL(let url): urls.append(url)
            case .imageData(let data): images.append(data)
            }
        }
        let staged = ComposerPasteboardAttachments.stageImageData(images)
        if !images.isEmpty, staged.isEmpty { noteComposerInputFeedback("这张图片无法读取，请先保存到本地再拖入") }
        return addDroppedURLs(urls + staged)
    }
}

/// @ 引用的文件和目录清单：git 仓库用 git ls-files（遵守 .gitignore，含隐藏文件），
/// 否则遍历目录；按根目录缓存一小段时间，连续输入不重复扫盘。真密钥文件不进清单。
enum FileMentionIndex {
    struct Entry: Sendable {
        let path: String
        let lowerPath: String
        let lowerName: String
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: (date: Date, entries: [Entry])] = [:]
        func entries(for key: String, maxAge: TimeInterval) -> [Entry]? {
            lock.lock(); defer { lock.unlock() }
            guard let item = items[key], Date().timeIntervalSince(item.date) < maxAge else { return nil }
            return item.entries
        }
        func store(_ entries: [Entry], for key: String) {
            lock.lock(); defer { lock.unlock() }
            if items.count >= 8, let oldest = items.min(by: { $0.value.date < $1.value.date })?.key {
                items.removeValue(forKey: oldest)
            }
            items[key] = (Date(), entries)
        }
    }

    private static let cache = Cache()
    private static let scanLocksGuard = NSLock()
    nonisolated(unsafe) private static var scanLocks: [String: NSLock] = [:]
    private static func scanLock(for key: String) -> NSLock {
        scanLocksGuard.lock(); defer { scanLocksGuard.unlock() }
        if let existing = scanLocks[key] { return existing }
        let created = NSLock()
        scanLocks[key] = created
        return created
    }
    private static let maxFiles = 50_000
    private static let cacheSeconds: TimeInterval = 20

    static func candidates(root: String, query: String, limit: Int) -> [String] {
        // 先解析符号链接，枚举出的路径才与前缀一致（/var 与 /private/var）。
        let rootURL: URL
        if let resolved = realpath(root, nil) {
            rootURL = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else {
            rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
        }
        let entries: [Entry]
        if let cached = cache.entries(for: rootURL.path, maxAge: cacheSeconds) {
            entries = cached
        } else {
            // 同一个根目录上同时只扫一次：后来的调用等前一次扫完，直接用它存下的清单。
            let rootScanLock = scanLock(for: rootURL.path)
            rootScanLock.lock()
            defer { rootScanLock.unlock() }
            guard !Task.isCancelled else { return [] }
            if let cached = cache.entries(for: rootURL.path, maxAge: cacheSeconds) {
                entries = cached
            } else {
                let paths = gitFiles(rootURL: rootURL) ?? walkedFiles(rootURL: rootURL)
                guard !Task.isCancelled else { return [] }
                entries = makeEntries(files: paths)
                cache.store(entries, for: rootURL.path)
            }
        }
        let needle = query.lowercased()
        var scored: [(path: String, score: Int)] = []
        for entry in entries {
            let score: Int
            if needle.isEmpty { score = 0 }
            else if entry.lowerName.hasPrefix(needle) || entry.lowerPath.hasPrefix(needle) { score = 0 }
            else if entry.lowerName.contains(needle) { score = 1 }
            else if entry.lowerPath.contains(needle) { score = 2 }
            else { continue }
            scored.append((entry.path, score))
        }
        return scored.sorted {
            ($0.score, $0.path.count, $0.path) < ($1.score, $1.path.count, $1.path)
        }.prefix(limit).map(\.path)
    }

    /// 文件列表 + 它们的各级父目录（目录以 / 结尾）；真密钥文件不列出。
    private static func makeEntries(files: [String]) -> [Entry] {
        var directories: Set<String> = []
        var result: [Entry] = []
        result.reserveCapacity(files.count + files.count / 8)
        for file in files where !SensitiveFilePolicy.contains("/" + file) {
            result.append(Entry(path: file, lowerPath: file.lowercased(),
                                lowerName: (file as NSString).lastPathComponent.lowercased()))
            var parts = file.split(separator: "/").dropLast().map(String.init)
            while !parts.isEmpty {
                let directory = parts.joined(separator: "/") + "/"
                if !directories.insert(directory).inserted { break }
                parts.removeLast()
            }
        }
        for directory in directories {
            let trimmed = String(directory.dropLast())
            result.append(Entry(path: directory, lowerPath: directory.lowercased(),
                                lowerName: (trimmed as NSString).lastPathComponent.lowercased()))
        }
        return result
    }

    private static func hasGitMetadata(near rootURL: URL) -> Bool {
        var url = rootURL
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }

    private static func gitFiles(rootURL: URL) -> [String]? {
        guard hasGitMetadata(near: rootURL),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 仓库自带的 core.fsmonitor 会执行命令，这里显式关闭。
        process.arguments = ["-C", rootURL.path, "-c", "core.fsmonitor=false",
                             "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let pid = process.processIdentifier
        let killer = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        var files: [String] = []
        for chunk in data.split(separator: 0) {
            guard let name = String(data: Data(chunk), encoding: .utf8), !name.isEmpty else { continue }
            files.append(name)
            if files.count >= maxFiles { break }
        }
        return files
    }

    private static func walkedFiles(rootURL: URL) -> [String] {
        let skipNames: Set<String> = [
            "node_modules", ".build", "DerivedData", "Pods", "build", "dist", "target",
            "venv", "__pycache__", "vendor", ".git"
        ]
        guard let walker = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return [] }
        let prefix = rootURL.path + "/"
        var files: [String] = []
        var visited = 0
        while let url = walker.nextObject() as? URL {
            visited += 1
            if visited > maxFiles || Task.isCancelled { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipNames.contains(name) { walker.skipDescendants() }
                continue
            }
            guard name != ".DS_Store", url.path.hasPrefix(prefix) else { continue }
            files.append(String(url.path.dropFirst(prefix.count)))
        }
        return files
    }
}

@MainActor
enum PastedTextComposerConsumer {
    /// Returns true only when the long paste was accepted into ChatStore.
    /// Short text remains owned by NSTextView's native paste path.
    @discardableResult
    static func accept(_ event: ComposerPasteEvent, in chat: ChatStore) -> Bool {
        if !event.attachmentURLs.isEmpty {
            // 粘贴与拖放共用同一个落地函数（只收本地文件，临时图片编号）。
            return chat.addDroppedURLs(event.attachmentURLs)
        }
        guard PastedTextPolicy.shouldCollapse(event.draft) else { return false }
        // Accepting a separate reference is not an edit or clear of an
        // unchanged body. Real body changes retain the draft persistence path.
        if chat.draftText != event.bodyBefore {
            chat.draftText = event.bodyBefore
        }
        return chat.setPastedTextDraft(event.draft)
    }

    @discardableResult
    static func save(
        _ draft: PastedTextDraft,
        expectedSessionID: UUID,
        expectedDraftID: UUID,
        in chat: ChatStore
    ) -> Bool {
        chat.updatePastedTextDraft(
            draft,
            expectedSessionID: expectedSessionID,
            expectedDraftID: expectedDraftID
        )
    }

    @discardableResult
    static func remove(
        expectedSessionID: UUID,
        expectedDraftID: UUID,
        in chat: ChatStore
    ) -> Bool {
        chat.removePastedTextDraft(
            expectedSessionID: expectedSessionID,
            expectedDraftID: expectedDraftID
        )
    }

    static func intentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        sessionReadIntentInput(body: body, pastedText: pastedText)
    }

    /// Reference material is never an authorization signal. Only the typed
    /// body and an explicit instruction capsule may enter intent matching.
    static func sessionReadIntentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        PastedTextPolicy.sessionReadIntentInput(body: body, pastedText: pastedText)
    }

    static func commandInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        PastedTextPolicy.commandInput(body: body, pastedText: pastedText)
    }

    static func submissionSnapshot(
        capsuleID: UUID,
        sessionID: UUID,
        body: String,
        pastedText: PastedTextDraft
    ) -> PastedTextSubmissionSnapshot {
        PastedTextSubmissionSnapshot(
            capsuleID: capsuleID,
            sessionID: sessionID,
            body: body,
            pastedText: pastedText
        )
    }
}

/// Bounded summary for long pasted text; the full payload remains outside the view.
struct PastedTextCapsuleView: View {
    static let accessibilityIdentifier = "composer.pasted-text.capsule"

    let draft: PastedTextDraft
    @Environment(\.themeTokens) private var theme
    let onPreview: () -> Void
    let onRemove: () -> Void

    init(
        draft: PastedTextDraft,
        onPreview: @escaping () -> Void = {},
        onRemove: @escaping () -> Void = {}
    ) {
        self.draft = draft
        self.onPreview = onPreview
        self.onRemove = onRemove
    }

    private var summary: PastedTextSummary {
        PastedTextPolicy.summary(for: draft.text)
    }

    var body: some View {
        HStack(spacing: 6) {
            MinisIconView(.document, size: MinisIconTokens.defaultSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(draft.kind == .instruction ? "粘贴指令" : "粘贴参考")
                    .font(.caption.weight(.medium))
                Text("\(summary.characterCount) 字符 · \(summary.lineCount) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !summary.preview.isEmpty {
                    Text(InvisibleCharacterPolicy.visible(summary.preview).replacingOccurrences(of: "\n", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPreview) {
                MinisIconView(.eye, size: MinisIconTokens.smallSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑粘贴文本")
            .accessibilityIdentifier("composer.pasted-text.preview")
            .help("预览并编辑粘贴文本")

            Button(action: onRemove) {
                MinisIconView(.remove, size: MinisIconTokens.smallSize, accessibilityLabel: "删除粘贴文本")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除粘贴文本")
            .accessibilityIdentifier("composer.pasted-text.remove")
            .help("删除粘贴文本")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(draft.kind == .instruction ? "粘贴指令摘要" : "粘贴参考摘要")
        .accessibilityValue("\(summary.characterCount) 字符，\(summary.lineCount) 行")
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

struct PastedTextEditorState: Identifiable {
    let id: UUID
    let sessionID: UUID
    let draft: PastedTextDraft

    init(sessionID: UUID, draft: PastedTextDraft) {
        self.id = draft.id
        self.sessionID = sessionID
        self.draft = draft
    }
}

struct PastedTextCapsuleEditor: View {
    @Bindable var chat: ChatStore
    let state: PastedTextEditorState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeTokens) private var theme
    @State private var text: String

    init(chat: ChatStore, state: PastedTextEditorState) {
        self.chat = chat
        self.state = state
        _text = State(initialValue: state.draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑粘贴文本")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 460, minHeight: 260)
                .accessibilityIdentifier("composer.pasted-text.editor")
                .accessibilityLabel("粘贴文本编辑器")

            if let notice = InvisibleCharacterPolicy.notice(in: [text]) {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.pasted-text.invisible-characters")
            }

            if let feedback = chat.pastedTextActionFeedback {
                Text(feedback)
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("composer.pasted-text.feedback")
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                Button("删除", role: .destructive) {
                    delete()
                }
                .accessibilityIdentifier("composer.pasted-text.delete")

                Spacer()

                Button("取消") {
                    chat.clearPastedTextActionFeedback()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("composer.pasted-text.cancel")

                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("composer.pasted-text.save")
            }
        }
        .padding(16)
        .onAppear {
            chat.clearPastedTextActionFeedback()
        }
    }

    private func save() {
        let updated = PastedTextDraft(
            id: state.draft.id,
            text: text,
            source: state.draft.source,
            kind: state.draft.kind
        )
        guard PastedTextComposerConsumer.save(
            updated,
            expectedSessionID: state.sessionID,
            expectedDraftID: state.draft.id,
            in: chat
        ) else { return }
        dismiss()
    }

    private func delete() {
        guard PastedTextComposerConsumer.remove(
            expectedSessionID: state.sessionID,
            expectedDraftID: state.draft.id,
            in: chat
        ) else { return }
        dismiss()
    }
}

/// Transcript projection for sent pasted material. Expansion is explicit and
/// the owning session is responsible for accepting the toggle.
struct PastedTextReferenceCardView: View {
    let card: PastedTextReferenceCard
    let isSessionCurrent: Bool
    let onToggle: () -> Void

    private var cardKindLabel: String {
        card.kind == .instruction ? "指令" : "参考"
    }

    /// Keep transcript elements unique across sessions and capsules while
    /// retaining a stable prefix for focused automation selectors.
    private var cardIdentity: String {
        "\(card.sessionID.uuidString).\(card.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                MinisIconView(.document, size: 14)
                    .accessibilityHidden(true)
                Text("粘贴\(cardKindLabel)")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(card.characterCount) 字符 · \(card.lineCount) 行")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(card.isExpanded ? "收起\(cardKindLabel)" : "展开\(cardKindLabel)", action: onToggle)
                    .buttonStyle(.link)
                    .font(.system(size: 10, weight: .medium))
                    .disabled(!isSessionCurrent)
                    .accessibilityLabel(card.isExpanded ? "收起粘贴\(cardKindLabel)" : "展开粘贴\(cardKindLabel)")
                    .accessibilityValue(isSessionCurrent ? "当前会话" : "会话已切换，已锁定")
                    .accessibilityIdentifier("chat.pasted-reference-card.toggle.\(cardIdentity)")
                    .help(card.isExpanded ? "收起粘贴\(cardKindLabel)" : "展开粘贴\(cardKindLabel)")
            }
            if !card.instruction.isEmpty {
                Text(card.instruction)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
            }
            Text(card.renderedMaterial)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(card.isExpanded ? nil : 4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "粘贴\(cardKindLabel)，\(card.stateLabel)，\(card.characterCount) 字符"
        )
        .accessibilityValue(isSessionCurrent ? "当前会话" : "会话已切换，已锁定")
        .accessibilityIdentifier("chat.pasted-reference-card.\(cardIdentity)")
    }
}
