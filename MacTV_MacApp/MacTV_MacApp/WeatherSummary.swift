import Foundation
import Observation
import SwiftUI

nonisolated struct WeatherForecast: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        let time: Double
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let is_day: Int
        let precipitation: Double
        let wind_speed_10m: Double
    }
    struct Daily: Codable, Equatable, Sendable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
    }
    struct Hourly: Codable, Equatable, Sendable {
        let time: [Double]
        let precipitation_probability: [Int?]
        let precipitation: [Double?]
        var temperature_2m: [Double?]? = nil
        var weather_code: [Int?]? = nil
        var is_day: [Int?]? = nil
    }
    let current: Current
    let daily: Daily
    let hourly: Hourly
    struct Hour: Identifiable {
        let date: Date
        let temperature: Double
        let code: Int
        let day: Bool
        let chance: Int?
        var id: Date { date }
        var label: String {
            let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }
    func nextHours(now: Date = .now) -> [Hour] {
        guard let temperatures = hourly.temperature_2m, let codes = hourly.weather_code else { return [] }
        return Array(hourly.time.indices.compactMap { i -> Hour? in
            guard hourly.time[i] > now.timeIntervalSince1970, temperatures.indices.contains(i), codes.indices.contains(i),
                  let temperature = temperatures[i], temperature.isFinite, let code = codes[i] else { return nil }
            let day = hourly.is_day.flatMap { $0.indices.contains(i) ? $0[i] : nil } == 1
            let chance = hourly.precipitation_probability.indices.contains(i) ? hourly.precipitation_probability[i] : nil
            return Hour(date: Date(timeIntervalSince1970: hourly.time[i]), temperature: temperature, code: code, day: day, chance: chance)
        }.prefix(6))
    }
    func outlook(now: Date = .now) -> String {
        let times = hourly.time.indices.filter { hourly.time[$0] > now.timeIntervalSince1970 && hourly.time[$0] <= now.addingTimeInterval(6 * 3600).timeIntervalSince1970 }
        if current.precipitation > 0.1 {
            return [71, 73, 75, 77, 85, 86].contains(current.weather_code) ? "Snow at the moment." : "Wet weather at the moment."
        }
        var usable = 0
        for i in times {
            guard hourly.precipitation_probability.indices.contains(i), hourly.precipitation.indices.contains(i) else { continue }
            guard hourly.precipitation_probability[i] != nil || hourly.precipitation[i] != nil else { continue }
            usable += 1
            let chance = hourly.precipitation_probability[i] ?? 0
            if chance >= 50 || (hourly.precipitation[i] ?? 0) >= 0.3 {
                let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "HH:mm"
                return "Rain possible around \(formatter.string(from: Date(timeIntervalSince1970: hourly.time[i])))\(chance > 0 ? " · \(chance)% chance" : "")."
            }
        }
        if current.wind_speed_10m >= 35 { return "Breezy outside · wind \(Int(current.wind_speed_10m.rounded())) km/h." }
        return usable == 0 ? "Short-term outlook unavailable." : "Low rain risk over the next 6 hours."
    }
    static func condition(_ code: Int, day: Bool) -> (String, String) {
        switch code {
        case 0: return (day ? "Clear skies" : "Clear night", day ? "sun.max.fill" : "moon.stars.fill")
        case 1, 2: return ("Partly cloudy", day ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Foggy", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57, 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 61, 63, 65, 80, 81, 82: return ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77, 85, 86: return ("Snow", "cloud.snow.fill")
        case 95, 96, 99: return ("Thunderstorms", "cloud.bolt.rain.fill")
        default: return ("Conditions unavailable", "cloud")
        }
    }
}

@MainActor @Observable final class WeatherSummary {
    static let city = "Freiburg im Breisgau"
    // Public city centre from Open-Meteo's geocoding service, not device location.
    static let endpoint = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=47.9959&longitude=7.85222&current=temperature_2m,apparent_temperature,weather_code,is_day,precipitation,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min&hourly=precipitation_probability,precipitation,temperature_2m,weather_code,is_day&timezone=Europe%2FBerlin&forecast_days=2&timeformat=unixtime")!
    var forecast: WeatherForecast?
    var fetchedAt: Date?
    var notice: String?
    var busy = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    nonisolated struct Cache: Codable { let forecast: WeatherForecast; let fetchedAt: Date }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "weather.freiburg.v2"), let cache = try? JSONDecoder().decode(Cache.self, from: data), Date().timeIntervalSince(cache.fetchedAt) < 6 * 3600,
           cache.forecast.daily.temperature_2m_max.first?.isFinite == true,
           cache.forecast.daily.temperature_2m_min.first?.isFinite == true {
            forecast = cache.forecast; fetchedAt = cache.fetchedAt
        }
    }
    func refresh(force: Bool = false) async {
        guard !busy else { return }
        let now = Date()
        guard force || lastAttempt.map({ now.timeIntervalSince($0) >= 900 }) ?? (fetchedAt.map { now.timeIntervalSince($0) >= 900 } ?? true) else { return }
        lastAttempt = now; busy = true
        defer { busy = false }
        do {
            var request = URLRequest(url: Self.endpoint); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 300_000 else { throw URLError(.badServerResponse) }
            let value = try JSONDecoder().decode(WeatherForecast.self, from: data)
            guard value.current.temperature_2m.isFinite, value.daily.temperature_2m_max.first?.isFinite == true,
                  value.daily.temperature_2m_min.first?.isFinite == true else { throw URLError(.cannotParseResponse) }
            forecast = value; fetchedAt = .now; notice = nil
            if let cached = try? JSONEncoder().encode(Cache(forecast: value, fetchedAt: fetchedAt!)) { defaults.set(cached, forKey: "weather.freiburg.v2") }
        } catch is CancellationError { return }
        catch { notice = forecast == nil ? "Weather unavailable · try again shortly" : "Offline · showing the last update" }
    }
    func observe() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}

struct WeatherSummaryCard: View {
    let weather: WeatherSummary
    var onRadar: () -> Void = {}
    var selected = false
    var selectedAction: Int?
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                Text(WeatherSummary.city).font(.system(size: compact ? 21 : 24, weight: .semibold)).lineLimit(2)
                if let forecast = weather.forecast {
                    let condition = WeatherForecast.condition(forecast.current.weather_code, day: forecast.current.is_day == 1)
                    let stale = weather.fetchedAt.map { timeline.date.timeIntervalSince($0) > 30 * 60 } ?? true
                    HStack(spacing: 12) {
                        Text("\(Int(forecast.current.temperature_2m.rounded()))°")
                            .font(.system(size: compact ? 60 : 76, weight: .light)).monospacedDigit()
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Image(systemName: condition.1).symbolRenderingMode(.multicolor).font(.system(size: 52))
                            Text(condition.0).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Text("Feels \(Int(forecast.current.apparent_temperature.rounded()))° · H \(Int(forecast.daily.temperature_2m_max[0].rounded()))°  L \(Int(forecast.daily.temperature_2m_min[0].rounded()))°")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(stale ? "Forecast needs an update." : forecast.outlook(now: timeline.date))
                        .font(.system(size: 14, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: compact ? 6 : 12)
                    VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                        Text("NEXT SIX HOURS").font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.6))
                        let hours = forecast.nextHours(now: timeline.date)
                        if hours.isEmpty { Text("Hourly forecast unavailable").font(.callout).foregroundStyle(.secondary) }
                        else {
                            HStack(spacing: 8) {
                                ForEach(hours) { hour in
                                    VStack(spacing: 8) {
                                        Text(hour.label).font(.system(size: 13, weight: .medium)).monospacedDigit()
                                        Image(systemName: WeatherForecast.condition(hour.code, day: hour.day).1)
                                            .symbolRenderingMode(.multicolor).font(.system(size: 25)).frame(height: 28)
                                        Text("\(Int(hour.temperature.rounded()))°").font(.system(size: 20, weight: .medium))
                                        Text(hour.chance.map { "\($0)%" } ?? "—").font(.system(size: 12)).foregroundStyle(.cyan)
                                    }.frame(maxWidth: .infinity).padding(.vertical, compact ? 8 : 10)
                                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
                    Spacer(minLength: compact ? 6 : 12)
                    HStack {
                    Text(weather.notice ?? (stale ? "Last updated \(weather.fetchedAt?.formatted(date: .omitted, time: .shortened) ?? "earlier")" : "Updated \(weather.fetchedAt?.formatted(date: .omitted, time: .shortened) ?? "now")"))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer(minLength: 8)
                        Link("Weather: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Spacer(minLength: 0)
                    if weather.busy { ProgressView("Checking the forecast…").font(.callout) }
                    else { Label(weather.notice ?? "Checking the forecast…", systemImage: "cloud").font(.callout) }
                    Spacer(minLength: 0)
                }
                HStack {
                    Button("Rain radar", action: onRadar)
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.white.opacity(selectedAction == 0 ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAction == 0 ? Color.mint : .clear, lineWidth: 2))
                    Spacer(minLength: 8)
                    Button { Task { await weather.refresh(force: true) } } label: { Label("Refresh weather", systemImage: "arrow.clockwise") }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.white.opacity(selectedAction == 1 ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedAction == 1 ? Color.mint : .clear, lineWidth: 2))
                        .help("Refresh weather").accessibilityLabel("Refresh weather").disabled(weather.busy)
                }
            }.padding(compact ? 16 : 20).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        }
        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.20, blue: 0.32), Color(red: 0.06, green: 0.09, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.mint : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
        .task { await weather.observe() }
    }
}
