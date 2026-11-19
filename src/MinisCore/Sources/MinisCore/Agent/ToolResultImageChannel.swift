import Foundation
import ImageIO
import Vision

/// 工具结果携带图片的旁路通道（对齐 Claude Code：Read 能读图片，MCP 工具返回的图片模型能看到）。
///
/// 工具执行器只返回字符串，所以图片不走返回值：产生图片的工具（file_read 读图片文件、
/// MCP 的 image 内容）调用 `attach` 把图片放进进程内暂存区，并在返回文字末尾带上一行
/// 一次性标记。AgentLoop 组装工具结果消息前用 `extract` 取走标记对应的图片并把标记从文字
/// 中去掉；标记只在内存里生效，从不写进会话文件。
public enum ToolResultImageChannel {
    /// 单次工具结果最多交给模型的图片张数。
    public static let maxImagesPerResult = 4
    /// 单张图片超过这个字节数或长边超过 `maxLongEdge` 时先缩小。
    /// Anthropic 的 5 MB 按 base64 编码后计算，原始字节须 ≤ 5 MB × 3/4；与输入框图片同值（`ChatStore.maxUploadImageBytes`）。
    public static let maxImageBytes = 5 * 1024 * 1024 * 3 / 4
    /// 取 2000：一次请求超过 20 张图时 Anthropic 要求每张边长都不超过 2000 像素。
    public static let maxLongEdge = 2000

    private static let markerPrefix = "[[minis-tool-image:"
    private static let markerSuffix = "]]"
    private static let storeLimit = 32
    private static let storeLifetime: TimeInterval = 600

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: (image: LLMMessage.ImageAttachment, storedAt: Date)] = [:]
    }
    private static let store = Store()

    /// 把一张图片放进暂存区，返回要附在工具文字结果末尾的标记；图片无法使用时返回 nil。
    /// 过大的图片会先缩小（超过 3.75 MB 或长边超过 2000）。
    public static func attach(data: Data, mimeType: String) -> String? {
        guard MediaPartKind.classify(mimeType: mimeType) == .rasterImage,
              let prepared = prepare(data: data, mimeType: mimeType) else { return nil }
        let id = UUID().uuidString
        let now = Date()
        store.lock.lock()
        store.items = store.items.filter { now.timeIntervalSince($0.value.storedAt) < storeLifetime }
        if store.items.count >= storeLimit,
           let oldest = store.items.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            store.items.removeValue(forKey: oldest)
        }
        store.items[id] = (LLMMessage.ImageAttachment(mimeType: prepared.mimeType, data: prepared.data), now)
        store.lock.unlock()
        return markerPrefix + id + markerSuffix
    }

    /// 丢弃已经附上、但最终不会交给模型的图片（工具报错或被取消时调用，避免暂存区残留）。
    public static func discard(markers: [String]) {
        guard !markers.isEmpty else { return }
        store.lock.lock()
        for marker in markers where marker.hasPrefix(markerPrefix) && marker.hasSuffix(markerSuffix) {
            let id = String(marker.dropFirst(markerPrefix.count).dropLast(markerSuffix.count))
            store.items.removeValue(forKey: id)
        }
        store.lock.unlock()
    }

    /// 缩小到不超过 3.75 MB、长边不超过 2000；已经满足时原样返回。
    /// GIF 不原样放行（各线路只认 PNG/JPEG/WebP），走转码取首帧。
    static func prepare(data: Data, mimeType: String) -> (data: Data, mimeType: String)? {
        guard let size = MediaConversion.imagePixelSize(data) else { return nil }
        let passThroughTypes: Set<String> = ["image/png", "image/jpeg", "image/webp"]
        if data.count <= maxImageBytes, max(size.width, size.height) <= maxLongEdge,
           passThroughTypes.contains(mimeType.lowercased()) {
            return (data, mimeType.lowercased())
        }
        switch MediaConversion.convertImageForUpload(data, maxBytes: maxImageBytes, maxPixel: maxLongEdge) {
        case .success(let converted): return converted
        case .failure: return nil
        }
    }

    // MARK: - 历史图片保留预算

    /// 请求里保留的工具图片上限：最多 8 张、合计不超过 12 MB（从最新一条往前数）。
    public static let historyImageCountBudget = 8
    public static let historyImageByteBudget = 12 * 1024 * 1024

    /// 只保留最近的工具图片：从最新的工具消息往前累计张数和字节，超出预算的更早消息整条摘掉图片。
    /// 最新一条工具消息的图片始终保留，所以刚返回的图一定能被模型看到。
    public static func pruneHistoryImages(
        _ messages: inout [LLMMessage],
        maxImages: Int = historyImageCountBudget,
        maxBytes: Int = historyImageByteBudget
    ) {
        var keptImages = 0
        var keptBytes = 0
        var newestKept = false
        for position in messages.indices.reversed() where messages[position].role == .tool {
            let images = messages[position].images
            guard !images.isEmpty else { continue }
            let bytes = images.reduce(0) { $0 + $1.data.count }
            if !newestKept || (keptImages + images.count <= maxImages && keptBytes + bytes <= maxBytes) {
                newestKept = true
                keptImages += images.count
                keptBytes += bytes
            } else {
                messages[position].images = []
            }
        }
    }

    // MARK: - 本地文字识别（非视觉模型）

    /// 用系统 Vision 对每张图做本地文字识别，返回合并后的文字（每张最多 4000 字）；识别不到返回空串。
    public static func recognizeText(in images: [LLMMessage.ImageAttachment]) async -> String {
        await Task.detached(priority: .utility) {
            var sections: [String] = []
            for (offset, image) in images.enumerated() {
                guard let text = recognizeTextSync(data: image.data), !text.isEmpty else { continue }
                sections.append(images.count > 1 ? "[图 \(offset + 1)]\n\(text)" : text)
            }
            return sections.joined(separator: "\n")
        }.value
    }

    static func recognizeTextSync(data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        func run(languages: [String]?) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let languages { request.recognitionLanguages = languages }
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        let lines = (try? run(languages: ["zh-Hans", "zh-Hant", "en-US"])) ?? (try? run(languages: nil)) ?? []
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : String(joined.prefix(4000))
    }

    /// 把末尾连续的图片标记行与正文分开，方便调用方对正文做限长、脱敏后再原样接回标记。
    public static func splitTrailingMarkers(_ text: String) -> (body: String, markers: String) {
        guard text.contains(markerPrefix) else { return (text, "") }
        var lines = text.components(separatedBy: "\n")
        var markers: [String] = []
        while let last = lines.last, last.hasPrefix(markerPrefix), last.hasSuffix(markerSuffix) {
            markers.insert(last, at: 0)
            lines.removeLast()
        }
        guard !markers.isEmpty else { return (text, "") }
        return (lines.joined(separator: "\n"), "\n" + markers.joined(separator: "\n"))
    }

    /// 取走文字里所有有效标记对应的图片，并把标记从文字里去掉。找不到图片的标记（伪造或已过期）只去掉标记，不产生图片。
    /// 超过 `maxImagesPerResult` 的图片被丢弃，数量写进 `droppedForLimit`。
    public static func extract(from text: String) -> (text: String, images: [LLMMessage.ImageAttachment], droppedForLimit: Int) {
        guard text.contains(markerPrefix) else { return (text, [], 0) }
        // 只认结果末尾的标记行；正文里碰巧出现的同样文字（例如读到的文件内容）原样保留。
        let split = splitTrailingMarkers(text)
        guard !split.markers.isEmpty else { return (text, [], 0) }
        var images: [LLMMessage.ImageAttachment] = []
        var dropped = 0
        for line in split.markers.components(separatedBy: "\n") where line.hasPrefix(markerPrefix) && line.hasSuffix(markerSuffix) {
            let id = String(line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count))
            store.lock.lock()
            let found = store.items.removeValue(forKey: id)
            store.lock.unlock()
            // 找不到图片的标记（伪造或已过期）只去掉标记，不产生图片。
            guard let found else { continue }
            if images.count < maxImagesPerResult { images.append(found.image) } else { dropped += 1 }
        }
        var output = split.body
        while output.hasSuffix("\n") { output.removeLast() }
        return (output, images, dropped)
    }
}
