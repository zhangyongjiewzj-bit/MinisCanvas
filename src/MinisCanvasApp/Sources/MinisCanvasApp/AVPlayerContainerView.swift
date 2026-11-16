import SwiftUI
import AVKit

/// AVPlayerView（AppKit）包装：替代 SwiftUI `VideoPlayer`。
///
/// 背景：macOS 26.5.2（SwiftUI 7.5.3 / arm64e）上 SwiftUI `VideoPlayer`
/// （底层 `_AVKit_SwiftUI` 桥）**首次渲染即崩溃**：
/// `__swift_instantiateGenericMetadata → getSuperclassMetadata → fatalError → abort()`
/// （用户 2026-08-06 实测：点文件里的 MP3 崩溃 PID 88298，主线程渲染事务内触发）。
/// 这是 Swift 泛型元数据初始化在 _AVKit_SwiftUI 私有桥层的框架级问题，
/// 与具体媒体类型无关——任何首次渲染 VideoPlayer 的操作都会崩。
/// AVPlayerView 是纯 AppKit 类（ObjC 层，无 Swift 泛型元数据参与），
/// 自包装为 NSViewRepresentable 即可规避。
///
/// 用法与原 VideoPlayer 一致：`AVPlayerContainerView(url:).frame(...)`
struct AVPlayerContainerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // 仅当 URL 变化时更换 player（避免每次 body 更新重置播放位置）。
        let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            nsView.player = AVPlayer(url: url)
        }
    }
}
