import AppKit

/// Classic tabbed About box: RadioPocket, Credits, Keyboard shortcuts, Version history.
final class AboutController: NSObject {
    private enum Tab: Int, CaseIterable {
        case about, credits, shortcuts, history
        var title: String { ["RadioPocket", "Credits", "Keyboard shortcuts", "Version history"][rawValue] }
    }
    private let window: PlayerWindow
    private let text = NSTextView()
    private let tabs: [ClassicButton]
    private let versions = ClassicPopup(frame: .zero, pullsDown: false)
    private let released = NSTextField(labelWithString: "")
    private let releases = Changelog.load()
    private var selected = Tab.about

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Changelog.load().first?.version ?? "" }

    override init() {
        let size = NSSize(width: 480, height: 360)
        window = PlayerWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        tabs = Tab.allCases.map { ClassicButton(title: $0.title, target: nil, action: nil) }
        super.init()
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        window.title = "About RadioPocket"
        let root = ClassicChrome(frame: NSRect(origin: .zero, size: size)); root.title = "ABOUT RADIOPOCKET"; window.contentView = root
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(closeWindow))
        close.frame = NSRect(x: size.width - 12, y: 3, width: 9, height: 9); close.isBordered = false; close.setAccessibilityLabel("Close About"); root.addSubview(close)

        var x: CGFloat = 14
        for (index, button) in tabs.enumerated() {
            let width = CGFloat(Tab(rawValue: index)!.title.count * 6 + 22)
            button.frame = NSRect(x: x, y: 32, width: width, height: 22); x += width + 4
            button.isBordered = false; button.tag = index; button.target = self; button.action = #selector(selectTab(_:))
            root.addSubview(button)
        }
        versions.frame = NSRect(x: 14, y: 64, width: 150, height: 21); versions.isBordered = false
        versions.addItems(withTitles: releases.map(\.title)); versions.target = self; versions.action = #selector(selectVersion)
        versions.setAccessibilityLabel("Version"); root.addSubview(versions)
        released.frame = NSRect(x: 172, y: 66, width: 290, height: 18); released.font = ClassicUI.font; released.textColor = ClassicUI.dim
        root.addSubview(released)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 92, width: size.width - 28, height: size.height - 106))
        scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder; scroll.drawsBackground = true; scroll.backgroundColor = ClassicUI.black
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = true; text.backgroundColor = ClassicUI.black
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; root.addSubview(scroll)
        show(.about)
    }

    func present() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func exportPreview(_ url: URL, tab: String) {
        if let match = Tab.allCases.first(where: { String(describing: $0) == tab }) { show(match) }
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private func show(_ tab: Tab) {
        selected = tab
        for (index, button) in tabs.enumerated() { button.state = index == tab.rawValue ? .on : .off; button.alphaValue = index == tab.rawValue ? 1 : 0.6 }
        let history = tab == .history
        versions.isHidden = !history; released.isHidden = !history
        if history { selectVersion() } else { setText(body(for: tab)) }
    }

    private func setText(_ string: String) {
        text.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ClassicUI.text,
        ]))
        text.scrollToBeginningOfDocument(nil)
    }

    private func body(for tab: Tab) -> String {
        switch tab {
        case .about:
            return "RadioPocket \(Self.version)\n\nA small native internet radio player inspired by classic desktop players.\n\nOpen a direct HTTP/HTTPS audio stream or M3U/PLS playlist. Drop a classic .wsz skin onto the player.\n\nAn independent app, not affiliated with Winamp."
        case .credits:
            guard let url = Bundle.main.url(forResource: "SKIN-CREDITS", withExtension: "md"), let credits = try? String(contentsOf: url, encoding: .utf8) else { return "Skin credits are unavailable." }
            let third = Bundle.main.url(forResource: "THIRD-PARTY", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return (third + "\n" + credits).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        case .shortcuts:
            let player = "Space        Play / pause\nZ X C V B    Previous · Play · Pause · Stop · Next\n↑ / ↓        Volume\n← / →        Back / forward 10 s (pause buffers up to 5 min)\nL            Jump to live\n⌘O           Open stream\n⌘D           Save favorite\n⌘L           Favorites\n⌘B           Station library\n⌘E           Equalizer\n⌘K           Choose skin\n⌘I           Import skin\n⌘1 ⌘2 ⌘3     Window size\n⌘T           Always on top\n⇧⌘V          Visualization window\n⌃⌘F          Full screen visualization\n\nVisualizer (click the analyzer in the player):\n  click           Bars → Fire → Oscilloscope\n  double-click    Open the visualization window\n  right-click     Visualizer options\n\nVisualization window and full screen:\n"
            return player + VisualizerKeys.help.map { "  " + $0.0.padding(toLength: 22, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        case .history:
            return ""
        }
    }

    @objc private func selectTab(_ sender: NSButton) { show(Tab(rawValue: sender.tag)!) }
    @objc private func closeWindow() { window.orderOut(nil) }
    @objc private func selectVersion() {
        guard releases.indices.contains(versions.indexOfSelectedItem) else { setText("Version history is unavailable."); released.stringValue = ""; return }
        let release = releases[versions.indexOfSelectedItem]
        released.stringValue = release.released.map { "Released: \($0)" } ?? ""
        setText(release.text)
        versions.needsDisplay = true
    }
}
