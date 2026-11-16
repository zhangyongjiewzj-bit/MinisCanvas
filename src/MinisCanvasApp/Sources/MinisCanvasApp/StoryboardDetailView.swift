import SwiftUI
import CanvasCore

// MARK: - P2 分镜表工作台：右侧镜头详情（各 section：提示词 / 参考图 / 参考视频 / 审核 / 备注）
//
// 设计文档：issues/p2_storyboard_design_20260805.md §5.2 右详情
// 字段绑定 StoryboardRow；缩略图复用 CanvasStore.cachedImage（限幅解码 + NSCache）

/// 单个镜头的详情面板（选中分镜行后显示）。
struct StoryboardDetailView: View {
    let row: StoryboardRow
    let store: CanvasStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                section("提示词") {
                    Text(row.prompt.isEmpty ? "（无）" : row.prompt)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .foregroundStyle(row.prompt.isEmpty ? Color.secondary : Color.primary)
                }
                section("参考图") { imageGrid }
                section("参考视频") { videoList }
                section("审核") { reviewBlock }
                section("备注") {
                    Text(row.notes.isEmpty ? "（无）" : row.notes)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .foregroundStyle(row.notes.isEmpty ? Color.secondary : Color.primary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 头部（标题 / 镜号 / 状态徽标）

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", row.sceneIndex))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(row.reviewStatus.statusColor)
                    .frame(width: 8, height: 8)
                Text(row.reviewStatus.label)
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }

    // MARK: 参考图网格（前 9 张，限幅缩略图）

    private var imageGrid: some View {
        let paths = Array(row.imageRefs.prefix(9))
        if paths.isEmpty {
            return AnyView(placeholder("（无参考图）"))
        }
        return AnyView(
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    if let img = store.cachedImage(path: path) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 64)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .help(path)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .quaternaryLabelColor))
                            .frame(height: 64)
                            .overlay(Text("无预览").font(.system(size: 9)).foregroundStyle(.secondary))
                    }
                }
            }
        )
    }

    // MARK: 参考视频列表

    private var videoList: some View {
        if row.videoRefs.isEmpty {
            return AnyView(placeholder("（无参考视频）"))
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(row.videoRefs.enumerated()), id: \.offset) { _, path in
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .help(path)
                    }
                }
            }
        )
    }

    // MARK: 审核块（状态 + 打回意见）

    private var reviewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.reviewStatus.statusColor)
                    .frame(width: 8, height: 8)
                Text(row.reviewStatus.label)
                    .font(.system(size: 12, weight: .medium))
                Text("（\(row.reviewStatus.rawValue)）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if !row.notes.isEmpty {
                Text(row.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: 通用小件

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}
