import Foundation
import Observation
import Security
import CryptoKit
import SwiftUI

nonisolated struct MovieMetadata: Codable, Identifiable, Sendable {
    let Title: String
    let Year: String
    let imdbID: String
    let Poster: String?
    let Plot: String?
    let Genre: String?
    let Runtime: String?
    let imdbRating: String?
    let `Type`: String?
    var id: String { imdbID }
    var posterURL: URL? {
        guard var parts = URLComponents(string: Poster ?? ""),
              ["m.media-amazon.com", "ia.media-imdb.com"].contains(parts.host?.lowercased() ?? "") else { return nil }
        parts.scheme = "https"; return parts.url
    }
    var imdbURL: URL? { imdbID.range(of: #"^tt[0-9]+$"#, options: .regularExpression) != nil ? URL(string: "https://www.imdb.com/title/\(imdbID)/") : nil }
    static func meaningful(_ value: String?) -> String? { guard let value, value != "N/A", !value.isEmpty else { return nil }; return value }
}

@MainActor @Observable final class MovieMetadataStore {
    private(set) var records: [String: MovieMetadata] = [:]
    private(set) var enabled = false
    private(set) var status = "Connect OMDb for posters, plots and IMDb ratings."
    private(set) var busy = false
    private(set) var revision = 0
    private(set) var requestsToday = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var quotaDay = ""
    private static func day(_ date: Date = .now) -> String { String(ISO8601DateFormatter().string(from: date).prefix(10)) }
    func retryMissing() { attempted = []; retryAfter = [:]; persist(); revision += 1 }
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var attempted = Set<String>()
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    private static let account: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "MacTV.OMDb.v1", kSecAttrAccount as String: "api-key"]
    init(defaults: UserDefaults = .standard, testKey: String? = nil,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.defaults = defaults; self.transport = transport
        if let testKey { key = testKey; enabled = !key.isEmpty }
        var result: CFTypeRef?
        var query = Self.account; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if testKey == nil, SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            key = String(data: data, encoding: .utf8) ?? ""; enabled = !key.isEmpty
        }
        if let data = defaults.data(forKey: "movieMetadata.v1"), let cached = try? JSONDecoder().decode([String: MovieMetadata].self, from: data) { records = cached }
        if let data = defaults.data(forKey: "movieMetadata.retry.v1"), let dates = try? JSONDecoder().decode([String: Date].self, from: data) { retryAfter = dates }
        quotaDay = defaults.string(forKey: "omdbQuotaDay.v1") ?? Self.day()
        requestsToday = quotaDay == Self.day() ? defaults.integer(forKey: "omdbQuotaCount.v1") : 0
        if enabled { status = "OMDb connected · \(records.count) saved titles" }
    }
    @discardableResult func saveKey(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 256 else { status = "Enter your OMDb API key."; return false }
        let data = Data(candidate.utf8)
        var query = Self.account
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { status = "Could not save the key in Keychain. Try again."; return false }
        key = candidate; enabled = true; retryMissing(); status = "OMDb connected · fetching matching titles"; return true
    }
    func disconnect() {
        let result = SecItemDelete(Self.account as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { status = "Could not remove the key from Keychain."; return }
        key = ""; enabled = false; revision += 1; status = "OMDb disconnected. Saved artwork and details remain available."
    }
    func clear(_ title: MediaCollection) { records.removeValue(forKey: title.id); attempted.insert(title.id); retryAfter[title.id] = .distantFuture; persist() }
    func match(_ title: MediaCollection, metadata: MovieMetadata) { records[title.id] = metadata; retryAfter.removeValue(forKey: title.id); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "movieMetadata.v1") }
        if let data = try? JSONEncoder().encode(retryAfter) { defaults.set(data, forKey: "movieMetadata.retry.v1") }
    }
    private func fetch(_ parameters: [URLQueryItem]) async throws -> Data {
        guard enabled else { throw MetadataError.message("Connect your OMDb key first.") }
        let today = Self.day()
        if quotaDay != today { quotaDay = today; requestsToday = 0 }
        guard requestsToday < 900 else { throw MetadataError.message("MacTV's 900-request daily safety limit has been reached. Saved details still work.") }
        requestsToday += 1
        defaults.set(today, forKey: "omdbQuotaDay.v1"); defaults.set(requestsToday, forKey: "omdbQuotaCount.v1")
        var url = URLComponents(string: "https://www.omdbapi.com/")!
        url.queryItems = [URLQueryItem(name: "apikey", value: key)] + parameters
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        let (data, response): (Data, URLResponse)
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else { throw MetadataError.message("OMDb is unavailable. Try again later.") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["Response"] as? String == "False" {
            // Return only the server's API message, never a URL containing the key.
            throw MetadataError.message((json?["Error"] as? String) ?? "No matching title found.")
        }
        return data
    }
    func enrich(_ titles: [MediaCollection]) async {
        guard enabled else { return }; let generation = revision; busy = true; defer { if generation == revision { busy = false } }
        var problem: String?
        for title in titles where records[title.id] == nil && !attempted.contains(title.id) && (retryAfter[title.id] ?? .distantPast) <= .now {
            guard !Task.isCancelled, enabled, generation == revision else { return }; attempted.insert(title.id)
            var parameters = [URLQueryItem(name: "t", value: title.title), URLQueryItem(name: "type", value: title.isSeries ? "series" : "movie"), URLQueryItem(name: "plot", value: "full")]
            if let year = title.year { parameters.append(URLQueryItem(name: "y", value: year)) }
            do {
                let detail = try JSONDecoder().decode(MovieMetadata.self, from: await fetch(parameters))
                guard !Task.isCancelled, generation == revision else { return }
                if Self.exactMatch(title, detail) { match(title, metadata: detail) }
                else { retryAfter[title.id] = .now.addingTimeInterval(30 * 86400); persist() }
            } catch let error as MetadataError {
                guard !Task.isCancelled, generation == revision else { return }
                problem = error.localizedDescription
                retryAfter[title.id] = .now.addingTimeInterval(problem!.localizedCaseInsensitiveContains("not found") ? 30 * 86400 : 900)
                persist()
                if problem!.localizedCaseInsensitiveContains("key") || problem!.localizedCaseInsensitiveContains("limit") { break }
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                problem = "Could not reach OMDb. Your videos still work offline."
                retryAfter[title.id] = .now.addingTimeInterval(900); persist(); break
            }
        }
        status = problem ?? "\(records.count) saved titles · Details and artwork via OMDb"
    }
    nonisolated static func exactMatch(_ title: MediaCollection, _ metadata: MovieMetadata) -> Bool {
        func normalized(_ string: String) -> String { string.lowercased().filter { $0.isLetter || $0.isNumber } }
        return normalized(title.title) == normalized(metadata.Title) &&
            (title.year == nil || metadata.Year.hasPrefix(title.year!)) &&
            metadata.Type == (title.isSeries ? "series" : "movie")
    }
    func search(_ query: String, series: Bool) async throws -> [MovieMetadata] {
        struct Results: Decodable { let Search: [MovieMetadata] }
        return try JSONDecoder().decode(Results.self, from: await fetch([URLQueryItem(name: "s", value: query), URLQueryItem(name: "type", value: series ? "series" : "movie")])).Search
    }
    func choose(_ result: MovieMetadata, for title: MediaCollection) async throws {
        let detail = try JSONDecoder().decode(MovieMetadata.self, from: await fetch([URLQueryItem(name: "i", value: result.imdbID), URLQueryItem(name: "plot", value: "full")]))
        match(title, metadata: detail)
    }
    enum MetadataError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let message) = self { return message }; return nil } }
}



struct MetadataConnectionView: View {
    let store: MovieMetadataStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Movie artwork & details").font(.title2.bold())
            Text("Connect OMDb to look up titles, posters, plots and IMDb ratings. Only cleaned titles and years are sent to OMDb; your files stay on this Mac.").foregroundStyle(.secondary)
            SecureField("OMDb API key", text: $key).textFieldStyle(.roundedBorder)
            Text("The key is stored in macOS Keychain. Details and posters stay on this Mac and are reused offline.").font(.caption).foregroundStyle(.secondary)
            Text(store.status).font(.callout)
            Text("\(store.records.count) saved titles · \(store.requestsToday) requests today from MacTV. MacTV stops at 900/day; other apps using this key count separately.").font(.caption).foregroundStyle(.secondary)
            if store.enabled { Button("Retry missing details") { store.retryMissing(); dismiss() } }

            Link("Get or manage an OMDb key", destination: URL(string: "https://www.omdbapi.com/apikey.aspx")!)
            HStack {
                if store.enabled { Button("Disconnect") { store.disconnect() } }
                Spacer(); Button("Cancel") { dismiss() }
                Button("Connect") { if store.saveKey(key) { key = ""; dismiss() } }.buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 480)
    }
}

struct MetadataMatchView: View {
    let store: MovieMetadataStore
    let title: MediaCollection
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MovieMetadata] = []
    @State private var message = ""
    @State private var searching = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Match \(title.title)").font(.title2.bold())
            HStack { TextField("Search OMDb", text: $query).onSubmit { search() }; Button("Search") { search() }.disabled(searching) }
            if searching { ProgressView() }
            Text(message).foregroundStyle(.secondary)
            List(results) { result in
                Button { searching = true; Task { do { try await store.choose(result, for: title); dismiss() } catch { message = "Could not load this match. Try again." }; searching = false } } label: {
                    HStack { Text(result.Title).bold(); Spacer(); Text(result.Year); Text(result.imdbID).foregroundStyle(.secondary) }
                }.disabled(searching)
            }.frame(height: 280)
            HStack { Button("Remove saved match") { store.clear(title); dismiss() }; Spacer(); Button("Done") { dismiss() } }
        }.padding(28).frame(width: 600).onAppear { query = title.title; search() }
    }
    private func search() {
        searching = true; message = ""
        Task { do { results = try await store.search(query, series: title.isSeries) }
            catch let error as MovieMetadataStore.MetadataError { results = []; message = error.localizedDescription }
            catch { results = []; message = "Could not reach OMDb. Try again." }; searching = false }
    }
}

/// Posters are durable application data, independent of URLSession's evictable HTTP cache.
nonisolated enum MoviePosterCache {
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacTV/Posters", isDirectory: true) }
    static func file(for url: URL, directory: URL) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()).appendingPathExtension("image")
    }
    static func load(_ url: URL, directory: URL? = nil,
                     download: (@Sendable (URL) async throws -> Data)? = nil) async -> Data? {
        let root = directory ?? self.directory, path = file(for: url, directory: directory ?? self.directory)
        if let cached = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: path) }).value, !cached.isEmpty { return cached }
        guard !Task.isCancelled else { return nil }
        do {
            let data: Data
            if let download { data = try await download(url) }
            else {
                var request = URLRequest(url: url); request.timeoutInterval = 20
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType?.hasPrefix("image/") == true else { return nil }
                data = bytes
            }
            guard !data.isEmpty, data.count <= 8_000_000, !Task.isCancelled else { return nil }
            await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: path, options: .atomic)
                } catch { /* Offline display can still use the in-memory image if storage is unavailable. */ }
            }.value
            return data
        } catch { return nil }
    }
}
