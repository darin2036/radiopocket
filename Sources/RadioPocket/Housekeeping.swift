import AppKit
import Darwin

/// Hands memory back at quiet moments, so a player left running for days stays as light as it started.
/// Nothing here polls: it reacts to the system's memory-pressure signal and to the app going unused.
final class Housekeeping {
    /// How long RadioPocket sits hidden or behind other apps before it tidies up.
    static let backgroundDelay: TimeInterval = 90
    private let directory: RadioDirectory
    private var pressure: DispatchSourceMemoryPressure?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(directory: RadioDirectory) { self.directory = directory }
    deinit { stop() }

    func start() {
        guard pressure == nil else { return }
        // The system asks apps to give memory back before it starts compressing or swapping.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.tidy(everything: true) }
        source.resume()
        pressure = source
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleBackgroundTidy() })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancelBackgroundTidy() })
        }
    }

    func stop() {
        pressure?.cancel(); pressure = nil
        cancelBackgroundTidy()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func scheduleBackgroundTidy() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tidy(everything: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundDelay, execute: work)
    }
    private func cancelBackgroundTidy() { pending?.cancel(); pending = nil }

    /// Frees the downloaded station lists held in memory (all of them under pressure, otherwise only the idle ones),
    /// then asks malloc to return the pages that freed to the system. The saved lists on disk are not touched.
    func tidy(everything: Bool) {
        let directory = directory
        Task(priority: .utility) {
            await directory.releaseMemory(everything: everything)
            URLCache.shared.removeAllCachedResponses()
            Self.returnFreedMemory()
        }
    }

    /// Without this, memory the app has freed can stay mapped for a long time.
    static func returnFreedMemory() { _ = malloc_zone_pressure_relief(nil, 0) }
}
