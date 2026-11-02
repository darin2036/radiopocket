import AppKit

private final class DiscoveryAction: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        perform = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; font = ClassicUI.small; controlSize = .small
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
}
private final class FrequencyArtwork: NSView {
    let genre: String
    init(_ genre: String) { self.genre = genre; super.init(frame: .zero); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let hash = genre.utf8.reduce(0) { ($0 + Int($1)) % 360 }
        let color = NSColor(calibratedHue: CGFloat(hash) / 360, saturation: 0.65, brightness: 0.72, alpha: 1)
        NSGradient(starting: color.withAlphaComponent(0.65), ending: NSColor(calibratedWhite: 0.08, alpha: 1))?.draw(in: bounds, angle: 20)
        let path = NSBezierPath(); path.lineWidth = 2
        for x in stride(from: CGFloat(0), through: bounds.width, by: 3) {
            let y = bounds.midY + sin(x / 15 + CGFloat(hash)) * 14 + cos(x / 7) * 5
            if x == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        color.blended(withFraction: 0.5, of: .white)!.setStroke(); path.stroke()
    }
}

/// Native, scrollable discovery surface. No artwork fetches, web view, autoplay or hidden network calls.
final class DiscoverPanel: NSView {
    var refresh: (() -> Void)?
    var importPlaylist: (() -> Void)?
    var browse: (() -> Void)?
    var play: ((RadioListing) -> Void)?
    var favorite: ((RadioListing) -> Void)?
    var dismiss: ((RadioListing) -> Void)?
    var preference: ((String?) -> Void)?
    var personalize: ((Bool) -> Void)?
    var clearData: (() -> Void)?
    var mediaChanged: ((Bool) -> Void)?
    var searchChanged: ((String) -> Void)?
    var aiChanged: ((Bool) -> Void)?
    var interpret: ((String) -> Void)?
    private let scroll = NSScrollView()
    private let content = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "Your discovery stays on this device.")
    private let shelves = NSStackView()
    private let options = NSStackView()
    private let interests = NSPopUpButton()
    private let history = NSButton(checkboxWithTitle: "Use recent listening on this device", target: nil, action: nil)
    private let ai = NSButton(checkboxWithTitle: "On-device AI search (optional)", target: nil, action: nil)
    private let search = NSSearchField()
    private var cardRows: [NSStackView] = []
    private var compactWidths: [NSLayoutConstraint] = []
    private var refreshButton: NSButton!
    private var selectedVideo = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.10, alpha: 1).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        let eyebrow = text("RADIO POCKET  /  YOUR PERSONAL DIAL", size: 10, color: .systemTeal, weight: .semibold)
        add(eyebrow)
        let title = text("Discover", size: 28, color: .white, weight: .bold)
        let back = DiscoveryAction("Station browser") { [weak self] in self?.browse?() }
        add(horizontal([title, NSView(), back]))
        add(text("Find your next frequency.", size: 16, color: .secondaryLabelColor))
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 0; add(status)
        refreshButton = DiscoveryAction("Refresh directories") { [weak self] in self?.refresh?() }
        let media = NSSegmentedControl(labels: ["Radio", "TV"], trackingMode: .selectOne, target: self, action: #selector(changeMedia(_:)))
        media.selectedSegment = 0; media.font = ClassicUI.small; media.setAccessibilityLabel("Discover media type")
        add(horizontal([media, NSView(), refreshButton]))
        let tune = DiscoveryAction("Tune your mix…") { [weak self] in
            guard let self else { return }; self.options.isHidden.toggle()
        }
        add(horizontal([tune, NSView()]))
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 10; options.isHidden = true; add(options)
        addOption(DiscoveryAction("Import a local playlist…") { [weak self] in self?.importPlaylist?() })
        interests.addItems(withTitles: ["Choose an interest…"] + DiscoverySafety.genres.map(\.capitalized))
        interests.font = ClassicUI.small; interests.target = self; interests.action = #selector(changeInterest); interests.setAccessibilityLabel("Discovery interests")
        let reset = DiscoveryAction("Reset interests") { [weak self] in self?.preference?(nil) }
        addOption(horizontal([interests, reset, NSView()]))
        history.font = ClassicUI.small; history.target = self; history.action = #selector(changeHistory); addOption(history)
        ai.font = ClassicUI.small; ai.target = self; ai.action = #selector(changeAI); addOption(ai)
        search.placeholderString = "Search saved stations or describe a sound…"; search.font = .systemFont(ofSize: 12)
        search.target = self; search.action = #selector(searchNow); search.setAccessibilityLabel("Search saved discovery listings")
        let find = DiscoveryAction("Find") { [weak self] in self?.searchNow() }
        add(horizontal([search, find]))
        shelves.orientation = .vertical; shelves.alignment = .leading; shelves.spacing = 12; add(shelves)
        add(text("Recommendations exclude flagged adult and sensitive metadata and unclassified stations. Live programming can change; metadata is not a content guarantee.", size: 11, color: .secondaryLabelColor))
        add(text("Search, preferences and listening history stay here. Refresh connects directly to enabled directories. No cloud AI. No account.", size: 11, color: .secondaryLabelColor))
        add(DiscoveryAction("Clear saved discovery data") { [weak self] in self?.clearData?() })
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
    func setStatus(_ value: String, busy: Bool = false) { status.stringValue = value; refreshButton.isEnabled = !busy; refreshButton.title = busy ? "Refreshing…" : "Refresh directories" }
    func configure(state: Library.State) {
        history.state = state.discoveryPersonalization == false ? .off : .on
        ai.state = state.discoveryAI == true ? .on : .off
    }
    func render(_ feed: DiscoveryFeed, favorites: [Station]) {
        for view in shelves.arrangedSubviews { shelves.removeArrangedSubview(view); view.removeFromSuperview() }
        cardRows = []; compactWidths = []
        let tags = feed.interests.map(\.capitalized).joined(separator: "  ·  ")
        addShelfView(text(tags.isEmpty ? "Start with a sound you love" : tags, size: 12, color: .systemTeal, weight: .medium))
        if feed.shelves.isEmpty {
            addShelfView(text("A fresh dial awaits", size: 22, color: .white, weight: .semibold))
            addShelfView(text("Choose an interest, then refresh your enabled directories. Discover only recommends listings with suitable music metadata. You can browse all stations in the station browser.", size: 13, color: .secondaryLabelColor))
        }
        for shelf in feed.shelves {
            addShelfView(text(shelf.title, size: 20, color: .white, weight: .semibold))
            addShelfView(text(shelf.subtitle, size: 12, color: .secondaryLabelColor))
            for offset in stride(from: 0, to: shelf.picks.count, by: 2) {
                let pair = Array(shelf.picks[offset..<min(offset + 2, shelf.picks.count)])
                let row = NSStackView(views: pair.map { pick in card(pick, saved: favorites.contains { $0.address == pick.listing.address }) })
                row.orientation = bounds.width < 540 ? .vertical : .horizontal; row.alignment = .top; row.distribution = .fillEqually; row.spacing = 12
                cardRows.append(row); addShelfView(row)
                for card in row.arrangedSubviews {
                    let width = card.widthAnchor.constraint(equalTo: row.widthAnchor)
                    width.isActive = bounds.width < 540; compactWidths.append(width)
                }
            }
        }
        needsLayout = true
    }
    private func addOption(_ view: NSView) {
        options.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
    }
    private func addShelfView(_ view: NSView) {
        shelves.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: shelves.widthAnchor).isActive = true
    }
    private func card(_ pick: DiscoveryPick, saved: Bool) -> NSView {
        let row = pick.listing
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 8
        card.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor; card.layer?.cornerRadius = 10
        func append(_ view: NSView) {
            card.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true
        }
        let genre = DiscoverySafety.interests(row).sorted().first ?? "music"
        let artwork = FrequencyArtwork(genre); artwork.heightAnchor.constraint(equalToConstant: 58).isActive = true; append(artwork)
        append(text(genre.uppercased() + (row.video ? "  /  TV" : "  /  RADIO"), size: 10, color: .systemTeal, weight: .semibold))
        let title = text(row.name, size: 15, color: .white, weight: .semibold); title.maximumNumberOfLines = 2; append(title)
        append(text(pick.reason, size: 12, color: .secondaryLabelColor))
        let details = [row.country, row.formatLabel, row.bitrate > 0 ? "\(row.bitrate) kbps" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        append(text(details, size: 11, color: .secondaryLabelColor))
        let source = text(pick.sources.joined(separator: " · "), size: 10, color: .secondaryLabelColor); source.maximumNumberOfLines = 2
        source.toolTip = "Listed by " + pick.sources.joined(separator: ", ") + "\nSaved " + pick.fetched.formatted() + "\nStream health is not verified by this recommendation."
        append(source)
        append(horizontal([DiscoveryAction("▶ Play") { [weak self] in self?.play?(row) }, DiscoveryAction(saved ? "★ Saved" : "+ Save") { [weak self] in self?.favorite?(row) }, NSView(), DiscoveryAction("Hide") { [weak self] in self?.dismiss?(row) }]))
        return card
    }
    override func layout() {
        super.layout()
        let compact = bounds.width < 540
        for width in compactWidths where width.isActive != compact { width.isActive = compact }
        for row in cardRows { row.orientation = compact ? .vertical : .horizontal; row.alignment = compact ? .leading : .top }
    }
    @objc private func changeMedia(_ sender: NSSegmentedControl) { selectedVideo = sender.selectedSegment == 1; mediaChanged?(selectedVideo) }
    @objc private func changeInterest() { if interests.indexOfSelectedItem > 0 { preference?(DiscoverySafety.genres[interests.indexOfSelectedItem - 1]) }; interests.selectItem(at: 0) }
    @objc private func changeHistory() { personalize?(history.state == .on) }
    @objc private func changeAI() { aiChanged?(ai.state == .on) }
    @objc private func searchNow() { if ai.state == .on { interpret?(search.stringValue) } else { searchChanged?(search.stringValue) } }
}
