import AppKit
import UniformTypeIdentifiers

final class FavoritesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let library: Library
    var play: ((Station) -> Void)?
    var edit: ((Station?) -> Void)?
    var report: ((Error) -> Void)?
    private var selectionButtons: [NSButton] = []

    init(library: Library) {
        self.library = library
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Favorite Stations"
        window.minSize = NSSize(width: 420, height: 220); window.isUserResizable = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let chrome = ClassicChrome(frame: NSRect(x: 0, y: 0, width: 540, height: 300)); chrome.title = "FAVORITE STATIONS"
        window.contentView = chrome; window.appearance = NSAppearance(named: .darkAqua)
        let content = chrome
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(closePanel))
        close.frame = NSRect(x: 528, y: 3, width: 9, height: 9); close.autoresizingMask = [.minXMargin]; close.isBordered = false; close.setAccessibilityLabel("Close favorites"); content.addSubview(close)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder; scroll.scrollerStyle = .legacy; scroll.backgroundColor = ClassicUI.black
        for (id, title, width) in [("name", "Station", 170.0), ("address", "Stream URL", 320.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.headerCell = LibraryHeader(textCell: title); column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self
        table.rowHeight = 20; table.backgroundColor = ClassicUI.black
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(playSelected)
        scroll.documentView = table
        content.addSubview(scroll)
        let buttons = NSStackView()
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for (title, selector) in [("Play", #selector(playSelected)), ("Add…", #selector(add)), ("Edit…", #selector(editSelected)), ("Remove", #selector(remove))] {
            let button = ClassicButton(title: title, target: self, action: selector)
            button.isBordered = false; button.font = ClassicUI.font
            button.widthAnchor.constraint(equalToConstant: 70).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            if title != "Add…" { selectionButtons.append(button) }
            buttons.addArrangedSubview(button)
        }
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let id = selected?.id; table.reloadData()
        if let id, let index = library.state.favorites.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        updateButtons()
    }
    @objc private func closePanel() { window?.orderOut(nil) }
    private func updateButtons() { selectionButtons.forEach { $0.isEnabled = selected != nil } }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = LibraryRow(); view.alternating = row % 2 == 1; return view }
    func numberOfRows(in tableView: NSTableView) -> Int { library.state.favorites.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let station = library.state.favorites[row]
        let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? station.name : station.address)
        label.font = ClassicUI.font; label.textColor = tableColumn?.identifier.rawValue == "name" ? ClassicUI.green : ClassicUI.text
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = station.address
        return label
    }
    private var selected: Station? { library.state.favorites.indices.contains(table.selectedRow) ? library.state.favorites[table.selectedRow] : nil }
    @objc private func playSelected() { if let selected { play?(selected) } }
    @objc private func add() { edit?(nil) }
    @objc private func editSelected() { if let selected { edit?(selected) } }
    @objc private func remove() {
        guard let selected else { return }
        do { try library.update { $0.favorites.removeAll { $0.id == selected.id } } }
        catch { report?(error) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: PlayerWindow!
    var view: PlayerView!
    var library: Library!
    let engine = RadioEngine()
    var favorites: FavoritesController!
    private var discovery: DiscoveryController?
    private var preferences: PreferencesController?
    private var recordedStation: UUID?
    var eqWindow: PlayerWindow!
    var eqView: EqualizerView!
    private var eqSave: DispatchWorkItem?
    private var volumeSave: DispatchWorkItem?
    private var importing = false
    private var readyForLinks = false
    private var pendingLink: URL?
    private var smokeFinished = false
    private var smokePath: String? { argument("--smoke-result") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            library = try Library(directory: argument("--data-dir").map { URL(fileURLWithPath: $0) })
        } catch {
            showError(RadioError.message("RadioPocket couldn’t read its saved library. Your existing file has been left intact.\n\n\(error.localizedDescription)"))
            NSApp.terminate(nil); return
        }
        engine.setVolume(smokePath == nil ? library.state.volume : 0)
        engine.setBalance(library.state.balance ?? 0)
        engine.equalizer.settings = library.state.equalizer ?? EQSettings()
        engine.leveling = library.state.leveling ?? false
        buildMenu()
        view = PlayerView(engine: engine)
        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 232), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RadioPocket"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        configureVisualizer()
        window.level = library.state.alwaysOnTop == true ? .floating : .normal
        scale(library.state.scale, save: false)
        window.center()
        window.setFrameAutosaveName("RadioPocket.Player")
        if smokePath == nil && argument("--preview") == nil {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
        favorites = FavoritesController(library: library)
        favorites.play = { [weak self] in self?.play($0) }
        favorites.edit = { [weak self] in self?.openDialog(station: $0, favoriteOnly: true) }
        favorites.report = { [weak self] in self?.showError($0) }
        library.changed = { [weak self] in self?.favorites.refresh(); self?.discovery?.libraryChanged() }
        updateBackgroundStations()
        startHousekeeping()
        view.action = { [weak self] in self?.handle($0) }
        view.volumeChanged = { [weak self] value in
            guard let self else { return }
            self.engine.setVolume(value)
            if self.sleepBaseVolume != nil { self.sleepBaseVolume = value }   // the fade continues from the new level
            self.scheduleVolumeSave()
        }
        view.balanceChanged = { [weak self] value in
            self?.engine.setBalance(value)
            self?.scheduleVolumeSave()
        }
        engine.onGiveUp = { [weak self] station, message in self?.stationFailed(station, message) }
        nowPlaying.action = { [weak self] in self?.handle($0) }
        nowPlaying.canSeek = { [weak self] in self?.engine.canTimeShift ?? false }
        nowPlaying.canPlay = { [weak self] in self.map { $0.engine.station != nil || $0.library.state.lastStation != nil } ?? false }
        nowPlaying.canSkip = { [weak self] in !(self?.library.state.favorites.isEmpty ?? true) }
        engine.changed = { [weak self] in
            guard let self else { return }
            self.view.needsDisplay = true
            self.visuals.hub.refresh()
            if self.smokePath == nil { self.nowPlaying.update(station: self.engine.station, title: self.engine.title, status: self.engine.status) }
            if self.engine.status == .playing, let station = self.engine.station {
                self.refreshTried.remove(station.id)
                // A moved station that plays: keep the working address in the favorite it came from.
                if let moved = self.addressFix, moved.address == station.address {
                    self.addressFix = nil
                    if self.library.state.favorites.contains(where: { $0.id == moved.id }) { try? self.library.save(moved) }
                }
            }
            if self.smokePath == nil, self.engine.status == .playing, let station = self.engine.station, self.recordedStation != station.id {
                self.recordedStation = station.id
                do { try self.library.recordRecent(station) } catch { self.showError(error) }
            }
            if self.smokePath != nil, self.engine.status == .playing {
                let eqReady = !CommandLine.arguments.contains("--test-eq") || (self.engine.equalizer.processedFrames > 10000 && self.engine.equalizer.measuredRatio < 0.35)
                let visReady = !CommandLine.arguments.contains("--test-vis") || self.visualizerSmokeResult() != nil
                if CommandLine.arguments.contains("--test-reconnect") {
                    // Passes after the stream played, was lost, and the engine got it playing again by itself.
                    if self.smokeWasPlaying == false { self.smokePlayStarts += 1 }
                    if self.smokePlayStarts >= 2 { self.smokeNote = "; playStarts=\(self.smokePlayStarts)"; self.finishSmoke(success: true) }
                } else if CommandLine.arguments.contains("--test-timeshift") { self.runTimeShiftSmoke() }
                else if eqReady && visReady { self.finishSmoke(success: true) }
            }
            if self.smokePath != nil, CommandLine.arguments.contains("--test-reconnect") { self.smokeWasPlaying = self.engine.status == .playing }
            if self.smokePath != nil, self.engine.status == .failed { self.finishSmoke(success: false) }
        }
        eqView = EqualizerView(equalizer: engine.equalizer)
        eqWindow = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 232), styleMask: [.borderless], backing: .buffered, defer: false)
        eqWindow.title = "RadioPocket Equalizer"
        eqWindow.level = window.level
        eqWindow.isReleasedWhenClosed = false; eqWindow.hasShadow = true; eqWindow.contentView = eqView
        eqView.action = { [weak self] in self?.presetAction($0) }
        engine.equalizer.changed = { [weak self] in
            guard let self else { return }
            self.eqView.refresh()
            self.engine.refreshEQStatus()
            self.eqSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persistEQ() }
            self.eqSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        scale(library.state.scale, save: false)
        let savedSkin = library.directory.appendingPathComponent("skin.json")
        if FileManager.default.fileExists(atPath: savedSkin.path) {
            do {
                let archive = try JSONDecoder().decode(ClassicSkin.Archive.self, from: Data(contentsOf: savedSkin))
                if let bundled = bundledSkinURL(archive.name) { view.skin = try ClassicSkin.load(bundled) }
                else {
                    let skin = try ClassicSkin(archive: archive)
                    try retainImportedSkin(skin)
                    view.skin = skin
                }
            }
            catch { showError(error) }
        }
        else if !FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("native-theme").path), let url = bundledSkinURL("base-2.91") {
            do { view.skin = try ClassicSkin.load(url) } catch { showError(error) }
        }
        if let skinPath = argument("--skin") {
            do { view.skin = try ClassicSkin.load(URL(fileURLWithPath: skinPath)) }
            catch { showError(error) }
        }
        eqView.skin = view.skin
        if let path = argument("--preferences-preview") {
            handle(argument("--preferences-page") ?? "skins")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let content = self.preferences?.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        if let path = argument("--directory-preview") {
            let browser = makeDiscovery()
            if let size = argument("--directory-size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                browser.window?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            browser.loaded = { success in
                if success, let content = browser.window?.contentView {
                    content.layoutSubtreeIfNeeded()
                    if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSApp.terminate(nil)
            }
            browser.showLibrary()
        }
        if let preview = argument("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if let self, let audit = self.argument("--ui-audit") {
                    var failures: [String] = []
                    for factor in [1.0, 2.0, 3.0] {
                        self.scale(factor, save: false)
                        for panel in [self.view as NSView, self.eqView as NSView] {
                            let controls = panel.subviews.filter { $0 is NSControl }
                            for control in controls {
                                if !panel.bounds.contains(control.frame) { failures.append("Control outside panel: \(control.identifier?.rawValue ?? "slider") at \(factor)×") }
                            }
                            for i in controls.indices { for j in controls.indices where j > i {
                                if controls[i].frame.intersects(controls[j].frame) { failures.append("Overlapping controls at \(factor)×") }
                            } }
                        }
                    }
                    self.scale(self.library.state.scale, save: false)
                    self.handle("shade")
                    if self.view.bounds.height != 14 { failures.append("Player shade failed") }
                    self.handle("shade")
                    if self.view.bounds.height != 116 { failures.append("Player restore failed") }
                    self.presetAction("shade")
                    if self.eqView.bounds.height != 14 { failures.append("EQ shade failed") }
                    self.presetAction("shade")
                    if self.eqView.bounds.height != 116 { failures.append("EQ restore failed") }
                    try? (failures.isEmpty ? "PASS: no overlapping or out-of-bounds controls at 1×/2×/3×; player and EQ shade/restore work.\n" : failures.joined(separator: "\n")).write(toFile: audit, atomically: true, encoding: .utf8)
                }
                if let self, let directory = self.argument("--panels-preview") {
                    let root = URL(fileURLWithPath: directory)
                    StreamDialog(station: nil, favoriteOnly: false).exportPreview(root.appendingPathComponent("RadioPocket-open-stream.png"))
                    let canvas = VisCanvasView(hub: self.visuals.hub, fullscreen: false)
                    canvas.nowPlaying = { ("Demo Radio", "Artist — Song Title", .playing) }
                    canvas.exportPreviews(into: root)
                    self.visuals.hub.hasSignal = { true }
                    self.visuals.hub.injectDemoFrame(phase: 2)
                    self.exportPreview(root.appendingPathComponent("RadioPocket-mini-visualizer.png").path)
                    self.visuals.exportPanelPreview(root.appendingPathComponent("RadioPocket-visualization-window.png"))
                    AboutController().exportPreview(root.appendingPathComponent("RadioPocket-about-history.png"), tab: "history")
                    if let content = self.favorites.window?.contentView {
                        content.layoutSubtreeIfNeeded()
                        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                            content.cacheDisplay(in: content.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("RadioPocket-favorites.png"))
                        }
                    }
                }
                self?.exportPreview(preview)
                if let path = self?.argument("--eq-preview"), let eqView = self?.eqView,
                   let rep = eqView.bitmapImageRepForCachingDisplay(in: eqView.bounds) {
                    eqView.cacheDisplay(in: eqView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        } else if let stream = argument("--smoke-stream") {
            if CommandLine.arguments.contains("--test-eq") {
                engine.setVolume(0.001)
                engine.equalizer.settings = EQSettings(enabled: true, preamp: -12)
            }
            engine.play(Station(name: "Local playback test", address: stream))
            DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--test-reconnect") ? 70 : 20)) { [weak self] in self?.finishSmoke(success: false) }
        }
        readyForLinks = true
        if let url = pendingLink { pendingLink = nil; self.application(NSApp, open: [url]) }
        if smokePath != nil && argument("--smoke-stream") == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finishSmoke(success: false) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // A radio player can play one station at a time. Do not silently import favorites.
        guard let url = urls.first else { return }
        guard readyForLinks else { pendingLink = url; return }
        do {
            let station = try ExternalRadioLink.station(for: url)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            play(station)
        } catch { showError(error) }
    }

    private func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    /// `--test-vis`: analyzes the live capture ring and passes when the loudest band is the 440 Hz test tone.
    private func visualizerSmokeResult() -> String? {
        var samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        guard let rate = samples.withUnsafeMutableBufferPointer({ engine.readVisSamples($0.baseAddress!, count: $0.count) }) else { return nil }
        let bands = SpectrumAnalyzer().bands(from: samples, sampleRate: rate)
        guard let loudest = bands.indices.max(by: { bands[$0] < bands[$1] }), bands[loudest] > 0.3 else { return nil }
        let ratio = powf(Float(min(16000, rate * 0.45)) / 45, 1 / Float(SpectrumAnalyzer.bands))
        let hertz = 45 * powf(ratio, Float(loudest) + 0.5)
        guard abs(hertz - 440) / 440 < 0.15 else { return nil }
        return "VIS loudest band ≈ \(Int(hertz)) Hz level \(bands[loudest])"
    }
    private var smokeNote = ""
    private var smokeWasPlaying = false
    private var smokePlayStarts = 0
    private var timeShiftStarted = false
    /// `--test-timeshift`: pause for 6 s, resume (must be ≥ 4 s behind live), rewind further, then jump back to live.
    private func runTimeShiftSmoke() {
        guard !timeShiftStarted else { return }
        timeShiftStarted = true
        let queue = DispatchQueue.main
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            engine.pause()
            queue.asyncAfter(deadline: .now() + 6) { [self] in
                let pausedStatus = engine.status
                engine.resume()
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    let resumed = engine.delay, statusAfterResume = engine.status
                    engine.seek(by: -3)
                    let rewound = engine.delay
                    engine.goLive()
                    queue.asyncAfter(deadline: .now() + 1) { [self] in
                        let live = engine.delay
                        smokeNote = String(format: "; paused=%@ resumedDelay=%.1f rewoundDelay=%.1f liveDelay=%.1f", pausedStatus.rawValue, resumed, rewound, live)
                        finishSmoke(success: pausedStatus == .paused && statusAfterResume == .playing && resumed >= 4 && rewound > resumed + 1.5 && live < 2 && engine.status == .playing)
                    }
                }
            }
        }
    }
    private func finishSmoke(success: Bool) {
        guard !smokeFinished, let path = smokePath else { return }
        smokeFinished = true
        let result = "\(success ? "PASS" : "FAIL"): \(engine.status.rawValue) — \(engine.detail); EQ frames=\(engine.equalizer.processedFrames), ratio=\(engine.equalizer.measuredRatio), title=\(engine.title)\(smokeNote)\(CommandLine.arguments.contains("--test-vis") ? "; " + (visualizerSmokeResult() ?? "VIS no tone detected") : "")\n"
        try? result.write(toFile: path, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 3 : 0)) { [weak self] in
            self?.engine.stop(); NSApp.terminate(nil)
        }
    }
    private func exportPreview(_ path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    private func configureVisualizer() {
        visuals.playerWindow = window
        visuals.hub.settings = library.state.visualizer ?? VisSettings()
        visuals.hub.source = { [weak self] out, count in self?.engine.readVisSamples(out, count: count) }
        visuals.hub.hasSignal = { [weak self] in self?.engine.hasVisSignal ?? false }
        visuals.perform = { [weak self] in self?.handle($0) }
        visuals.nowPlaying = { [weak self] in
            guard let self else { return ("", "", .idle) }
            let signal: VisSignal = self.engine.status != .playing ? .idle : self.engine.hasVisSignal ? .playing : .unavailable
            return (self.engine.station?.name ?? "", self.engine.station == nil ? "" : self.engine.title, signal)
        }
        view.attach(visuals: visuals)
        visuals.hub.observeSettings { [weak self] settings in
            guard let self else { return }
            self.visSave?.cancel()
            let work = DispatchWorkItem { [weak self] in try? self?.library.update { $0.visualizer = settings } }
            self.visSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    /// Menu bar in the standard macOS order: app, File, Edit, the app's own Controls, View, Visualization, Window, Help.
    private func buildMenu() {
        // macOS would add its own Enter Full Screen (⌃⌘F) to View; that shortcut belongs to the full-screen visualization.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        let menu = NSMenu()
        @discardableResult
        func add(_ title: String, to bar: NSMenu = menu) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); root.submenu = submenu; bar.addItem(root)
            return submenu
        }
        func command(_ title: String, _ id: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], to target: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.representedObject = id; item.target = self; target.addItem(item)
        }
        func standard(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let arrow = { (key: Int) in String(UnicodeScalar(key)!) }

        let app = add("RadioPocket")
        standard("About RadioPocket", #selector(aboutApp), target: self, to: app)
        app.addItem(.separator())
        command("Preferences…", "preferences", ",", to: app)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesRoot = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); servicesRoot.submenu = services; app.addItem(servicesRoot)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        standard("Hide RadioPocket", #selector(NSApplication.hide(_:)), "h", to: app)
        standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], to: app)
        standard("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app)
        app.addItem(.separator())
        standard("Quit RadioPocket", #selector(NSApplication.terminate(_:)), "q", to: app)

        let file = add("File")
        command("Open Stream…", "open", "o", to: file)
        file.addItem(.separator())
        command("Save Favorite…", "favorite", "d", to: file)
        command("Station Info…", "info", "i", [.command, .shift], to: file)
        command("Copy Open-in-Player Link", "copyLink", to: file)
        file.addItem(.separator())
        command("Import Classic Skin…", "skin", "i", to: file)
        file.addItem(.separator())
        standard("Close Window", #selector(closeKeyWindow), "w", target: self, to: file)

        let edit = add("Edit")
        standard("Undo", Selector(("undo:")), "z", to: edit)
        standard("Redo", Selector(("redo:")), "z", [.command, .shift], to: edit)
        edit.addItem(.separator())
        for (name, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v")] { standard(name, Selector(action), key, to: edit) }
        standard("Delete", Selector(("delete:")), to: edit)
        standard("Select All", Selector(("selectAll:")), "a", to: edit)

        let controls = add("Controls")
        command("Play", "toggle", "p", to: controls)
        command("Stop", "stop", ".", to: controls)
        controls.addItem(.separator())
        command("Rewind 10 Seconds", "back10", "[", to: controls)
        command("Forward 10 Seconds", "forward10", "]", to: controls)
        command("Jump to Live", "live", "j", to: controls)
        controls.addItem(.separator())
        command("Previous Favorite", "previous", arrow(NSLeftArrowFunctionKey), [.command, .option], to: controls)
        command("Next Favorite", "next", arrow(NSRightArrowFunctionKey), [.command, .option], to: controls)
        command("Jump to Station…", "jump", "j", [.command, .shift], to: controls)
        controls.addItem(.separator())
        command("Volume Up", "volumeUp", arrow(NSUpArrowFunctionKey), to: controls)
        command("Volume Down", "volumeDown", arrow(NSDownArrowFunctionKey), to: controls)
        controls.addItem(.separator())
        let sleep = add("Sleep Timer", to: controls)
        for (title, minutes) in [("Off", 0), ("15 Minutes", 15), ("30 Minutes", 30), ("45 Minutes", 45), ("60 Minutes", 60), ("90 Minutes", 90), ("2 Hours", 120)] {
            command(title, "sleep:\(minutes)", to: sleep)
            if minutes == 0 { sleep.addItem(.separator()) }
        }
        command("Loudness Leveling", "leveling", to: controls)

        let view = add("View")
        for factor in 1...3 { command("Size: \(factor)×", "scale\(factor)", "\(factor)", to: view) }
        view.addItem(.separator())
        command("Compact Player", "shade", to: view)
        command("Always on Top", "ontop", "t", to: view)
        view.addItem(.separator())
        command("Choose Skin…", "skins", "k", to: view)
        command("Use RadioPocket Theme", "resetSkin", to: view)

        let visualization = NSMenuItem(title: "Visualization", action: nil, keyEquivalent: "")
        visualization.submenu = visuals.menu(withKeys: true); menu.addItem(visualization)

        let windows = add("Window")
        standard("Minimize", #selector(minimizeKeyWindow), "m", target: self, to: windows)
        windows.addItem(.separator())
        command("RadioPocket", "player", to: windows)
        command("Station Library", "discovery", "b", to: windows)
        command("Favorite Stations", "favorites", "l", to: windows)
        command("Equalizer", "equalizer", "e", to: windows)
        command("Visualization", "vis:panel", to: windows)
        windows.addItem(.separator())
        standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), to: windows)

        let help = add("Help")
        command("Keyboard Shortcuts", "help:shortcuts", to: help)
        command("Version History", "help:history", to: help)

        NSApp.mainMenu = menu
        NSApp.helpMenu = help
        // The system also adds a (here redundant) Enter Full Screen item to View; keep it out.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: view, queue: .main) { note in
            guard let menu = note.object as? NSMenu else { return }
            menu.items.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }.forEach(menu.removeItem)
        }
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "ontop" {
            window.level = window.level == .floating ? .normal : .floating
            eqWindow?.level = window.level
            saveWindowLevel()
        } else if let id = sender.representedObject as? String { handle(id) }
    }
    @objc private func minimizeKeyWindow() { NSApp.keyWindow?.miniaturize(nil) }
    /// Closing the player quits, as its × button does; any other panel just closes.
    @objc private func closeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key === window { handle("close") }
        else if key === visuals.panelWindow { visuals.closePanel() }
        else { key.close() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeKeyWindow) { return NSApp.modalWindow == nil && NSApp.keyWindow != nil }
        if item.action == #selector(minimizeKeyWindow) { return NSApp.keyWindow?.styleMask.contains(.miniaturizable) == true }
        guard let id = item.representedObject as? String, library != nil else { return true }
        if id.hasPrefix("vis:") { return visuals.validateMenuItem(item) }
        func mark(_ on: Bool) { item.state = on ? .on : .off }
        var enabled = true
        switch id {
        case "toggle":
            item.title = engine.status == .playing || engine.status == .connecting ? "Pause" : "Play"
            enabled = engine.station != nil || library.state.lastStation != nil
        case "stop": enabled = engine.status != .stopped
        case "back10", "forward10", "live": enabled = engine.canTimeShift
        case "previous", "next": enabled = !library.state.favorites.isEmpty
        case "leveling": mark(engine.leveling)
        case "ontop": mark(window.level == .floating)
        case "shade": mark(view.shaded)
        case "resetSkin": mark(view.skin == nil)
        case "discovery": mark(discovery?.window?.isVisible == true)
        case "favorites": mark(favorites.window?.isVisible == true)
        case "equalizer": mark(eqWindow.isVisible)
        case "player": mark(window.isVisible)
        case "scale1", "scale2", "scale3": mark(library.state.scale == Double(id.dropFirst(5)))
        default:
            if id.hasPrefix("sleep:") { mark(Int(id.dropFirst(6)) == sleepMinutes) }
        }
        return enabled
    }
    private var about: AboutController?
    private var jump: JumpToStationController?
    private var info: StationInfoController?
    private let nowPlaying = NowPlayingController()
    let visuals = VisualizerController()
    private var visSave: DispatchWorkItem?
    @objc private func aboutApp() {
        if about == nil { about = AboutController() }
        about?.present()
    }
    func handle(_ id: String) {
        switch id {
        case "copyLink":
            guard let station = engine.station ?? library.state.lastStation else {
                showError(RadioError.message("Choose a station first to copy its Open-in-Player link.")); return
            }
            do {
                let url = try ExternalRadioLink.link(for: station)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } catch { showError(error) }
        case "open": openDialog()
        case "play":
            if engine.station != nil { engine.resume() }
            else if let last = library.state.lastStation { play(last) }
            else { openDialog() }
        case "toggle": handle(engine.status == .playing || engine.status == .connecting ? "pause" : "play")
        case "pause": engine.pause()
        case "stop": engine.stop()
        case "back10": engine.seek(by: -10)
        case "forward10": engine.seek(by: 10)
        case "live": engine.goLive()
        case "volumeUp": view.volumeChanged?(min(1, engine.player.volume + 0.05))
        case "volumeDown": view.volumeChanged?(max(0, engine.player.volume - 0.05))
        case "favorite":
            if let current = engine.station ?? library.state.lastStation { openDialog(station: current, favoriteOnly: true) }
            else { openDialog(favoriteOnly: true) }
        case "discovery":
            // PL and the menu item toggle: a second click closes the library.
            let browser = makeDiscovery()
            if browser.window?.isVisible == true { browser.window?.close() } else { browser.showLibrary() }
        case "clearstations":
            clearSavedStations()
        case "favorites":
            favorites.showWindow(nil)
            if let frame = window?.frame { favorites.window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.minY - 8)) }
            favorites.window?.makeKeyAndOrderFront(nil)
        case "previous", "next":
            let list = library.state.favorites
            guard !list.isEmpty else { handle("favorites"); return }
            let index = list.firstIndex { $0.address == engine.station?.address }
            let next = index.map { ($0 + (id == "next" ? 1 : list.count - 1)) % list.count } ?? 0
            play(list[next])
        case "equalizer":
            if eqWindow.isVisible { eqWindow.orderOut(nil) }
            else {
                eqWindow.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: window.frame.minY))
                eqWindow.makeKeyAndOrderFront(nil)
            }
        case "skins", "preferences", "directories", "visprefs":
            if preferences == nil { preferences = PreferencesController(app: self) }
            preferences?.present(skins: id == "skins", directories: id == "directories", visualization: id == "visprefs")
        case "skin":
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .data, .zip]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { importSkin(url) }
        case "resetSkin":
            do {
                let url = library.directory.appendingPathComponent("skin.json")
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try Data().write(to: library.directory.appendingPathComponent("native-theme"), options: .atomic)
                view.skin = nil
                eqView.skin = nil
                preferences?.refresh()
            } catch { showError(error) }
        case "jump":
            if jump == nil { jump = JumpToStationController(library: library); jump?.play = { [weak self] in self?.play($0) } }
            jump?.present(over: window)
        case "info":
            if info == nil { info = StationInfoController(engine: engine, directory: directoryClient) }
            info?.present(over: window)
        case "leveling":
            engine.leveling.toggle()
            do { try library.update { $0.leveling = engine.leveling } } catch { showError(error) }
        case "shade": view.shaded.toggle(); resizePlayer()
        case "scale1": scale(1)
        case "scale2": scale(2)
        case "scale3": scale(3)
        case "minimize": window.miniaturize(nil)
        case "player":
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        case "about": aboutApp()
        case "help:shortcuts", "help:history":
            if about == nil { about = AboutController() }
            about?.present(tab: id == "help:history" ? .history : .shortcuts)
        case "close": NSApp.terminate(nil)
        case "menu":
            let menu = NSMenu()
            for (title, id) in [("Open Stream…", "open"), ("Jump to Station…", "jump"), ("Save Favorite…", "favorite"), ("Station Info…", "info"), ("", ""),
                                ("Station Library", "discovery"), ("Favorite Stations", "favorites"), ("Equalizer", "equalizer"), ("Visualization", "vis:panel"), ("Full Screen Visualization", "vis:fullscreen"), ("", ""),
                                ("Loudness Leveling", "leveling"), ("", ""),
                                ("Choose Skin…", "skins"), ("Import Classic Skin…", "skin"), ("Use RadioPocket Theme", "resetSkin"), ("", ""),
                                ("Size: 1×", "scale1"), ("Size: 2×", "scale2"), ("Size: 3×", "scale3")] {
                if id.isEmpty { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = id; menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 6, y: 14), in: view)
        default:
            if id.hasPrefix("sleep:"), let minutes = Int(id.dropFirst(6)) { setSleep(minutes: minutes) }
            else if id.hasPrefix("vis:") { visuals.handle(id) }
            else if id.hasPrefix("bundled:"), let url = bundledSkinURL(String(id.dropFirst(8))) { importSkin(url) }
            else if id.hasPrefix("installed:") { importSkin(URL(fileURLWithPath: String(id.dropFirst(10)))) }
            else if id.hasPrefix("skin:") { importSkin(URL(fileURLWithPath: String(id.dropFirst(5)))) }
        }
    }
    private func scale(_ value: Double, save: Bool = true) {
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: 275 * value, height: (view.shaded ? 14 : 116) * value))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        view.setBoundsSize(NSSize(width: 275, height: view.shaded ? 14 : 116))
        view.needsDisplay = true
        if let eqWindow, let eqView {
            eqWindow.setContentSize(NSSize(width: 275 * value, height: (eqView.shaded ? 14 : 116) * value))
            eqView.setBoundsSize(NSSize(width: 275, height: eqView.shaded ? 14 : 116))
            eqWindow.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: window.frame.minY))
        }
        if save { do { try library.update { $0.scale = value } } catch { showError(error) } }
    }
    private func resizePlayer() {
        // An equalizer docked under the player follows its bottom edge when the player shades or restores.
        let docked = eqWindow.isVisible && abs(eqWindow.frame.maxY - window.frame.minY) <= 6
        defer { if docked { eqWindow.setFrameTopLeftPoint(NSPoint(x: eqWindow.frame.minX, y: window.frame.minY)) } }
        let scale = library.state.scale, top = window.frame.maxY
        window.setContentSize(NSSize(width: 275 * scale, height: (view.shaded ? 14 : 116) * scale))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        view.setBoundsSize(NSSize(width: 275, height: view.shaded ? 14 : 116))
    }
    // MARK: When a station can’t be reached

    private var refreshTried = Set<UUID>()
    private var addressFix: Station?
    private var offering = false

    /// Called after automatic reconnection gives up. First asks the directory whether the station moved;
    /// if not, offers the directory’s closest alternative, a search, or the next favorite.
    private func stationFailed(_ station: Station, _ message: String) {
        guard smokePath == nil, library != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.refreshTried.contains(station.id), let current = await self.directoryClient.refreshed(uuid: station.id.uuidString), current.address != station.address {
                self.refreshTried.insert(station.id)
                let moved = Station(id: station.id, name: station.name, address: current.address)
                self.addressFix = moved
                self.play(moved); return
            }
            let alternates = await self.directoryClient.alternates(for: station)
            guard self.engine.status == .failed, self.engine.station?.id == station.id, !self.offering else { return }
            self.offerAlternatives(for: station, message: message, alternates: alternates)
        }
    }

    private func offerAlternatives(for station: Station, message: String, alternates: [RadioListing]) {
        offering = true; defer { offering = false }
        let alert = NSAlert()
        alert.messageText = "“\(station.name)” can’t be reached"
        alert.informativeText = message + "\n\nRadioPocket keeps trying again when your network comes back, or you can switch now."
        var actions: [() -> Void] = []
        if let alternate = alternates.first {
            let country = alternate.country.isEmpty ? "" : " (\(alternate.country))"
            alert.addButton(withTitle: "Try “\(String(alternate.name.prefix(34)))”\(country)")
            actions.append { [weak self] in self?.play(alternate.station) }
        }
        alert.addButton(withTitle: "Find Similar…")
        actions.append { [weak self] in self?.makeDiscovery().findSimilar(to: station.name) }
        if library.state.favorites.contains(where: { $0.address != station.address }) {
            alert.addButton(withTitle: "Next Favorite")
            actions.append { [weak self] in self?.handle("next") }
        }
        alert.addButton(withTitle: "Dismiss")
        actions.append {}
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(index) { actions[index]() }
    }

    // MARK: Sleep timer

    private var sleepTimer: Timer?
    private var sleepDeadline: Date?
    private var sleepBaseVolume: Float?
    private var sleepMinutes = 0
    /// Stops playback after `minutes` (0 cancels). The last 20 seconds fade the volume down; it is restored afterwards.
    private func setSleep(minutes: Int) {
        cancelSleep()
        sleepMinutes = minutes
        guard minutes > 0 else { return }
        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sleepTick() }
        RunLoop.main.add(timer, forMode: .common); sleepTimer = timer
        sleepTick()
    }
    private func cancelSleep() {
        sleepTimer?.invalidate(); sleepTimer = nil; sleepDeadline = nil; sleepMinutes = 0
        if let base = sleepBaseVolume { sleepBaseVolume = nil; engine.setVolume(base) }
        engine.sleepRemaining = nil
        view?.needsDisplay = true
    }
    private func sleepTick() {
        guard let deadline = sleepDeadline else { return }
        let remaining = Int(ceil(deadline.timeIntervalSinceNow))
        guard remaining > 0 else { cancelSleep(); engine.stop(); return }
        engine.sleepRemaining = remaining
        if remaining <= 20, engine.status == .playing {
            if sleepBaseVolume == nil { sleepBaseVolume = engine.player.volume }
            engine.setVolume((sleepBaseVolume ?? 1) * Float(remaining) / 20)
        }
        view.needsDisplay = true
    }

    private func play(_ station: Station) {
        info?.stationChanged()
        do { try library.update { $0.lastStation = station }; recordedStation = nil; engine.play(station) }
        catch { showError(error) }
    }
    func saveWindowLevel() {
        do { try library.update { $0.alwaysOnTop = window.level == .floating } } catch { showError(error) }
    }
    private func scheduleVolumeSave() {
        volumeSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistVolume() }
        volumeSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private func persistVolume() {
        guard library != nil, smokePath == nil else { return }
        do { try library.update { $0.volume = sleepBaseVolume ?? engine.player.volume; $0.balance = engine.balance } } catch { showError(error) }
    }
    func openDialog(station: Station? = nil, favoriteOnly: Bool = false) {
        let dialog = StreamDialog(station: station, favoriteOnly: favoriteOnly)
        if let (entry, save) = dialog.run() {
            do {
                if save { try library.save(entry) }
                if !favoriteOnly { play(entry) }
            } catch { showError(error) }
        }
    }
    let bundledSkins: [(String, String)] = [
        ("Winamp Classic — Original Default", "base-2.91"),
        ("Amiga PPC Dark", "AmigaPPC-dark"),
        ("Internet Archive", "Internet-Archive"),
        ("Mac OS X Aqua", "MacOSXAqua1-5"),
        ("My Funny Valentine", "My_Funny_Valentine"),
        ("Sonic Attitude", "Sonic_Attitude"),
        ("TopazAmp", "TopazAmp1-2"),
        ("Vizor", "Vizor1-01"),
        ("XMMS Turquoise", "XMMS-Turquoise"),
        ("Zaxon Remake", "ZaxonRemake1-0"),
        ("Rei", "rei_1")
    ]
    private func bundledSkinURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wsz", subdirectory: "Skins")
    }
    private func retainImportedSkin(_ skin: ClassicSkin) throws {
        guard !bundledSkins.contains(where: { $0.1 == skin.name }) else { return }
        let folder = library.directory.appendingPathComponent("Installed Skins")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = String(skin.name.map { "/:\u{0}".contains($0) ? "_" : $0 }.prefix(180))
        try JSONEncoder().encode(skin.archive).write(to: folder.appendingPathComponent(safeName + ".json"), options: .atomic)
    }
    private func importSkin(_ url: URL) {
        guard !importing else { return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if url.pathExtension == "json" { return try ClassicSkin(archive: JSONDecoder().decode(ClassicSkin.Archive.self, from: Data(contentsOf: url))) }
                return try ClassicSkin.load(url)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importing = false
                do {
                    let skin = try result.get()
                    try self.retainImportedSkin(skin)
                    try JSONEncoder().encode(skin.archive).write(to: self.library.directory.appendingPathComponent("skin.json"), options: .atomic)
                    self.view.skin = skin
                    self.eqView.skin = skin
                    self.preferences?.refresh()
                } catch { self.showError(error) }
            }
        }
    }
    private lazy var directoryClient: RadioDirectory = {
        // Local-only test endpoint; production always uses Radio Browser's HTTPS mirrors.
        if argument("--data-dir") != nil, let raw = argument("--directory-api"), let url = URL(string: raw),
           ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), ["http", "https"].contains(url.scheme ?? "") {
            return RadioDirectory(baseURLs: [url], cache: stationCache)
        }
        return RadioDirectory(cache: stationCache)
    }()
    private lazy var stationCache = StationCache.standard(dataDirectory: argument("--data-dir").map { URL(fileURLWithPath: $0) })
    /// Opens the station lists from disk and keeps them fresh in the background; nothing happens in smoke or preview runs.
    func updateBackgroundStations() {
        guard smokePath == nil, argument("--preview") == nil else { return }
        let client = directoryClient, sources = library.state.directories ?? []
        if library.state.backgroundStations == false { Task { await client.stopBackgroundRefresh() } }
        else { Task { await client.configure(sources); await client.startBackgroundRefresh() } }
    }
    func clearSavedStations() { let client = directoryClient; Task { await client.clearSavedStations() } }
    private var housekeeping: Housekeeping?
    /// Gives memory back on system memory pressure and after the app has sat in the background; see Housekeeping.
    private func startHousekeeping() {
        guard smokePath == nil, argument("--preview") == nil else { return }
        housekeeping = Housekeeping(directory: directoryClient)
        housekeeping?.start()
    }
    private func makeDiscovery() -> DiscoveryController {
        if let discovery { return discovery }
        let client = directoryClient
        let browser = DiscoveryController(library: library, directory: client)
        browser.play = { [weak self] in self?.play($0) }
        browser.openStream = { [weak self] in self?.openDialog() }
        browser.report = { [weak self] in self?.showError($0) }
        discovery = browser
        return browser
    }

    private func persistEQ() {
        guard library != nil, smokePath == nil else { return }
        do { try library.update { $0.equalizer = engine.equalizer.settings } } catch { showError(error) }
    }
    private func presetAction(_ action: String) {
        if action == "shade" {
            eqView.shaded.toggle()
            let top = eqWindow.frame.maxY, factor = library.state.scale
            eqWindow.setContentSize(NSSize(width: 275 * factor, height: (eqView.shaded ? 14 : 116) * factor))
            eqWindow.setFrameOrigin(NSPoint(x: eqWindow.frame.minX, y: top - eqWindow.frame.height))
            eqView.setBoundsSize(NSSize(width: 275, height: eqView.shaded ? 14 : 116)); return
        }
        do {
            switch action {
            case "save":
                let alert = NSAlert(); alert.messageText = "Save Equalizer Preset"
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                field.placeholderString = "Preset name"; alert.accessoryView = field; alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw RadioError.message("Give the preset a name.") }
                guard !EQPreset.classic.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw RadioError.message("Choose a different name to preserve the built-in preset.") }
                var settings = engine.equalizer.settings
                settings.custom.removeAll { $0.name == name }
                settings.custom.append(EQPreset(name: String(name.prefix(128)), preamp: settings.preamp, bands: settings.bands))
                settings.preset = String(name.prefix(128)); engine.equalizer.settings = settings
            case "import":
                let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "eqf") ?? .data, UTType(filenameExtension: "q1") ?? .data]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw RadioError.message("This preset library is too large.") }
                let imported = try EQFile.read(Data(contentsOf: url))
                var settings = engine.equalizer.settings
                for preset in imported {
                    var copy = preset
                    if EQPreset.classic.contains(where: { $0.name == copy.name }) { copy.name += " (Imported)" }
                    settings.custom.removeAll { $0.name == copy.name }; settings.custom.append(copy)
                }
                engine.equalizer.settings = settings
                if let first = settings.custom.last { engine.equalizer.select(first) }
            case "export":
                let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "eqf") ?? .data]
                panel.nameFieldStringValue = engine.equalizer.settings.preset + ".eqf"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let settings = engine.equalizer.settings
                try EQFile.write(EQPreset(name: settings.preset, preamp: settings.preamp, bands: settings.bands)).write(to: url, options: .atomic)
            default: break
            }
        } catch { showError(error) }
    }
    /// Tells an open library window that the user changed their directory list.
    func directoriesChanged() { discovery?.refreshSources(); updateBackgroundStations() }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "RadioPocket"; alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        volumeSave?.cancel()
        eqSave?.cancel()
        persistEQ()
        persistVolume()
        engine.stop()
    }
}
