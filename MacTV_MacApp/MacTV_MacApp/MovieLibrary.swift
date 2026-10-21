import AppKit
import Observation

nonisolated struct LocalMovie: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
    var id: String { url.path }
    var info: MediaName {
        let components = (relativePath as NSString).pathComponents
        let section = components.first?.lowercased()
        let override: Bool? = section == "series" ? true : (section == "movies" ? false : nil)
        let context = override == true ? Array(components.dropFirst().dropLast()) : []
        return MediaName(url.deletingPathExtension().lastPathComponent, parent: url.deletingLastPathComponent().lastPathComponent,
                         seriesContext: context, kindOverride: override)
    }
    var title: String { info.title }
    var format: String { url.pathExtension.uppercased() }
}

nonisolated struct MediaName: Equatable, Sendable {
    let title: String
    let year: String?
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    private let kindOverride: Bool?
    var isSeries: Bool { kindOverride ?? (season != nil || episode != nil) }
    init(_ filename: String, parent: String = "", seriesContext: [String] = [], kindOverride: Bool? = nil) {
        self.kindOverride = kindOverride
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()")))
        }
        func yearRange(in value: String) -> Range<String.Index>? {
            let regex = try! NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#)
            return regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .filter { $0.range.location > 0 }.last.flatMap { Range($0.range, in: value) }
        }
        let stripped = filename.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        let pattern = #"(?i)\bS(\d{1,2})[ ._-]*E(\d{1,3})(?:[ ._-]*E\d{1,3})?\b|\b(\d{1,2})x(\d{2,3})\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(stripped.startIndex..., in: stripped)
        if let match = regex.firstMatch(in: stripped, range: range), let r = Range(match.range, in: stripped) {
            func number(_ group: Int) -> Int? { Range(match.range(at: group), in: stripped).flatMap { Int(stripped[$0]) } }
            season = number(1) ?? number(3); episode = number(2) ?? number(4)
            var name = clean(String(stripped[..<r.lowerBound]))
            if name.isEmpty { name = clean(seriesContext.first ?? parent) }
            let y = yearRange(in: name)
            year = y.map { String(name[$0]) }
            if let y { name = clean(String(name[..<y.lowerBound])) }
            title = name.isEmpty ? clean(filename) : name
            let tail = String(stripped[r.upperBound...])
            let end = tail.range(of: #"(?i)\b(?:2160p|1080p|720p|480p|WEBRip|WEB-DL|BluRay|HDTV|x26[45]|HEVC|10bit|DDP)"#, options: .regularExpression)?.lowerBound ?? tail.endIndex
            let subtitle = clean(String(tail[..<end]))
            episodeTitle = subtitle.isEmpty ? nil : subtitle
        } else {
            // Also recognise numbered episode files inside an explicitly named Season folder.
            let ep = stripped.range(of: #"(?i)^episode[ ._-]*(\d+)"#, options: .regularExpression)
            let seasonMatch = parent.range(of: #"(?i)season[ ._-]*(\d+)"#, options: .regularExpression)
            season = seasonMatch.flatMap { Int(parent[$0].filter(\.isNumber)) } ?? seriesContext.reversed().compactMap { component -> Int? in
                guard let range = component.range(of: #"(?i)season[ ._-]*\d+"#, options: .regularExpression) else { return nil }
                return Int(component[range].filter(\.isNumber))
            }.first
            episode = ep.flatMap { Int(stripped[$0].filter(\.isNumber)) } ?? (kindOverride == true ? stripped.range(of: #"^\d{1,3}\b"#, options: .regularExpression).flatMap { Int(stripped[$0]) } : nil)
            if kindOverride == true {
                let subtitle = clean(stripped.replacingOccurrences(of: #"(?i)^(?:episode[ ._-]*)?\d{1,3}[ ._-]*"#, with: "", options: .regularExpression))
                episodeTitle = subtitle.isEmpty ? nil : subtitle
            } else { episodeTitle = nil }
            let y = yearRange(in: stripped)
            year = y.map { String(stripped[$0]) }
            let cutoff = y?.lowerBound ?? stripped.range(of: #"(?i)\b(?:2160p|1080p|720p|480p|WEBRip|WEB-DL|BluRay|x26[45]|HEVC)\b"#, options: .regularExpression)?.lowerBound ?? stripped.endIndex
            let name = clean(String(stripped[..<cutoff]))
            if kindOverride == true, let folder = seriesContext.first {
                title = MediaName(folder).title
            } else { title = name.isEmpty ? clean(filename) : name }
        }
    }
}

nonisolated struct MediaCollection: Identifiable, Equatable, Sendable {
    let title: String
    let year: String?
    let isSeries: Bool
    let files: [LocalMovie]
    var id: String { "\(isSeries ? "series" : "movie")|\(title.lowercased())|\(year ?? "")" }
    var seasons: [Int] { Array(Set(files.map { $0.info.season ?? 1 })).sorted() }
    var localPoster: URL? {
        guard let first = files.first else { return nil }
        let folder = first.url.deletingLastPathComponent()
        var candidates = [first.url.deletingPathExtension().appendingPathExtension("jpg"), first.url.deletingPathExtension().appendingPathExtension("png")]
        // Generic posters belong to this title's folder, never the mixed library root.
        if first.relativePath.contains("/") {
            candidates += ["poster.jpg", "poster.png", "folder.jpg", "cover.jpg"].map { folder.appendingPathComponent($0) }
            if isSeries { candidates += ["poster.jpg", "folder.jpg"].map { folder.deletingLastPathComponent().appendingPathComponent($0) } }
        }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }
}

@MainActor @Observable
final class MovieLibrary {
    nonisolated static let extensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "mpeg", "mpg", "wmv", "ts", "m2ts", "mts", "ogv", "flv"]
    private(set) var folder: URL
    private(set) var movies: [LocalMovie] = []
    private(set) var isScanning = false
    private(set) var notice: String?
    var query = "" { didSet { selection = 0 } }
    enum Section: String, CaseIterable { case movies = "Movies", series = "Series" }
    var section: Section = .movies { didSet { collection = nil; selection = 0 } }
    var collection: MediaCollection? { didSet { selection = 0; seasonFocused = false; selectedSeason = collection?.seasons.first ?? 1 } }
    var seasonFocused = false
    var selectedSeason = 1 { didSet { selection = 0 } }
    var selection = 0
    var columns: Int { collection == nil ? 5 : 1 }
    var titles: [MediaCollection] {
        Self.group(filtered).filter { $0.isSeries == (section == .series) }
    }
    var episodes: [LocalMovie] { collection?.files.filter { ($0.info.season ?? 1) == selectedSeason } ?? [] }
    var selectedTitle: MediaCollection? { titles.indices.contains(selection) ? titles[selection] : nil }
    var selectedEpisode: LocalMovie? { episodes.indices.contains(selection) ? episodes[selection] : nil }
    var itemCount: Int { collection == nil ? titles.count : (collection?.isSeries == true ? episodes.count : 1) }
    nonisolated static func group(_ movies: [LocalMovie]) -> [MediaCollection] {
        let groups = Dictionary(grouping: movies) { movie in
            let info = movie.info
            return "\(info.isSeries ? "series" : "movie")|\(info.title.lowercased())|\(info.isSeries ? "" : info.year ?? "")"
        }
        return groups.values.map { files in
            let sorted = files.sorted {
                let a = $0.info, b = $1.info
                if a.season != b.season { return (a.season ?? 1) < (b.season ?? 1) }
                if a.episode != b.episode { return (a.episode ?? 0) < (b.episode ?? 0) }
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            let info = sorted[0].info
            return MediaCollection(title: info.title, year: info.year, isSeries: info.isSeries, files: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scoped = false
    init(folder: URL? = nil) {
        var stale = false
        if let folder { self.folder = folder }
        else if let data = UserDefaults.standard.data(forKey: "movieFolderBookmark.v1"),
                let restored = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            self.folder = restored
            scoped = restored.startAccessingSecurityScopedResource()
        } else {
            self.folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Movies", isDirectory: true)
        }
    }
    var filtered: [LocalMovie] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? movies : movies.filter { $0.relativePath.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var selected: LocalMovie? { filtered.indices.contains(selection) ? filtered[selection] : nil }
    func chooseFolder(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Choose your Movies folder"; panel.prompt = "Use folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.use(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func use(_ folder: URL) {
        if scoped { self.folder.stopAccessingSecurityScopedResource() }
        self.folder = folder; scoped = folder.startAccessingSecurityScopedResource()
        if let bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "movieFolderBookmark.v1")
        }
        query = ""; collection = nil; movies = []; refresh()
    }
    func refresh() {
        scan?.cancel(); generation += 1
        let current = generation, root = folder
        isScanning = true; notice = nil
        scan = Task {
            let result = await Task.detached(priority: .utility) { Self.scan(root) }.value
            guard !Task.isCancelled, current == generation else { return }
            movies = result.movies; notice = result.error; isScanning = false
            selection = min(selection, max(0, filtered.count - 1))
        }
    }
    nonisolated static func scan(_ folder: URL) -> (movies: [LocalMovie], error: String?) {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ([], "The Movies folder was not found. Choose a folder to add your videos.")
        }
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            return ([], "Allow MacTV to read Downloads in System Settings → Privacy & Security → Files and Folders, or choose the folder again.")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var readError = false
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in readError = true; return true }) else {
            return ([], "MacTV could not read this folder. Choose it again to grant access.")
        }
        var movies: [LocalMovie] = []
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            let relative = url.pathComponents.suffix(max(1, entries.level)).joined(separator: "/")
            movies.append(LocalMovie(url: url, relativePath: relative, size: Int64(values.fileSize ?? 0)))
        }
        movies.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return (movies, readError ? "Some subfolders could not be read. Choose the folder again to grant access." : nil)
    }
}
