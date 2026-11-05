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
        setUpAudioButton()
    }
    required init?(coder: NSCoder) { fatalError() }
    var onToggleFullScreen: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTakeAudio: (() -> Void)?
    private let audioButton = NSButton()
    private var hovering = false
    /// With several video panels, a speaker shows which one has the audio; hovering any panel offers to move it there.
    var audioShown = false { didSet { refreshAudioButton() } }
    var audible = true { didSet { refreshAudioButton() } }
    private func setUpAudioButton() {
        audioButton.isBordered = false; audioButton.bezelStyle = .regularSquare
        audioButton.wantsLayer = true
        audioButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        audioButton.layer?.cornerRadius = 4
        audioButton.contentTintColor = .white
        audioButton.target = self; audioButton.action = #selector(takeAudio)
        audioButton.isHidden = true
        addSubview(audioButton)
    }
    @objc private func takeAudio() { if !audible { onTakeAudio?() } }
    private func refreshAudioButton() {
        let name = audible ? "speaker.wave.2.fill" : "speaker.slash.fill"
        audioButton.image = NSImage(systemSymbolName: name, accessibilityDescription: audible ? "Audio from this panel" : "Play audio from this panel")
        audioButton.setAccessibilityLabel(audible ? "Audio from this panel" : "Play audio from this panel")
        audioButton.isHidden = !(audioShown && (hovering || audible))
        audioButton.frame = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 28, width: 24, height: 22)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshAudioButton() }
    override func mouseMoved(with event: NSEvent) { if !hovering { hovering = true; refreshAudioButton() } }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshAudioButton() }
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
        refreshAudioButton()
    }
}

/// The classic-skinned window that shows an Internet TV channel, like Winamp's video window.
/// The "Tune In on" submenu shared by the library and favorites: one item per open video panel, then a new one.
/// Runs a closure from a menu item; the item keeps it alive through `representedObject`.
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
    static func item(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let box = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = box; item.representedObject = box; item.isEnabled = enabled
        return item
    }
}

enum PanelMenu {
    /// A "Tune In on" item for closure-based menus; nil when no video panel is open. A nil choice means a new panel.
    static func item(_ title: String, titles: [String], choose: @escaping (Int?) -> Void) -> NSMenuItem? {
        guard !titles.isEmpty else { return nil }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""), menu = NSMenu()
        for (index, name) in titles.enumerated() { menu.addItem(MenuAction.item(name) { choose(index) }) }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("New Panel") { choose(nil) })
        parent.submenu = menu
        return parent
    }
    static func fill(_ item: NSMenuItem, titles: [String], target: AnyObject, action: Selector) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = target; entry.representedObject = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Panel", action: action, keyEquivalent: ""); new.target = target; new.representedObject = -1
        menu.addItem(new)
        item.submenu = menu
        item.isHidden = titles.isEmpty
    }
}

final class VideoController: NSWindowController {
    private let root: ClassicChrome
    private let placed: Bool
    /// "Video" alone, "Video 1", "Video 2"… once several panels are open.
    private var label = "Video"
    private var channel = ""
    private func heading() -> String { channel.isEmpty ? label.uppercased() : label.uppercased() + " — " + channel.uppercased() }
    func setLabel(_ value: String) { guard value != label else { return }; label = value; root.title = heading() }
    private let video: VideoView
    private let closeButton: ClassicWindowButton
    private var restore: (frame: NSRect, level: NSWindow.Level)?
    static let frameName = "RadioPocket.Video"
    /// Called when the × closes this panel, after its channel has stopped.
    var onClose: (() -> Void)?
    /// Called when the speaker is clicked, asking for this panel to have the audio.
    var onTakeAudio: (() -> Void)?
    let engine: RadioEngine

    /// The main video panel remembers its position; extra panels cascade from the last one instead.
    init(engine: RadioEngine, extra: Bool = false) {
        self.engine = engine
        placed = !extra && UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameName)") != nil
        let size = NSSize(width: 499, height: 304)
        let window = PlayerWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RadioPocket — Video"
        window.minSize = NSSize(width: 259, height: 164); window.isUserResizable = true
        window.aspectChrome = NSSize(width: 19, height: 34)
        window.contentAspect = { [weak engine] in
            let size = engine?.player.currentItem?.presentationSize ?? .zero
            return size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
        }
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
        video.onTakeAudio = { [weak self] in self?.onTakeAudio?() }
        if !extra { window.setFrameAutosaveName(Self.frameName) }
    }

    /// Marks this panel as holding the audio or not, and whether other video panels exist to switch between.
    func setAudio(audible: Bool, shown: Bool) { video.audible = audible; video.audioShown = shown }

    /// Fills the screen with just the picture; borderless windows can't use the system full-screen space.
    private func toggleFullScreen() {
        guard let window, let root = window.contentView else { return }
        if let saved = restore {
            restore = nil
            FullScreenPresentation.leave()
            window.level = saved.level
            window.setFrame(saved.frame, display: true)
            video.frame = NSRect(x: 11, y: 20, width: root.bounds.width - 19, height: root.bounds.height - 34)
            closeButton.isHidden = false
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            restore = (window.frame, window.level)
            FullScreenPresentation.enter()
            window.level = .statusBar
            window.setFrame(screen.frame, display: true)
            video.frame = root.bounds
            closeButton.isHidden = true
            window.makeFirstResponder(video)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(title: String, below player: NSWindow?, offset: CGFloat = 0) {
        channel = title; root.title = heading()
        guard window?.isVisible != true, !suspended else { return }
        if (!placed || offset > 0), let player { window?.setFrameTopLeftPoint(NSPoint(x: player.frame.minX + offset, y: player.frame.minY - 8 - offset)) }
        window?.orderFront(nil)
    }
    /// Hidden while the multiview wall shows its picture; `resume` brings it back.
    private var suspended = false
    var isShown: Bool { window?.isVisible == true || suspended }
    func suspend() { guard window?.isVisible == true else { return }; leaveFullScreen(); suspended = true; window?.orderOut(nil) }
    func resume() { guard suspended else { return }; suspended = false; window?.orderFront(nil) }
    var frame: NSRect { window?.frame ?? .zero }
    var level: NSWindow.Level { get { window?.level ?? .normal } set { if restore == nil { window?.level = newValue } } }
    func retitle(_ title: String) { channel = title; root.title = heading() }
    func hide() { suspended = false; leaveFullScreen(); window?.orderOut(nil) }
    private func leaveFullScreen() { if restore != nil { toggleFullScreen() } }
    /// Closing the video panel stops the channel.
    @objc private func dismiss() { hide(); engine.stop(); onClose?() }
}
#endif
