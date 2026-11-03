import AppKit

private final class DiscoveryAction: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        perform = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; font = .systemFont(ofSize: 12, weight: .medium); controlSize = .regular
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
}
private final class FrequencyArtwork: NSView {
    let genre: String
    private let artworkURL: String?
    private var stationImage: NSImage?
    private var request: Task<Void, Never>?
    private var attempted = false
    init(_ genre: String, artworkURL: String? = nil) { self.genre = genre; self.artworkURL = artworkURL; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { request?.cancel() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { request?.cancel() } }
    override func draw(_ dirtyRect: NSRect) {
        if !attempted, window != nil, !visibleRect.isEmpty, artworkURL != nil {
            attempted = true
            let url = artworkURL
            request = Task { @MainActor [weak self] in
                let image = await StationArtwork.image(at: url)
                guard !Task.isCancelled else { return }; self?.stationImage = image; self?.needsDisplay = true
            }
        }
        let hash = genre.utf8.reduce(0) { ($0 + Int($1)) % 360 }
        let color = NSColor(calibratedHue: CGFloat(hash) / 360, saturation: 0.65, brightness: 0.72, alpha: 1)
        NSGradient(starting: color.withAlphaComponent(0.65), ending: NSColor(calibratedWhite: 0.08, alpha: 1))?.draw(in: bounds, angle: 20)
        let path = NSBezierPath(); path.lineWidth = 2
        for x in stride(from: CGFloat(0), through: bounds.width, by: 3) {
            let y = bounds.midY + sin(x / 15 + CGFloat(hash)) * 14 + cos(x / 7) * 5
            if x == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        color.blended(withFraction: 0.5, of: .white)!.withAlphaComponent(stationImage == nil ? 0.7 : 0.18).setStroke(); path.stroke()
        if let stationImage {
            let side = min(bounds.height - 20, 96)
            let badge = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill(); NSBezierPath(roundedRect: badge, xRadius: 12, yRadius: 12).fill()
            let inset = badge.insetBy(dx: 6, dy: 6), size = stationImage.size
            let scale = min(inset.width / max(1, size.width), inset.height / max(1, size.height))
            stationImage.draw(in: NSRect(x: inset.midX - size.width * scale / 2, y: inset.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale))
        }
    }
}

private final class DiscoveryContentStack: NSStackView { override var isFlipped: Bool { true } }

private final class DiscoverySectionHeader: NSView {
    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.textColor = .white
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [heading, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        labels.translatesAutoresizingMaskIntoConstraints = false; addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.23, blue: 0.27, alpha: 1), ending: NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.19, alpha: 1))?.draw(in: bounds, angle: 0)
        let wave = NSBezierPath(); wave.lineWidth = 1.5
        let start = max(bounds.width * 0.6, bounds.width - 180)
        for x in stride(from: start, through: bounds.width, by: 2) {
            let y = bounds.midY + sin((x - start) / 18) * 12
            if x == start { wave.move(to: NSPoint(x: x, y: y)) } else { wave.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor.systemTeal.withAlphaComponent(0.22).setStroke(); wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

private final class DiscoveryReasonScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let text = documentView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            let textHeight = layout.usedRect(for: container).height + 2 * text.textContainerInset.height
            if textHeight <= contentView.bounds.height, let parent = superview?.enclosingScrollView {
                parent.scrollWheel(with: event)
                return
            }
        }
        super.scrollWheel(with: event)
    }
}

/// Explicit content insets keep the artwork inside the card even at compact sizes.
private final class DiscoveryStationCard: NSView {
    let content = NSStackView()
    var artworkHeight: NSLayoutConstraint?
    var titleHeight: NSLayoutConstraint?
    var titleField: NSTextField?
    override init(frame: NSRect) {
        super.init(frame: frame)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        let tight = bounds.width < 280 || (enclosingScrollView.map { $0.contentView.bounds.height < 450 } ?? false)
        let imageSize: CGFloat = tight ? 44 : 64
        if artworkHeight?.constant != imageSize { artworkHeight?.constant = imageSize }
        let fontSize: CGFloat = tight ? 14 : 16
        if titleField?.font?.pointSize != fontSize { titleField?.font = .systemFont(ofSize: fontSize, weight: .semibold) }
        let titleSize: CGFloat = tight ? 34 : 39
        if titleHeight?.constant != titleSize { titleHeight?.constant = titleSize }
        let spacing: CGFloat = tight ? 5 : 7
        if content.spacing != spacing { content.spacing = spacing }
        super.layout()
    }
}

/// Presentation-only discovery surface; metadata, preference persistence and ranking are owned separately.
final class DiscoverPanel: NSView {
    var useLocationRequested: (() -> Void)?
    var skipWeatherRequested: (() -> Void)?
    private var weatherIntro: NSStackView!
    private var locationNotice: String?
    var collectionRequested: ((Bool) -> Void)?
    private var showingMoods = false
    private let pageTitle = NSTextField(labelWithString: "Your next frequency")
    private var searchRow: NSStackView!
    private var weatherRow: NSStackView!
    private let weatherLabel = NSTextField(wrappingLabelWithString: "Set up weather in Your mix → Weather")
    private var selectedMood: String?
    var isBrowsingMood: Bool { showingMoods && selectedMood != nil }
    private var loadingSpinner: NSProgressIndicator?
    private var currentFeed: DiscoveryFeed?
    private var currentFavorites: [Station] = []
    var recommendedStations: [RadioListing] { currentFeed?.shelves.flatMap(\.picks).map(\.listing) ?? [] }
    func updateFavorites(_ favorites: [Station]) {
        guard currentFavorites != favorites, let feed = currentFeed else { return }
        // Repaint saved controls using the same ordered snapshot, without recomputing recommendations.
        render(feed, favorites: favorites)
    }
    var refresh: (() -> Void)?
    var importPlaylist: (() -> Void)?
    var browse: (() -> Void)?
    var play: ((RadioListing) -> Void)?
    var favorite: ((RadioListing) -> Void)?
    var feedbackChanged: ((RadioListing, Int) -> Void)?
    var preferencesChanged: ((DiscoveryPreferences) -> Void)?
    var preference: ((String?) -> Void)?
    var personalize: ((Bool) -> Void)?
    var clearData: (() -> Void)?
    var mediaChanged: ((Bool) -> Void)?
    var searchChanged: ((String) -> Void)?
    var aiChanged: ((Bool) -> Void)?
    var interpret: ((String) -> Void)?
    private let scroll = NSScrollView()
    private let content = DiscoveryContentStack()
    private var moodsStatusVisible = false
    private var howMoods: NSButton!
    private var howMoodsRow: NSStackView!
    private var moodsPopover: NSPopover?
    private var discoveryFootnote: NSTextField!
    private let status = NSTextField(wrappingLabelWithString: "Your discovery stays on this device.")
    private let shelves = NSStackView()
    private var preferences = DiscoveryPreferences(state: Library.State())
    private var preferencesController: DiscoverPreferencesController?
    private let summary = NSTextField(labelWithString: "A fresh perspective on your dial")
    private let search = NSSearchField()
    private var cardRows: [NSStackView] = []
    private var compactWidths: [NSLayoutConstraint] = []
    private var lastLayoutGeometry = NSSize.zero
    private var refreshItem: NSMenuItem!
    private var selectedVideo = false
    private var querySummary: String?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.10, alpha: 1).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        let title = pageTitle; title.font = .systemFont(ofSize: 28, weight: .bold); title.textColor = .white
        let settings = DiscoveryAction("Your mix") { [weak self] in self?.openPreferences() }
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil); settings.imagePosition = .imageLeading
        let more = NSPopUpButton(frame: .zero, pullsDown: true); more.bezelStyle = .texturedRounded
        more.addItem(withTitle: "•••"); more.setAccessibilityLabel("Discovery actions")
        for (title, selector) in [("Discover", #selector(openDiscover)), ("Moods", #selector(openMoods)), ("Refresh stations", #selector(refreshStations)), ("Station browser", #selector(showBrowser)), ("Import playlist…", #selector(importStations)), ("Reset station feedback", #selector(resetHidden)), ("Clear saved discovery data", #selector(clearSaved))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; more.menu?.addItem(item)
            if selector == #selector(refreshStations) { refreshItem = item }
        }
        more.menu?.autoenablesItems = false
        add(horizontal([title, NSView(), settings, more]))
        summary.font = .systemFont(ofSize: 12); summary.textColor = .secondaryLabelColor; summary.lineBreakMode = .byTruncatingTail; add(summary)
        search.placeholderString = "A sound, a place, a station…"; search.font = .systemFont(ofSize: 13)
        search.target = self; search.action = #selector(searchNow); search.setAccessibilityLabel("Search discovery")
        search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        let media = NSSegmentedControl(labels: ["Radio", "TV"], trackingMode: .selectOne, target: self, action: #selector(changeMedia(_:)))
        media.selectedSegment = 0; media.font = .systemFont(ofSize: 12); media.setAccessibilityLabel("Discover media type")
        searchRow = horizontal([search, media]); add(searchRow)
        weatherLabel.font = .systemFont(ofSize: 12); weatherLabel.textColor = .secondaryLabelColor
        weatherLabel.lineBreakMode = .byTruncatingTail; weatherLabel.maximumNumberOfLines = 2
        weatherLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let city = DiscoveryAction("Weather settings…") { [weak self] in self?.openPreferences(weather: true) }
        let attribution = DiscoveryAction("Open-Meteo ↗") { NSWorkspace.shared.open(URL(string: "https://open-meteo.com/")!) }
        for control in [city, attribution] { control.setContentCompressionResistancePriority(.required, for: .horizontal); control.setContentHuggingPriority(.required, for: .horizontal) }
        attribution.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        city.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        attribution.cell?.wraps = false
        attribution.isBordered = false; attribution.toolTip = "Weather by Open-Meteo · Location data by GeoNames"
        weatherRow = horizontal([weatherLabel, city, attribution]); add(weatherRow); weatherRow.isHidden = true
        let locate = DiscoveryAction("Use my location") { [weak self] in self?.useLocationRequested?() }
        let skip = DiscoveryAction("Not now") { [weak self] in self?.skipWeatherRequested?() }
        weatherIntro = NSStackView(views: [text("Let the weather set the mood", size: 18, color: .white, weight: .semibold), text("Find your nearby city with macOS permission. An approximate area is saved and sent to Open-Meteo for weather. You can skip this and set it up later in Your mix → Weather.", size: 12, color: .secondaryLabelColor), horizontal([locate, skip, NSView()])])
        weatherIntro.orientation = .vertical; weatherIntro.alignment = .leading; weatherIntro.spacing = 10
        add(weatherIntro); weatherIntro.isHidden = true
        for view in weatherIntro.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: weatherIntro.widthAnchor).isActive = true }
        shelves.orientation = .vertical; shelves.alignment = .leading; shelves.spacing = 12; add(shelves)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3; add(status)
        discoveryFootnote = text("Made for you, on this device. Live programming can differ from directory descriptions.", size: 11, color: .secondaryLabelColor)
        add(discoveryFootnote)
        howMoods = DiscoveryAction("How moods work") { [weak self] in self?.showMoodsExplainer() }
        howMoods.isBordered = false; howMoods.contentTintColor = .systemTeal
        howMoods.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil); howMoods.imagePosition = .imageLeading
        howMoodsRow = horizontal([howMoods, NSView()]); add(howMoodsRow); howMoodsRow.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    private func text(_ value: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: value); view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color; view.maximumNumberOfLines = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        return row
    }
    private func add(_ view: NSView) {
        content.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36).isActive = true
    }
    func setStatus(_ value: String, busy: Bool = false, important: Bool = false) {
        moodsStatusVisible = busy || important
        status.isHidden = showingMoods && !moodsStatusVisible
        status.stringValue = value; status.toolTip = value
        refreshItem?.isEnabled = !busy
        if busy { summary.stringValue = "Finding more stations for your mix…" } else { updateSummary() }
    }
    func setMoods(_ enabled: Bool) {
        if showingMoods != enabled {
            selectedMood = nil; currentFeed = nil; clearShelves()
            scroll.contentView.scroll(to: .zero)
        }
        if showingMoods != enabled { moodsPopover?.close() }
        status.isHidden = enabled && !moodsStatusVisible
        discoveryFootnote.isHidden = enabled; howMoodsRow.isHidden = !enabled
        showingMoods = enabled; pageTitle.stringValue = enabled ? "Moods" : "Your next frequency"
        searchRow.isHidden = enabled; weatherRow.isHidden = !enabled
        weatherIntro.isHidden = !enabled || preferences.weatherPromptHandled || preferences.moodCity != nil
        updateSummary()
    }
    func setLocationNotice(_ message: String?) {
        locationNotice = message
        weatherRow.isHidden = !showingMoods || message == nil
        if let message { weatherLabel.stringValue = message; weatherLabel.toolTip = message }
    }
    func setWeather(city: MoodCity?, condition: String?) {
        if city != nil { locationNotice = nil; weatherRow.isHidden = true }
        weatherLabel.stringValue = locationNotice ?? city.map { $0.name + " · " + (condition ?? "") } ?? "Set up weather in Your mix → Weather"
        weatherLabel.toolTip = weatherLabel.stringValue
    }
    func configure(state: Library.State) { preferences = DiscoveryPreferences(state: state); weatherIntro.isHidden = !showingMoods || preferences.weatherPromptHandled || preferences.moodCity != nil; updateSummary() }
    func setQuerySummary(_ value: String?) { querySummary = value; updateSummary() }
    private func updateSummary() {
        summary.isHidden = showingMoods
        weatherRow.isHidden = !showingMoods || locationNotice == nil
        if showingMoods {
            let moment = MoodCuration.Moment()
            let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            pageTitle.stringValue = selectedMood ?? MoodPlanning.greeting(moment: moment, name: name, options: currentFeed?.moodGreetings ?? [])
            pageTitle.lineBreakMode = .byTruncatingTail
            pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            summary.stringValue = moment.label + (moment.occasion.map { " · " + $0 } ?? "") + " · What sounds good right now?"
            summary.toolTip = summary.stringValue; return
        }
        if let querySummary { summary.stringValue = querySummary; summary.toolTip = querySummary; return }
        summary.stringValue = currentFeed?.basis ?? "Fresh frequencies for your kind of listening"
        summary.toolTip = summary.stringValue
    }
    func openPreferences(weather: Bool = false) {
        guard let window, window.attachedSheet == nil else { return }
        let controller = DiscoverPreferencesController(preferences: preferences)
        controller.apply = { [weak self] value in self?.preferencesChanged?(value) }
        preferencesController = controller; controller.present(on: window, weather: weather)
    }
    func releaseContent() {
        clearShelves(); currentFeed = nil; currentFavorites = []; selectedMood = nil
        moodsPopover?.close(); moodsPopover = nil
    }
    private func clearShelves() {
        loadingSpinner?.stopAnimation(nil); loadingSpinner = nil
        for view in shelves.arrangedSubviews { shelves.removeArrangedSubview(view); view.removeFromSuperview() }
        cardRows = []; compactWidths = []
    }
    func beginLoading() {
        // Keep an existing feed steady during background refreshes, but never reuse another surface's cards.
        guard currentFeed == nil else { return }
        clearShelves()
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let icon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemTeal; icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(icon)
        } else {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
            spinner.isIndeterminate = true; spinner.setAccessibilityLabel("Loading")
            spinner.widthAnchor.constraint(equalToConstant: 24).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(spinner); loadingSpinner = spinner; spinner.startAnimation(nil)
        }
        row.addArrangedSubview(text(showingMoods ? "Finding your mood…" : "Finding your next frequency…", size: 16, color: .secondaryLabelColor))
        row.addArrangedSubview(NSView())
        row.heightAnchor.constraint(equalToConstant: 120).isActive = true
        addShelfView(row); needsLayout = true
    }
    func loadingFailed() {
        guard currentFeed == nil else { return }
        clearShelves()
        addShelfView(text(showingMoods ? "Moods couldn’t load" : "Discovery couldn’t load", size: 16, color: .secondaryLabelColor))
        addShelfView(text("Try Refresh stations from the ••• menu.", size: 13, color: .secondaryLabelColor))
        needsLayout = true
    }
    func render(_ feed: DiscoveryFeed, favorites: [Station]) {
        currentFeed = feed; currentFavorites = favorites
        if let selectedMood, !feed.moodGroups.contains(where: { $0.title == selectedMood }) { self.selectedMood = nil }
        updateSummary()
        clearShelves()
        if feed.shelves.isEmpty {
            addShelfView(text(showingMoods ? "A mood is waiting for its stations" : "A fresh dial awaits", size: 22, color: .white, weight: .semibold))
            addShelfView(text("Discover includes stations rated four stars or higher. Choose genres and languages in Your mix, then refresh stations from the ••• menu, or open the full station browser.", size: 13, color: .secondaryLabelColor))
        }
        if showingMoods, !feed.moodGroups.isEmpty {
            renderMoodBrowser(feed)
            needsLayout = true
            return
        }
        for shelf in feed.shelves where !showingMoods || shelf.title == selectedMood {
            if showingMoods || shelf.title != "Your next frequency" {
                addShelfView(DiscoverySectionHeader(title: shelf.title, subtitle: shelf.subtitle))
            }
            for offset in stride(from: 0, to: shelf.picks.count, by: 2) {
                let pair = Array(shelf.picks[offset..<min(offset + 2, shelf.picks.count)])
                let row = NSStackView(views: pair.map { pick in card(pick, saved: favorites.contains { $0.address == pick.listing.address }) })
                row.orientation = compactCards ? .vertical : .horizontal; row.alignment = .top; row.distribution = .fillEqually; row.spacing = 12
                cardRows.append(row); addShelfView(row)
                for card in row.arrangedSubviews {
                    let width = card.widthAnchor.constraint(equalTo: row.widthAnchor)
                    width.isActive = compactCards; compactWidths.append(width)
                }
            }
        }
        needsLayout = true
    }
    private func renderMoodBrowser(_ feed: DiscoveryFeed) {
        func grids(_ cards: [NSView]) {
            for offset in stride(from: 0, to: cards.count, by: 2) { addCardRow(Array(cards[offset..<min(offset + 2, cards.count)])) }
        }
        guard let group = feed.moodGroups.first(where: { $0.title == selectedMood }) else {
            addShelfView(MoodCardGrid(cards: feed.moodGroups.map { group in
                let card = MoodCard(title: group.title, count: group.collections.flatMap(\.picks).count, unit: "station", artwork: group.artwork)
                card.toolTip = group.detail
                card.choose = { [weak self] in
                    guard let self, let feed = self.currentFeed else { return }
                    self.selectedMood = group.title
                    self.render(feed, favorites: self.currentFavorites); self.scroll.contentView.scroll(to: .zero)
                }
                return card
            }))
            return
        }
        let back = DiscoveryAction("← All moods") { [weak self] in
            guard let self, let feed = self.currentFeed else { return }
            self.selectedMood = nil
            self.render(feed, favorites: self.currentFavorites); self.scroll.contentView.scroll(to: .zero)
        }
        addShelfView(back)
        grids(group.collections.flatMap(\.picks).map { pick in
            card(pick, saved: currentFavorites.contains { $0.address == pick.listing.address })
        })
    }

    private func addCardRow(_ cards: [NSView]) {
        let row = NSStackView(views: cards)
        row.orientation = compactCards ? .vertical : .horizontal; row.alignment = .top; row.distribution = .fillEqually; row.spacing = 12
        cardRows.append(row); addShelfView(row)
        for card in cards {
            let width = card.widthAnchor.constraint(equalTo: row.widthAnchor)
            width.isActive = compactCards; compactWidths.append(width)
        }
    }
    private func addShelfView(_ view: NSView) {
        shelves.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: shelves.widthAnchor).isActive = true
    }
    private func card(_ pick: DiscoveryPick, saved: Bool) -> NSView {
        let row = pick.listing
        let card = DiscoveryStationCard(frame: .zero)
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).cgColor; card.layer?.cornerRadius = 14; card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        func append(_ view: NSView, height: CGFloat? = nil) {
            card.content.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
            if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
        }
        let genre = DiscoverySafety.interests(row).sorted().first ?? "music"
        let artwork = FrequencyArtwork(genre, artworkURL: preferences.showArtwork ? row.artworkURL : nil); artwork.wantsLayer = true; artwork.layer?.cornerRadius = 8; artwork.layer?.masksToBounds = true; card.artworkHeight = artwork.heightAnchor.constraint(equalToConstant: 64); card.artworkHeight?.isActive = true; append(artwork)
        append(text(genre.uppercased() + (row.video ? "  /  TV" : "  /  RADIO"), size: 10, color: .systemTeal, weight: .semibold), height: 12)
        let title = text(row.name, size: 16, color: .white, weight: .semibold); title.maximumNumberOfLines = 2; title.toolTip = row.name; append(title)
        card.titleField = title; card.titleHeight = title.heightAnchor.constraint(equalToConstant: 39); card.titleHeight?.isActive = true
        let reasonScroll = DiscoveryReasonScrollView()
        reasonScroll.drawsBackground = false; reasonScroll.borderType = .noBorder
        reasonScroll.hasVerticalScroller = true; reasonScroll.autohidesScrollers = true
        reasonScroll.scrollerStyle = .overlay
        let reason = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 48))
        reason.string = pick.reason; reason.font = .systemFont(ofSize: 12)
        reason.textColor = .secondaryLabelColor; reason.drawsBackground = false
        reason.isEditable = false; reason.isSelectable = true
        reason.textContainerInset = .zero; reason.textContainer?.lineFragmentPadding = 0
        reason.isVerticallyResizable = true; reason.isHorizontallyResizable = false
        reason.autoresizingMask = [.width]; reason.textContainer?.widthTracksTextView = true
        reason.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        reason.setAccessibilityLabel("Why this station")
        reasonScroll.documentView = reason
        append(reasonScroll, height: 30)
        let details = [row.country, (row.languages ?? []).map(DiscoveryCatalog.languageName).joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
        let quality = text(row.quality > 0 ? row.qualityStars : "☆ ☆ ☆ ☆ ☆", size: 10, color: .secondaryLabelColor)
        quality.toolTip = row.quality > 0 ? "Estimated stream quality: \(row.quality) of 5" : "Stream quality not published"
        quality.setAccessibilityLabel(quality.toolTip)
        quality.setContentHuggingPriority(.required, for: .horizontal)
        let country = text(details, size: 11, color: .secondaryLabelColor)
        country.maximumNumberOfLines = 1; country.lineBreakMode = .byTruncatingTail; country.toolTip = details
        append(horizontal([country, NSView(), quality]), height: 14)
        let availability = text(pick.availability?.label ?? "Availability not checked", size: 10, color: .secondaryLabelColor)
        availability.toolTip = "Local stream response check; separate from audio quality and not a guarantee of playback."
        append(availability, height: 14)
        let playButton = DiscoveryAction("Play") { [weak self] in self?.play?(row) }
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil); playButton.imagePosition = .imageLeading; playButton.bezelColor = .systemTeal
        let saveButton = DiscoveryAction(saved ? "Saved" : "Save") { [weak self] in self?.favorite?(row) }
        saveButton.image = NSImage(systemSymbolName: saved ? "heart.fill" : "heart", accessibilityDescription: nil); saveButton.imagePosition = .imageLeading
        func thumb(_ value: Int) -> NSButton {
            let title = value > 0 ? "Recommend more like " + row.name : "Lower the priority of " + row.name
            let button = DiscoveryAction(title) { [weak self] in self?.feedbackChanged?(row, value) }
            button.image = NSImage(systemSymbolName: (value > 0 ? "hand.thumbsup" : "hand.thumbsdown") + (pick.feedback == value ? ".fill" : ""), accessibilityDescription: nil)
            button.imagePosition = .imageOnly; button.isBordered = false; button.contentTintColor = pick.feedback == value ? .systemTeal : .secondaryLabelColor
            button.toolTip = (value > 0 ? "More like this station" : "Less often — keeps this station available") + (pick.feedback == value ? " · Click again to clear" : "")
            button.setAccessibilityValue(pick.feedback == value ? "Selected" : "Not selected")
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }
        append(horizontal([playButton, saveButton, NSView(), thumb(1), thumb(-1)]), height: 24)
        if let website = StationArtwork.website(row.homepage) {
            let link = DiscoveryAction("Station website ↗") { NSWorkspace.shared.open(website) }
            link.isBordered = false; link.contentTintColor = .systemTeal; link.alignment = .left
            link.toolTip = website.host; link.setAccessibilityLabel("Open " + row.name + " website")
            append(link, height: 20)
        } else {
            append(NSView(), height: 20)
        }
        return card
    }
    private var compactCards: Bool { bounds.width < (showingMoods && selectedMood == nil ? 420 : 540) }
    override func layout() {
        super.layout()
        let geometry = NSSize(width: bounds.width, height: scroll.contentView.bounds.height)
        let geometryChanged = geometry != lastLayoutGeometry
        lastLayoutGeometry = geometry
        if geometryChanged {
            for grid in shelves.arrangedSubviews.compactMap({ $0 as? MoodCardGrid }) { grid.needsLayout = true }
        }
        let compact = compactCards
        if showingMoods {
            let titleSize: CGFloat = bounds.width < 420 ? 19 : bounds.width < 600 ? 23 : 28
            if pageTitle.font?.pointSize != titleSize { pageTitle.font = .systemFont(ofSize: titleSize, weight: .bold) }
        } else if pageTitle.font?.pointSize != 28 { pageTitle.font = .systemFont(ofSize: 28, weight: .bold) }
        let orientation: NSUserInterfaceLayoutOrientation = compact ? .vertical : .horizontal
        let weatherAlignment: NSLayoutConstraint.Attribute = compact ? .leading : .centerY
        if weatherRow.orientation != orientation { weatherRow.orientation = orientation }
        if weatherRow.alignment != weatherAlignment { weatherRow.alignment = weatherAlignment }
        for width in compactWidths where width.isActive != compact { width.isActive = compact }
        for row in cardRows {
            let alignment: NSLayoutConstraint.Attribute = compact ? .leading : .top
            if row.orientation != orientation { row.orientation = orientation }
            if row.alignment != alignment { row.alignment = alignment }
            if geometryChanged { for card in row.arrangedSubviews { card.needsLayout = true } }
        }
    }
    private func showMoodsExplainer() {
        guard let howMoods, let window else { return }
        if moodsPopover?.isShown == true { moodsPopover?.close(); return }
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = true
        let controller = NSViewController()
        let width = min(CGFloat(360), max(CGFloat(280), window.frame.width - 48))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        var totalHeight: CGFloat = 40
        func paragraph(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) {
            let field = text(value, size: size, color: .labelColor, weight: weight)
            let usable = width - 40
            let height = ceil((value as NSString).boundingRect(with: NSSize(width: usable, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).height) + 3
            field.widthAnchor.constraint(equalToConstant: usable).isActive = true
            field.heightAnchor.constraint(equalToConstant: height).isActive = true
            stack.addArrangedSubview(field); totalHeight += height + 14
        }
        paragraph("Your little radio concierge", size: 18, weight: .semibold)
        paragraph("A rainy afternoon? A Friday night? Different moments call for different sounds.")
        var explanation = "RadioPocket uses the time, day, your tastes, and—if you’ve enabled it—the weather to suggest a few moods."
        if preferences.useAI { explanation += " On-device AI helps match them with stations from your directories." }
        paragraph(explanation)
        paragraph("Pick a mood, then choose a station to listen. These are live broadcasts, so the station still chooses the songs.")
        let done = DiscoveryAction("Sounds good") { [weak popover] in popover?.close() }
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done); totalHeight += 26
        stack.frame = NSRect(x: 0, y: 0, width: width, height: totalHeight)
        controller.view = stack; popover.contentViewController = controller
        popover.contentSize = NSSize(width: width, height: totalHeight)
        moodsPopover = popover
        popover.show(relativeTo: howMoods.bounds, of: howMoods, preferredEdge: .maxY)
    }
    @objc private func openDiscover() { collectionRequested?(false) }
    @objc private func openMoods() { collectionRequested?(true) }
    @objc private func changeMedia(_ sender: NSSegmentedControl) { selectedVideo = sender.selectedSegment == 1; mediaChanged?(selectedVideo) }
    @objc private func refreshStations() { refresh?() }
    @objc private func showBrowser() { browse?() }
    @objc private func importStations() { importPlaylist?() }
    @objc private func resetHidden() { preference?(nil) }
    @objc private func clearSaved() { StationArtwork.clearMemory(); clearData?() }
    @objc private func searchNow() { if preferences.useAI { interpret?(search.stringValue) } else { searchChanged?(search.stringValue) } }
}
