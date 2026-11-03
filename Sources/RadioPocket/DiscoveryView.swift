import AppKit
import UniformTypeIdentifiers

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
    var delete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { enter?() }
        else if event.keyCode == 51 || event.keyCode == 117, let delete { delete() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { deselectAll(nil) }
        return super.menu(for: event)
    }
}

private enum LibraryScope: Equatable {
    case discover, moods, popular, rated, alphabetical, genre(String), favorites, recent, tv, tvGenre(String)
    var isTV: Bool { if case .tv = self { return true }; if case .tvGenre = self { return true }; return false }
    var curated: Bool { self == .discover || self == .moods }
    var local: Bool { self == .favorites || self == .recent }
    var title: String {
        switch self {
        case .discover: return "DISCOVER"
        case .moods: return "MOODS"
        case .popular: return "POPULAR STATIONS"
        case .rated: return "TOP RATED STATIONS"
        case .alphabetical: return "ALL STATIONS"
        case .genre(let value): return value.uppercased() + " RADIO"
        case .favorites: return "FAVORITE STATIONS"
        case .recent: return "RECENTLY PLAYED"
        case .tv: return "INTERNET TV CHANNELS"
        case .tvGenre(let value): return value.uppercased() + " TV"
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
    private lazy var availability = DiscoveryAvailability.shared(directory: library.directory)
    private var availabilityTask: Task<Void, Never>?
    private var curationTask: Task<(DiscoveryFeed, MoodPlanning.Context?, (key: String, plan: MoodPlan)?), Never>?
    private var availabilityTimer: Timer?
    private let library: Library
    private let directory: RadioDirectory
    var play: ((Station) -> Void)?
    var openStream: (() -> Void)?
    var inspect: ((RadioListing) -> Void)?
    var loaded: ((Bool) -> Void)?
    var report: ((Error) -> Void)?
    private let table = StationTable()
    private let sidebar = NSOutlineView()
    private let search = NSTextField()
    private let genre = ClassicPopup()
    private let country = ClassicPopup()
    private let order = ClassicPopup()
    private let sourceMenu = ClassicPopup()
    private let heading = NSTextField(labelWithString: "POPULAR STATIONS")
    private let selectedTitle = NSTextField(labelWithString: "")
    private let selectedInfo = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var tune: NSButton!
    private var save: NSButton!
    private var scope: LibraryScope = .discover
    private let discoverPanel = DiscoverPanel()
    private var browserViews: [NSView] = []
    private var discoverVideo = false
    private let moodLocation = MoodLocation()
    private var locationTask: Task<Void, Never>?
    private let moodWeather = MoodWeather()
    private var moodPlans: [String: MoodPlan] = [:]
    /// The plan the visible moods came from. Passive reloads reuse it for the same day, time-of-day and settings so the cards stay put.
    private var pinnedMoodPlan: (key: String, plan: MoodPlan)?
    private var lastMoodWeather: (city: MoodCity, kind: MoodWeather.Kind?)?
    private var moodSources: [DirectorySource]?
    private var recommendationFavorites: [Station] = []
    private var recommendationRecents: [Station] = []
    private var recommendationSources: [DirectorySource]?
    private var discoverText = ""
    private var queryGenres: [String] = []
    private var queryLanguages: [String] = []
    private var aiTask: Task<Void, Never>?
    private var aiTimeout: Task<Void, Never>?
    private var aiGeneration = UUID()
    private var query = DirectoryQuery()
    private var rows: [RadioListing] = []
    private var remoteSearch = false
    private var hasMore = false
    private var loadingMore = false
    private var busy = false
    private var hasLoaded = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var suppressSelection = false
    private var suppressSort = false
    private let tvGenres = ["Animation", "Classic", "Comedy", "Cooking", "Culture", "Documentary", "Drama", "Education", "Entertainment", "Family", "General", "Kids", "Lifestyle", "Movies", "Music", "News", "Religious", "Series", "Sports", "Travel"]
    private var genreListIsTV = false
    private let genres = ["Alternative", "Ambient", "Blues", "Classical", "Country", "Electronic", "Folk", "Hip Hop", "Indie", "Jazz", "Metal", "News", "Pop", "Reggae", "Rock", "Soul", "Talk", "World"]
    private var nodes: [LibraryNode] = []
    private var sideWidth: NSLayoutConstraint!, sideGap: NSLayoutConstraint!
    private var tableGap: NSLayoutConstraint!
    private var navInset: [NSLayoutConstraint] = []
    private let sectionMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private var narrowHidden: [NSView] = []
    private weak var sideScrollView: NSView?
    private var lastTableViewportWidth: CGFloat = -1
    /// Column share of the table width and the narrowest width each stays readable at; the least important drop out first.
    private let columnLayout: [(id: String, share: CGFloat, minimum: CGFloat, hideBelow: CGFloat)] = [
        ("name", 0.36, 90, 0), ("tags", 0.22, 60, 520), ("country", 0.14, 50, 440), ("codec", 0.11, 44, 0), ("quality", 0.10, 52, 0), ("votes", 0.09, 40, 360)]

    init(library: Library, directory: RadioDirectory = RadioDirectory()) {
        self.library = library; self.directory = directory
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 500), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RadioPocket — Internet Radio & TV Library"
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
        if let row = (0..<sidebar.numberOfRows).first(where: { (sidebar.item(atRow: $0) as? LibraryNode)?.scope == .popular }) {
            if sidebar.selectedRow == row { searchNow() } else { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }
    /// Rebuilds the directory picker from Preferences, keeping the current choice when it still exists.
    func refreshSources() {
        let current = sourceMenu.selectedItem?.representedObject as? String ?? "all"
        let enabled = DirectorySource.resolved(library.state.directories).filter { $0.enabled && $0.serves(video: scope.isTV) }
        sourceMenu.removeAllItems()
        sourceMenu.addItem(withTitle: "All Directories"); sourceMenu.lastItem?.representedObject = "all"
        for source in enabled { sourceMenu.addItem(withTitle: source.name); sourceMenu.lastItem?.representedObject = source.id }
        if let index = sourceMenu.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) { sourceMenu.selectItem(at: index) }
        else { sourceMenu.selectItem(at: 0) }
        query.sourceID = sourceMenu.selectedItem?.representedObject as? String ?? "all"
    }
    func showLibrary() {
        let wasVisible = window?.isVisible == true
        let previous = query.sourceID
        refreshSources()
        if hasLoaded, previous != query.sourceID { hasLoaded = false }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        if !hasLoaded || (scope.curated && !(scope == .moods && wasVisible)) { load() }
    }
    /// The TV filters changed: reload the channels on screen, or the next time the library opens.
    func safetyChanged() { if scope == .tv, window?.isVisible == true { load() } else { hasLoaded = false } }
    /// Opens the library on the Internet TV channels.
    func showTV() {
        showLibrary()
        if let row = (0..<sidebar.numberOfRows).first(where: { (sidebar.item(atRow: $0) as? LibraryNode)?.scope == .tv }), sidebar.selectedRow != row {
            sidebar.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
    func windowDidResize(_ notification: Notification) { adaptLayout() }
    /// Compact windows shed the genre sidebar, then the filter row; the table keeps its columns proportional to its width.
    private func adaptLayout() {
        guard let root = window?.contentView, sideWidth != nil else { return }
        let showSide = root.bounds.width >= 700
        sideWidth.constant = showSide ? 145 : 0; sideGap.constant = showSide ? 9 : 0; sideScrollView?.isHidden = !showSide
        // Without the sidebar the current section becomes a menu of the same tree, so navigation stays visible.
        sectionMenu.isHidden = showSide; heading.isHidden = !showSide
        navInset.forEach { $0.constant = showSide ? 0 : 28 }
        if !showSide { updateSectionMenu() }
        let mainWidth = root.bounds.width - 24 - (showSide ? 154 : 0)
        let showFilters = mainWidth >= 580 && root.bounds.height >= 380
        narrowHidden.forEach { $0.isHidden = !showFilters }
        layoutColumns(width: mainWidth)
    }
    private func updateSectionMenu() {
        sectionMenu.menu?.items.first?.title = scope.title
        sectionMenu.setAccessibilityLabel("Library section: \(scope.title.capitalized)")
    }
    private func buildSectionMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(withTitle: scope.title, action: nil, keyEquivalent: "")
        func fill(_ nodes: [LibraryNode], into menu: NSMenu) {
            for node in nodes {
                if let scope = node.scope {
                    let item = NSMenuItem(title: node.title, action: #selector(sectionPicked(_:)), keyEquivalent: ""); item.target = self; item.representedObject = scope
                    menu.addItem(item)
                } else if node.title == node.title.uppercased() {
                    if menu.items.count > 1 { menu.addItem(.separator()) }
                    menu.addItem(withTitle: node.title, action: nil, keyEquivalent: "").isEnabled = false
                    fill(node.children, into: menu)
                } else {
                    let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: ""); let sub = NSMenu(title: node.title); sub.autoenablesItems = false
                    fill(node.children, into: sub); item.submenu = sub; menu.addItem(item)
                }
            }
        }
        fill(nodes, into: menu)
        sectionMenu.menu = menu
    }
    @objc private func sectionPicked(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? LibraryScope { selectScope(target) }
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
    func releaseIdleMemory(underPressure: Bool) {
        if underPressure {
            moodPlans.removeAll(keepingCapacity: false)
            aiTask?.cancel(); aiTimeout?.cancel(); aiGeneration = UUID()
            availabilityTask?.cancel()
        }
        if window?.isVisible != true {
            task?.cancel(); generation = UUID(); aiGeneration = UUID()
            curationTask?.cancel(); curationTask = nil
            availabilityTask?.cancel(); aiTask?.cancel(); aiTimeout?.cancel()
            discoverPanel.releaseContent(); hasLoaded = false
        } else if !NSApp.isActive {
            availabilityTask?.cancel(); aiTask?.cancel(); aiTimeout?.cancel()
        }
    }
    func windowWillClose(_ notification: Notification) {
        curationTask?.cancel(); curationTask = nil
        discoverPanel.releaseContent(); StationArtwork.clearMemory()
        recommendationFavorites = []; recommendationRecents = []
        hasLoaded = false
        availabilityTask?.cancel(); availabilityTimer?.invalidate(); availabilityTimer = nil
        locationTask?.cancel(); moodLocation.cancel(); discoverPanel.setLocationNotice(nil)
        task?.cancel(); generation = UUID(); aiTask?.cancel(); aiTimeout?.cancel(); aiGeneration = UUID()
        if busy || loadingMore { hasLoaded = false }
        loadingMore = false
        setBusy(false)
    }
    func libraryChanged() {
        guard window?.isVisible == true else { if scope.local { hasLoaded = false }; return }
        if scope.curated {
            let state = library.state
            guard state.favorites != recommendationFavorites || (state.recentStations ?? []) != recommendationRecents || state.directories != recommendationSources else { return }
            recommendationFavorites = state.favorites; recommendationRecents = state.recentStations ?? []; recommendationSources = state.directories
        }
        if scope == .moods, moodSources == library.state.directories {
            discoverPanel.updateFavorites(library.state.favorites)
        } else if scope.curated { loadDiscover() } else if scope.local { loadLocal(preservingSelection: true) } else { reloadKeepingSelection(); updateSelection() }
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
        popup.addItems(withTitles: values); popup.menu?.autoenablesItems = false; popup.font = BrowserTheme.small
        popup.heightAnchor.constraint(equalToConstant: 22).isActive = true
        popup.target = self; popup.action = #selector(filtersChanged)
        popup.setAccessibilityLabel(label); popup.toolTip = label
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = FittedScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
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

        nodes = [LibraryNode("MY LIBRARY", children: [LibraryNode("Discover", scope: .discover), LibraryNode("Moods", scope: .moods), LibraryNode("Favorites", scope: .favorites), LibraryNode("Recently Played", scope: .recent)]),
                 LibraryNode("INTERNET RADIO", children: [LibraryNode("Popular", scope: .popular), LibraryNode("Top Rated", scope: .rated), LibraryNode("All Stations", scope: .alphabetical),
                                                          LibraryNode("Genres", children: genres.map { LibraryNode($0, scope: .genre($0.lowercased())) })]),
                 LibraryNode("INTERNET TV", children: [LibraryNode("All Channels", scope: .tv),
                                                       LibraryNode("Genres", children: tvGenres.map { LibraryNode($0, scope: .tvGenre($0.lowercased())) })])]
        let sideColumn = NSTableColumn(identifier: .init("section")); sideColumn.width = 145
        sidebar.addTableColumn(sideColumn); sidebar.outlineTableColumn = sideColumn; sidebar.headerView = nil
        sidebar.style = .plain; sidebar.floatsGroupRows = false
        sidebar.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebar.indentationPerLevel = 9; sidebar.delegate = self; sidebar.dataSource = self; sidebar.rowHeight = 19
        sidebar.setAccessibilityLabel("Radio library categories")
        let sideScroll = scroll(sidebar)
        add(sideScroll, to: root); sideScrollView = sideScroll
        let main = NSView(); add(main, to: root)
        sideWidth = sideScroll.widthAnchor.constraint(equalToConstant: 145); sideGap = main.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor, constant: 9)
        NSLayoutConstraint.activate([
            sideScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), sideScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 25),
            sideWidth!, sideScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            sideGap!, main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            main.topAnchor.constraint(equalTo: sideScroll.topAnchor), main.bottomAnchor.constraint(equalTo: sideScroll.bottomAnchor)
        ])
        heading.font = .monospacedSystemFont(ofSize: 11, weight: .bold); heading.textColor = BrowserTheme.green
        popup(sourceMenu, label: "Radio directory", values: [], width: 118)
        refreshSources()
        let refresh = button("Refresh", #selector(refresh), width: 56)
        let titleRow = row([heading, NSView(), button("Discover", #selector(showDiscover), width: 65), sourceMenu, refresh], spacing: 4); add(titleRow, to: main)
        search.placeholderString = "Search station names…"; ClassicUI.field(search)
        search.target = self; search.action = #selector(searchNow)
        search.setAccessibilityLabel("Search radio station names")
        search.heightAnchor.constraint(equalToConstant: 22).isActive = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        popup(order, label: "Station ordering", values: ["Popular", "Top rated", "Name A–Z", "Best quality"], width: 104)
        for (i, sort) in ["clickcount:1", "votes:1", "name:0", "quality:1"].enumerated() { order.item(at: i)?.representedObject = sort }
        popup(genre, label: "Genre filter", values: ["All genres"] + genres, width: 96)
        popup(country, label: "Country filter", values: ["Any country"], width: 112)
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.map { ($0, Locale.current.localizedString(forRegionCode: $0) ?? $0) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (code, name) in codes { country.addItem(withTitle: name); country.lastItem?.representedObject = code }
        let clear = button("Clear", #selector(clearFilters), width: 56)
        narrowHidden = [genre, country, clear]
        let searchRow = row([search, button("Search", #selector(searchNow), width: 56), genre, country, order, clear], spacing: 4); add(searchRow, to: main)
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(playSelected)
        table.enter = { [weak self] in self?.playSelected() }
        table.delete = { [weak self] in if self?.scope == .favorites { self?.saveSelected() } }
        ; table.setAccessibilityLabel("Internet radio stations")
        for (id, title, width) in [("name", "Station", 235.0), ("tags", "Genre", 140.0), ("country", "Country", 90.0), ("codec", "Format", 75.0), ("quality", "Quality", 62.0), ("votes", "Votes", 55.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.width = width; c.minWidth = id == "name" ? 150 : 42
            c.headerCell = LibraryHeader(textCell: title); c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let tableScroll = scroll(table); add(tableScroll, to: main)
        // One continuous list: the next page of stations is fetched as the list is scrolled toward its end.
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)
        let context = NSMenu()
        for (title, selector) in [("Tune In", #selector(playSelected)), ("Add to Favorites", #selector(saveSelected)), ("Copy Stream URL", #selector(copySelected)), ("Station Info…", #selector(inspectSelected))] {
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
        // Long names and URLs must truncate, never widen the window.
        for label in [selectedTitle, selectedInfo, heading] {
            label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        }
        let titleTop = titleRow.topAnchor.constraint(equalTo: main.topAnchor)
        tableGap = tableScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 7)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), titleRow.trailingAnchor.constraint(equalTo: main.trailingAnchor), titleTop, titleRow.heightAnchor.constraint(equalToConstant: 22),
            searchRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), searchRow.trailingAnchor.constraint(equalTo: main.trailingAnchor), searchRow.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 6),
            tableScroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), tableScroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), tableGap!,
            // Buttons on the left, the two selection lines beside them, vertically centred on the buttons.
            actionRow.leadingAnchor.constraint(equalTo: main.leadingAnchor), actionRow.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -4),
            tableScroll.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -13),
            selectedTitle.leadingAnchor.constraint(equalTo: actionRow.trailingAnchor, constant: 12), selectedTitle.trailingAnchor.constraint(equalTo: main.trailingAnchor), selectedTitle.heightAnchor.constraint(equalToConstant: 16),
            selectedTitle.bottomAnchor.constraint(equalTo: actionRow.centerYAnchor, constant: 1),
            selectedInfo.leadingAnchor.constraint(equalTo: selectedTitle.leadingAnchor), selectedInfo.trailingAnchor.constraint(equalTo: main.trailingAnchor), selectedInfo.topAnchor.constraint(equalTo: selectedTitle.bottomAnchor), selectedInfo.heightAnchor.constraint(equalToConstant: 15),
            message.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor), message.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor), message.widthAnchor.constraint(lessThanOrEqualTo: tableScroll.widthAnchor, constant: -50),
            spinner.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor), spinner.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -10)
        ])
        sidebar.reloadData(); nodes.forEach { sidebar.expandItem($0) }
        sidebar.target = self; sidebar.action = #selector(sidebarClicked)
        suppressSelection = true
        if let popular = nodes[0].children.first { sidebar.selectRowIndexes(IndexSet(integer: sidebar.row(forItem: popular)), byExtendingSelection: false) }
        suppressSelection = false
        // Opens on Popular with stations sorted by quality, best first, shown as the table's sort too.
        order.selectItem(at: 3); suppressSort = true; table.sortDescriptors = [NSSortDescriptor(key: "quality", ascending: false)]; suppressSort = false
        browserViews = main.subviews
        add(discoverPanel, to: main)
        let panelTop = discoverPanel.topAnchor.constraint(equalTo: main.topAnchor)
        NSLayoutConstraint.activate([discoverPanel.leadingAnchor.constraint(equalTo: main.leadingAnchor), discoverPanel.trailingAnchor.constraint(equalTo: main.trailingAnchor), panelTop, discoverPanel.bottomAnchor.constraint(equalTo: main.bottomAnchor)])
        // Outside browserViews so it stays visible on Discover and Moods, which hide the station list.
        sectionMenu.font = BrowserTheme.small; sectionMenu.bezelStyle = .smallSquare; sectionMenu.isBordered = true
        buildSectionMenu(); add(sectionMenu, to: main)
        NSLayoutConstraint.activate([sectionMenu.leadingAnchor.constraint(equalTo: main.leadingAnchor), sectionMenu.topAnchor.constraint(equalTo: main.topAnchor), sectionMenu.heightAnchor.constraint(equalToConstant: 22), sectionMenu.widthAnchor.constraint(equalToConstant: 190)])
        navInset = [panelTop, titleTop]
        wireDiscover()
        captureQuery()
        adaptLayout()
        updateSelection()
    }

    private func showDiscoverySurface(_ shown: Bool) {
        browserViews.forEach { $0.isHidden = shown }; discoverPanel.isHidden = !shown
        if !shown { adaptLayout() }
    }
    @objc private func showDiscover() { selectScope(.discover) }
    private func selectScope(_ target: LibraryScope) {
        if let index = (0..<sidebar.numberOfRows).first(where: { (sidebar.item(atRow: $0) as? LibraryNode)?.scope == target }) {
            sidebar.selectRowIndexes([index], byExtendingSelection: false)
        }
    }
    private func wireDiscover() {
        discoverPanel.collectionRequested = { [weak self] moods in self?.selectScope(moods ? .moods : .discover) }
        discoverPanel.skipWeatherRequested = { [weak self] in self?.editDiscovery { $0.moodWeatherPromptHandled = true } }
        discoverPanel.useLocationRequested = { [weak self] in
            guard let self else { return }
            self.editDiscovery { $0.moodWeatherPromptHandled = true }
            self.locationTask?.cancel()
            self.discoverPanel.setLocationNotice("Waiting for macOS location permission, then finding your nearby city…")
            self.locationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let city = try await self.moodLocation.detectCity()
                    guard !Task.isCancelled else { return }
                    self.editDiscovery { $0.moodCity = city; $0.moodWeatherPromptHandled = true }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.discoverPanel.setLocationNotice(error.localizedDescription)
                }
            }
        }
        discoverPanel.preferencesChanged = { [weak self] preferences in
            guard let self else { return }
            self.locationTask?.cancel(); self.moodLocation.cancel(); self.discoverPanel.setLocationNotice(nil)
            self.queryGenres = []; self.queryLanguages = []; self.discoverPanel.setQuerySummary(nil)
            if !preferences.showArtwork { StationArtwork.clearMemory() }
            self.editDiscovery { preferences.apply(to: &$0) }
        }
        discoverPanel.importPlaylist = { [weak self] in self?.importDiscoveryPlaylist() }
        discoverPanel.browse = { [weak self] in self?.selectScope(.popular) }
        discoverPanel.refresh = { [weak self] in self?.loadDiscover(refresh: true) }
        discoverPanel.play = { [weak self] row in
            guard DiscoverySafety.allows(row) else { return }
            self?.play?(row.station) // Recommendations never report directory clicks.
        }
        discoverPanel.favorite = { [weak self] row in
            guard let self else { return }
            do { if !self.library.isFavorite(row.station) { try self.library.save(row.station) } }
            catch { self.report?(error) }
        }
        discoverPanel.feedbackChanged = { [weak self] row, vote in
            self?.editDiscovery { DiscoveryFeedback.toggle(vote, station: row, state: &$0) }
        }
        discoverPanel.preference = { [weak self] genre in
            self?.editDiscovery { state in
                if let genre { var values = state.discoveryInterests ?? []; if !values.contains(genre) { values.append(genre) }; state.discoveryInterests = values }
                else { state.discoveryDismissed = []; state.discoveryFeedback = [:] }
            }
        }
        discoverPanel.personalize = { [weak self] on in self?.editDiscovery { $0.discoveryPersonalization = on } }
        discoverPanel.aiChanged = { [weak self] on in self?.aiTask?.cancel(); self?.aiTimeout?.cancel(); self?.aiGeneration = UUID(); self?.editDiscovery { $0.discoveryAI = on } }
        discoverPanel.mediaChanged = { [weak self] video in self?.discoverVideo = video; self?.loadDiscover() }
        discoverPanel.searchChanged = { [weak self] text in self?.queryGenres = []; self?.queryLanguages = []; self?.discoverPanel.setQuerySummary(nil); self?.discoverText = String(text.prefix(500)); self?.loadDiscover() }
        discoverPanel.interpret = { [weak self] text in self?.interpretDiscovery(text) }
        discoverPanel.clearData = { [weak self] in
            guard let self else { return }
            self.task?.cancel(); self.generation = UUID(); self.moodPlans.removeAll(); self.pinnedMoodPlan = nil
            self.task = Task { @MainActor [weak self, directory] in
                let cleared = await directory.clearSavedStations()
                guard let self else { return }
                guard cleared else { self.discoverPanel.setStatus("Couldn’t clear saved discovery data. Please try again.", important: true); return }
                self.availabilityTask?.cancel(); self.availability.clear()
                self.editDiscovery { $0.discoveryInterests = []; $0.discoveryDismissed = []; $0.discoveryFeedback = [:] }
            }
        }
    }
    private func importDiscoveryPlaylist() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let custom = DirectorySource.resolved(library.state.directories).filter { !$0.builtIn }
            guard custom.count < DirectorySource.maximumCustom else { throw RadioError.message("Remove a custom directory in Preferences before adding another.") }
            let id = "local-" + UUID().uuidString.lowercased(), name = url.deletingPathExtension().lastPathComponent
            let rows = try LocalPlaylistDirectory.read(url: url, label: name, sourceID: id, video: discoverVideo)
            guard !rows.isEmpty else { throw RadioError.message("This file has no supported absolute HTTP/HTTPS station entries.") }
            let unique = Dictionary(grouping: rows, by: { DiscoveryIndex.matchKey($0.address) }).count
            let safe = rows.filter(DiscoverySafety.allows).count
            let alert = NSAlert(); alert.messageText = "Import \(name)?"
            alert.informativeText = "\(rows.count) usable entries, \(unique) unique streams. \(safe) entries have suitable music metadata for Discover. Up to 5,000 entries are imported. Other stations remain available in the browser."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let folder = library.directory.appendingPathComponent("Directories")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(id + ".m3u")
            // Save only parsed names and absolute URLs, never executable playlist directives.
            let contents = "#EXTM3U\n" + rows.map { row in
                func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
                let attributes = [!row.video ? "radio=\"true\"" : "", "group-title=\"" + escaped(row.tags) + "\"", "tvg-logo=\"" + escaped(row.artworkURL ?? "") + "\"", "tvg-language=\"" + (row.languages ?? []).joined(separator: ",") + "\""].filter { !$0.isEmpty }.joined(separator: " ")
                return "#EXTINF:-1 " + attributes + "," + escaped(row.name) + "\n" + row.address
            }.joined(separator: "\n")
            try Data(contents.utf8).write(to: destination, options: .atomic)
            let source = DirectorySource(id: id, name: name, kind: discoverVideo ? .localTVList : .localList, url: destination.absoluteString)
            do { try library.update { $0.directories = DirectorySource.resolved($0.directories) + [source] } }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            refreshSources()
            task = Task { @MainActor [weak self, directory] in
                guard let self else { return }
                do {
                    await directory.configure(self.library.state.directories ?? [], safety: self.library.state.tvSafety)
                    try await directory.ingestLocalSource(id)
                    self.loadDiscover(note: "Imported on this device; no directory refresh was needed")
                } catch { self.report?(error) }
            }
        } catch { report?(error) }
    }
    private func editDiscovery(_ edit: (inout Library.State) -> Void) {
        availabilityTask?.cancel()
        do { try library.update(edit); loadDiscover() } catch { report?(error) }
    }
    private func loadDiscover(refresh: Bool = false, note: String? = nil, checkAvailability: Bool = true) {
        guard scope.curated else { return }
        aiTask?.cancel(); aiTimeout?.cancel(); aiGeneration = UUID()
        curationTask?.cancel()
        if refresh { pinnedMoodPlan = nil }
        task?.cancel(); generation = UUID(); let token = generation
        hasMore = false; loadingMore = false; setBusy(false); hasLoaded = true
        showDiscoverySurface(true); discoverPanel.setMoods(scope == .moods); discoverPanel.configure(state: library.state)
        discoverPanel.beginLoading()
        let moods = scope == .moods
        let moment = MoodCuration.Moment()
        if availabilityTimer == nil {
            availabilityTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                guard let self, self.allowsOptionalDiscoveryWork, self.scope.curated else { return }
                if self.scope == .moods {
                    self.checkCuratedAvailability(self.discoverPanel.recommendedStations, token: self.generation, refreshFeed: false)
                } else { self.loadDiscover() }
            }
            availabilityTimer?.tolerance = 30
        }
        let availabilitySnapshot = availability.snapshot()
        let cachedPlans = moodPlans, pinned = pinnedMoodPlan
        let cachedWeather = lastMoodWeather
        let state = library.state, video = moods ? false : discoverVideo, text = moods ? "" : discoverText
        recommendationFavorites = state.favorites; recommendationRecents = state.recentStations ?? []; recommendationSources = state.directories
        if moods { moodSources = state.directories }
        let requiredGenres = queryGenres, requestedLanguages = queryLanguages
        discoverPanel.setStatus(refresh ? "Refreshing enabled directories directly…" : "Searching saved listings on this device…", busy: refresh)
        task = Task { @MainActor [weak self, directory] in
            do {
                await directory.configure(state.directories ?? [], safety: state.tvSafety)
                var failures: [String] = []
                if refresh { failures = try await directory.refreshDiscovery(video: video, genre: state.discoveryInterests?.last ?? "") }
                let records = try await directory.discoveryRecords(video: video, text: text)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { () -> (DiscoveryFeed, MoodPlanning.Context?, (key: String, plan: MoodPlan)?) in
                    if moods {
                        let context = MoodPlanning.context(records: records, state: state, moment: moment, weather: cachedWeather?.city == state.moodCity ? cachedWeather?.kind : nil)
                        let pinKey = [context.moment.key, state.moodCity?.name ?? "", state.discoveryAI == true ? "ai" : "", context.languages.sorted().joined(separator: ",")].joined(separator: "|")
                        let plan: MoodPlan, settled: Bool
                        if let pinned, pinned.key == pinKey { plan = pinned.plan; settled = true }
                        else {
                            let refined = state.discoveryAI == true ? cachedPlans[context.cacheKey] : nil
                            plan = refined ?? MoodPlanning.fallback(context)
                            // Pin only once weather and the AI plan have landed, so the first load can still settle into the final set.
                            settled = (state.moodCity == nil || cachedWeather?.city == state.moodCity) && (state.discoveryAI != true || refined != nil)
                        }
                        return (MoodPlanning.build(records: records, state: state, context: context, plan: plan, availability: availabilitySnapshot), context, settled ? (pinKey, plan) : nil)
                    }
                    return (DiscoveryRecommendations.build(records: records, recent: state.recentStations ?? [], favorites: state.favorites, interests: requiredGenres.isEmpty ? state.discoveryInterests ?? [] : requiredGenres, dismissed: Set(state.discoveryDismissed ?? []), personalizes: state.discoveryPersonalization != false, video: video, languages: requestedLanguages.isEmpty ? state.discoveryLanguages ?? [] : requestedLanguages, includeUnknownLanguage: requestedLanguages.isEmpty && state.discoveryIncludeUnknownLanguage != false, requiredGenres: requiredGenres, feedback: state.discoveryFeedback ?? [:], availability: availabilitySnapshot), nil, nil)
                }
                self?.curationTask = worker
                let prepared = await worker.value
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                self.curationTask = nil
                let feed = prepared.0
                if moods { self.pinnedMoodPlan = prepared.2 ?? self.pinnedMoodPlan }
                self.discoverPanel.render(feed, favorites: state.favorites)
                let date = feed.updated.map { " · Saved " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                let warning = failures.isEmpty ? "" : " · Couldn’t refresh: " + failures.joined(separator: ", ")
                self.discoverPanel.setStatus((note.map { $0 + " · " } ?? "") + feed.basis + " · \(feed.indexed) saved listings (partial coverage)" + date + warning, important: !failures.isEmpty)
                self.loaded?(true)
                if checkAvailability, state.discoveryAvailabilityChecks != false, self.window?.isVisible == true, BackgroundPolicy.allows() {
                    self.checkCuratedAvailability(feed.shelves.flatMap(\.picks).map(\.listing), token: token, refreshFeed: !moods)
                }
                if var moodContext = prepared.1 {
                    self.discoverPanel.setWeather(city: state.moodCity, condition: state.moodCity == nil ? nil : "Checking weather…")
                    if let city = state.moodCity {
                        let weather = await self.moodWeather.current(for: city)
                        guard !Task.isCancelled, token == self.generation else { return }
                        self.lastMoodWeather = (city, weather?.kind)
                        self.discoverPanel.setWeather(city: city, condition: weather?.label ?? "Weather unavailable · using time of day")
                        // Save fresh context for the next visit/explicit refresh; never replace a visible mood snapshot.
                        moodContext.weather = weather?.kind
                        guard !Task.isCancelled, token == self.generation else { return }
                    }
                    if state.discoveryAI == true, !feed.shelves.isEmpty {
                        self.refineMoods(context: moodContext, token: token)
                    }
                }
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.discoverPanel.loadingFailed()
                self.discoverPanel.setStatus(error.localizedDescription + " Your favorites and station browser still work.", important: true)
            }
        }
    }
    private var allowsOptionalDiscoveryWork: Bool {
        NSApp.isActive && window?.isVisible == true && window?.occlusionState.contains(.visible) == true && BackgroundPolicy.allows()
    }
    private func checkCuratedAvailability(_ rows: [RadioListing], token: UUID, refreshFeed: Bool) {
        guard library.state.discoveryAvailabilityChecks != false, allowsOptionalDiscoveryWork else { return }
        availabilityTask?.cancel()
        availabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let changed = await DiscoveryAvailabilityChecks.shared.refresh(rows, store: self.availability)
            guard changed, !Task.isCancelled, token == self.generation, self.scope.curated else { return }
            if refreshFeed { self.loadDiscover(checkAvailability: false) }
        }
    }
    private func refineMoods(context: MoodPlanning.Context, token: UUID) {
        guard allowsOptionalDiscoveryWork else { return }
        let moment = context.moment
        // Cached plans were already resolved in the background by loadDiscover.
        if moodPlans[context.cacheKey] != nil { return }
        aiGeneration = UUID(); let request = aiGeneration
        discoverPanel.setStatus(moment.label + " · Matching moods with on-device AI…")
        aiTask = Task { @MainActor [weak self] in
            do {
                let refined = try await LocalDiscoveryAI.curate(context: context)
                guard let self, !Task.isCancelled, self.generation == token, self.aiGeneration == request else { return }
                self.aiTimeout?.cancel()
                // curate validates against the small genre summary; station resolution waits for the next real load.
                if !refined.activities.isEmpty {
                    if self.moodPlans.count >= 8, let oldest = self.moodPlans.keys.sorted().first { self.moodPlans.removeValue(forKey: oldest) }
                    self.moodPlans[context.cacheKey] = refined
                }
                // The refined plan is cached for the next explicit load; the visible snapshot stays unchanged.
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.aiGeneration == request else { return }
                self.aiTimeout?.cancel()
                self.discoverPanel.setStatus(moment.label + " · AI unavailable; using local genre matching · Partial directory coverage")
            }
        }
        aiTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.generation == token, self.aiGeneration == request else { return }
            self.aiTask?.cancel(); self.aiGeneration = UUID()
            self.discoverPanel.setStatus(moment.label + " · AI took too long; using local genre matching · Partial directory coverage")
        }
    }
    private func interpretDiscovery(_ text: String) {
        queryGenres = []; queryLanguages = []; discoverPanel.setQuerySummary(nil)
        let preferences = DiscoveryPreferences(state: library.state)
        discoverText = String(text.prefix(500)); loadDiscover(note: "Showing literal matches while on-device AI interprets your request")
        aiTask?.cancel(); aiTimeout?.cancel(); aiGeneration = UUID(); let token = aiGeneration
        aiTask = Task { @MainActor [weak self] in
            do {
                let intent = try await LocalDiscoveryAI.interpret(text, preferredGenres: preferences.genres, preferredLanguages: preferences.languages)
                guard let self, self.aiGeneration == token, !Task.isCancelled, self.scope == .discover else { return }
                self.aiTimeout?.cancel()
                guard !intent.genres.isEmpty || !intent.languages.isEmpty || !intent.keywords.isEmpty else { self.loadDiscover(note: "Using literal search"); return }
                self.discoverText = intent.keywords; self.queryGenres = intent.genres; self.queryLanguages = intent.languages
                let summary = (intent.genres.map(\.capitalized) + intent.languages.map(DiscoveryCatalog.languageName) + (intent.keywords.isEmpty ? [] : [intent.keywords])).joined(separator: " · ")
                self.discoverPanel.setQuerySummary("Searching for " + summary)
                self.loadDiscover(note: "On-device interpretation: " + summary + ". Edit your search to change it")
            } catch {
                guard let self, self.aiGeneration == token, !Task.isCancelled else { return }
                self.aiTimeout?.cancel(); self.loadDiscover(note: "AI unavailable; using literal search")
            }
        }
        aiTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.aiGeneration == token else { return }
            self.aiTask?.cancel(); self.aiGeneration = UUID(); self.loadDiscover(note: "AI took too long; using literal search")
        }
    }

    private func chooseGenre(_ name: String) {
        genre.selectItem(at: genre.itemTitles.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } ?? 0)
    }
    private func captureQuery(resetPage: Bool = true) {
        query.name = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = (genre.titleOfSelectedItem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        query.genre = tag == "All genres" ? "" : tag.lowercased()
        query.countryCode = country.selectedItem?.representedObject as? String ?? ""
        query.codec = ""; query.supportedOnly = true; query.video = scope.isTV
        query.sourceID = sourceMenu.selectedItem?.representedObject as? String ?? "all"
        query.minimumBitrate = 0
        let sorting = (order.selectedItem?.representedObject as? String ?? "clickcount:1").split(separator: ":")
        query.order = String(sorting[0]); query.reverse = sorting.count > 1 && sorting[1] == "1"
        if resetPage { query.offset = 0 }
    }
    private func load(refresh: Bool = false) {
        task?.cancel(); generation = UUID()
        aiTask?.cancel(); aiTimeout?.cancel(); aiGeneration = UUID()
        showDiscoverySurface(scope.curated)
        if scope.curated { loadDiscover(refresh: refresh); return }
        if scope.local { loadLocal(); return }
        let token = generation
        let request = query
        remoteSearch = refresh
        heading.stringValue = scope.title
        rows = []; hasMore = false; loadingMore = false; table.reloadData(); table.deselectAll(nil)
        message.stringValue = "Loading stations…"; message.isHidden = false
        let sources = library.state.directories ?? [], safety = library.state.tvSafety
        setBusy(true); hasLoaded = false
        task = Task { @MainActor [weak self, directory] in
            do {
                await directory.configure(sources, safety: safety)
                let page = try await (!request.name.isEmpty && !refresh ? directory.searchSaved(request) : directory.search(request, refresh: refresh))
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.rows = page.stations; self.hasMore = page.hasMore; self.hasLoaded = true
                if !request.name.isEmpty && !refresh { self.heading.stringValue = "SAVED MATCHES · PARTIAL INDEX" }
                self.setBusy(false); self.table.reloadData()
                self.message.stringValue = !page.stations.isEmpty ? "" : (page.hasMore ? "Looking for supported streams…" : (!request.name.isEmpty ? "No saved matches. Refresh searches enabled directories." : "No stations found"))
                self.message.isHidden = !page.stations.isEmpty
                self.updateSelection(); self.loaded?(true)
                self.loadMoreIfNeeded()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.hasMore = false; self.setBusy(false)
                self.message.stringValue = "Couldn’t reach the station directory"
                self.message.isHidden = false
                self.loaded?(false)
            }
        }
    }
    /// Fetches the next page once the list is scrolled within a screenful of its end, appending it so the list reads as one.
    private func loadMoreIfNeeded() {
        guard !scope.curated, hasMore, !busy, !loadingMore, !scope.local, hasLoaded, let scroll = table.enclosingScrollView else { return }
        let visible = scroll.contentView.bounds
        guard visible.maxY >= table.frame.height - visible.height else { return }
        loadingMore = true
        var request = query; request.offset += DirectoryQuery.pageSize
        let useRemoteSearch = remoteSearch
        let token = generation
        task = Task { @MainActor [weak self, directory] in
            do {
                let page = try await (!request.name.isEmpty && !useRemoteSearch ? directory.searchSaved(request) : directory.search(request, refresh: false))
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
            }
        }
    }
    /// A nested heading such as Genres opens and closes when clicked.
    @objc private func sidebarClicked() {
        guard let node = sidebar.item(atRow: sidebar.clickedRow) as? LibraryNode, node.scope == nil, !node.children.isEmpty, sidebar.level(forItem: node) > 0 else { return }
        if sidebar.isItemExpanded(node) { sidebar.collapseItem(node) } else { sidebar.expandItem(node) }
    }
    @objc private func listScrolled() {
        if let clip = table.enclosingScrollView?.contentView, clip.bounds.width != lastTableViewportWidth {
            lastTableViewportWidth = clip.bounds.width
            layoutColumns(width: clip.bounds.width)
        }
        loadMoreIfNeeded()
    }
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
            save?.title = saved ? "★ Favorite" : "+ Favorite"
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
    @objc private func clearFilters() {
        search.stringValue = ""; chooseGenre("All genres")
        country.selectItem(at: 0)
        clearSortIndicators(); captureQuery(); load()
    }
    @objc private func refresh() { leaveLocalScope(); captureQuery(); load(refresh: true) }
    @objc private func playSelected() {
        guard let selected else { return }
        play?(selected.station)
        if library.state.directoryClickReporting == true, let id = selected.directoryID { Task { [directory] in await directory.countPlay(id) } }
    }
    @objc private func saveSelected() {
        guard let selected else { return }
        do {
            if library.isFavorite(selected.station) { try library.removeFavorite(selected.station) } else { try library.save(selected.station) }
            if !scope.local { reloadKeepingSelection(); updateSelection() }
        }
        catch { report?(error) }
    }
    @objc private func copySelected() { guard let selected else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.address, forType: .string) }
    @objc private func inspectSelected() { if let selected { inspect?(selected) } }
    @objc private func openURL() { openStream?() }
    @objc private func closeLibrary() { window?.close() }
    @objc private func minimizeLibrary() { window?.miniaturize(nil) }
    /// The popups share this target, so only the row context menu depends on a selection;
    /// otherwise every directory/country/format choice greys out whenever no row is selected or a load is running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, [#selector(playSelected), #selector(saveSelected), #selector(copySelected), #selector(inspectSelected)].contains(action) else { return true }
        if action == #selector(saveSelected) { menuItem.title = selected.map { library.isFavorite($0.station) } == true ? "Remove from Favorites" : "Add to Favorites" }
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
        let heading = node.scope == nil && outlineView.level(forItem: item) == 0
        let cell = label(node.title, color: heading ? BrowserTheme.dim : BrowserTheme.text)
        if heading { cell.font = .monospacedSystemFont(ofSize: 10, weight: .semibold) }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = sidebar.item(atRow: sidebar.selectedRow) as? LibraryNode, let scope = node.scope else { return }
        self.scope = scope
        updateSectionMenu()
        if !scope.curated {
            availabilityTask?.cancel(); curationTask?.cancel(); aiTask?.cancel(); aiTimeout?.cancel()
            discoverPanel.releaseContent()
        }
        clearSortIndicators()
        if scope.isTV != genreListIsTV {
            genreListIsTV = scope.isTV
            genre.removeAllItems(); genre.addItems(withTitles: ["All genres"] + (scope.isTV ? tvGenres : genres)); chooseGenre("All genres")
        }
        switch scope {
        case .genre(let tag), .tvGenre(let tag): chooseGenre(tag)
        case .popular: chooseGenre("All genres"); order.selectItem(at: 0)
        case .rated: chooseGenre("All genres"); order.selectItem(at: 1)
        case .alphabetical, .tv: chooseGenre("All genres"); order.selectItem(at: 2)
        default: break
        }
        refreshSources()
        captureQuery(); load()
    }
}
