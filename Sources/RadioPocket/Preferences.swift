import AppKit

private final class PreferencesBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); bounds.fill()
    }
}

/// A lazy, native preferences window; no web runtime or background polling.
final class PreferencesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: AppDelegate
    private let categories = ["General Preferences", "    Playback", "    Appearance", "    Skins", "Equalizer", "Media Library", "    Directories", "Visualization"]
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
    func present(skins: Bool = false, directories: Bool = false, visualization: Bool = false) {
        if skins { category = 3 } else if directories { category = 6 } else if visualization { category = 7 }
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
        case 6: directoriesPage()
        case 7: visualizationPage()
        case 5:
            label("Internet radio", x: 0, y: 402, bold: true)
            label("Browse stations from eight built-in sources and any directories you add.\nSave favorites or open a station’s direct stream URL.", x: 0, y: 332, width: 510, height: 54)
            button("Station library…", "discovery", x: 0, y: 282)
            button("Favorite stations…", "favorites", x: 200, y: 282)
            button("Manage directories…", "directories", x: 0, y: 238, width: 390)
            label("\(app.library.state.favorites.count) saved favorites", x: 0, y: 196)
            let fresh = NSButton(checkboxWithTitle: "Keep station lists saved and up to date", target: self, action: #selector(freshChanged(_:)))
            fresh.frame = NSRect(x: 0, y: 150, width: 480, height: 24); fresh.state = app.library.state.backgroundStations == false ? .off : .on; page.addSubview(fresh)
            label("Saves the most-used lists on this Mac so the library opens instantly, even offline, and refreshes a few pages about every hour. It pauses on Low Power Mode, hotspots, Low Data Mode and while the Mac runs hot.", x: 0, y: 84, width: 510, height: 58)
            button("Clear saved lists", "clearstations", x: 0, y: 44)
        default:
            label("RadioPocket", x: 0, y: 402, bold: true)
            label("A compact, native internet radio player.\nSettings are saved automatically.\n\n⌘O  Open stream\n⌘B  Station library\n⌘E  Equalizer\n⌘K  Skins\n⌘,   Preferences", x: 0, y: 170, width: 510, height: 210)
            button("Open a stream…", "open", x: 0, y: 112)
        }
    }
    /// One row per visualization option, each a popup that writes straight to the shared settings.
    private func visualizationPage() {
        let s = app.visuals.hub.settings
        let speeds = ["Slowest", "Slow", "Moderate", "Fast", "Fastest"], levels = ["Lowest", "Low", "Medium", "High", "Highest"], turbulence = ["Calm", "Gentle", "Medium", "Strong", "Wild"]
        var y: CGFloat = 420
        func row(_ title: String, _ id: String, _ items: [String], selected: Int) {
            label(title, x: 0, y: y, width: 200)
            let popup = NSPopUpButton(frame: NSRect(x: 210, y: y - 3, width: 220, height: 28), pullsDown: false)
            popup.addItems(withTitles: items); popup.selectItem(at: selected)
            popup.identifier = NSUserInterfaceItemIdentifier(id); popup.target = self; popup.action = #selector(visChanged(_:)); popup.setAccessibilityLabel(title)
            page.addSubview(popup); y -= 28
        }
        func check(_ title: String, _ id: String, _ on: Bool) {
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(visToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(id); box.state = on ? .on : .off; box.frame = NSRect(x: 0, y: y, width: 420, height: 24); page.addSubview(box); y -= 28
        }
        row("Player visualizer", "mini", MiniVisMode.allCases.map(\.title), selected: MiniVisMode.allCases.firstIndex(of: s.mini) ?? 0)
        row("Window visualization", "mode", VisPanelMode.allCases.map(\.title), selected: VisPanelMode.allCases.firstIndex(of: s.panel) ?? 0)
        row("Analyzer coloring", "color", VisColoring.allCases.map(\.title), selected: VisColoring.allCases.firstIndex(of: s.coloring) ?? 0)
        row("Band line width", "bandwidth", BandWidth.allCases.map(\.title), selected: BandWidth.allCases.firstIndex(of: s.bandWidth) ?? 0)
        row("Analyzer falloff", "falloff", speeds, selected: s.falloff)
        row("Peak falloff", "peakfall", speeds, selected: s.peakFalloff)
        row("Refresh rate", "refresh", VisRefresh.allCases.map(\.title), selected: VisRefresh.allCases.firstIndex(of: s.refresh) ?? 0)
        row("Oscilloscope style", "scope", ScopeStyle.allCases.map(\.title), selected: ScopeStyle.allCases.firstIndex(of: s.scope) ?? 0)
        check("Automatically cycle visualizations", "autocycle", s.autoCycle)
        row("Change visualization every", "cycletime", VisCycleInterval.seconds.map(VisCycleInterval.title), selected: VisCycleInterval.seconds.firstIndex(of: s.cycleSeconds) ?? 0)
        label("Fire", x: 0, y: y, bold: true); y -= 30
        row("Flame height", "fireheight", levels, selected: s.fireHeight)
        row("Turbulence", "fireturb", turbulence, selected: s.fireTurbulence)
        row("Flame colors", "firepalette", FirePalette.allCases.map(\.title), selected: FirePalette.allCases.firstIndex(of: s.firePalette) ?? 0)
        check("Show peak markers", "peaks", s.peaks)
    }
    @objc private func visChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let i = sender.indexOfSelectedItem
        let value: String
        switch key {
        case "mini": value = MiniVisMode.allCases[i].rawValue
        case "mode": value = VisPanelMode.allCases[i].rawValue
        case "color": value = VisColoring.allCases[i].rawValue
        case "bandwidth": value = BandWidth.allCases[i].rawValue
        case "refresh": value = VisRefresh.allCases[i].rawValue
        case "scope": value = ScopeStyle.allCases[i].rawValue
        case "firepalette": value = FirePalette.allCases[i].rawValue
        case "cycletime": value = String(VisCycleInterval.seconds[i])
        default: value = String(i)
        }
        app.visuals.handle("vis:\(key):\(value)")
    }
    @objc private func visToggled(_ sender: NSButton) { if let key = sender.identifier?.rawValue { app.visuals.handle("vis:\(key)") } }
    private var directoryList: [DirectorySource] { DirectorySource.resolved(app.library.state.directories) }
    private func directoriesPage() {
        label("Choose where the station library looks. Search results from every enabled directory are combined, and the library window can also search one directory at a time.", x: 0, y: 398, width: 510, height: 44)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 54, width: 524, height: 336))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 504, height: max(334, CGFloat(directoryList.count * 48 + 16))))
        scroll.documentView = content; page.addSubview(scroll)
        content.scroll(NSPoint(x: 0, y: content.bounds.height))
        var y = content.bounds.height - 34
        for (index, source) in directoryList.enumerated() {
            let box = NSButton(checkboxWithTitle: source.name, target: self, action: #selector(directoryToggled(_:)))
            box.tag = index; box.state = source.enabled ? .on : .off; box.frame = NSRect(x: 0, y: y, width: source.builtIn ? 480 : 400, height: 20); content.addSubview(box)
            if !source.builtIn {
                let remove = NSButton(title: "Remove", target: self, action: #selector(directoryRemoved(_:)))
                remove.tag = index; remove.bezelStyle = .rounded; remove.controlSize = .small; remove.frame = NSRect(x: 430, y: y - 2, width: 70, height: 22); content.addSubview(remove)
            }
            let detail = NSTextField(labelWithString: source.detail)
            detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
            detail.frame = NSRect(x: 20, y: y - 16, width: 478, height: 14); content.addSubview(detail)
            y -= 48
        }
        let customCount = directoryList.filter { !$0.builtIn }.count
        let add = NSButton(title: "Add Directory…", target: self, action: #selector(addDirectory))
        add.bezelStyle = .rounded; add.frame = NSRect(x: 0, y: 8, width: 160, height: 30); add.isEnabled = customCount < DirectorySource.maximumCustom; page.addSubview(add)
        label("Add a Radio Browser–compatible server, or a link to an M3U / PLS list of stations.", x: 170, y: 8, width: 340, height: 32)
    }
    private func saveDirectories(_ list: [DirectorySource]) {
        do { try app.library.update { $0.directories = list } } catch { app.showError(error); return }
        let position = page.subviews.compactMap { $0 as? NSScrollView }.first?.contentView.bounds.origin
        app.directoriesChanged(); refresh()
        if let position, let scroll = page.subviews.compactMap({ $0 as? NSScrollView }).first {
            scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    @objc private func directoryToggled(_ sender: NSButton) {
        var list = directoryList
        guard list.indices.contains(sender.tag) else { return }
        list[sender.tag].enabled = sender.state == .on
        if !list.contains(where: \.enabled) { list[sender.tag].enabled = true } // The library needs at least one source.
        saveDirectories(list)
    }
    @objc private func directoryRemoved(_ sender: NSButton) {
        var list = directoryList
        guard list.indices.contains(sender.tag), !list[sender.tag].builtIn else { return }
        list.remove(at: sender.tag)
        saveDirectories(list)
    }
    @objc private func addDirectory() {
        let alert = NSAlert()
        alert.messageText = "Add a station directory"
        alert.informativeText = "Only add directories you trust. RadioPocket reads station names and stream links from them."
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        let name = NSTextField(frame: NSRect(x: 0, y: 66, width: 360, height: 24)); name.placeholderString = "Name (optional)"
        let url = NSTextField(frame: NSRect(x: 0, y: 34, width: 360, height: 24)); url.placeholderString = "https://…"
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 360, height: 26), pullsDown: false)
        kind.addItems(withTitles: ["M3U / PLS station list", "Radio Browser–compatible server"])
        [name, url, kind].forEach(form.addSubview)
        alert.accessoryView = form
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = url
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let source = try DirectorySource.custom(name: name.stringValue, url: url.stringValue, kind: kind.indexOfSelectedItem == 0 ? .stationList : .radioBrowserAPI)
            guard let backend = source.makeBackend() else { return }
            window?.title = "RadioPocket Preferences — Checking directory…"
            Task { @MainActor [weak self] in
                defer { self?.window?.title = "RadioPocket Preferences" }
                do {
                    var probe = DirectoryQuery(); probe.supportedOnly = false
                    let page = try await backend.search(probe, refresh: true)
                    guard let self else { return }
                    if page.rawCount == 0 && page.stations.isEmpty { throw RadioError.message("That directory returned no stations.") }
                    self.saveDirectories(self.directoryList + [source])
                } catch { self?.app.showError(error) }
            }
        } catch { app.showError(error) }
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
    @objc private func freshChanged(_ sender: NSButton) {
        do { try app.library.update { $0.backgroundStations = sender.state == .on }; app.updateBackgroundStations() }
        catch { app.showError(error) }
    }
    @objc private func eqChanged(_ sender: NSButton) { app.engine.equalizer.settings.enabled = sender.state == .on }
    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let presets = EQPreset.classic + app.engine.equalizer.settings.custom
        if presets.indices.contains(sender.indexOfSelectedItem) { app.engine.equalizer.select(presets[sender.indexOfSelectedItem]); refresh() }
    }
}
