import UIKit

/// The classic player. Landscape shows the main window alone, as on the desktop; portrait stacks the main window, equalizer and
/// playlist windows down the screen, each at full width.
final class PlayerViewController: UIViewController {
    private let engine = RadioEngine()
    private let library: Library?
    private let nowPlaying = NowPlayingController()
    private let directory = RadioDirectory()
    private lazy var player = ClassicPlayerView(engine: engine)
    private lazy var equalizerView = ClassicEqualizerView(equalizer: engine.equalizer)
    private let playlist = ClassicPlaylistView()
    private var stations: StationBrowserController?
    private var recordedStation: UUID?
    private var volumeSave: DispatchWorkItem?
    private var equalizerSave: DispatchWorkItem?

    override init(nibName: String?, bundle: Bundle?) {
        library = try? Library()
        super.init(nibName: nibName, bundle: bundle)
        if let saved = library?.state.directories { Task { [directory] in await directory.configure(saved) } }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let skin = ClassicSkin.fallback
        player.skin = skin; equalizerView.skin = skin; playlist.skin = skin
        view.addSubview(player); view.addSubview(equalizerView); view.addSubview(playlist)

        player.action = { [weak self] in self?.handle($0) }
        player.volumeChanged = { [weak self] value in
            guard let self else { return }
            engine.setVolume(value); saveSoon()
        }
        player.balanceChanged = { [weak self] value in
            guard let self else { return }
            engine.setBalance(value); saveSoon()
        }
        equalizerView.presetsRequested = { [weak self] in self?.chooseEqualizerPreset() }
        playlist.action = { [weak self] in self?.playlistAction($0) }

        if let library {
            let state = library.state
            engine.setVolume(state.volume)
            engine.setBalance(state.balance ?? 0)
            engine.leveling = state.leveling ?? false
            if let eq = state.equalizer { engine.equalizer.settings = eq }
            if let spatial = state.spatial { engine.equalizer.spatial = spatial }
            if let last = state.lastStation { engine.load(last) }
            let browser = StationBrowserController(library: library) { [weak self] station in self?.play(station) }
            browser.skin = skin
            addChild(browser)
            playlist.addSubview(browser.view)
            browser.didMove(toParent: self)
            stations = browser
        }
        engine.equalizer.changed = { [weak self] in self?.equalizerChanged() }
        engine.changed = { [weak self] in self?.engineChanged() }
        nowPlaying.action = { [weak self] in self?.handle($0) }
        nowPlaying.canPlay = { [weak self] in self?.currentStation != nil }
        nowPlaying.canSkip = { [weak self] in (self?.library?.state.favorites.count ?? 0) > 1 }
        engineChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        stations?.refresh()
    }

    // MARK: Layout

    private var isLandscape: Bool { view.bounds.width > view.bounds.height }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let area = CGRect(x: safe.left, y: safe.top, width: view.bounds.width - safe.left - safe.right, height: view.bounds.height - safe.top - safe.bottom)
        equalizerView.isHidden = isLandscape; playlist.isHidden = isLandscape
        if isLandscape {
            player.frame = area
        } else {
            let window = (area.width * 116 / 275).rounded()
            player.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: window)
            equalizerView.frame = CGRect(x: area.minX, y: player.frame.maxY, width: area.width, height: window)
            playlist.frame = CGRect(x: area.minX, y: equalizerView.frame.maxY, width: area.width, height: max(0, area.maxY - equalizerView.frame.maxY))
            stations?.view.frame = playlist.contentFrame
            stations?.scaleFactor = playlist.scale
        }
    }

    // MARK: Engine

    private var currentStation: Station? { engine.station ?? library?.state.lastStation }

    private func engineChanged() {
        player.setNeedsDisplay()
        nowPlaying.update(station: engine.station, title: engine.title, status: engine.status)
        stations?.currentAddress = engine.station?.address
        if engine.status == .playing, let station = engine.station, recordedStation != station.id {
            recordedStation = station.id
            try? library?.recordRecent(station)
            stations?.refresh()
        }
    }

    private func equalizerChanged() {
        equalizerView.setNeedsDisplay()
        engine.refreshEQStatus()
        equalizerSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? library?.update { $0.equalizer = self.engine.equalizer.settings }
        }
        equalizerSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveSoon() {
        volumeSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? library?.update { $0.volume = self.engine.player.volume; $0.balance = self.engine.balance }
        }
        volumeSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func play(_ station: Station, listingID: String? = nil) {
        try? library?.update { $0.lastStation = station }
        recordedStation = nil
        engine.play(station)
        if let listingID { Task { [directory] in await directory.countPlay(listingID) } }
    }

    private func step(_ offset: Int) {
        guard let favorites = library?.state.favorites, !favorites.isEmpty else { return }
        let current = favorites.firstIndex { $0.address == currentStation?.address } ?? (offset > 0 ? -1 : 0)
        play(favorites[(current + offset + favorites.count) % favorites.count])
    }

    // MARK: Actions

    private func handle(_ id: String) {
        switch id {
        case "play":
            if engine.station != nil { engine.resume() }
            else if let last = library?.state.lastStation { play(last) }
            else { showLibrary() }
        case "toggle": handle(engine.status == .playing || engine.status == .connecting ? "pause" : "play")
        case "pause": engine.pause()
        case "stop": engine.stop()
        case "next": step(1)
        case "previous": step(-1)
        case "open", "library": showLibrary()
        case "equalizer": showEqualizer()
        default: break
        }
        player.setNeedsDisplay()
    }

    private func playlistAction(_ id: String) {
        switch id {
        case "add": showLibrary(.browse)
        case "select": stations?.setScope(.favorites)
        case "misc": stations?.setScope(.recent)
        case "remove":
            if let station = currentStation { try? library?.removeFavorite(station); stations?.refresh() }
        case "options":
            guard let station = currentStation, let library else { return }
            if library.isFavorite(station) { try? library.removeFavorite(station) } else { try? library.save(station) }
            stations?.refresh()
        default: break
        }
    }

    /// The full-screen stream library, over either layout.
    private func showLibrary(_ scope: StationLibraryController.Scope? = nil) {
        guard let library, presentedViewController == nil else { return }
        let browser = StationLibraryController(library: library, directory: directory, skin: ClassicSkin.fallback, scope: scope,
                                               currentAddress: { [weak self] in self?.engine.station?.address }) { [weak self] station, listingID in self?.play(station, listingID: listingID) }
        present(browser, animated: true) { [weak self] in self?.stations?.refresh() }
    }

    private func showEqualizer() {
        guard presentedViewController == nil else { return }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .black
        equalizerView.removeFromSuperview()
        equalizerView.translatesAutoresizingMaskIntoConstraints = false
        sheet.view.addSubview(equalizerView)
        NSLayoutConstraint.activate([
            equalizerView.leadingAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.leadingAnchor), equalizerView.trailingAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.trailingAnchor),
            equalizerView.topAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.topAnchor), equalizerView.bottomAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        sheet.modalPresentationStyle = .fullScreen
        let close = UIButton(type: .close, primaryAction: UIAction { [weak sheet, weak self] _ in
            sheet?.dismiss(animated: true) { self?.restoreEqualizer() }
        })
        close.translatesAutoresizingMaskIntoConstraints = false
        sheet.view.addSubview(close)
        NSLayoutConstraint.activate([close.trailingAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.trailingAnchor, constant: -8), close.topAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.topAnchor, constant: 8)])
        present(sheet, animated: true)
    }

    private func restoreEqualizer() {
        equalizerView.translatesAutoresizingMaskIntoConstraints = true
        view.insertSubview(equalizerView, belowSubview: playlist)
        view.setNeedsLayout()
    }

    private func chooseEqualizerPreset() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for preset in EQPreset.classic + engine.equalizer.settings.custom {
            let action = UIAlertAction(title: preset.name, style: .default) { [weak self] _ in self?.engine.equalizer.select(preset) }
            if engine.equalizer.settings.preset == preset.name { action.setValue(true, forKey: "checked") }
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let host = presentedViewController ?? self
        sheet.popoverPresentationController?.sourceView = equalizerView
        sheet.popoverPresentationController?.sourceRect = equalizerView.bounds
        host.present(sheet, animated: true)
    }
}
