import AppKit

private typealias BrowserTheme = ClassicUI
private typealias LibraryChrome = ClassicChrome
private typealias LibraryButton = ClassicButton

final class LibraryHeader: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        ClassicUI.palette.headerBackground.setFill(); cellFrame.fill()
        ClassicUI.palette.headerText.withAlphaComponent(0.35).setFill(); NSRect(x: cellFrame.minX, y: cellFrame.minY, width: cellFrame.width, height: 1).fill()
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        ClassicUI.caption(stringValue, rect: cellFrame.insetBy(dx: 3, dy: 0), color: ClassicUI.palette.headerText, font: BrowserTheme.small, alignment: .left)
    }
}

final class LibraryRow: NSTableRowView {
    var alternating = false
    override func drawBackground(in dirtyRect: NSRect) {
        (alternating ? ClassicUI.palette.itemAlternate : BrowserTheme.black).setFill(); bounds.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) { BrowserTheme.selection.setFill(); bounds.fill() }
}

private final class StationTable: NSTableView {
    var enter: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { enter?() } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { deselectAll(nil) }
        return super.menu(for: event)
    }
}

private enum LibraryScope: Equatable {
    case popular, rated, alphabetical, genre(String), favorites, recent
    var local: Bool { self == .favorites || self == .recent }
    var title: String {
        switch self {
        case .popular: return "POPULAR STATIONS"
        case .rated: return "TOP RATED STATIONS"
        case .alphabetical: return "ALL STATIONS"
        case .genre(let value): return value.uppercased() + " RADIO"
        case .favorites: return "FAVORITE STATIONS"
        case .recent: return "RECENTLY PLAYED"
        }
    }
}
private final class LibraryNode {
    let title: String
    let scope: LibraryScope?
    let children: [LibraryNode]
    init(_ title: String, scope: LibraryScope? = nil, children: [LibraryNode] = []) { self.title = title; self.scope = scope; self.children = children }
}

final class DiscoveryController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    private let library: Library
    private let directory: RadioDirectory
    var play: ((Station) -> Void)?
    var openStream: (() -> Void)?
    var loaded: ((Bool) -> Void)?
    private let table = StationTable()
    private let sidebar = NSOutlineView()
    private let search = NSTextField()
    private let genre = ClassicCombo()
    private let country = ClassicPopup()
    private let format = ClassicPopup()
    private let bitrate = ClassicPopup()
    private let order = ClassicPopup()
    private let sourceMenu = ClassicPopup()
    private let heading = NSTextField(labelWithString: "POPULAR STATIONS")
    private let status = NSTextField(labelWithString: "")
    private let nowPlaying = NSTextField(labelWithString: "READY")
    private let selectedTitle = NSTextField(labelWithString: "")
    private let selectedInfo = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var tune: NSButton!
    private var save: NSButton!
    private var scope: LibraryScope = .popular
    private var query = DirectoryQuery()
    private var rows: [RadioListing] = []
    private var hasMore = false
    private var loadingMore = false
    private var busy = false
    private var hasLoaded = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var suppressSelection = false
    private var suppressSort = false
    private let genres = ["Alternative", "Ambient", "Blues", "Classical", "Country", "Electronic", "Folk", "Hip Hop", "Indie", "Jazz", "Metal", "News", "Pop", "Reggae", "Rock", "Soul", "Talk", "World"]
    private var nodes: [LibraryNode] = []
    private var sideWidth: NSLayoutConstraint!, sideGap: NSLayoutConstraint!
    private var filterHeight: NSLayoutConstraint!, filterGap: NSLayoutConstraint!, tableGap: NSLayoutConstraint!
    private weak var filterRowView: NSView?
    private weak var sideScrollView: NSView?
    /// Column share of the table width and the narrowest width each stays readable at; the least important drop out first.
    private let columnLayout: [(id: String, share: CGFloat, minimum: CGFloat, hideBelow: CGFloat)] = [
        ("name", 0.36, 90, 0), ("tags", 0.22, 60, 520), ("country", 0.14, 50, 440), ("codec", 0.11, 44, 0), ("quality", 0.10, 52, 0), ("votes", 0.09, 40, 360)]

    init(library: Library, directory: RadioDirectory = RadioDirectory()) {
        self.library = library; self.directory = directory
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 500), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RadioPocket — Internet Radio Library"
        window.minSize = NSSize(width: 480, height: 300); window.isUserResizable = true
        window.isReleasedWhenClosed = false; window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.contentView = LibraryChrome(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        build()
        window.center(); window.setFrameAutosaveName("RadioPocket.Discovery")
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Opens the library on the popular list with the station’s name already searched.
    func findSimilar(to name: String) {
        showLibrary()
        search.stringValue = name
        format.selectItem(at: 0)
        if let row = (0..<sidebar.numberOfRows).first(where: { (sidebar.item(atRow: $0) as? LibraryNode)?.scope == .popular }) {
            if sidebar.selectedRow == row { searchNow() } else { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }
    /// Rebuilds the directory picker from Preferences, keeping the current choice when it still exists.
    func refreshSources() {
        let current = sourceMenu.selectedItem?.representedObject as? String ?? "all"
        let enabled = DirectorySource.resolved(library.state.directories).filter(\.enabled)
        sourceMenu.removeAllItems()
        sourceMenu.addItem(withTitle: "All Directories"); sourceMenu.lastItem?.representedObject = "all"
        for source in enabled { sourceMenu.addItem(withTitle: source.name); sourceMenu.lastItem?.representedObject = source.id }
        if let index = sourceMenu.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) { sourceMenu.selectItem(at: index) }
        else { sourceMenu.selectItem(at: 0) }
        query.sourceID = sourceMenu.selectedItem?.representedObject as? String ?? "all"
    }
    func showLibrary() {
        let previous = query.sourceID
        refreshSources()
        if hasLoaded, previous != query.sourceID { hasLoaded = false }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        if !hasLoaded { load() }
    }
    func windowDidResize(_ notification: Notification) { adaptLayout() }
    /// Compact windows shed the genre sidebar, then the filter row; the table keeps its columns proportional to its width.
    private func adaptLayout() {
        guard let root = window?.contentView, sideWidth != nil else { return }
        let showSide = root.bounds.width >= 700
        sideWidth.constant = showSide ? 145 : 0; sideGap.constant = showSide ? 9 : 0; sideScrollView?.isHidden = !showSide
        let mainWidth = root.bounds.width - 24 - (showSide ? 154 : 0)
        let showFilters = mainWidth >= 580 && root.bounds.height >= 380
        filterRowView.map { ($0 as? NSStackView)?.arrangedSubviews.forEach { $0.isHidden = !showFilters } }
        filterHeight.constant = showFilters ? 22 : 0; filterGap.constant = showFilters ? 7 : 0; tableGap.constant = showFilters ? 6 : 0
        layoutColumns(width: mainWidth)
    }
    private func layoutColumns(width: CGFloat) {
        // Fit the columns to the clip view itself: the border, the legacy scroller and the 1pt cell spacing
        // between columns all come out of the width, or the table scrolls sideways and slides under the scroller.
        let clip = table.enclosingScrollView.map { $0.contentSize.width } ?? 0
        let usable = clip > 100 ? clip : width - 4 - 16
        let shown = columnLayout.filter { usable - CGFloat(columnLayout.count) >= $0.hideBelow }
        let available = max(120, usable - table.intercellSpacing.width * CGFloat(shown.count))
        let total = shown.reduce(0) { $0 + $1.share }
        for entry in columnLayout {
            guard let column = table.tableColumn(withIdentifier: .init(entry.id)) else { continue }
            column.isHidden = !shown.contains { $0.id == entry.id }
            column.minWidth = min(entry.minimum, 30)
            column.width = max(entry.minimum, (available * entry.share / total).rounded(.down))
        }
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); generation = UUID()
        if busy || loadingMore { hasLoaded = false }
        loadingMore = false
        setBusy(false)
    }
    func libraryChanged() {
        guard window?.isVisible == true else { if scope.local { hasLoaded = false }; return }
        if scope.local { loadLocal(preservingSelection: true) } else { reloadKeepingSelection(); updateSelection() }
    }
    func updatePlayback(_ engine: RadioEngine) {
        guard window?.isVisible == true else { return }
        nowPlaying.stringValue = engine.station.map { "\(engine.status.rawValue) • \($0.name)" } ?? engine.status.rawValue
        nowPlaying.toolTip = engine.title + "\n" + engine.detail
    }

    private func label(_ value: String, color: NSColor = BrowserTheme.dim) -> NSTextField {
        let field = NSTextField(labelWithString: value); field.font = BrowserTheme.small; field.textColor = color; field.lineBreakMode = .byTruncatingTail
        return field
    }
    private func add(_ view: NSView, to parent: NSView) { view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view) }
    private func button(_ title: String, _ selector: Selector, width: CGFloat) -> NSButton {
        let b = LibraryButton(title: title, target: self, action: selector); b.isBordered = false; b.setButtonType(.momentaryPushIn)
        b.font = BrowserTheme.small; b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }
    private func row(_ children: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: children); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing; row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
    private func popup(_ popup: NSPopUpButton, label: String, values: [String], width: CGFloat) {
        popup.addItems(withTitles: values); popup.menu?.autoenablesItems = false; popup.font = BrowserTheme.small; popup.controlSize = .small
        popup.heightAnchor.constraint(equalToConstant: 22).isActive = true
        popup.target = self; popup.action = #selector(filtersChanged)
        popup.setAccessibilityLabel(label); popup.toolTip = label
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .lineBorder; scroll.scrollerStyle = .legacy; scroll.backgroundColor = BrowserTheme.black; scroll.drawsBackground = true
        table.backgroundColor = BrowserTheme.black; table.rowHeight = 19; table.intercellSpacing = NSSize(width: 1, height: 0)
        table.selectionHighlightStyle = .regular
        return scroll
    }
    private func build() {
        guard let root = window?.contentView else { return }
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(closeLibrary))
        let minimize = ClassicWindowButton(title: "−", target: self, action: #selector(minimizeLibrary))
        close.setAccessibilityLabel("Close library"); minimize.setAccessibilityLabel("Minimize library")
        for control in [minimize, close] {
            control.isBordered = false; control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 9).isActive = true
            control.heightAnchor.constraint(equalToConstant: 9).isActive = true
        }
        let titleControls = row([minimize, close], spacing: 2)
        add(titleControls, to: root)
        NSLayoutConstraint.activate([titleControls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -3), titleControls.topAnchor.constraint(equalTo: root.topAnchor, constant: 3)])

        nodes = [LibraryNode("MY LIBRARY", children: [LibraryNode("Favorites", scope: .favorites), LibraryNode("Recently Played", scope: .recent)]),
                 LibraryNode("INTERNET RADIO", children: [LibraryNode("Popular", scope: .popular), LibraryNode("Top Rated", scope: .rated), LibraryNode("All Stations", scope: .alphabetical)]),
                 LibraryNode("GENRES", children: genres.map { LibraryNode($0, scope: .genre($0.lowercased())) })]
        let sideColumn = NSTableColumn(identifier: .init("section")); sideColumn.width = 145
        sidebar.addTableColumn(sideColumn); sidebar.outlineTableColumn = sideColumn; sidebar.headerView = nil
        sidebar.style = .plain; sidebar.floatsGroupRows = false
        sidebar.indentationPerLevel = 9; sidebar.delegate = self; sidebar.dataSource = self; sidebar.rowHeight = 19
        sidebar.setAccessibilityLabel("Radio library categories")
        let sideScroll = scroll(sidebar); sideScroll.hasHorizontalScroller = false
        add(sideScroll, to: root); sideScrollView = sideScroll
        let main = NSView(); add(main, to: root)
        sideWidth = sideScroll.widthAnchor.constraint(equalToConstant: 145); sideGap = main.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor, constant: 9)
        add(nowPlaying, to: root); nowPlaying.font = BrowserTheme.small; nowPlaying.textColor = BrowserTheme.green; nowPlaying.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            sideScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), sideScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 25),
            sideWidth!, sideScroll.bottomAnchor.constraint(equalTo: nowPlaying.topAnchor, constant: -9),
            sideGap!, main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            main.topAnchor.constraint(equalTo: sideScroll.topAnchor), main.bottomAnchor.constraint(equalTo: sideScroll.bottomAnchor),
            nowPlaying.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            nowPlaying.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), nowPlaying.heightAnchor.constraint(equalToConstant: 15)
        ])
        heading.font = .monospacedSystemFont(ofSize: 11, weight: .bold); heading.textColor = BrowserTheme.green
        popup(sourceMenu, label: "Radio directory", values: [], width: 118)
        refreshSources()
        let refresh = button("Refresh", #selector(refresh), width: 56)
        let titleRow = row([heading, NSView(), sourceMenu, refresh]); add(titleRow, to: main)
        search.placeholderString = "Search station names…"; ClassicUI.field(search)
        search.target = self; search.action = #selector(searchNow)
        search.setAccessibilityLabel("Search radio station names")
        search.heightAnchor.constraint(equalToConstant: 22).isActive = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        popup(order, label: "Station ordering", values: ["Popular", "Top rated", "Name A–Z", "Best quality"], width: 104)
        for (i, sort) in ["clickcount:1", "votes:1", "name:0", "quality:1"].enumerated() { order.item(at: i)?.representedObject = sort }
        let searchRow = row([search, button("Search", #selector(searchNow), width: 54), order]); add(searchRow, to: main)
        genre.addItems(withObjectValues: ["All genres"] + genres.map { $0.lowercased() }); genre.stringValue = "All genres"
        genre.font = BrowserTheme.small; genre.textColor = BrowserTheme.text; genre.focusRingType = .none; genre.heightAnchor.constraint(equalToConstant: 22).isActive = true; genre.controlSize = .small; genre.target = self; genre.action = #selector(filtersChanged)
        genre.delegate = self; genre.setAccessibilityLabel("Genre filter")
        genre.widthAnchor.constraint(equalToConstant: 96).isActive = true
        popup(country, label: "Country filter", values: ["Any country"], width: 112)
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.map { ($0, Locale.current.localizedString(forRegionCode: $0) ?? $0) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (code, name) in codes { country.addItem(withTitle: name); country.lastItem?.representedObject = code }
        popup(format, label: "Audio format filter", values: ["Common formats", "MP3", "AAC", "Opus", "Ogg Vorbis", "All formats"], width: 100)
        popup(bitrate, label: "Minimum bitrate filter", values: ["Any kbps", "64+ kbps", "128+ kbps", "192+ kbps", "256+ kbps"], width: 84)
        let filterRow = row([label("Genre"), genre, country, format, bitrate, NSView()], spacing: 4); add(filterRow, to: main); filterRowView = filterRow
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(playSelected)
        table.enter = { [weak self] in self?.playSelected() }; table.setAccessibilityLabel("Internet radio stations")
        for (id, title, width) in [("name", "Station", 235.0), ("tags", "Genre", 140.0), ("country", "Country", 90.0), ("codec", "Format", 75.0), ("quality", "Quality", 62.0), ("votes", "Votes", 55.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.width = width; c.minWidth = id == "name" ? 150 : 42
            c.headerCell = LibraryHeader(textCell: title); c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let tableScroll = scroll(table); tableScroll.hasHorizontalScroller = false; add(tableScroll, to: main)
        // One continuous list: the next page of stations is fetched as the list is scrolled toward its end.
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)
        let context = NSMenu()
        for (title, selector) in [("Tune In", #selector(playSelected)), ("Add to Favorites", #selector(saveSelected)), ("Copy Stream URL", #selector(copySelected))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; context.addItem(item)
        }
        table.menu = context
        message.textColor = BrowserTheme.text; message.font = BrowserTheme.font; message.alignment = .center
        message.maximumNumberOfLines = 4; add(message, to: tableScroll)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false; add(spinner, to: tableScroll)
        selectedTitle.font = BrowserTheme.font; selectedTitle.textColor = BrowserTheme.green; selectedTitle.lineBreakMode = .byTruncatingTail
        selectedInfo.font = BrowserTheme.small; selectedInfo.textColor = BrowserTheme.dim; selectedInfo.lineBreakMode = .byTruncatingMiddle; selectedInfo.isSelectable = true
        add(selectedTitle, to: main); add(selectedInfo, to: main)
        tune = button("▶ Tune In", #selector(playSelected), width: 88)
        save = button("+ Favorite", #selector(saveSelected), width: 92)
        let actionRow = row([tune, save, button("Open URL…", #selector(openURL), width: 85)]); add(actionRow, to: main)
        // The directory status shares the bottom line with the now-playing text instead of taking a row of its own.
        status.font = BrowserTheme.small; status.textColor = BrowserTheme.dim; status.lineBreakMode = .byTruncatingTail; add(status, to: root)
        // Long names and URLs must truncate, never widen the window.
        for label in [selectedTitle, selectedInfo, status, nowPlaying, heading] {
            label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        }
        status.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        nowPlaying.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(400), for: .horizontal)
        filterHeight = filterRow.heightAnchor.constraint(equalToConstant: 22); filterGap = filterRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 7)
        tableGap = tableScroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 6)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), titleRow.trailingAnchor.constraint(equalTo: main.trailingAnchor), titleRow.topAnchor.constraint(equalTo: main.topAnchor), titleRow.heightAnchor.constraint(equalToConstant: 22),
            searchRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), searchRow.trailingAnchor.constraint(equalTo: main.trailingAnchor), searchRow.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 6),
            filterRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), filterRow.trailingAnchor.constraint(equalTo: main.trailingAnchor), filterGap!, filterHeight!,
            tableScroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), tableScroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), tableGap!,
            // Buttons on the left, the two selection lines beside them, vertically centred on the buttons.
            actionRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), actionRow.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -4),
            tableScroll.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -13),
            selectedTitle.leadingAnchor.constraint(equalTo: actionRow.trailingAnchor, constant: 12), selectedTitle.trailingAnchor.constraint(equalTo: main.trailingAnchor), selectedTitle.heightAnchor.constraint(equalToConstant: 16),
            selectedTitle.bottomAnchor.constraint(equalTo: actionRow.centerYAnchor, constant: 1),
            selectedInfo.leadingAnchor.constraint(equalTo: selectedTitle.leadingAnchor), selectedInfo.trailingAnchor.constraint(equalTo: main.trailingAnchor), selectedInfo.topAnchor.constraint(equalTo: selectedTitle.bottomAnchor), selectedInfo.heightAnchor.constraint(equalToConstant: 15),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), status.centerYAnchor.constraint(equalTo: nowPlaying.centerYAnchor), status.heightAnchor.constraint(equalToConstant: 15),
            status.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.55), nowPlaying.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -12),
            message.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor), message.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor), message.widthAnchor.constraint(lessThanOrEqualTo: tableScroll.widthAnchor, constant: -50),
            spinner.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor), spinner.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10)
        ])
        sidebar.reloadData(); sidebar.expandItem(nil, expandChildren: true)
        suppressSelection = true
        if let popular = nodes[1].children.first { sidebar.selectRowIndexes(IndexSet(integer: sidebar.row(forItem: popular)), byExtendingSelection: false) }
        suppressSelection = false
        adaptLayout()
        updateSelection()
    }

    private func captureQuery(resetPage: Bool = true) {
        query.name = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = genre.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        query.genre = tag == "All genres" ? "" : tag.lowercased()
        query.countryCode = country.selectedItem?.representedObject as? String ?? ""
        query.codec = ["", "MP3", "AAC", "OPUS", "OGG", ""][min(5, max(0, format.indexOfSelectedItem))]
        query.supportedOnly = format.indexOfSelectedItem != 5
        query.sourceID = sourceMenu.selectedItem?.representedObject as? String ?? "all"
        query.minimumBitrate = [0,64,128,192,256][max(0, bitrate.indexOfSelectedItem)]
        let sorting = (order.selectedItem?.representedObject as? String ?? "clickcount:1").split(separator: ":")
        query.order = String(sorting[0]); query.reverse = sorting.count > 1 && sorting[1] == "1"
        if resetPage { query.offset = 0 }
    }
    private func load(refresh: Bool = false) {
        task?.cancel(); generation = UUID()
        if scope.local { loadLocal(); return }
        let token = generation
        let request = query
        heading.stringValue = scope.title
        rows = []; hasMore = false; loadingMore = false; table.reloadData(); table.deselectAll(nil)
        message.stringValue = "Loading stations…"; message.isHidden = false
        status.toolTip = nil
        let sources = library.state.directories ?? []
        setBusy(true); status.stringValue = ""; hasLoaded = false
        task = Task { @MainActor [weak self, directory] in
            do {
                await directory.configure(sources)
                let page = try await directory.search(request, refresh: refresh)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.rows = page.stations; self.hasMore = page.hasMore; self.hasLoaded = true
                self.setBusy(false); self.table.reloadData()
                self.message.stringValue = !page.stations.isEmpty ? "" : (page.hasMore ? "Looking for supported streams…" : "No stations found")
                self.message.isHidden = !page.stations.isEmpty
                self.updateSelection(); self.loaded?(true)
                self.loadMoreIfNeeded()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.hasMore = false; self.setBusy(false)
                self.message.stringValue = "Couldn’t reach the station directory"
                self.message.isHidden = false; self.status.stringValue = error.localizedDescription; self.status.toolTip = error.localizedDescription
                self.loaded?(false)
            }
        }
    }
    /// Fetches the next page once the list is scrolled within a screenful of its end, appending it so the list reads as one.
    private func loadMoreIfNeeded() {
        guard hasMore, !busy, !loadingMore, !scope.local, hasLoaded, let scroll = table.enclosingScrollView else { return }
        let visible = scroll.contentView.bounds
        guard visible.maxY >= table.frame.height - visible.height else { return }
        loadingMore = true
        var request = query; request.offset += DirectoryQuery.pageSize
        let token = generation
        task = Task { @MainActor [weak self, directory] in
            do {
                let page = try await directory.search(request, refresh: false)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.query.offset = request.offset; self.loadingMore = false
                let known = Set(self.rows.map(\.id))
                let fresh = page.stations.filter { !known.contains($0.id) }
                let start = self.rows.count
                self.rows += fresh; self.hasMore = page.hasMore
                if !fresh.isEmpty { self.table.insertRows(at: IndexSet(integersIn: start..<self.rows.count), withAnimation: []) }
                self.message.isHidden = !self.rows.isEmpty
                if self.rows.isEmpty, !page.hasMore { self.message.stringValue = "No stations found" }
                self.loadMoreIfNeeded()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.loadingMore = false; self.hasMore = false
                if self.rows.isEmpty { self.message.stringValue = "Couldn’t reach the station directory"; self.message.isHidden = false }
                self.status.stringValue = error.localizedDescription; self.status.toolTip = error.localizedDescription
            }
        }
    }
    @objc private func listScrolled() { loadMoreIfNeeded() }
    private func loadLocal(preservingSelection: Bool = false) {
        let selectedID = preservingSelection ? selected?.id : nil
        task?.cancel(); generation = UUID(); setBusy(false); hasMore = false; loadingMore = false; hasLoaded = true
        heading.stringValue = scope.title
        let local = scope == .favorites ? library.state.favorites : (library.state.recentStations ?? [])
        rows = local.filter(query.matchesLocal).map(RadioListing.init(station:))
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        message.stringValue = !rows.isEmpty ? "" : scope == .favorites ? "No favorites" : "No recent stations"
        message.isHidden = !rows.isEmpty
        status.stringValue = ""; status.toolTip = nil
        updateSelection()
    }
    private func reloadKeepingSelection() {
        let id = selected?.id
        table.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    private func setBusy(_ value: Bool) {
        busy = value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateSelection()
    }
    private var selected: RadioListing? { !busy && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func updateSelection() {
        let entry = selected
        tune?.isEnabled = entry != nil; save?.isEnabled = entry != nil
        selectedTitle.stringValue = entry?.name ?? ""
        if let entry {
            let info = [entry.country, entry.tags, entry.codec.isEmpty ? "" : entry.formatLabel, entry.bitrate > 0 ? "\(entry.bitrate) kbps" : "", entry.sourceName ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")
            selectedInfo.stringValue = info.isEmpty ? entry.address : info
            selectedInfo.toolTip = entry.address + (entry.directoryID != nil && !entry.likelyPlayable ? "\nThis format may not play on this Mac." : "")
            let saved = library.state.favorites.contains { $0.address == entry.address }
            save?.title = saved ? "✓ Favorite" : "+ Favorite"; save?.isEnabled = !saved
        } else { selectedInfo.stringValue = ""; selectedInfo.toolTip = nil; save?.title = "+ Favorite" }
    }
    private func clearSortIndicators() { suppressSort = true; table.sortDescriptors = []; suppressSort = false }
    @objc private func searchNow() { clearSortIndicators(); captureQuery(); load() }
    /// Favorites and Recently Played are on-disk lists, so choosing a directory, filter or Refresh means the user wants the
    /// directory: move to Popular instead of leaving those controls greyed out and inert.
    private func leaveLocalScope() {
        guard scope.local, let popular = nodes[1].children.first, let target = popular.scope else { return }
        scope = target
        suppressSelection = true
        sidebar.selectRowIndexes(IndexSet(integer: sidebar.row(forItem: popular)), byExtendingSelection: false)
        suppressSelection = false
    }
    @objc private func filtersChanged() { leaveLocalScope(); clearSortIndicators(); captureQuery(); load() }
    @objc private func refresh() { leaveLocalScope(); captureQuery(); load(refresh: true) }
    @objc private func playSelected() {
        guard let selected else { return }
        play?(selected.station)
        if let id = selected.directoryID { Task { [directory] in await directory.countPlay(id) } }
    }
    @objc private func saveSelected() {
        guard let selected else { return }
        do { try library.save(selected.station); reloadKeepingSelection(); updateSelection(); status.stringValue = "Saved \(selected.name) to Favorites" }
        catch { status.stringValue = "Couldn’t save favorite: \(error.localizedDescription)" }
    }
    @objc private func copySelected() { guard let selected else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.address, forType: .string) }
    @objc private func openURL() { openStream?() }
    @objc private func closeLibrary() { window?.close() }
    @objc private func minimizeLibrary() { window?.miniaturize(nil) }
    /// The popups share this target, so only the row context menu depends on a selection;
    /// otherwise every directory/country/format choice greys out whenever no row is selected or a load is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, [#selector(playSelected), #selector(saveSelected), #selector(copySelected)].contains(action) else { return true }
        return selected != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { LibraryRow() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = LibraryRow(); view.alternating = row % 2 == 1; return view }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]; let key = tableColumn?.identifier.rawValue ?? "name"
        let identifier = NSUserInterfaceItemIdentifier("cell-" + key)
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? label("")
        cell.identifier = identifier; cell.font = BrowserTheme.font
        cell.textColor = key == "name" ? BrowserTheme.green : BrowserTheme.text
        cell.lineBreakMode = .byTruncatingTail
        switch key {
        case "tags": cell.stringValue = entry.tags.replacingOccurrences(of: ",", with: ", ")
        case "country": cell.stringValue = entry.country
        case "codec": cell.stringValue = entry.formatLabel
        case "quality": cell.stringValue = entry.qualityStars
        case "votes": cell.stringValue = entry.directoryID == nil ? "—" : entry.votes.formatted()
        default:
            let star = library.state.favorites.contains { $0.address == entry.address } ? "★ " : ""
            cell.stringValue = star + entry.name
        }
        cell.toolTip = key == "name" ? entry.name + "\n" + entry.address : key == "quality" ? (entry.quality == 0 ? "Bitrate unknown" : "\(entry.quality) of 5 • \(entry.formatLabel) \(entry.bitrate) kbps") : cell.stringValue
        return cell
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSort, let sort = table.sortDescriptors.first, let key = sort.key else { return }
        if scope.local {
            let selectedID = selected?.id
            rows = RadioListing.ordered(rows, by: key, reverse: !sort.ascending); table.reloadData()
            if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            updateSelection()
        } else {
            if order.numberOfItems > 4 { order.removeItem(at: 4) }
            let title = table.tableColumn(withIdentifier: .init(key))?.headerCell.stringValue ?? key
            order.addItem(withTitle: title + (sort.ascending ? " ↑" : " ↓"))
            order.lastItem?.representedObject = key + (sort.ascending ? ":0" : ":1")
            order.selectItem(at: 4)
            captureQuery(); load()
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? LibraryNode)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? LibraryNode)?.children[index] ?? nodes[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! LibraryNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! LibraryNode).scope != nil }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! LibraryNode
        let cell = label(node.title, color: node.scope == nil ? BrowserTheme.dim : BrowserTheme.text)
        if node.scope == nil { cell.font = .monospacedSystemFont(ofSize: 10, weight: .semibold) }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = sidebar.item(atRow: sidebar.selectedRow) as? LibraryNode, let scope = node.scope else { return }
        self.scope = scope
        clearSortIndicators()
        switch scope {
        case .genre(let tag): genre.stringValue = tag
        case .popular: genre.stringValue = "All genres"; order.selectItem(at: 0)
        case .rated: genre.stringValue = "All genres"; order.selectItem(at: 1)
        case .alphabetical: genre.stringValue = "All genres"; order.selectItem(at: 2)
        default: break
        }
        captureQuery(); load()
    }
}

extension DiscoveryController: NSComboBoxDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // AppKit sends this before the combo box's field value is updated.
        DispatchQueue.main.async { [weak self] in self?.filtersChanged() }
    }
}
