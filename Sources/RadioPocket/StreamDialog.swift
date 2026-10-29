import AppKit

final class StreamDialog: NSObject {
    private let window: PlayerWindow
    private let name = NSTextField()
    private let address = NSTextField()
    private let save = ClassicCheckBox(title: "Save to Favorites", target: nil, action: nil)
    private let error = NSTextField(labelWithString: "")
    private let original: Station?
    private let favoriteOnly: Bool
    private var result: (Station, Bool)?

    init(station: Station?, favoriteOnly: Bool) {
        original = station; self.favoriteOnly = favoriteOnly
        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 204), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        window.title = favoriteOnly ? "Save Favorite Station" : "Open Radio Stream"
        let root = ClassicChrome(frame: NSRect(x: 0, y: 0, width: 440, height: 204))
        root.title = favoriteOnly ? "SAVE FAVORITE" : "OPEN INTERNET RADIO"; window.contentView = root
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(cancel))
        close.frame = NSRect(x: 428, y: 3, width: 9, height: 9); close.isBordered = false; close.setAccessibilityLabel("Cancel stream entry"); root.addSubview(close)
        for (title, y, field) in [("Station", 38.0, name), ("Stream URL", 70.0, address)] {
            let label = NSTextField(labelWithString: title); label.font = ClassicUI.font; label.textColor = ClassicUI.text
            label.frame = NSRect(x: 16, y: y + 4, width: 76, height: 18); root.addSubview(label)
            field.frame = NSRect(x: 92, y: y, width: 330, height: 23); ClassicUI.field(field)
            field.setAccessibilityLabel(title); root.addSubview(field)
        }
        name.stringValue = station?.name ?? ""; name.placeholderString = "Name (optional)"
        address.stringValue = station?.address ?? ""; address.placeholderString = "https://station.example/live"
        save.setButtonType(.switch); save.isBordered = false
        save.frame = NSRect(x: 90, y: 102, width: 250, height: 22); save.font = ClassicUI.font
        save.isHidden = favoriteOnly; root.addSubview(save)
        error.frame = NSRect(x: 16, y: 128, width: 408, height: 26); error.font = ClassicUI.font
        error.textColor = .systemOrange; error.maximumNumberOfLines = 2; error.lineBreakMode = .byWordWrapping; root.addSubview(error)
        for (title, x, selector, key) in [(favoriteOnly ? "Save" : "Play", 264.0, #selector(submit), "\r"), ("Cancel", 346.0, #selector(cancel), "\u{1b}")] {
            let button = ClassicButton(title: title, target: self, action: selector)
            button.frame = NSRect(x: x, y: 164, width: 76, height: 23); button.isBordered = false; button.keyEquivalent = key
            root.addSubview(button)
        }
        window.initialFirstResponder = station == nil ? address : name
        name.nextKeyView = address; address.nextKeyView = save
    }
    func exportPreview(_ url: URL) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
    func run() -> (Station, Bool)? {
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window); window.orderOut(nil)
        return result
    }
    @objc private func submit() {
        do {
            let url = try StreamAddress.parse(address.stringValue)
            let entered = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result = (Station(id: original?.id ?? UUID(), name: String((entered.isEmpty ? url.host! : entered).prefix(200)), address: url.absoluteString), favoriteOnly || save.state == .on)
            NSApp.stopModal()
        } catch { self.error.stringValue = error.localizedDescription; window.makeFirstResponder(address) }
    }
    @objc private func cancel() { NSApp.stopModal() }
}
