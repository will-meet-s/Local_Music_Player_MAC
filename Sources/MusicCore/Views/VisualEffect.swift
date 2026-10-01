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
    /// 磨砂层自身的不透明度。调的只是背景 —— 前景文字和控件始终不受影响。
    public var opacity: Double

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        opacity: Double = 1
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.opacity = opacity
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.alphaValue = max(0, min(1, opacity))
    }
}

/// 让承载它的窗口变透明。
///
/// `.behindWindow` 模式要求窗口本身不是不透明的，否则模糊层背后是纯色窗口背景，
/// 看不到桌面 —— 磨砂就成了灰色板子。
///
/// T-018：**主窗口**额外加上 `fullSizeContentView` + 透明标题栏，让标题栏那一条
/// 和内容区显示同一层磨砂，不再单独着色（FR-031 ①②）。状态栏控制板是
/// `NSPanel`，不碰它（FR-031 ⑥）。
///
/// v2（F-23）：v1 只在窗口出现时设置过一次，SwiftUI 在窗口重新获得焦点、退出全屏、
/// 场景更新时会按自己记录的样式把这些设置改回默认值。这里把设置抽成 `configure`，
/// 在 `updateNSView` 和窗口的 `didBecomeKey`/`didExitFullScreen` 通知时都重新执行一遍
/// 作为兜底（幂等，重复执行没有副作用）；`WindowGroup` 这边另外加了
/// `.windowStyle(.hiddenTitleBar)`，让 SwiftUI 自己记录的样式本身就是这个样子。
struct TransparentWindow: NSViewRepresentable {

    /// F-24：`updateNSView` 在 SwiftUI 每次重绘时都会被调用（播放时每 0.1 秒一次）。
    /// 每一项都先判断是否已经是目标值，不同才赋值——已经设置过之后，这里每次都
    /// 直接返回、不触碰任何属性，不会让 AppKit 反复重排标题栏布局。
    private static func configure(_ window: NSWindow) {
        guard !(window is NSPanel) else { return } // 状态栏控制板不动（FR-031 ⑥）
        if window.isOpaque { window.isOpaque = false }
        if window.backgroundColor != .clear { window.backgroundColor = .clear }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden } // 「窗口」菜单里仍然显示「音乐播放器」
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none } // FR-031 ②：没有分隔线
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 插入视图层级时 window 还是 nil，延到下一个 runloop 再取
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            Self.configure(window)
            context.coordinator.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.configure(window)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    /// 持有 `didBecomeKey`/`didExitFullScreen` 的观察者令牌，`dismantleNSView` 时移除。
    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow) {
            guard tokens.isEmpty else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    guard let window else { return }
                    TransparentWindow.configure(window)
                })
            }
        }

        func stopObserving() {
            let center = NotificationCenter.default
            tokens.forEach(center.removeObserver)
            tokens.removeAll()
        }
    }
}

extension View {
    /// 给整个窗口铺上磨砂背景。T-018：`.ignoresSafeArea()` 加在磨砂层上，不是
    /// 整个视图树上——这样磨砂能铺到标题栏，但 `HeaderBar` 仍然乖乖排在标题栏
    /// 让出来的安全区下面，不会钻到三个窗口按钮底下（方案 §7 易踩的坑）。
    func frostedBackground(
        _ material: NSVisualEffectView.Material = .underWindowBackground,
        opacity: Double = 1
    ) -> some View {
        background(VisualEffectView(material: material, opacity: opacity).ignoresSafeArea())
            .background(TransparentWindow())
    }
}
