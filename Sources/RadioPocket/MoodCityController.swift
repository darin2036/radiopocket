import AppKit

final class MoodCityController: NSWindowController {
    var save: ((MoodCity?) -> Void)?
    private let search = NSSearchField()
    private let results = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Search for a city, then choose the matching place.")
    private var cities: [MoodCity] = []
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var use: NSButton!
    init(city: MoodCity?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Weather for your moods"; panel.appearance = NSAppearance(named: .darkAqua)
        super.init(window: panel)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20)])
        let description = NSTextField(wrappingLabelWithString: "Add an optional city for weather-inspired moods. City searches and the selected city's coordinates go to Open-Meteo. Your listening stays on this device. No device location is used.")
        description.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(description)
        search.placeholderString = "City, region or country"; search.font = .systemFont(ofSize: 13); search.target = self; search.action = #selector(findCity); search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false; search.setAccessibilityLabel("Find weather city")
        root.addArrangedSubview(search)
        results.font = .systemFont(ofSize: 12); results.setAccessibilityLabel("Matching cities"); results.isEnabled = false; root.addArrangedSubview(results)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; root.addArrangedSubview(status)
        if let city { status.stringValue = "Saved city: " + city.name }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet)); cancel.keyEquivalent = "\u{1b}"
        let remove = NSButton(title: "Turn weather off", target: self, action: #selector(removeCity)); remove.isEnabled = city != nil
        use = NSButton(title: "Use city", target: self, action: #selector(saveCity)); use.isEnabled = false
        let buttons = NSStackView(views: [remove, NSView(), cancel, use]); buttons.spacing = 8
        for button in [remove, cancel, use!] { button.font = .systemFont(ofSize: 12, weight: .medium) }
        root.addArrangedSubview(buttons)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    func present(on parent: NSWindow) { guard let window else { return }; parent.beginSheet(window); window.makeFirstResponder(search) }
    @objc private func findCity() {
        request?.cancel(); generation = UUID(); let token = generation
        cities = []; results.removeAllItems(); results.isEnabled = false; use.isEnabled = false
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { status.stringValue = "Enter at least two characters."; return }
        status.stringValue = "Finding cities…"
        request = Task { @MainActor [weak self] in
            do {
                let places = try await MoodWeather.cities(matching: term)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.cities = places; self.results.addItems(withTitles: places.map(\.name)); self.results.isEnabled = !places.isEmpty; self.use.isEnabled = !places.isEmpty
                self.status.stringValue = places.isEmpty ? "No matching cities. Try a nearby city or add a country." : "Choose a place, then Use city. Weather by Open-Meteo."
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.status.stringValue = "City search unavailable. Try again later; your saved city is unchanged."
            }
        }
    }
    @objc private func saveCity() { guard cities.indices.contains(results.indexOfSelectedItem) else { return }; save?(cities[results.indexOfSelectedItem]); cancelSheet() }
    @objc private func removeCity() { save?(nil); cancelSheet() }
    @objc private func cancelSheet() { request?.cancel(); generation = UUID(); if let window { window.sheetParent?.endSheet(window) } }
}
