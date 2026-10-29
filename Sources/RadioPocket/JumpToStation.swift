import AppKit

/// Winamp's "jump to file" box for stations: start typing, arrows to choose, Return to tune in.
final class JumpToStationController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let field = NSTextField()
    private let table = NSTableView()
    private let library: Library
    private var matches: [Station] = []
    var play: ((Station) -> Void)?

    init(library: Library) {
        self.library = library
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Jump to Station"
        window.isReleasedWhenClosed = false; window.hasShadow = true; window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        let root = ClassicChrome(frame: NSRect(x: 0, y: 0, width: 420, height: 280)); root.title = "JUMP TO STATION"
        window.contentView = root
        let close = ClassicWindowButton(title: "×", target: self, action: #selector(dismiss))
        close.frame = NSRect(x: 408, y: 3, width: 9, height: 9); close.isBordered = false; close.setAccessibilityLabel("Close"); root.addSubview(close)
        field.frame = NSRect(x: 12, y: 28, width: 396, height: 23); ClassicUI.field(field)
        field.placeholderString = "Type part of a station name"; field.delegate = self; field.setAccessibilityLabel("Station name")
        root.addSubview(field)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 58, width: 396, height: 212))
        scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder; scroll.scrollerStyle = .legacy; scroll.backgroundColor = ClassicUI.black
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.width = 380; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 20; table.backgroundColor = ClassicUI.black
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityLabel("Matching stations")
        scroll.documentView = table; root.addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Favorites first, then recently played and the last station, without repeats.
    private var candidates: [Station] {
        var seen = Set<String>(), list: [Station] = []
        for station in library.state.favorites + (library.state.recentStations ?? []) + [library.state.lastStation].compactMap({ $0 }) where seen.insert(station.address).inserted { list.append(station) }
        return list
    }
    func present(over player: NSWindow?) {
        field.stringValue = ""; refilter()
        if let player { window?.setFrameTopLeftPoint(NSPoint(x: player.frame.minX, y: player.frame.minY - 8)) } else { window?.center() }
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(field)
    }
    private func refilter() {
        matches = StationSearch.match(field.stringValue, in: candidates)
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func controlTextDidChange(_ notification: Notification) { refilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func choose() {
        guard matches.indices.contains(table.selectedRow) else { return }
        let station = matches[table.selectedRow]
        dismiss(); play?(station)
    }
    @objc private func dismiss() { window?.orderOut(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = LibraryRow(); view.alternating = row % 2 == 1; return view }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: matches[row].name)
        label.font = ClassicUI.font; label.textColor = ClassicUI.green; label.lineBreakMode = .byTruncatingTail
        label.toolTip = matches[row].address
        return label
    }
}
