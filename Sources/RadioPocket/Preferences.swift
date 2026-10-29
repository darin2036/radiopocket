import AppKit

private final class PreferencesBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); bounds.fill()
    }
}

/// A lazy, native preferences window; no web runtime or background polling.
final class PreferencesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: AppDelegate
    private let categories = ["General Preferences", "    Playback", "    Appearance", "    Skins", "Equalizer", "Media Library"]
    private let sidebar = NSTableView()
    private let skins = NSTableView()
    private let page = NSView()
    private var entries: [(title: String, action: String, name: String?)] = []
    private var rebuilding = false
    private var category = 3

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "RadioPocket Preferences"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = PreferencesBackground(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        guard let root = window.contentView else { return }
        let scroll = list(sidebar, frame: NSRect(x: 16, y: 58, width: 184, height: 446))
        root.addSubview(scroll)
        page.frame = NSRect(x: 220, y: 16, width: 524, height: 488)
        root.addSubview(page)
        let close = NSButton(title: "Close", target: self, action: #selector(closePreferences))
        close.bezelStyle = .rounded; close.frame = NSRect(x: 12, y: 16, width: 192, height: 28)
        root.addSubview(close)
        sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
        window.center()
        window.setFrameAutosaveName("RadioPocket.Preferences")
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(skins: Bool = false) {
        if skins { category = 3 }
        sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
        refresh(); window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard page.superview != nil else { return }
        rebuilding = true
        defer { rebuilding = false }
        page.subviews.forEach { $0.removeFromSuperview() }
        label(categories[category].trimmingCharacters(in: .whitespaces), x: 0, y: 454, width: 520, bold: true)
        switch category {
        case 3: skinPage()
        case 1:
            label("Output volume", x: 0, y: 402)
            let slider = NSSlider(value: Double(app.engine.player.volume), minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
            slider.frame = NSRect(x: 0, y: 364, width: 420, height: 24); slider.setAccessibilityLabel("Output volume"); page.addSubview(slider)
            label("MP3 / AAC streams use the native audio engine.\nHLS playback uses macOS media playback.\nStations start only when you choose to play them.", x: 0, y: 254, width: 510, height: 82)
            button("Open a stream…", "open", x: 0, y: 206)
        case 2:
            label("Player and equalizer size", x: 0, y: 402)
            let size = NSPopUpButton(frame: NSRect(x: 0, y: 362, width: 220, height: 28), pullsDown: false)
            size.addItems(withTitles: ["1× — Original", "2× — Default", "3× — Large"])
            size.selectItem(at: max(0, min(2, Int(app.library.state.scale) - 1)))
            size.target = self; size.action = #selector(sizeChanged(_:)); page.addSubview(size)
            let top = NSButton(checkboxWithTitle: "Keep player and equalizer on top", target: self, action: #selector(topChanged(_:)))
            top.frame = NSRect(x: 0, y: 312, width: 480, height: 24); top.state = app.window.level == .floating ? .on : .off; page.addSubview(top)
            button("Choose a skin…", "skins", x: 0, y: 252)
        case 4:
            let enabled = NSButton(checkboxWithTitle: "Enable equalizer", target: self, action: #selector(eqChanged(_:)))
            enabled.frame = NSRect(x: 0, y: 398, width: 400, height: 24); enabled.state = app.engine.equalizer.settings.enabled ? .on : .off; page.addSubview(enabled)
            label("Preset", x: 0, y: 350)
            let presets = NSPopUpButton(frame: NSRect(x: 0, y: 310, width: 300, height: 28), pullsDown: false)
            presets.addItems(withTitles: (EQPreset.classic + app.engine.equalizer.settings.custom).map(\.name))
            presets.selectItem(withTitle: app.engine.equalizer.settings.preset)
            presets.target = self; presets.action = #selector(presetChanged(_:)); page.addSubview(presets)
            label("10 bands and preamp, with 18 classic presets.\nEqualization applies to MP3 / AAC streams.\nHLS playback does not support the equalizer.", x: 0, y: 204, width: 510, height: 80)
            button("Open equalizer…", "equalizer", x: 0, y: 154)
        case 5:
            label("Internet radio", x: 0, y: 402, bold: true)
            label("Browse independent stations through Radio Browser.\nSave favorites or open a station’s direct stream URL.", x: 0, y: 332, width: 510, height: 54)
            button("Station library…", "discovery", x: 0, y: 282)
            button("Favorite stations…", "favorites", x: 200, y: 282)
            label("\(app.library.state.favorites.count) saved favorites", x: 0, y: 226)
        default:
            label("RadioPocket", x: 0, y: 402, bold: true)
            label("A compact, native internet radio player.\nSettings are saved automatically.\n\n⌘O  Open stream\n⌘B  Station library\n⌘E  Equalizer\n⌘K  Skins\n⌘,   Preferences", x: 0, y: 170, width: 510, height: 210)
            button("Open a stream…", "open", x: 0, y: 112)
        }
    }
    private func skinPage() {
        entries = app.bundledSkins.map { ($0.0, "bundled:" + $0.1, Optional($0.1)) }
        entries.append(("RadioPocket Original", "resetSkin", nil))
        let folder = app.library.directory.appendingPathComponent("Installed Skins")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            entries.append((url.deletingPathExtension().lastPathComponent, "installed:" + url.path, url.deletingPathExtension().lastPathComponent))
        }
        label("Installed", x: 0, y: 414)
        page.addSubview(list(skins, frame: NSRect(x: 0, y: 190, width: 342, height: 218)))
        skins.reloadData()
        if let selected = entries.firstIndex(where: { $0.name == app.view.skin?.name }) { skins.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        button("Import skin…", "skin", x: 354, y: 378, width: 170)
        label("Classic .wsz / .zip\nskins supported.\n\nSelect a skin to\napply it instantly.", x: 358, y: 250, width: 160, height: 110)
        label("Current skin", x: 0, y: 152)
        let name = entries.first(where: { $0.name == app.view.skin?.name })?.title ?? app.view.skin?.name ?? "RadioPocket Original"
        label(name, x: 0, y: 126, width: 520, bold: true)
        // Render the actual player, including text and controls, instead of an empty skin bitmap.
        if let rep = app.view.bitmapImageRepForCachingDisplay(in: app.view.bounds) {
            app.view.cacheDisplay(in: app.view.bounds, to: rep)
            let image = NSImage(size: app.view.bounds.size); image.addRepresentation(rep)
            let preview = NSImageView(frame: NSRect(x: 0, y: 4, width: 275, height: 116))
            preview.image = image; preview.imageScaling = .scaleProportionallyUpOrDown; page.addSubview(preview)
        }
        label("11 bundled classic skins\nplus the native theme.\nImported skins stay installed.", x: 296, y: 34, width: 224, height: 76)
    }
    private func list(_ table: NSTableView, frame: NSRect) -> NSScrollView {
        if table.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.width = frame.width - 4; table.addTableColumn(column)
        }
        table.headerView = nil; table.rowHeight = 24; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel(table === sidebar ? "Preferences categories" : "Installed skins")
        let scroll = NSScrollView(frame: frame); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.documentView = table
        return scroll
    }
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 500, height: CGFloat = 24, bold: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        label.frame = NSRect(x: x, y: y, width: width, height: height); page.addSubview(label)
    }
    private func button(_ title: String, _ id: String, x: CGFloat, y: CGFloat, width: CGFloat = 190) {
        let button = NSButton(title: title, target: self, action: #selector(action(_:)))
        button.bezelStyle = .rounded; button.identifier = NSUserInterfaceItemIdentifier(id)
        button.frame = NSRect(x: x, y: y, width: width, height: 30); page.addSubview(button)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sidebar ? categories.count : entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: tableView === sidebar ? categories[row] : entries[row].title)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding, let table = notification.object as? NSTableView else { return }
        if table === sidebar, categories.indices.contains(table.selectedRow) { category = table.selectedRow; refresh() }
        else if table === skins, entries.indices.contains(table.selectedRow) { app.handle(entries[table.selectedRow].action) }
    }
    @objc private func closePreferences() { window?.orderOut(nil) }
    @objc private func action(_ sender: NSButton) { if let id = sender.identifier?.rawValue { app.handle(id) } }
    @objc private func volumeChanged(_ sender: NSSlider) { app.view.volumeChanged?(sender.floatValue) }
    @objc private func sizeChanged(_ sender: NSPopUpButton) { app.handle("scale\(sender.indexOfSelectedItem + 1)") }
    @objc private func topChanged(_ sender: NSButton) { app.window.level = sender.state == .on ? .floating : .normal; app.eqWindow.level = app.window.level; app.saveWindowLevel() }
    @objc private func eqChanged(_ sender: NSButton) { app.engine.equalizer.settings.enabled = sender.state == .on }
    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let presets = EQPreset.classic + app.engine.equalizer.settings.custom
        if presets.indices.contains(sender.indexOfSelectedItem) { app.engine.equalizer.select(presets[sender.indexOfSelectedItem]); refresh() }
    }
}
