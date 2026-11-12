import Foundation

struct MoodCity: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    static func approximate(name: String, latitude: Double, longitude: Double) -> MoodCity {
        // About 5 km resolution: weather needs an area, not a precise device coordinate.
        MoodCity(name: name, latitude: (latitude * 20).rounded() / 20, longitude: (longitude * 20).rounded() / 20)
    }
    var valid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

/// Optional area-level weather only. No precise device coordinates, listening data or station data is sent.
actor MoodWeather {
    enum Kind: String { case rain, snow, cloudy, clear }
    struct Conditions {
        var kind: Kind
        var observed: Date
        var label: String { kind == .rain ? "Rainy skies" : kind == .snow ? "Snowy skies" : kind == .cloudy ? "Cloudy skies" : "Clear skies" }
    }
    private var cached: (city: MoodCity, checked: Date, result: Conditions?)?
    static func kind(code: Int) -> Kind? {
        switch code {
        case 0, 1: return .clear
        case 2, 3, 45, 48: return .cloudy
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        default: return nil
        }
    }
    static func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(UserAgent.value + " (optional city weather)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 256_000 else { throw RadioError.message("Weather service unavailable") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func cities(matching name: String) async throws -> [MoodCity] {
        struct Result: Decodable {
            struct Place: Decodable { var name: String; var admin1: String?; var country: String?; var latitude: Double; var longitude: Double }
            var results: [Place]?
        }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: String(name.prefix(100))), URLQueryItem(name: "count", value: "8"), URLQueryItem(name: "language", value: "en")]
        let response = try await get(url.url!, as: Result.self)
        return (response.results ?? []).map { place in
            MoodCity(name: [place.name, place.admin1, place.country].compactMap { $0 }.joined(separator: ", "), latitude: place.latitude, longitude: place.longitude)
        }.filter(\.valid)
    }
    func current(for city: MoodCity, now: Date = Date()) async -> Conditions? {
        guard city.valid else { return nil }
        if let cached, cached.city == city, now.timeIntervalSince(cached.checked) >= 0, now.timeIntervalSince(cached.checked) < 900 { return cached.result }
        struct Forecast: Decodable {
            struct Current: Decodable { var time: Double; var weather_code: Int }
            var current: Current
        }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(city.latitude)), URLQueryItem(name: "longitude", value: String(city.longitude)), URLQueryItem(name: "current", value: "weather_code"), URLQueryItem(name: "timeformat", value: "unixtime"), URLQueryItem(name: "forecast_days", value: "1")]
        do {
            let response = try await Self.get(url.url!, as: Forecast.self)
            let observed = Date(timeIntervalSince1970: response.current.time)
            guard abs(now.timeIntervalSince(observed)) < 7200, let kind = Self.kind(code: response.current.weather_code) else {
                cached = (city, now, nil); return nil
            }
            let result = Conditions(kind: kind, observed: observed)
            cached = (city, now, result); return result
        } catch {
            if !Task.isCancelled { cached = (city, now, nil) }
            return nil
        }
    }
}
