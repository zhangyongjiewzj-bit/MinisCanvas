import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MinisCore

/// 2026-11-16：工具返回的图片真正交给模型（file_read 读图片、MCP image 内容）。
struct ToolResultImagesTests {
    private static func pngData(width: Int = 8, height: Int = 8) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static let visionCaps = ModelCapabilities(supportedModalities: .vision, supportedAuth: [.apiKey])
    private static let textOnlyCaps = ModelCapabilities(supportedModalities: .textOnly, supportedAuth: [.apiKey])

    @Test func fileReadReturnsImageThroughSideChannelAndTextHasNoMarker() async throws {
        let root = try minisCoreToolContractRoot("x1-image").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pic.png")
        try Self.pngData().write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let output = try await executor.execute(name: "file_read", input: ["path": file.path])
        let extracted = ToolResultImageChannel.extract(from: output)
        #expect(extracted.images.count == 1)
        #expect(extracted.images.first?.mimeType == "image/png")
        #expect(extracted.text.contains("这是图片文件") && extracted.text.contains("8×8"))
        #expect(!extracted.text.contains("minis-tool-image"))
    }

    @Test func extractKeepsAtMostFourImagesAndReportsTheRest() throws {
        let png = try Self.pngData()
        let markers = try (0..<5).map { _ in try #require(ToolResultImageChannel.attach(data: png, mimeType: "image/png")) }
        let extracted = ToolResultImageChannel.extract(from: "结果\n" + markers.joined(separator: "\n"))
        #expect(extracted.images.count == 4)
        #expect(extracted.droppedForLimit == 1)
        #expect(extracted.text == "结果")
    }

    @Test func oversizedImageIsShrunkToLongEdge2000() throws {
        let big = try Self.pngData(width: 3000, height: 1000)
        let prepared = try #require(ToolResultImageChannel.prepare(data: big, mimeType: "image/png"))
        let size = try #require(MediaConversion.imagePixelSize(prepared.data))
        #expect(ToolResultImageChannel.maxLongEdge == 2000)
        #expect(max(size.width, size.height) <= ToolResultImageChannel.maxLongEdge)
    }

    /// 随机噪点 PNG，压缩不下去，用来造出超过 3.75 MB 的图。
    private static func noisePNG(side: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func toolImageByteCapIsBase64SafeAndOversizedPngIsShrunk() throws {
        #expect(ToolResultImageChannel.maxImageBytes == 5 * 1024 * 1024 * 3 / 4)
        let noisy = try Self.noisePNG(side: 1200)  // 1200×1200 随机像素，PNG 约 4.3 MB，超过 3.75 MB 且不到 5 MB
        #expect(noisy.count > ToolResultImageChannel.maxImageBytes)
        let prepared = try #require(ToolResultImageChannel.prepare(data: noisy, mimeType: "image/png"))
        #expect(prepared.data.count <= ToolResultImageChannel.maxImageBytes)
    }

    @Test func gifToolImageIsConvertedNotPassedThrough() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try #require(ToolResultImageChannel.prepare(data: output as Data, mimeType: "image/gif"))
        #expect(prepared.mimeType == "image/png" || prepared.mimeType == "image/jpeg")
    }

    @Test func anthropicToolResultCarriesImageBlock() throws {
        let message = LLMMessage(role: .tool, content: "截图完成", images: [
            .init(mimeType: "image/png", data: try Self.pngData())], toolCallID: "call_1")
        let dict = AnthropicProvider.anthropicMessageDict(message, mediaCapabilities: Self.visionCaps)
        let blocks = try #require(dict["content"] as? [[String: Any]])
        let result = try #require(blocks.first)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "image"])
        #expect((content[1]["source"] as? [String: Any])?["type"] as? String == "base64")
        // 没有图片时保持原来的字符串内容。
        let plain = AnthropicProvider.anthropicMessageDict(LLMMessage(role: .tool, content: "ok", toolCallID: "c"))
        #expect(((plain["content"] as? [[String: Any]])?.first?["content"] as? String) == "ok")
    }

    @Test func openAIAppendsUserMessageWithImageAfterToolMessages() throws {
        let call = LLMToolCall(id: "call_1", name: "file_read", rawArguments: "{}", arguments: [:])
        let messages = [
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: "这是图片文件", images: [.init(mimeType: "image/png", data: try Self.pngData())],
                       toolCallID: "call_1"),
        ]
        let items = OpenAICompatibleProvider.openAIRequestMessages(messages, mediaCapabilities: Self.visionCaps)
        #expect(items.count == 3)
        #expect(items[1]["role"] as? String == "tool" && items[1]["content"] as? String == "这是图片文件")
        #expect(items[2]["role"] as? String == "user")
        let parts = try #require(items[2]["content"] as? [[String: Any]])
        #expect(parts.contains { $0["type"] as? String == "image_url" })
        #expect(parts.contains { ($0["text"] as? String) == "[工具 file_read 返回的图片]" })
        // 不支持图片输入的模型：追加的 user 消息里没有图片块。
        let textOnly = OpenAICompatibleProvider.openAIRequestMessages(messages, mediaCapabilities: Self.textOnlyCaps)
        let textOnlyParts = try #require(textOnly[2]["content"] as? [[String: Any]])
        #expect(!textOnlyParts.contains { $0["type"] as? String == "image_url" })
    }

    @Test func historyKeepsRecentImagesWithinBudgetAndAlwaysTheNewest() throws {
        let png = try Self.pngData()
        func toolMessage(_ id: String) -> LLMMessage {
            LLMMessage(role: .tool, content: "x", images: [.init(mimeType: "image/png", data: png)], toolCallID: id)
        }
        var messages = (0..<5).map { toolMessage("c\($0)") }
        ToolResultImageChannel.pruneHistoryImages(&messages, maxImages: 3, maxBytes: 1_000_000)
        #expect(messages.map { $0.images.count } == [0, 0, 1, 1, 1])
        // 即使单条就超出字节预算，最新一条的图片仍然保留。
        var tiny = [toolMessage("a"), toolMessage("b")]
        ToolResultImageChannel.pruneHistoryImages(&tiny, maxImages: 8, maxBytes: 1)
        #expect(tiny.map { $0.images.count } == [0, 1])
    }

    @Test func browserScreenshotOutputWithImageMarkerStillDecodesAsSucceeded() throws {
        let png = try Self.pngData()
        let response = try BrowserToolResponse.succeeded(
            action: "screenshot", scopeID: "scope-1", result: "Screenshot saved to: /tmp/browser_1.jpg")
        let marker = try #require(ToolResultImageChannel.attach(data: png, mimeType: "image/png"))
        let split = ToolResultImageChannel.splitTrailingMarkers(response + "\n" + marker)
        let terminal = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName, input: ["action": "screenshot"], output: split.body))
        #expect(terminal.status == .succeeded && !terminal.isError)
        #expect(ToolResultImageChannel.extract(from: terminal.feedback + split.markers).images.count == 1)
    }

    @Test func historyHandedToCallersCarriesNoToolImages() throws {
        let messages = [LLMMessage(role: .tool, content: "x", images: [.init(mimeType: "image/png", data: try Self.pngData())],
                                   toolCallID: "c")]
        #expect(AgentLoop.withoutToolImages(messages).allSatisfy { $0.images.isEmpty })
    }
}
