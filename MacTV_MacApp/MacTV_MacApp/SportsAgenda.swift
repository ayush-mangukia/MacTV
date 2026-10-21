import Foundation
import Observation

nonisolated struct SportsEvent: Codable, Equatable, Identifiable, Sendable {
    enum Sport: String, Codable, Sendable { case football, f1 }
    let id: String
    let sport: Sport
    let title: String
    let competition: String
    let start: Date
    let state: String
    let detail: String
    let teamIDs: [String]
    let score: String?
    let timeConfirmed: Bool
    var favorite: Bool { sport == .f1 || teamIDs.contains("126") || teamIDs.contains("367") }
    var live: Bool { state == "in" }
    var scheduled: Bool { state == "pre" && timeConfirmed }
    var berlinTime: String {
        let format = DateFormatter(); format.timeZone = TimeZone(identifier: "Europe/Berlin"); format.dateFormat = "EEE d MMM · HH:mm"
        return format.string(from: start)
    }
}

/// Decode only public display fields. Provider links and executable/HTML content are ignored.
nonisolated enum SportsFeedParser {
    static func football(_ data: Data, competition: String) throws -> [SportsEvent] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let entries = root?["events"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return entries.compactMap { event in
            guard let id = event["id"] as? String, let rawDate = event["date"] as? String, let date = date(rawDate),
                  let game = (event["competitions"] as? [[String: Any]])?.first,
                  let teams = game["competitors"] as? [[String: Any]], teams.count == 2 else { return nil }
            let ordered = teams.sorted { ($0["homeAway"] as? String == "home" ? 0 : 1) < ($1["homeAway"] as? String == "home" ? 0 : 1) }
            let names = ordered.compactMap { ($0["team"] as? [String: Any])?["displayName"] as? String }
            guard names.count == 2 else { return nil }
            let status = event["status"] as? [String: Any] ?? game["status"] as? [String: Any] ?? [:]
            let type = status["type"] as? [String: Any] ?? [:]
            let stateName = type["name"] as? String ?? ""
            let state = ["STATUS_POSTPONED", "STATUS_CANCELED", "STATUS_DELAYED", "STATUS_SUSPENDED"].contains(stateName) ? "unavailable" : type["state"] as? String ?? "unknown"
            let scores = ordered.compactMap { player -> String? in
                if let value = player["score"] as? String { return value }
                return (player["score"] as? [String: Any])?["displayValue"] as? String
            }
            return SportsEvent(id: "football-" + id, sport: .football, title: names.joined(separator: " vs "), competition: competition, start: date, state: state,
                detail: type["shortDetail"] as? String ?? type["description"] as? String ?? "", teamIDs: ordered.compactMap { ($0["team"] as? [String: Any])?["id"] as? String },
                score: state == "in" && scores.count == 2 ? scores.joined(separator: " – ") : nil,
                timeConfirmed: (game["timeValid"] as? Bool ?? true) && state == "pre" && stateName != "STATUS_TBD")
        }
    }
    static func races(_ data: Data) throws -> [SportsEvent] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let table = (root?["MRData"] as? [String: Any])?["RaceTable"] as? [String: Any], let races = table["Races"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return races.compactMap { race in
            guard let season = race["season"] as? String, let round = race["round"] as? String, let title = race["raceName"] as? String,
                  let day = race["date"] as? String, let time = race["time"] as? String, let start = date(day + "T" + time) else { return nil }
            return SportsEvent(id: "f1-\(season)-\(round)", sport: .f1, title: title, competition: "Formula 1 · Race", start: start, state: "pre", detail: "Scheduled start", teamIDs: [], score: nil, timeConfirmed: true)
        }
    }
    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let short = DateFormatter(); short.locale = Locale(identifier: "en_US_POSIX"); short.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return short.date(from: string)
    }
}

@MainActor @Observable final class SportsAgenda {
    struct Feed: Codable {
        let events: [SportsEvent]
        let updated: Date
    }
    private struct Source: Sendable {
        let key: String
        let address: String
        let label: String
        let interval: TimeInterval
        var races: Bool { key == "f1" }
    }
    private static let sources: [Source] = [
        .init(key: "freiburg", address: "https://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/teams/126/schedule?fixture=true", label: "SC Freiburg", interval: 900),
        .init(key: "spurs", address: "https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/teams/367/schedule?fixture=true", label: "Tottenham Hotspur", interval: 900),
        .init(key: "bundesliga-live", address: "https://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/scoreboard", label: "Bundesliga", interval: 60),
        .init(key: "premier-live", address: "https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard", label: "Premier League", interval: 60),
        .init(key: "champions", address: "https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard", label: "Champions League", interval: 60),
        .init(key: "f1", address: "https://api.jolpi.ca/ergast/f1/current/races.json?limit=100", label: "Formula 1", interval: 21600)
    ]
    var feeds: [String: Feed] = [:]
    var busy = false
    var notice: String?
    var showingPreferences = false
    var followFreiburg: Bool { didSet { savePreferences() } }
    var followSpurs: Bool { didSet { savePreferences() } }
    var followChampions: Bool { didSet { savePreferences() } }
    var followF1: Bool { didSet { savePreferences() } }
    var leadMinutes: Int { didSet { savePreferences() } }
    var pinned: Set<String> { didSet { savePreferences() } }
    let reminders = SportsReminders()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var attempts: [String: Date] = [:]
    @ObservationIgnored private var loadErrors: Set<String> = []
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        followFreiburg = defaults.object(forKey: "sports.freiburg") as? Bool ?? true
        followSpurs = defaults.object(forKey: "sports.spurs") as? Bool ?? true
        followChampions = defaults.object(forKey: "sports.champions") as? Bool ?? true
        followF1 = defaults.object(forKey: "sports.f1") as? Bool ?? true
        leadMinutes = [10, 15, 30].contains(defaults.integer(forKey: "sports.lead")) ? defaults.integer(forKey: "sports.lead") : 15
        pinned = Set(defaults.stringArray(forKey: "sports.pinned") ?? [])
        if let data = defaults.data(forKey: "sports.feeds.v1"), let saved = try? JSONDecoder().decode([String: Feed].self, from: data) {
            feeds = saved.filter { Date().timeIntervalSince($0.value.updated) < 86400 }
        }
        reminders.enabled = defaults.object(forKey: "sports.reminders.inApp") as? Bool ?? true
    }
    func follows(_ event: SportsEvent) -> Bool {
        if event.sport == .f1 { return followF1 }
        if event.teamIDs.contains("126") && followFreiburg { return true }
        if event.teamIDs.contains("367") && followSpurs { return true }
        return followChampions && event.competition == "Champions League"
    }
    func automaticReminder(_ event: SportsEvent) -> Bool {
        event.sport == .f1 ? followF1 : ((event.teamIDs.contains("126") && followFreiburg) || (event.teamIDs.contains("367") && followSpurs))
    }
    func events(now: Date = .now) -> [SportsEvent] {
        var merged: [String: SportsEvent] = [:]
        // Oldest first: live scoreboards supersede a cached fixture with the same event ID.
        let ordered = feeds.sorted { left, right in
            let leftLive = left.key.contains("-live") || left.key == "champions"
            let rightLive = right.key.contains("-live") || right.key == "champions"
            if leftLive != rightLive { return !leftLive }
            return left.value.updated < right.value.updated
        }
        for (_, feed) in ordered where now.timeIntervalSince(feed.updated) < 86400 {
            for event in feed.events where follows(event) || pinned.contains(event.id) { merged[event.id] = event }
        }
        return merged.values.sorted { $0.start < $1.start }
    }
    func live(now: Date = .now) -> [SportsEvent] {
        let freshIDs = Set(feeds.values.filter { now.timeIntervalSince($0.updated) <= 180 }.flatMap { $0.events.filter(\.live).map(\.id) })
        return events(now: now).filter { $0.live && freshIDs.contains($0.id) }
    }
    func upcoming(now: Date = .now) -> [SportsEvent] {
        events(now: now).filter { $0.state == "pre" && $0.start > now }
    }
    func highlights(now: Date = .now) -> [SportsEvent] {
        let next = upcoming(now: now)
        var selection: [SportsEvent] = []
        for club in ["126", "367"] { if let event = next.first(where: { $0.teamIDs.contains(club) }) { selection.append(event) } }
        if let race = next.first(where: { $0.sport == .f1 }) { selection.append(race) }
        // Prioritise fixtures involving established featured clubs, especially when
        // both opponents are in this set. Users can pin individual matches separately.
        let featuredClubs: Set<String> = ["86", "132", "359", "110", "360"] // Real Madrid, Bayern, Arsenal, Inter, Man United
        let champions = next.filter { $0.competition == "Champions League" }.sorted { left, right in
            let a = left.teamIDs.filter { featuredClubs.contains($0) }.count
            let b = right.teamIDs.filter { featuredClubs.contains($0) }.count
            if a != b { return a > b }
            if left.start != right.start { return left.start < right.start }
            return left.id < right.id
        }
        selection += champions.prefix(3)
        var seen: Set<String> = []
        return selection.filter { seen.insert($0.id).inserted }
    }
    func toggleReminder(_ event: SportsEvent) {
        if automaticReminder(event) { return }
        if pinned.contains(event.id) { pinned.remove(event.id) } else { pinned.insert(event.id) }
    }
    func enableReminders() async {
        reminders.enabled = true
        defaults.set(true, forKey: "sports.reminders.inApp")
        await syncReminders()
    }
    func disableReminders() async {
        reminders.enabled = false; defaults.set(false, forKey: "sports.reminders.inApp")
        await reminders.replace([], lead: leadMinutes)
    }
    func syncReminders() async {
        guard reminders.enabled else { return }
        await reminders.replace(events().filter { automaticReminder($0) || pinned.contains($0.id) }, lead: leadMinutes)
    }
    private func savePreferences() {
        defaults.set(followFreiburg, forKey: "sports.freiburg"); defaults.set(followSpurs, forKey: "sports.spurs")
        defaults.set(followChampions, forKey: "sports.champions"); defaults.set(followF1, forKey: "sports.f1")
        defaults.set(leadMinutes, forKey: "sports.lead"); defaults.set(Array(pinned), forKey: "sports.pinned")
        Task { await syncReminders() }
    }
    private static func fetch(_ source: Source) async -> (String, [SportsEvent]?) {
        do {
            var request = URLRequest(url: URL(string: source.address)!); request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 3_000_000 else { return (source.key, nil) }
            return (source.key, try source.races ? SportsFeedParser.races(data) : SportsFeedParser.football(data, competition: source.label))
        } catch { return (source.key, nil) }
    }
    func refresh(force: Bool = false) async {
        guard !busy else { return }
        let now = Date()
        let due = Self.sources.filter { source in
            let last = attempts[source.key] ?? feeds[source.key]?.updated ?? .distantPast
            return now.timeIntervalSince(last) >= (force ? 15 : source.interval)
        }
        guard !due.isEmpty else { return }
        busy = true; defer { busy = false }
        for source in due { attempts[source.key] = now }
        await withTaskGroup(of: (String, [SportsEvent]?).self) { group in
            for source in due { group.addTask { await Self.fetch(source) } }
            for await (key, events) in group {
                if let events { feeds[key] = Feed(events: events, updated: .now); loadErrors.remove(key) }
                else { loadErrors.insert(key) }
            }
        }
        notice = loadErrors.isEmpty ? nil : "Some schedules are unavailable · showing the last saved fixtures"
        if let data = try? JSONEncoder().encode(feeds) { defaults.set(data, forKey: "sports.feeds.v1") }
        await syncReminders()
    }
    func observe() async {
        await syncReminders()
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
