#if os(macOS)
import AppKit
import AVFoundation

/// Draws the picture of the TV channel AVPlayer is playing.
private final class VideoView: NSView {
    private let playerLayer = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player; playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    var onToggleFullScreen: (() -> Void)?
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onToggleFullScreen?() } else { super.mouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The classic-skinned window that shows an Internet TV channel, like Winamp's video window.
final class VideoController: NSWindowController {
    private let root: ClassicChrome
    private let placed: Bool
    private let engine: RadioEngine
    private let video: VideoView
    private let closeButton: ClassicWindowButton
    private var restore: (frame: NSRect, level: NSWindow.Level, options: NSApplication.PresentationOptions)?
    static let frameName = "RadioPocket.Video"

    init(engine: RadioEngine) {
        self.engine = engine
        placed = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") != nil
        let size = NSSize(width: 499, height: 304)
        let window = PlayerWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RadioPocket — Video"
        window.minSize = NSSize(width: 259, height: 164); window.isUserResizable = true
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        root = ClassicChrome(frame: NSRect(origin: .zero, size: size)); root.title = "VIDEO"
        video = VideoView(player: engine.player)
        closeButton = ClassicWindowButton(title: "×", target: nil, action: #selector(dismiss))
        super.init(window: window)
        window.contentView = root
        video.frame = NSRect(x: 11, y: 20, width: size.width - 19, height: size.height - 34)
        video.autoresizingMask = [.width, .height]
        root.addSubview(video)
        let close = closeButton
        close.frame = NSRect(x: size.width - 12, y: 3, width: 9, height: 9); close.autoresizingMask = [.minXMargin]
        close.isBordered = false; close.setAccessibilityLabel("Close video"); root.addSubview(close)
        close.target = self
        video.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        video.onEscape = { [weak self] in if self?.restore != nil { self?.toggleFullScreen() } }
        window.setFrameAutosaveName(Self.frameName)
    }

    /// Fills the screen with just the picture; borderless windows can't use the system full-screen space.
    private func toggleFullScreen() {
        guard let window, let root = window.contentView else { return }
        if let saved = restore {
            restore = nil
            NSApp.presentationOptions = saved.options
            window.level = saved.level
            window.setFrame(saved.frame, display: true)
            video.frame = NSRect(x: 11, y: 20, width: root.bounds.width - 19, height: root.bounds.height - 34)
            closeButton.isHidden = false
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            restore = (window.frame, window.level, NSApp.presentationOptions)
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.level = .statusBar
            window.setFrame(screen.frame, display: true)
            video.frame = root.bounds
            closeButton.isHidden = true
            window.makeFirstResponder(video)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(title: String, below player: NSWindow?) {
        root.title = "VIDEO — " + title.uppercased()
        guard window?.isVisible != true else { return }
        if !placed, let player { window?.setFrameTopLeftPoint(NSPoint(x: player.frame.minX, y: player.frame.minY - 8)) }
        window?.orderFront(nil)
    }
    var level: NSWindow.Level { get { window?.level ?? .normal } set { window?.level = newValue } }
    func retitle(_ title: String) { root.title = "VIDEO — " + title.uppercased() }
    func hide() { leaveFullScreen(); window?.orderOut(nil) }
    private func leaveFullScreen() { if restore != nil { toggleFullScreen() } }
    /// Closing the video panel stops the channel.
    @objc private func dismiss() { hide(); engine.stop() }
}
#endif
