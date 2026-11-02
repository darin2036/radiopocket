import AppKit

private final class PreferencesBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); bounds.fill()
    }
}

/// A lazy, native preferences window; no web runtime or background polling.
final class PreferencesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: AppDelegate
    private let categories = ["General Preferences", "    Appearance", "    Skins", "Playback", "Internet Radio", "Internet TV", "Visualization"]
    private let sidebar = NSTableView()
    private let skins = NSTableView()
    private let directoryTable = NSTableView()
    private var skinControl: NSSegmentedControl?
    private var directoryControl: NSSegmentedControl?
    private let page = NSView()
    private var entries: [(title: String, action: String, name: String?)] = []
    private var rebuilding = false
    private var category = 2
    private static let sizes = [1.0, 1.5, 2.0, 3.0]

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
        close.bezelStyle = .rounded; close.frame = NSRect(x: 16, y: 16, width: 184, height: 28)
        root.addSubview(close)
        sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
        window.center()
        window.setFrameAutosaveName("RadioPocket.Preferences")
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(skins: Bool = false, radio: Bool = false, tv: Bool = false, visualization: Bool = false) {
        if skins { category = 2 } else if radio { category = 4 } else if tv { category = 5 } else if visualization { category = 6 }
        sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
        refresh(); window?.makeKeyAndOrderFront(nil)
    }
    func refresh() {
        guard page.superview != nil else { return }
        rebuilding = true
        defer { rebuilding = false }
        page.subviews.forEach { $0.removeFromSuperview() }
        // The table pages fill the page top to bottom; the rest sit a little higher now there is no heading.
        page.setBoundsOrigin(NSPoint(x: 0, y: category == 2 || category == 4 || category == 5 ? 0 : -40))
        switch category {
        case 2: skinPage()
        case 1:
            label("Player and equalizer size", x: 0, y: 422)
            let size = NSPopUpButton(frame: NSRect(x: 0, y: 390, width: 220, height: 28), pullsDown: false)
            size.addItems(withTitles: ["1× — Original", "1.5×", "2× — Default", "3× — Large"])
            size.selectItem(at: Self.sizes.firstIndex(of: app.library.state.scale) ?? 2)
            size.target = self; size.action = #selector(sizeChanged(_:)); page.addSubview(size)
            let top = NSButton(checkboxWithTitle: "Keep player and equalizer on top", target: self, action: #selector(topChanged(_:)))
            top.frame = NSRect(x: 0, y: 356, width: 480, height: 24); top.state = app.window.level == .floating ? .on : .off; page.addSubview(top)
        case 3:
            let eq = app.engine.equalizer
            label("Spatial audio", x: 0, y: 422, width: 200)
            let style = NSPopUpButton(frame: NSRect(x: 210, y: 419, width: 220, height: 28), pullsDown: false)
            style.addItems(withTitles: SpatialStyle.allCases.map(\.title)); style.selectItem(at: eq.spatial.style.rawValue)
            style.target = self; style.action = #selector(spatialStyleChanged(_:)); style.setAccessibilityLabel("Spatial audio"); page.addSubview(style)
            func slider(_ title: String, y: CGFloat, value: Float, max: Double, id: String) {
                label(title, x: 0, y: y, width: 200)
                let s = NSSlider(value: Double(value), minValue: 0, maxValue: max, target: self, action: #selector(spatialSliderChanged(_:)))
                s.frame = NSRect(x: 210, y: y, width: 220, height: 24); s.identifier = NSUserInterfaceItemIdentifier(id); s.setAccessibilityLabel(title); page.addSubview(s)
            }
            slider("Spatial amount", y: 390, value: eq.spatial.amount, max: 1, id: "amount")
            slider("Stereo width", y: 362, value: eq.spatial.width, max: 2, id: "width")
            let leveling = NSButton(checkboxWithTitle: "Loudness leveling", target: self, action: #selector(levelingChanged(_:)))
            leveling.frame = NSRect(x: 0, y: 324, width: 400, height: 24); leveling.state = app.engine.leveling ? .on : .off; page.addSubview(leveling)
            button("Open a stream…", "open", x: 0, y: 296)
        case 4:
            button("Station library…", "discovery", x: 0, y: 452)
            button("Favorite stations…", "favorites", x: 200, y: 452)
            let fresh = NSButton(checkboxWithTitle: "Keep station lists saved and up to date", target: self, action: #selector(freshChanged(_:)))
            fresh.frame = NSRect(x: 0, y: 418, width: 480, height: 24); fresh.state = app.library.state.backgroundStations == false ? .off : .on; page.addSubview(fresh)
            let check = NSButton(checkboxWithTitle: "Hide stations that no longer respond", target: self, action: #selector(checkChanged(_:)))
            check.frame = NSRect(x: 0, y: 390, width: 480, height: 24); check.state = app.library.state.checkStations == false ? .off : .on; page.addSubview(check)
            button("Clear saved lists", "clearstations", x: 0, y: 352)
            label("Directories", x: 0, y: 322, bold: true)
            directoriesPage(top: 316)
        case 5:
            button("Channel library…", "tvlibrary", x: 0, y: 452)
            let adult = NSButton(checkboxWithTitle: "Hide adult channels", target: self, action: #selector(tvAdultChanged(_:)))
            adult.frame = NSRect(x: 0, y: 418, width: 480, height: 24); adult.state = app.library.state.tvSafety.hideAdult ? .on : .off; page.addSubview(adult)
            let unreliable = NSButton(checkboxWithTitle: "Hide geo-blocked and unreliable channels", target: self, action: #selector(tvUnreliableChanged(_:)))
            unreliable.frame = NSRect(x: 0, y: 390, width: 480, height: 24); unreliable.state = app.library.state.tvSafety.hideUnreliable ? .on : .off; page.addSubview(unreliable)
            label("Directories", x: 0, y: 358, bold: true)
            directoriesPage(top: 352)
        case 6: visualizationPage()
        default:
            button("Open a stream…", "open", x: 0, y: 418)
        }
    }
    /// One row per visualization option, each a popup that writes straight to the shared settings.
    private func visualizationPage() {
        let s = app.visuals.hub.settings
        let speeds = ["Slowest", "Slow", "Moderate", "Fast", "Fastest"], levels = ["Lowest", "Low", "Medium", "High", "Highest"], turbulence = ["Calm", "Gentle", "Medium", "Strong", "Wild"]
        var y: CGFloat = 424
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
        check("Animate Dock icon while playing", "dockicon", s.dockIcon)
        check("Show title in full screen", "overlay", s.overlay)
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
    /// The Internet TV section lists TV directories; Internet Radio lists radio ones.
    private var showsTV: Bool { category == 5 }
    private var allDirectories: [DirectorySource] { DirectorySource.resolved(app.library.state.directories) }
    private var directoryList: [DirectorySource] { allDirectories.filter { $0.isTV == showsTV } }
    private var allRemovedBuiltIns: [DirectorySource] { (app.library.state.directories ?? []).filter { $0.removed == true && $0.builtIn } }
    private var removedBuiltIns: [DirectorySource] { allRemovedBuiltIns.filter { $0.isTV == showsTV } }
    private func directoriesPage(top: CGFloat) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 64, width: 524, height: top - 64))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        if directoryTable.tableColumns.isEmpty { directoryTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))) }
        directoryTable.tableColumns[0].width = 500
        directoryTable.headerView = nil; directoryTable.rowHeight = 42; directoryTable.intercellSpacing = .zero
        directoryTable.delegate = self; directoryTable.dataSource = self; directoryTable.allowsEmptySelection = true
        directoryTable.setAccessibilityLabel("Directories")
        scroll.documentView = directoryTable; page.addSubview(scroll)
        directoryTable.reloadData()
        directoryControl = plusMinus(#selector(directoryPlusMinus(_:)))
        updateDirectoryControl()
    }
    /// The usual + / − pair under a list, drawn as part of its box.
    private func plusMinus(_ action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(images: [NSImage(named: NSImage.addTemplateName)!, NSImage(named: NSImage.removeTemplateName)!], trackingMode: .momentary, target: self, action: action)
        control.segmentStyle = .smallSquare; control.setWidth(26, forSegment: 0); control.setWidth(26, forSegment: 1)
        control.frame = NSRect(x: 0, y: 42, width: 52, height: 22); control.setAccessibilityLabel("Add or remove")
        page.addSubview(control)
        return control
    }
    private func updateDirectoryControl() {
        directoryControl?.setEnabled(directoryTable.selectedRow >= 0 && (showsTV || directoryList.count > 1), forSegment: 1)
    }
    private func saveDirectories(_ list: [DirectorySource], removed: [DirectorySource]? = nil) {
        let discarded = allDirectories.filter { old in [.localList, .localTVList].contains(old.kind) && !list.contains(where: { $0.id == old.id }) }
        do { try app.library.update { $0.directories = list + (removed ?? allRemovedBuiltIns) } } catch { app.showError(error); return }
        let importedFolder = app.library.directory.appendingPathComponent("Directories").standardizedFileURL.path + "/"
        for source in discarded {
            if let url = source.url.flatMap({ URL(string: $0) }), url.isFileURL, url.standardizedFileURL.path.hasPrefix(importedFolder) { try? FileManager.default.removeItem(at: url) }
        }
        let position = page.subviews.compactMap { $0 as? NSScrollView }.first?.contentView.bounds.origin
        let selected = directoryTable.selectedRow
        app.directoriesChanged(); refresh()
        if let position, let scroll = page.subviews.compactMap({ $0 as? NSScrollView }).first {
            scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if directoryList.indices.contains(selected) { directoryTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
    }
    @objc private func directoryToggled(_ sender: NSButton) {
        let shown = directoryList
        var list = allDirectories
        guard shown.indices.contains(sender.tag), let index = list.firstIndex(where: { $0.id == shown[sender.tag].id }) else { return }
        list[index].enabled = sender.state == .on
        // The radio library needs at least one source; the TV library can be left empty.
        if !showsTV, !list.contains(where: { $0.enabled && !$0.isTV }) { list[index].enabled = true }
        saveDirectories(list)
    }
    @objc private func directoryPlusMinus(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { removeDirectory(); return }
        let gone = removedBuiltIns
        guard !gone.isEmpty else { addDirectory(); return }
        let menu = NSMenu(); menu.autoenablesItems = false
        let custom = NSMenuItem(title: "Custom Directory…", action: #selector(addDirectory), keyEquivalent: ""); custom.target = self
        custom.isEnabled = allDirectories.filter { !$0.builtIn }.count < DirectorySource.maximumCustom
        menu.addItem(custom); menu.addItem(.separator())
        for source in gone {
            let name = DirectorySource.defaults.first { $0.id == source.id }?.name ?? source.name
            let item = NSMenuItem(title: name, action: #selector(restoreDirectory(_:)), keyEquivalent: ""); item.target = self; item.representedObject = source.id; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }
    @objc private func restoreDirectory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        saveDirectories(allDirectories, removed: allRemovedBuiltIns.filter { $0.id != id })
    }
    private func removeDirectory() {
        let shown = directoryList
        var list = allDirectories
        let row = directoryTable.selectedRow
        guard shown.indices.contains(row), showsTV || shown.count > 1, let index = list.firstIndex(where: { $0.id == shown[row].id }) else { return }
        let gone = list.remove(at: index)
        if !showsTV, !list.contains(where: { $0.enabled && !$0.isTV }), let first = list.firstIndex(where: { !$0.isTV }) { list[first].enabled = true }
        var removed = allRemovedBuiltIns
        if gone.builtIn { var marker = gone; marker.removed = true; removed.append(marker) }
        directoryTable.deselectAll(nil)
        saveDirectories(list, removed: removed)
    }
    @objc private func addDirectory() {
        let alert = NSAlert()
        let tv = showsTV
        alert.messageText = tv ? "Add a TV channel list" : "Add a station directory"
        alert.informativeText = tv ? "Only add lists you trust and have the right to watch. RadioPocket reads channel names and stream links from them."
                                   : "Only add directories you trust. RadioPocket reads station names and stream links from them."
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        let name = NSTextField(frame: NSRect(x: 0, y: 66, width: 360, height: 24)); name.placeholderString = "Name (optional)"
        let url = NSTextField(frame: NSRect(x: 0, y: 34, width: 360, height: 24)); url.placeholderString = "https://…"
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 360, height: 26), pullsDown: false)
        kind.addItems(withTitles: tv ? ["M3U TV channel list"] : ["M3U / PLS station list", "Radio Browser–compatible server"])
        [name, url, kind].forEach(form.addSubview)
        alert.accessoryView = form
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = url
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let source = try DirectorySource.custom(name: name.stringValue, url: url.stringValue, kind: (tv ? [.tvList] : [.stationList, .radioBrowserAPI] as [DirectorySource.Kind])[kind.indexOfSelectedItem])
            guard let backend = source.makeBackend(safety: app.library.state.tvSafety) else { return }
            window?.title = "RadioPocket Preferences — Checking directory…"
            Task { @MainActor [weak self] in
                defer { self?.window?.title = "RadioPocket Preferences" }
                do {
                    var probe = DirectoryQuery(); probe.supportedOnly = false; probe.video = tv
                    var page = try await backend.search(probe, refresh: true)
                    // A TV list may hold only radio streams, which belong to the radio library.
                    if tv, page.stations.isEmpty { probe.video = false; page = try await backend.search(probe, refresh: false) }
                    guard let self else { return }
                    if page.rawCount == 0 && page.stations.isEmpty { throw RadioError.message("That directory returned no stations.") }
                    self.saveDirectories(self.allDirectories + [source])
                } catch { self?.app.showError(error) }
            }
        } catch { app.showError(error) }
    }
    private func skinPage() {
        entries = builtInSkins.filter { !hiddenSkins.contains($0.action) }
        let folder = app.library.directory.appendingPathComponent("Installed Skins")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            entries.append((url.deletingPathExtension().lastPathComponent, "installed:" + url.path, url.deletingPathExtension().lastPathComponent))
        }
        page.addSubview(list(skins, frame: NSRect(x: 0, y: 212, width: 524, height: 276)))
        skins.reloadData()
        if let selected = entries.firstIndex(where: { $0.name == app.view.skin?.name }) { skins.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        let control = plusMinus(#selector(skinPlusMinus(_:)))
        control.frame.origin.y = 190; control.setEnabled(entries.count > 1, forSegment: 1); skinControl = control
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
    }
    private var builtInSkins: [(title: String, action: String, name: String?)] {
        app.bundledSkins.map { ($0.0, "bundled:" + $0.1, Optional($0.1)) } + [("RadioPocket Original", "resetSkin", nil)]
    }
    private var hiddenSkins: Set<String> { Set(app.library.state.hiddenSkins ?? []) }
    private func setHiddenSkins(_ ids: Set<String>) {
        do { try app.library.update { $0.hiddenSkins = ids.sorted() } } catch { app.showError(error) }
    }
    @objc private func skinPlusMinus(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { removeSkin(); return }
        let gone = builtInSkins.filter { hiddenSkins.contains($0.action) }
        let menu = NSMenu()
        let importItem = NSMenuItem(title: "Import Skin…", action: #selector(importSkinItem), keyEquivalent: ""); importItem.target = self; menu.addItem(importItem)
        if !gone.isEmpty { menu.addItem(.separator()) }
        for skin in gone {
            let item = NSMenuItem(title: skin.title, action: #selector(restoreSkin(_:)), keyEquivalent: ""); item.target = self; item.representedObject = skin.action; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }
    @objc private func importSkinItem() { app.handle("skin") }
    @objc private func restoreSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setHiddenSkins(hiddenSkins.subtracting([id]))
        app.handle(id); refresh()
    }
    /// Deletes the selected skin — a built-in is hidden, an imported one is removed from disk — and switches to another.
    private func removeSkin() {
        guard entries.indices.contains(skins.selectedRow), entries.count > 1 else { return }
        let gone = entries[skins.selectedRow]
        if gone.action.hasPrefix("installed:") { try? FileManager.default.removeItem(atPath: String(gone.action.dropFirst(10))) }
        else { setHiddenSkins(hiddenSkins.union([gone.action])) }
        if let next = entries.first(where: { $0.action != gone.action }) { app.handle(next.action) }
        refresh()
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
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? categories.count : tableView === directoryTable ? directoryList.count : entries.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === directoryTable {
            let sources = directoryList
            guard sources.indices.contains(row) else { return nil }
            let cell = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 42))
            let box = NSButton(checkboxWithTitle: sources[row].name, target: self, action: #selector(directoryToggled(_:)))
            box.tag = row; box.state = sources[row].enabled ? .on : .off; box.frame = NSRect(x: 6, y: 20, width: 480, height: 20); cell.addSubview(box)
            let detail = NSTextField(labelWithString: sources[row].detail)
            detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
            detail.frame = NSRect(x: 26, y: 4, width: 468, height: 14); cell.addSubview(detail)
            return cell
        }
        let label = NSTextField(labelWithString: tableView === sidebar ? categories[row] : entries[row].title)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding, let table = notification.object as? NSTableView else { return }
        if table === sidebar, categories.indices.contains(table.selectedRow) { category = table.selectedRow; refresh() }
        else if table === directoryTable { updateDirectoryControl() }
        else if table === skins, entries.indices.contains(table.selectedRow) { app.handle(entries[table.selectedRow].action) }
    }
    @objc private func closePreferences() { window?.orderOut(nil) }
    @objc private func action(_ sender: NSButton) { if let id = sender.identifier?.rawValue { app.handle(id) } }
    @objc private func sizeChanged(_ sender: NSPopUpButton) { app.handle("scale" + String(format: "%g", Self.sizes[sender.indexOfSelectedItem])) }
    @objc private func topChanged(_ sender: NSButton) { app.window.level = sender.state == .on ? .floating : .normal; app.eqWindow.level = app.window.level; app.saveWindowLevel() }
    @objc private func freshChanged(_ sender: NSButton) {
        do { try app.library.update { $0.backgroundStations = sender.state == .on }; app.updateBackgroundStations() }
        catch { app.showError(error) }
    }
    @objc private func checkChanged(_ sender: NSButton) {
        do { try app.library.update { $0.checkStations = sender.state == .on }; app.updateBackgroundStations() }
        catch { app.showError(error) }
    }
    @objc private func tvAdultChanged(_ sender: NSButton) {
        if sender.state == .off {
            let alert = NSAlert()
            alert.messageText = "Show adult channels?"
            alert.informativeText = "Channels in your TV lists that look adult will no longer be hidden."
            alert.addButton(withTitle: "Show Them"); alert.addButton(withTitle: "Keep Hiding")
            guard alert.runModal() == .alertFirstButtonReturn else { sender.state = .on; return }
        }
        saveTVFilters { $0.tvHideAdult = sender.state == .on }
    }
    @objc private func tvUnreliableChanged(_ sender: NSButton) { saveTVFilters { $0.tvHideUnreliable = sender.state == .on } }
    private func saveTVFilters(_ edit: (inout Library.State) -> Void) {
        do { try app.library.update(edit); app.tvFiltersChanged() } catch { app.showError(error) }
    }
    @objc private func spatialStyleChanged(_ sender: NSPopUpButton) {
        if let style = SpatialStyle(rawValue: sender.indexOfSelectedItem) { app.engine.equalizer.spatial.style = style }
    }
    @objc private func spatialSliderChanged(_ sender: NSSlider) {
        if sender.identifier?.rawValue == "width" { app.engine.equalizer.spatial.width = sender.floatValue }
        else { app.engine.equalizer.spatial.amount = sender.floatValue }
    }
    @objc private func levelingChanged(_ sender: NSButton) { if (sender.state == .on) != app.engine.leveling { app.handle("leveling") } }
}
