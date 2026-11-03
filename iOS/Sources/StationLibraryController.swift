import UIKit

/// The full-screen stream library: saved favorites and recents, and the combined internet radio directories with search,
/// source / genre / country / sort filters, paging, and favorites. Rows are sized for fingers.
final class StationLibraryController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Scope: Int, CaseIterable { case favorites, recent, browse
        var title: String { ["Favorites", "Recent", "Browse"][rawValue] }
    }
    private struct Row { var station: Station; var detail: String; var listingID: String? }

    private static let genres = ["Alternative", "Ambient", "Blues", "Classical", "Country", "Electronic", "Folk", "Hip Hop", "Indie", "Jazz", "Metal", "News", "Pop", "Reggae", "Rock", "Soul", "Talk", "World"]
    private static let sorts: [(title: String, order: String, reverse: Bool)] = [("Popular", "clickcount", true), ("Top rated", "votes", true), ("Name A–Z", "name", false), ("Best quality", "quality", true)]
    private static let countries: [(code: String, name: String)] = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        .map { ($0, Locale.current.localizedString(forRegionCode: $0) ?? $0) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

    private let library: Library
    private let directory: RadioDirectory
    private let currentAddress: () -> String?
    private let onPlay: (Station, String?) -> Void
    private let accent: UIColor

    private let search = UISearchBar()
    private let scopes = UISegmentedControl(items: Scope.allCases.map(\.title))
    private let chips = UIScrollView()
    private let chipStack = UIStackView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let refresher = UIRefreshControl()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var scope: Scope
    private var rows: [Row] = []
    private var query = DirectoryQuery()
    private var sources: [DirectorySource] = []
    private var hasMore = false
    private var loading: Task<Void, Never>?
    private var generation = 0
    private var failure: String?

    init(library: Library, directory: RadioDirectory, skin: ClassicSkin?, scope: Scope? = nil, currentAddress: @escaping () -> String?, onPlay: @escaping (Station, String?) -> Void) {
        self.library = library; self.directory = directory; self.currentAddress = currentAddress; self.onPlay = onPlay
        accent = skin?.palette.accent ?? .systemGreen
        self.scope = scope ?? (library.state.favorites.isEmpty ? .browse : .favorites)
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = accent
        sources = DirectorySource.resolved(library.state.directories).filter(\.enabled)

        let close = UIButton(type: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let title = UILabel(); title.text = "Stations"; title.font = .preferredFont(forTextStyle: .headline)
        let top = UIStackView(arrangedSubviews: [title, UIView(), close]); top.alignment = .center

        search.placeholder = "Search stations"
        search.searchBarStyle = .minimal
        search.autocapitalizationType = .none
        search.returnKeyType = .search
        search.delegate = self

        scopes.selectedSegmentIndex = scope.rawValue
        scopes.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)

        chipStack.axis = .horizontal; chipStack.spacing = 8; chipStack.translatesAutoresizingMaskIntoConstraints = false
        chips.showsHorizontalScrollIndicator = false
        chips.addSubview(chipStack)
        NSLayoutConstraint.activate([
            chipStack.leadingAnchor.constraint(equalTo: chips.contentLayoutGuide.leadingAnchor), chipStack.trailingAnchor.constraint(equalTo: chips.contentLayoutGuide.trailingAnchor),
            chipStack.topAnchor.constraint(equalTo: chips.contentLayoutGuide.topAnchor), chipStack.bottomAnchor.constraint(equalTo: chips.contentLayoutGuide.bottomAnchor),
            chipStack.heightAnchor.constraint(equalTo: chips.frameLayoutGuide.heightAnchor), chips.heightAnchor.constraint(equalToConstant: 36),
        ])

        let header = UIStackView(arrangedSubviews: [top, search, scopes, chips])
        header.axis = .vertical; header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        table.dataSource = self; table.delegate = self
        table.register(StationCell.self, forCellReuseIdentifier: "station")
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 64
        table.keyboardDismissMode = .onDrag
        table.refreshControl = refresher
        refresher.addTarget(self, action: #selector(refresh), for: .valueChanged)
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        status.textColor = .secondaryLabel; status.font = .preferredFont(forTextStyle: .body); status.textAlignment = .center; status.numberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true; spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status); view.addSubview(spinner)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: guide.leadingAnchor), table.trailingAnchor.constraint(equalTo: guide.trailingAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: table.centerXAnchor), status.centerYAnchor.constraint(equalTo: table.centerYAnchor, constant: -40),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: table.leadingAnchor, constant: 32), status.trailingAnchor.constraint(lessThanOrEqualTo: table.trailingAnchor, constant: -32),
            spinner.centerXAnchor.constraint(equalTo: table.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: table.centerYAnchor, constant: -40),
        ])
        rebuildChips()
        reload()
    }

    // MARK: Filters

    private var filtersActive: Bool { !query.genre.isEmpty || !query.countryCode.isEmpty || query.sourceID != "all" || !(query.order == "clickcount") }

    private func rebuildChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.isHidden = scope != .browse
        guard scope == .browse else { return }
        let sourceName = sources.first { $0.id == query.sourceID }?.name
        chipStack.addArrangedSubview(chip(sourceName.map { String($0.prefix(18)) } ?? "All sources", active: query.sourceID != "all", menu: UIMenu(children:
            [UIAction(title: "All sources", state: query.sourceID == "all" ? .on : .off) { [weak self] _ in self?.query.sourceID = "all"; self?.filtersChanged() }] +
            sources.map { source in UIAction(title: source.name, state: query.sourceID == source.id ? .on : .off) { [weak self] _ in self?.query.sourceID = source.id; self?.filtersChanged() } })))
        chipStack.addArrangedSubview(chip(query.genre.isEmpty ? "Genre" : query.genre.capitalized, active: !query.genre.isEmpty, menu: UIMenu(children:
            [UIAction(title: "All genres", state: query.genre.isEmpty ? .on : .off) { [weak self] _ in self?.query.genre = ""; self?.filtersChanged() }] +
            Self.genres.map { genre in UIAction(title: genre, state: query.genre == genre.lowercased() ? .on : .off) { [weak self] _ in self?.query.genre = genre.lowercased(); self?.filtersChanged() } })))
        let country = Self.countries.first { $0.code == query.countryCode }?.name
        chipStack.addArrangedSubview(chip(country ?? "Country", active: country != nil, menu: UIMenu(children:
            [UIAction(title: "Any country", state: query.countryCode.isEmpty ? .on : .off) { [weak self] _ in self?.query.countryCode = ""; self?.filtersChanged() }] +
            Self.countries.map { entry in UIAction(title: entry.name, state: query.countryCode == entry.code ? .on : .off) { [weak self] _ in self?.query.countryCode = entry.code; self?.filtersChanged() } })))
        let sort = Self.sorts.first { $0.order == query.order && $0.reverse == query.reverse } ?? Self.sorts[0]
        chipStack.addArrangedSubview(chip(sort.title, active: sort.order != "clickcount", menu: UIMenu(children: Self.sorts.map { option in
            UIAction(title: option.title, state: option.order == sort.order ? .on : .off) { [weak self] _ in self?.query.order = option.order; self?.query.reverse = option.reverse; self?.filtersChanged() } })))
        if filtersActive {
            var configuration = UIButton.Configuration.plain(); configuration.title = "Clear"; configuration.baseForegroundColor = .secondaryLabel
            chipStack.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.clearFilters() }))
        }
    }

    private func chip(_ title: String, active: Bool, menu: UIMenu) -> UIButton {
        var configuration = active ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing; configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        configuration.baseBackgroundColor = active ? accent : .secondaryLabel
        configuration.baseForegroundColor = active ? .black : .label
        let button = UIButton(configuration: configuration)
        button.menu = menu; button.showsMenuAsPrimaryAction = true
        return button
    }

    private func filtersChanged() { rebuildChips(); reload() }
    private func clearFilters() { query.genre = ""; query.countryCode = ""; query.sourceID = "all"; query.order = "clickcount"; query.reverse = true; filtersChanged() }
    @objc private func scopeChanged() { scope = Scope(rawValue: scopes.selectedSegmentIndex) ?? .favorites; rebuildChips(); reload() }
    @objc private func refresh() { reload(refresh: true) }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { reload(debounce: true) }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

    // MARK: Loading

    private var searchText: String { (search.text ?? "").trimmingCharacters(in: .whitespaces) }

    private func reload(refresh: Bool = false, debounce: Bool = false) {
        loading?.cancel()
        generation += 1
        let mine = generation, text = searchText
        failure = nil; hasMore = false
        switch scope {
        case .favorites, .recent:
            let stations = scope == .favorites ? library.state.favorites : library.state.recentStations ?? []
            rows = stations.filter { text.isEmpty || StationSearch.matches(StationSearch.words(text), in: [$0.name, $0.address]) }.map { Row(station: $0, detail: Self.host($0.address), listingID: nil) }
            refresher.endRefreshing(); spinner.stopAnimating()
            finishLoading(empty: scope == .favorites ? "No favorites yet.\nStar a station in Browse to keep it here." : "Nothing played yet.")
        case .browse:
            query.name = text; query.offset = 0
            if rows.isEmpty || !debounce { spinner.startAnimating() }
            status.text = nil
            let snapshot = query
            loading = Task { [weak self, directory] in
                if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
                guard !Task.isCancelled else { return }
                do {
                    let page = try await directory.search(snapshot, refresh: refresh)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.generation == mine else { return }
                        self.rows = page.stations.map(Self.row); self.hasMore = page.hasMore
                        self.refresher.endRefreshing(); self.spinner.stopAnimating()
                        self.finishLoading(empty: "No stations match.")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.generation == mine else { return }
                        self.rows = []; self.failure = error.localizedDescription
                        self.refresher.endRefreshing(); self.spinner.stopAnimating()
                        self.finishLoading(empty: "")
                    }
                }
            }
        }
    }

    private func loadMore() {
        guard scope == .browse, hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        var next = query; next.offset = rows.count
        let mine = generation
        Task { [weak self, directory] in
            let page = try? await directory.search(next)
            await MainActor.run {
                guard let self else { return }
                self.isLoadingMore = false
                guard self.generation == mine, let page else { return }
                let known = Set(self.rows.map(\.station.address))
                self.rows += page.stations.map(Self.row).filter { !known.contains($0.station.address) }
                self.hasMore = page.hasMore
                self.table.reloadData()
            }
        }
    }
    private var isLoadingMore = false

    private func finishLoading(empty: String) {
        status.text = rows.isEmpty ? (failure ?? empty) : nil
        table.reloadData()
    }

    private static func row(_ listing: RadioListing) -> Row {
        let facts = [listing.country, listing.codec, listing.bitrate > 0 ? "\(listing.bitrate) kbps" : ""].filter { !$0.isEmpty }
        return Row(station: Station(name: listing.name, address: listing.address), detail: facts.joined(separator: " • "), listingID: listing.directoryID)
    }
    private static func host(_ address: String) -> String { URL(string: address)?.host ?? address }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "station", for: indexPath) as! StationCell
        let row = rows[indexPath.row]
        cell.configure(name: row.station.name, detail: row.detail, playing: row.station.address == currentAddress(), favorite: library.isFavorite(row.station), accent: accent)
        cell.toggleFavorite = { [weak self] in self?.toggleFavorite(row.station) }
        if indexPath.row >= rows.count - 8 { loadMore() }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        onPlay(row.station, row.listingID)
        dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let row = rows[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let favorite = self.library.isFavorite(row.station)
            return UIMenu(children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in self.onPlay(row.station, row.listingID); self.dismiss(animated: true) },
                UIAction(title: favorite ? "Remove Favorite" : "Save Favorite", image: UIImage(systemName: favorite ? "star.slash" : "star")) { _ in self.toggleFavorite(row.station) },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    if let url = try? ExternalRadioLink.link(for: row.station) { UIPasteboard.general.url = url }
                },
            ])
        })
    }

    private func toggleFavorite(_ station: Station) {
        do { if library.isFavorite(station) { try library.removeFavorite(station) } else { try library.save(station) } } catch { return }
        if scope == .favorites { reload() } else { table.reloadData() }
    }
}

/// A two-line station row with a large favorite star.
private final class StationCell: UITableViewCell {
    private let name = UILabel(), detail = UILabel(), star = UIButton(type: .system), playing = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    var toggleFavorite: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        name.font = .preferredFont(forTextStyle: .body)
        detail.font = .preferredFont(forTextStyle: .footnote); detail.textColor = .secondaryLabel
        playing.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [name, detail]); text.axis = .vertical; text.spacing = 2
        let row = UIStackView(arrangedSubviews: [playing, text, star]); row.alignment = .center; row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        star.addAction(UIAction { [weak self] _ in self?.toggleFavorite?() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor), row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            star.widthAnchor.constraint(equalToConstant: 44), star.heightAnchor.constraint(equalToConstant: 44),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, detail: String, playing isPlaying: Bool, favorite: Bool, accent: UIColor) {
        self.name.text = name
        self.name.textColor = isPlaying ? accent : .label
        self.detail.text = detail
        playing.isHidden = !isPlaying; playing.tintColor = accent
        star.setImage(UIImage(systemName: favorite ? "star.fill" : "star"), for: .normal)
        star.tintColor = favorite ? .systemOrange : .tertiaryLabel
        star.accessibilityLabel = favorite ? "Remove favorite" : "Save favorite"
    }
}
