import UIKit

/// Favorites and recents inside the classic playlist window, coloured by the skin. Tapping a row plays it; a swipe removes a favorite.
/// Browsing the directories happens in `StationLibraryController`.
final class StationBrowserController: UITableViewController {
    enum Scope { case favorites, recent }
    private let library: Library
    private let onPlay: (Station) -> Void
    private let search = UISearchBar()
    private var rows: [Station] = []
    private(set) var scope: Scope = .favorites
    var skin: ClassicSkin? { didSet { applyStyle(); tableView.reloadData() } }
    /// The station playing now, drawn in the skin's highlight colour.
    var currentAddress: String? { didSet { if oldValue != currentAddress { tableView.reloadData() } } }
    var scaleFactor: CGFloat = 1 { didSet { if oldValue != scaleFactor { applyStyle(); tableView.reloadData() } } }

    init(library: Library, onPlay: @escaping (Station) -> Void) {
        self.library = library; self.onPlay = onPlay
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var palette: SkinPalette { skin?.palette ?? .native }
    private var searchText: String { (search.text ?? "").trimmingCharacters(in: .whitespaces) }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.keyboardDismissMode = .onDrag
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        search.delegate = self
        search.autocapitalizationType = .none
        search.searchBarStyle = .minimal
        tableView.tableHeaderView = search
        applyStyle()
        reload()
    }

    private func applyStyle() {
        guard isViewLoaded else { return }
        tableView.backgroundColor = palette.item
        search.overrideUserInterfaceStyle = .dark
        search.searchTextField.textColor = palette.text
        search.searchTextField.font = .systemFont(ofSize: 9 * scaleFactor)
        search.searchTextField.attributedPlaceholder = NSAttributedString(string: "Search saved stations", attributes: [.foregroundColor: palette.label])
        search.sizeToFit()
        tableView.tableHeaderView = search
    }

    func setScope(_ next: Scope) { scope = next; reload() }
    /// Re-reads the saved lists after a favorite or recent changes elsewhere.
    func refresh() { reload() }

    private func reload() {
        let text = searchText
        let saved = scope == .favorites ? library.state.favorites : library.state.recentStations ?? []
        rows = saved.filter { text.isEmpty || StationSearch.matches(StationSearch.words(text), in: [$0.name, $0.address]) }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { max(26, 15 * scaleFactor) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let station = rows[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.text = station.name
        content.textProperties.color = station.address == currentAddress ? palette.accent : palette.text
        content.textProperties.font = .systemFont(ofSize: 9 * scaleFactor)
        content.textProperties.numberOfLines = 1
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4 * scaleFactor, bottom: 0, trailing: 4 * scaleFactor)
        cell.contentConfiguration = content
        cell.backgroundColor = indexPath.row % 2 == 0 ? palette.item : palette.itemAlternate
        let selected = UIView(); selected.backgroundColor = palette.selection
        cell.selectedBackgroundView = selected
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onPlay(rows[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard scope == .favorites else { return nil }
        let station = rows[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            do { try self?.library.removeFavorite(station) } catch { return done(false) }
            self?.reload(); done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }
}

extension StationBrowserController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { reload() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
}
