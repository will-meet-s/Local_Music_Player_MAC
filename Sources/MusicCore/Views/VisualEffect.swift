import SwiftUI
import AppKit

/// 把 AppKit 的 `NSVisualEffectView` 桥接进 SwiftUI —— 系统的磨砂/毛玻璃背景。
///
/// SwiftUI 自带的 `.ultraThinMaterial` 只在**同一窗口内**的图层之间模糊，
/// 拿不到窗口背后的桌面内容。要做整窗磨砂必须用 `NSVisualEffectView`
/// 配 `.behindWindow` 混合模式。
public struct VisualEffectView: NSViewRepresentable {

    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    /// `.active` 表示窗口失焦时也保持磨砂；`.followsWindowActiveState` 则会变灰。
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// 让承载它的窗口变透明。
///
/// `.behindWindow` 模式要求窗口本身不是不透明的，否则模糊层背后是纯色窗口背景，
/// 看不到桌面 —— 磨砂就成了灰色板子。标题栏保持系统默认样式，它自己会画出
/// 与内容区一致的材质。
struct TransparentWindow: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 插入视图层级时 window 还是 nil，延到下一个 runloop 再取
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// 给整个窗口铺上磨砂背景。
    func frostedBackground(_ material: NSVisualEffectView.Material = .underWindowBackground) -> some View {
        background(VisualEffectView(material: material))
            .background(TransparentWindow())
    }
}
