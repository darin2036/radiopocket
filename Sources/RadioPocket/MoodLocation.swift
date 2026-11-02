import AppKit
import CoreLocation

/// A user-initiated, one-shot city lookup. No background or continuous location tracking.
@MainActor
// CLLocationManager is created on the main run loop, which also delivers its delegate callbacks.
final class MoodLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private let geocoder = CLGeocoder()
    private var continuation: CheckedContinuation<MoodCity, Error>?
    private var timeout: Task<Void, Never>?
    private var geocoding = false
    private var authorizationRequested = false
    private var locationRequested = false
    private var token = UUID()

    func detectCity() async throws -> MoodCity {
        cancel()
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil else {
            throw RadioError.message("Open the RadioPocket app bundle to use location, or choose a city manually in Your mix.")
        }
        let request = token
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager(); self.manager = manager
                manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
                manager.delegate = self
                advance(manager)
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.token == request { self?.cancel() } } }
    }
    private func advance(_ manager: CLLocationManager) {
        guard continuation != nil, self.manager === manager, !geocoding else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !authorizationRequested {
                authorizationRequested = true
                startTimeout(seconds: 45, message: "macOS hasn’t completed location permission. If no prompt appeared, quit and reopen RadioPocket, then try again. You can also choose a city manually.")
                NSApp.activate(ignoringOtherApps: true)
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationRequested else { return }
            locationRequested = true
            startTimeout(seconds: 20, message: "Couldn’t find your city. Try again or choose a city in Your mix → Weather.")
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(RadioError.message("Location access is off. You can enable RadioPocket in System Settings → Privacy & Security → Location Services, or choose a city in Your mix → Weather.")))
        @unknown default: finish(.failure(RadioError.message("Location is unavailable. Choose a city in Your mix → Weather.")))
        }
    }
    private func startTimeout(seconds: Double, message: String) {
        timeout?.cancel()
        let request = token
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.token == request else { return }
            self.finish(.failure(RadioError.message(message)))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { advance(manager) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, continuation != nil, !geocoding,
              let location = locations.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50_000 && abs($0.timestamp.timeIntervalSinceNow) < 300 }) else { return }
        geocoding = true; manager.stopUpdatingLocation()
        let request = token
        geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
            Task { @MainActor in
                guard let self, self.token == request, self.continuation != nil else { return }
                let place = places?.first
                let name = [place?.locality ?? place?.subAdministrativeArea, place?.administrativeArea, place?.country].compactMap { $0 }.joined(separator: ", ")
                let city = MoodCity.approximate(name: name.isEmpty ? "Nearby area" : name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                guard city.valid else { self.finish(.failure(RadioError.message("The location could not be used. Choose a city manually."))); return }
                self.finish(.success(city))
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager else { return }
        finish(.failure(RadioError.message("Couldn’t determine your location. Check Location Services or choose a city in Your mix → Weather.")))
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<MoodCity, Error>) {
        token = UUID(); timeout?.cancel(); timeout = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil; manager = nil
        geocoder.cancelGeocode(); geocoding = false; authorizationRequested = false; locationRequested = false
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}
