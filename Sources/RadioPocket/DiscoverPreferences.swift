import AppKit

/// Preferences apply atomically. Explicit location and city-search actions can request permission/network access before Apply.
private final class MixStack: NSStackView { override var isFlipped: Bool { true } }

final class DiscoverPreferencesController: NSWindowController, NSTabViewDelegate, NSWindowDelegate {
    var apply: ((DiscoveryPreferences) -> Void)?
    private var draft: DiscoveryPreferences
    private let tabs = NSTabView()
    private let weatherStatus = NSTextField(wrappingLabelWithString: "")
    private var cityController: MoodCityController?
    private let location = MoodLocation()
    private var locationTask: Task<Void, Never>?
    private var locationButton: NSButton!
    private var genreButtons: [(String, NSButton)] = []
    private var languageButtons: [(String, NSButton)] = []
    private let unknown = NSButton(checkboxWithTitle: "Include stations with no published language", target: nil, action: nil)
    private let history = NSButton(checkboxWithTitle: "Use my recent listening", target: nil, action: nil)
    private let ai = NSButton(checkboxWithTitle: "Use on-device AI for searches and moods", target: nil, action: nil)
    private let availability = NSButton(checkboxWithTitle: "Check stream availability locally", target: nil, action: nil)
    private let artwork = NSButton(checkboxWithTitle: "Show station artwork", target: nil, action: nil)
    init(preferences: DiscoveryPreferences) {
        draft = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Your mix"; panel.appearance = NSAppearance(named: .darkAqua); panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func label(_ text: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); label.textColor = bold ? .labelColor : .secondaryLabelColor; return label
    }
    private func stack() -> NSStackView { let s = MixStack(); s.orientation = .vertical; s.alignment = .leading; s.spacing = 12; return s }
    private func checkbox(_ title: String, selected: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil); button.state = selected ? .on : .off; button.font = .systemFont(ofSize: 12); return button
    }
    private func addGrid(_ buttons: [NSButton], to stack: NSStackView) {
        for start in stride(from: 0, to: buttons.count, by: 3) {
            let slice = Array(buttons[start..<min(start + 3, buttons.count)])
            let views: [NSView] = slice + (0..<(3 - slice.count)).map { _ in NSView() }
            let row = NSStackView(views: views); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
            stack.addArrangedSubview(row)
        }
    }
    private func scrolling(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.horizontalScrollElasticity = .none; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        for view in stack.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false; stack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12); scroll.documentView = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return scroll
    }
    private func build() {
        guard let root = window?.contentView else { return }
        let body = stack(); body.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), body.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)])
        body.addArrangedSubview(label("Make room for your kind of radio.", size: 22, bold: true))
        body.addArrangedSubview(label("Choose a few favorites or leave it open. Your choices are saved on this device."))
        tabs.delegate = self; body.addArrangedSubview(tabs); tabs.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true; tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        let genres = stack()
        genres.addArrangedSubview(label("Select any number of genres. Recommendations still leave room for something new."))
        for group in DiscoveryCatalog.groups {
            genres.addArrangedSubview(label(group.name, size: 13, bold: true))
            let buttons = group.values.map { genre -> NSButton in
                let button = checkbox(genre.capitalized, selected: draft.genres.contains(genre)); genreButtons.append((genre, button)); return button
            }
            addGrid(buttons, to: genres)
        }
        let languages = stack()
        languages.addArrangedSubview(label("Prefer these broadcast languages. None selected means all languages. Country is never used to guess a station’s language."))
        let buttons = DiscoveryCatalog.languages.map { language -> NSButton in
            let button = checkbox(language.name, selected: draft.languages.contains(language.code)); languageButtons.append((language.code, button)); return button
        }
        addGrid(buttons, to: languages)
        unknown.state = draft.includeUnknownLanguage ? .on : .off; unknown.font = .systemFont(ofSize: 12); languages.addArrangedSubview(unknown)
        let listening = stack()
        for (button, enabled) in [(history, draft.useHistory), (ai, draft.useAI), (artwork, draft.showArtwork), (availability, draft.checkAvailability)] { button.state = enabled ? .on : .off; button.font = .systemFont(ofSize: 12) }
        listening.addArrangedSubview(history); listening.addArrangedSubview(label("Refresh may send chosen genres to enabled directories. Uses the recent stations already in your library. Favorites and selected genres work even with this off."))
        listening.addArrangedSubview(ai); listening.addArrangedSubview(label("Optional Apple Intelligence interprets genres and languages locally. Ordinary search remains available on every supported Mac."))
        listening.addArrangedSubview(availability); listening.addArrangedSubview(label("Briefly contacts recommended streams while discovery is open. Stations can see your IP address; only check results are saved on this device. Quality stars remain separate."))
        listening.addArrangedSubview(artwork); listening.addArrangedSubview(label("Loads published station images directly when cards appear. Images stay in memory and are never saved as graphic files or cached on disk. Image hosts can see your IP address."))
        listening.addArrangedSubview(label("Adult and sensitive listings remain excluded from Discover. Live programming can change independently of station metadata."))
        let weather = stack()
        weather.addArrangedSubview(label("Weather for your moods", size: 18, bold: true))
        weather.addArrangedSubview(label("Use your device to find a nearby city, or choose a city yourself. Weather changes your mood suggestions; it never changes your station language preferences."))
        weatherStatus.font = .systemFont(ofSize: 12); weatherStatus.textColor = .secondaryLabelColor; weather.addArrangedSubview(weatherStatus)
        locationButton = NSButton(title: "Use my location", target: self, action: #selector(detectLocation))
        let choose = NSButton(title: "Choose city…", target: self, action: #selector(chooseCity))
        let off = NSButton(title: "Turn weather off", target: self, action: #selector(disableWeather))
        for button in [locationButton!, choose, off] { button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12, weight: .medium) }
        weather.addArrangedSubview(NSStackView(views: [locationButton, choose, off]))
        weather.addArrangedSubview(label("macOS asks for location permission the first time. This is a one-time lookup, not continuous tracking. An approximate area is saved on this device and sent to Open-Meteo for weather. Use this button again after travelling to update the area."))
        weather.addArrangedSubview(label("City lookup uses Apple Location Services or Open-Meteo city search. Apply saves your weather choice; Cancel keeps the previous choice."))
        let attribution = NSButton(title: "Weather by Open-Meteo ↗ · Location data by GeoNames", target: self, action: #selector(openWeatherProvider))
        attribution.isBordered = false; attribution.font = .systemFont(ofSize: 12)
        weather.addArrangedSubview(attribution)
        updateWeatherStatus()
        for (title, pane) in [("Genres", genres), ("Languages", languages), ("Listening & privacy", listening), ("Weather", weather)] {
            let tab = NSTabViewItem(identifier: title); tab.label = title; tab.view = scrolling(pane); tabs.addTabViewItem(tab)
        }
        let reset = NSButton(title: "Reset choices", target: self, action: #selector(resetChoices)); reset.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(save)); apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [reset, NSView(), cancel, apply]); actions.orientation = .horizontal; actions.spacing = 8
        body.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
    @objc private func openWeatherProvider() { NSWorkspace.shared.open(URL(string: "https://open-meteo.com/")!) }
    func present(on parent: NSWindow, weather: Bool = false) { guard let window else { return }; if weather { tabs.selectTabViewItem(withIdentifier: "Weather") }; parent.beginSheet(window); window.contentView?.layoutSubtreeIfNeeded() }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let scroll = tabViewItem?.view as? NSScrollView else { return }
        DispatchQueue.main.async { scroll.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    private func updateWeatherStatus() { weatherStatus.stringValue = draft.moodCity.map { "Weather area: " + $0.name } ?? "Weather is off. Moods still uses the day and time." }
    @objc private func detectLocation() {
        locationTask?.cancel(); locationButton.isEnabled = false
        weatherStatus.stringValue = "Waiting for location permission or finding your nearby city…"
        locationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.locationButton.isEnabled = true }
            do {
                let city = try await self.location.detectCity()
                guard !Task.isCancelled else { return }
                self.draft.moodCity = city; self.draft.weatherPromptHandled = true; self.updateWeatherStatus()
            } catch {
                guard !Task.isCancelled else { return }
                self.weatherStatus.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func chooseCity() {
        guard let window, window.attachedSheet == nil else { return }
        locationTask?.cancel(); location.cancel(); locationButton.isEnabled = true
        let controller = MoodCityController(city: draft.moodCity)
        controller.save = { [weak self] city in self?.draft.moodCity = city; self?.draft.weatherPromptHandled = true; self?.updateWeatherStatus() }
        cityController = controller; controller.present(on: window)
    }
    @objc private func disableWeather() {
        locationTask?.cancel(); location.cancel(); locationButton.isEnabled = true
        draft.moodCity = nil; draft.weatherPromptHandled = true; updateWeatherStatus()
    }
    func windowWillClose(_ notification: Notification) { locationTask?.cancel(); location.cancel() }
    private func finish() { locationTask?.cancel(); location.cancel(); if let window, let parent = window.sheetParent { parent.endSheet(window) }; close() }
    @objc private func cancel() { finish() }
    @objc private func resetChoices() { for (_, button) in genreButtons + languageButtons { button.state = .off }; unknown.state = .on }
    @objc private func save() {
        draft.genres = genreButtons.filter { $0.1.state == .on }.map(\.0); draft.languages = languageButtons.filter { $0.1.state == .on }.map(\.0)
        draft.checkAvailability = availability.state == .on
        draft.includeUnknownLanguage = unknown.state == .on; draft.useHistory = history.state == .on; draft.useAI = ai.state == .on; draft.showArtwork = artwork.state == .on
        apply?(draft); finish()
    }
}
