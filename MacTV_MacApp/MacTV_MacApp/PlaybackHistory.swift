import Foundation
import Observation

/// Device-local history; no metadata requests and no credentials or video contents stored.
@MainActor @Observable
final class PlaybackHistory {
    struct Entry: Codable { let seconds: Double; let duration: Double; let updated: Date; let completed: Bool }
    private let defaults: UserDefaults
    private(set) var entries: [String: Entry]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "playbackHistory.v1").flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    // Stable across moves between library subfolders; include size to distinguish different encodes.
    func key(_ movie: LocalMovie) -> String { "\(movie.url.lastPathComponent.lowercased())|\(movie.size)" }
    func position(_ movie: LocalMovie) -> Double {
        guard let entry = entries[key(movie)], !entry.completed, entry.seconds >= 5 else { return 0 }
        return entry.seconds
    }
    func save(_ movie: LocalMovie, seconds: Double, duration: Double, completed: Bool = false) {
        guard seconds.isFinite, duration.isFinite, duration > 0, seconds >= 0 else { return }
        entries[key(movie)] = Entry(seconds: completed ? 0 : seconds, duration: duration, updated: .now, completed: completed)
        // Bound history and write only at checkpoints / explicit playback actions.
        if entries.count > 2000 { entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.updated > $1.value.updated }.prefix(2000).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "playbackHistory.v1") }
    }
    func restart(_ movie: LocalMovie) { entries.removeValue(forKey: key(movie)); if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "playbackHistory.v1") } }
    func continuing(_ movies: [LocalMovie]) -> [LocalMovie] {
        let ordered = movies.filter { position($0) > 0 }.sorted {
            (entries[key($0)]?.updated ?? .distantPast) > (entries[key($1)]?.updated ?? .distantPast)
        }
        var seen = Set<String>()
        return ordered.filter { movie in
            let info = movie.info
            let group = info.isSeries ? "series|\(info.title.lowercased())" : key(movie)
            return seen.insert(group).inserted
        }
    }
    func isCompleted(_ movie: LocalMovie) -> Bool { entries[key(movie)]?.completed == true }
    func label(_ movie: LocalMovie) -> String {
        let seconds = Int(position(movie))
        return seconds > 0 ? String(format: "Resume at %d:%02d", seconds / 60, seconds % 60) : "Play fullscreen"
    }
}
