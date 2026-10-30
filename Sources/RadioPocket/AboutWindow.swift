import AppKit

/// Classic tabbed About box: RadioPocket, Credits, Keyboard shortcuts, Version history.
final class AboutController: NSObject {
    enum Tab: Int, CaseIterable {
        case about, credits, shortcuts, history
        var title: String { ["RadioPocket", "Credits", "Keyboard shortcuts", "Version history"][rawValue] }
    }
    private let window: PlayerWindow
    private let text = NSTextView()
    private let tabs: [ClassicButton]
    private let versions = ClassicPopup(frame: .zero, pullsDown: false)
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
            let width = CGFloat(Tab(rawValue: index)!.title.count * 6 + 16)
            button.frame = NSRect(x: x, y: 32, width: width, height: 22); x += width + 4
            button.isBordered = false; button.tag = index; button.target = self; button.action = #selector(selectTab(_:))
            root.addSubview(button)
        }
        versions.frame = NSRect(x: size.width - 14 - 58, y: 32, width: 58, height: 22); versions.isBordered = false
        versions.addItems(withTitles: releases.map(\.label)); versions.target = self; versions.action = #selector(selectVersion)
        versions.setAccessibilityLabel("Version"); root.addSubview(versions)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 60, width: size.width - 28, height: size.height - 74))
        scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder; scroll.drawsBackground = true; scroll.backgroundColor = ClassicUI.black
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = true; text.backgroundColor = ClassicUI.black
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; root.addSubview(scroll)
        show(.about)
    }

    func present(tab: Tab? = nil) {
        if !window.isVisible { window.center() }
        if let tab { show(tab) }
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
        versions.isHidden = !history
        if history { selectVersion() } else { setText(body(for: tab)) }
    }

    private func setText(_ string: String, hanging: Bool = false) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let style = NSMutableParagraphStyle()
        if hanging { style.headIndent = ("  • " as NSString).size(withAttributes: [.font: font]).width }
        text.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: ClassicUI.text, .paragraphStyle: style,
        ]))
        text.scrollToBeginningOfDocument(nil)
    }

    private static let legalNotice = """
    TERMS OF USE & LEGAL NOTICE

    Purpose of this player
    RadioPocket plays internet audio streams, including HTTP/HTTPS URLs you enter and stations found through third-party directories. It does not host streams or offer media-file downloads, recording exports, redistribution, or social sharing of streams. Temporary playback buffering supports pause and rewind; it does not create a saved media library.

    Responsible use
    Only access streams you are legally authorized to use. You are responsible for complying with applicable laws, copyright protections, and the stream provider’s terms. A publicly accessible URL or directory listing does not, by itself, establish permission to use a stream.

    Content rights
    All rights in streamed content remain with their respective owners. This app grants no license to that content or permission to record, distribute, or publicly perform it. Do not use this app to infringe copyright or unlawfully bypass access controls or payment requirements.

    Third-party streams
    Streams and station directories are operated by third parties outside our control. We do not endorse or guarantee their content, legality, safety, or availability.

    Use at your own risk
    To the extent permitted by applicable law, this app is provided “as is” and “as available,” without warranties. Its developers disclaim liability for loss or damage arising from use of the app or third-party streams, to the extent permitted by law. Nothing in this notice excludes rights or liability that cannot legally be excluded.
    """

    private func body(for tab: Tab) -> String {
        switch tab {
        case .about:
            return "RadioPocket \(Self.version)\n\nA small native internet radio player inspired by classic desktop players.\n\nOpen a direct HTTP/HTTPS audio stream or M3U/PLS playlist. Drop a classic .wsz skin onto the player.\n\nAn independent app, not affiliated with Winamp.\n\n" + Self.legalNotice
        case .credits:
            guard let url = Bundle.main.url(forResource: "SKIN-CREDITS", withExtension: "md"), let credits = try? String(contentsOf: url, encoding: .utf8) else { return "Skin credits are unavailable." }
            let third = Bundle.main.url(forResource: "THIRD-PARTY", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return (third + "\n" + credits).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        case .shortcuts:
            let player = "Space        Play / pause\nZ X C V B    Previous · Play · Pause · Stop · Next\n↑ / ↓        Volume\n← / →        Back / forward 10 s (pause buffers up to 5 min)\nL            Jump to live\n⌘O           Open stream\n⇧⌘J          Jump to station\n⌘D           Save favorite\n⇧⌘I          Station info\n⌘L           Favorites\n⌘B           Station library\n⌘E           Equalizer\n⌘K           Choose skin\n⌘I           Import skin\n⌘1 ⌘2 ⌘3     Window size\n⌘T           Always on top\n⌘W ⌘M        Close / minimize window\n⌥⌘← / ⌥⌘→    Previous / next favorite\n⇧⌘V          Visualization window\n⌃⌘F          Full screen visualization\n\nVisualizer (click the analyzer in the player):\n  click           Bars → Fire → Oscilloscope\n  double-click    Open the visualization window\n  right-click     Visualizer options\n\nVisualization window and full screen:\n"
            return player + VisualizerKeys.help.map { "  " + $0.0.padding(toLength: 22, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        case .history:
            return ""
        }
    }

    @objc private func selectTab(_ sender: NSButton) { show(Tab(rawValue: sender.tag)!) }
    @objc private func closeWindow() { window.orderOut(nil) }
    @objc private func selectVersion() {
        guard releases.indices.contains(versions.indexOfSelectedItem) else { setText("Version history is unavailable."); return }
        let release = releases[versions.indexOfSelectedItem]
        setText(release.text, hanging: true)
        versions.needsDisplay = true
    }
}
