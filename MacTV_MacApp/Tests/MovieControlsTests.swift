import AppKit
import SwiftUI
import Foundation

@MainActor final class FullscreenTestWindow: NSWindow {
    var fullscreenRequests = 0
    override func toggleFullScreen(_ sender: Any?) { fullscreenRequests += 1 }
}
@MainActor final class PointerClickTarget: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: Any?) { clicks += 1 }
}
actor RequestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

@MainActor @main struct MovieControlsTests {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure.check(message) } }
    static func wait(_ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw Failure.check(message)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("MacTV movie controls passed"); fflush(stdout); exit(0) }
            catch { fputs("MacTV movie controls failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        let playbackSuite = "MacTV.PlaybackTests." + UUID().uuidString
        let playbackDefaults = UserDefaults(suiteName: playbackSuite)!
        defer { playbackDefaults.removePersistentDomain(forName: playbackSuite) }
        let weatherNow = Date(timeIntervalSince1970: 1_800_000_000)
        let dry = WeatherForecast.Current(time: weatherNow.timeIntervalSince1970, temperature_2m: 13, apparent_temperature: 11, weather_code: 3, is_day: 1, precipitation: 0, wind_speed_10m: 10)
        let daily = WeatherForecast.Daily(temperature_2m_max: [16], temperature_2m_min: [8])
        let rain = WeatherForecast(current: dry, daily: daily, hourly: .init(time: [weatherNow.addingTimeInterval(3600).timeIntervalSince1970], precipitation_probability: [70], precipitation: [0.5]))
        try check(rain.outlook(now: weatherNow).contains("70% chance"), "Weather outlook missed approaching rain")
        let missingWeather = WeatherForecast(current: dry, daily: daily, hourly: .init(time: [weatherNow.addingTimeInterval(3600).timeIntervalSince1970], precipitation_probability: [nil], precipitation: [nil]))
        try check(missingWeather.outlook(now: weatherNow) == "Short-term outlook unavailable.", "Missing weather became a false dry forecast")
        let weatherCache = WeatherSummary.Cache(forecast: rain, fetchedAt: Date().addingTimeInterval(-7 * 3600))
        playbackDefaults.set(try JSONEncoder().encode(weatherCache), forKey: "weather.freiburg.v2")
        try check(WeatherSummary(defaults: playbackDefaults).forecast == nil, "Expired weather cache was reused")
        playbackDefaults.set(try JSONEncoder().encode(WeatherSummary.Cache(forecast: rain, fetchedAt: .now)), forKey: "weather.freiburg.v2")
        try check(WeatherSummary(defaults: playbackDefaults).forecast == rain, "Weather cache did not survive relaunch")
        let manifest = try JSONDecoder().decode(RadarManifest.self, from: Data(#"{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":100,"path":"/v2/radar/3ab83d5628ea"},{"time":101,"path":"/../../private"}]}}"#.utf8))
        try check(manifest.safeFrames.count == 1, "Radar must accept current hashed tile IDs and reject unexpected paths")
        let maliciousRadar = try JSONDecoder().decode(RadarManifest.self, from: Data(#"{"host":"http://127.0.0.1","radar":{"past":[{"time":100,"path":"/v2/radar/3ab83d5628ea"}]}}"#.utf8))
        try check(maliciousRadar.safeFrames.isEmpty, "Untrusted radar hosts must not be fetched")
        let mapCentre = RadarMapPosition(latitude: 0, longitude: 0, zoom: 7)
        try check(abs(mapCentre.x - 64) < 0.00001 && abs(mapCentre.y - 64) < 0.00001, "Radar projection origin failed")
        let freiburgMap = RadarMapPosition(latitude: 47.9959, longitude: 7.85222, zoom: 7)
        try check(Int(freiburgMap.x) == 66 && Int(freiburgMap.y) == 44, "Radar map points to the wrong Freiburg tile")
        let sportsFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let football = try SportsFeedParser.football(Data(contentsOf: sportsFixtures.appendingPathComponent("football.json")), competition: "SC Freiburg")
        try check(football.count == 1 && football[0].teamIDs.contains("126") && football[0].title.contains("Freiburg"), "Favourite fixture parser failed")
        let races = try SportsFeedParser.races(Data(contentsOf: sportsFixtures.appendingPathComponent("f1.json")))
        try check(races.count == 2 && races.allSatisfy { !$0.live && $0.timeConfirmed }, "Scheduled F1 races must not become fabricated live events")
        let future = SportsEvent(id: "test-match", sport: .football, title: "Freiburg vs Test", competition: "SC Freiburg", start: Date().addingTimeInterval(3600), state: "pre", detail: "", teamIDs: ["126"], score: nil, timeConfirmed: true)
        let actualLive = SportsEvent(id: future.id, sport: .football, title: future.title, competition: "Bundesliga", start: .now, state: "in", detail: "45′", teamIDs: ["126"], score: "1 – 0", timeConfirmed: false)
        let agenda = SportsAgenda(defaults: playbackDefaults)
        agenda.feeds = ["freiburg": .init(events: [future], updated: .now), "bundesliga-live": .init(events: [actualLive], updated: Date().addingTimeInterval(-30))]
        try check(agenda.live().first?.score == "1 – 0", "Live scoreboard must override a newer fixture snapshot")
        agenda.feeds["bundesliga-live"] = .init(events: [actualLive], updated: Date().addingTimeInterval(-400))
        try check(agenda.live().isEmpty, "Stale scores must not be labelled live")
        try check(SportsReminders.eligible([future], lead: 15).count == 1, "Favourite reminder timing failed")
        try check(SportsReminders.eligible([actualLive], lead: 15).isEmpty, "Live or unknown start time must not schedule a new reminder")
        let reminderSoon = SportsEvent(id: "soon", sport: .football, title: "Spurs soon", competition: "Tottenham", start: Date().addingTimeInterval(600), state: "pre", detail: "", teamIDs: ["367"], score: nil, timeConfirmed: true)
        let inAppReminder = SportsReminders()
        await inAppReminder.replace([reminderSoon, future], lead: 15)
        try check(inAppReminder.due().map(\.id) == ["soon"], "In-app reminder lead window failed")
        inAppReminder.dismiss(reminderSoon)
        try check(inAppReminder.due().isEmpty, "Dismissed in-app reminder returned")
        inAppReminder.enabled = false
        try check(inAppReminder.due().isEmpty, "Disabled in-app reminders remained visible")
        try check(!ProviderControls.isMediaButton(["Mute"], action: "unmute_stream") && ProviderControls.isMediaButton(["Click to unmute"], action: "unmute_stream"), "Unmute must never toggle an already audible player to mute")
        let history = PlaybackHistory(defaults: playbackDefaults)
        let volume = SystemVolume(simulated: true)
        let model = MacTVModel(history: history, systemVolume: volume, pausesOtherAudio: false)
        let window = FullscreenTestWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MacTV — isolated movie controls test"
        model.window = window
        try check(model.receiveRemote(["kind":"launch", "app":"movies"]).0 == "dispatched" && model.showsMovies, "Phone Movies launch failed")
        model.movies.refresh()
        try await wait("Movie library scan did not finish") { !model.movies.isScanning }
        try check(!model.movies.filtered.isEmpty, "Default Downloads/Movies folder is empty")
        _ = model.receiveRemote(["kind":"key", "key":"right"])
        try check(model.movies.selection == 1, "Phone D-pad did not move library selection")
        try check(model.receiveRemote(["kind":"text", "text":"unmatched-mactv-test-search"]).0 == "dispatched" && model.movies.filtered.isEmpty, "Phone movie search failed")
        model.movies.query = ""
        try check(model.receiveRemote(["kind":"launch", "app":"/bin/sh"]).0 == "unsupported", "Arbitrary launch was accepted")
        // Model navigation follows poster rows and supports categories, details and seasons.
        model.movies.selection = 0
        _ = model.receiveRemote(["kind":"key", "key":"up"])
        try check(model.libraryTabsFocused, "Categories not reachable with phone")
        _ = model.receiveRemote(["kind":"key", "key":"right"])
        try check(model.movies.section == .series, "Series category not reachable")
        _ = model.receiveRemote(["kind":"key", "key":"down"])
        _ = model.receiveRemote(["kind":"key", "key":"ok"])
        try check(model.movies.collection?.isSeries == true, "Series details not reachable")
        _ = model.receiveRemote(["kind":"key", "key":"up"])
        try check(model.movies.seasonFocused, "Seasons not reachable with phone")
        _ = model.receiveRemote(["kind":"key", "key":"down"])
        _ = model.receiveRemote(["kind":"key", "key":"back"])
        try check(model.movies.collection == nil && model.showsMovies, "Back should return to collection")

        let movieName = MediaName("The.Dark.Knight.2008.2160p.4K.BluRay.x265.10bit.AAC5.1-[YTS.MX]")
        try check(movieName.title == "The Dark Knight" && movieName.year == "2008" && !movieName.isSeries, "Movie release parsing failed")
        let numericTitle = MediaName("2001.A.Space.Odyssey.1968.1080p.BluRay")
        try check(numericTitle.title == "2001 A Space Odyssey" && numericTitle.year == "1968", "Numeric movie title misread as release year")
        let anime = MediaName("[DiabloTripleA] The Unwanted Undead Adventurer - S01E07 [1080p HEVC]")
        try check(anime.title == "The Unwanted Undead Adventurer" && anime.season == 1 && anime.episode == 7, "Anime episode parsing failed")
        let ted = MediaName("Ted.Lasso.S04E06.Dont.Jump.Around.Much.Anymore.1080p.WEBRip.10Bit.DDP5.1.x265-NeoNoir")
        try check(ted.title == "Ted Lasso" && ted.season == 4 && ted.episodeTitle == "Dont Jump Around Much Anymore", "Episode subtitle parsing failed")
        let grouped = MovieLibrary.group([
            LocalMovie(url: URL(fileURLWithPath: "/fixture/Show.S02E03.mkv"), relativePath: "Show.S02E03.mkv", size: 1),
            LocalMovie(url: URL(fileURLWithPath: "/fixture/Show.S01E02.mkv"), relativePath: "Show.S01E02.mkv", size: 1),
            LocalMovie(url: URL(fileURLWithPath: "/fixture/Show.S01E01.mkv"), relativePath: "Show.S01E01.mkv", size: 1)])
        try check(grouped.count == 1 && grouped[0].seasons == [1,2] && grouped[0].files.map { $0.info.episode! } == [1,2,3], "Series grouping and ordering failed")
        let detail = try JSONDecoder().decode(MovieMetadata.self, from: Data(#"{"Title":"The Dark Knight","Year":"2008","imdbID":"tt0468569","Type":"movie","Poster":"https://m.media-amazon.com/images/example.jpg"}"#.utf8))
        let film = MediaCollection(title: "The Dark Knight", year: "2008", isSeries: false, files: [])
        try check(MovieMetadataStore.exactMatch(film, detail) && detail.imdbURL != nil && detail.posterURL != nil, "Metadata matching failed")
        try check(!MovieMetadataStore.exactMatch(MediaCollection(title: "The Dark Knight", year: "2012", isSeries: false, files: []), detail), "Wrong-year metadata accepted")
        try check(!MovieMetadataStore.exactMatch(MediaCollection(title: "Other Film", year: "2008", isSeries: false, files: []), detail), "Wrong-title metadata accepted")

        let numbered = LocalMovie(url: URL(fileURLWithPath: "/fixture/Series/Example Show/Season 02/03 - Pilot.mp4"), relativePath: "Series/Example Show/Season 02/03 - Pilot.mp4", size: 1).info
        try check(numbered.isSeries && numbered.title == "Example Show" && numbered.season == 2 && numbered.episode == 3 && numbered.episodeTitle == "Pilot", "Explicit series/show/season folders were ignored")
        let seasonOnly = LocalMovie(url: URL(fileURLWithPath: "/fixture/Series/Example Show/Season 01/S01E01.mkv"), relativePath: "Series/Example Show/Season 01/S01E01.mkv", size: 1).info
        try check(seasonOnly.title == "Example Show" && seasonOnly.isSeries, "Season-only filename lost its show title")
        let forceMovie = LocalMovie(url: URL(fileURLWithPath: "/fixture/Movies/Clip.S01E01.mp4"), relativePath: "Movies/Clip.S01E01.mp4", size: 1).info
        try check(!forceMovie.isSeries, "Explicit Movies folder must override filename hints")
        try check(Service(rawValue: "apple") == nil && Service.allCases.count == 6, "Apple TV launch was not removed")
        try check(Service.f1.browserBundleID == "com.google.Chrome" && Service.f1.address == "https://f1tv.formula1.com/", "F1 TV must use Chrome")
        try check(Service.football.browserBundleID == "com.google.Chrome" && Service.football.address == "https://foxtrend.app/", "Football must use Foxtrend in Chrome")
        try check(RemoteInput.canCloseTab(service: .football, bundleID: "com.google.Chrome"), "Football Chrome tab close is unavailable")
        try check(!RemoteInput.canCloseTab(service: .youtube, bundleID: "com.google.Chrome") && !RemoteInput.canCloseTab(service: .football, bundleID: "com.apple.Safari"), "Tab close escaped its Football/Chrome scope")
        model.handle(.home); model.handle(.up)
        try check(model.area == .music, "Music dashboard not reachable from services")
        model.handle(.right); model.handle(.right)
        try check(model.area == .weather, "Weather dashboard not reachable")
        model.handle(.right)
        try check(model.area == .weather && model.weatherIndex == 1, "Weather refresh action is not reachable from radar")
        model.handle(.left)
        try check(model.weatherIndex == 0, "Weather radar selection did not return")
        model.handle(.ok)
        try check(model.showsRadar, "Weather radar action failed")
        model.handle(.back)
        try check(!model.showsRadar, "Back did not dismiss radar")
        model.handle(.left); model.handle(.up)
        try check(model.area == .hero, "Library shortcuts not reachable from dashboard")
        model.handle(.right); model.handle(.ok)
        try check(model.showsMovies && model.movies.section == .series, "Home Series shortcut failed")
        model.handle(.home); model.handle(.down)
        try check(model.area == .sports && model.selectedService.isSport, "Sports row not reachable from streaming")
        model.handle(.down)
        try check(model.area == .agenda, "Sports agenda not reachable")
        model.handle(.down)
        try check(model.area == .agenda, "Down must stop at the sports agenda after removing the preview row")
        model.handle(.up)
        try check(model.area == .sports, "Sports navigation must return above the agenda")
        model.handle(.home)

        let suite = "MacTV.MetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = RequestCounter()
        let fake: (URLRequest) async throws -> (Data, URLResponse) = { request in
            await counter.increment()
            let missing = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "t" && $0.value == "Missing" } == true
            let data = missing ? Data(#"{"Response":"False","Error":"Movie not found!"}"#.utf8) : try JSONEncoder().encode(detail)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let missing = MediaCollection(title: "Missing", year: nil, isSeries: false, files: [])
        let store = MovieMetadataStore(defaults: defaults, testKey: "test-only-placeholder", transport: fake)
        await store.enrich([film, missing])
        let firstCount = await counter.value
        try check(firstCount == 2 && store.records.count == 1, "Initial metadata lookup count incorrect")
        let reloaded = MovieMetadataStore(defaults: defaults, testKey: "test-only-placeholder", transport: fake)
        await reloaded.enrich([film, missing])
        let secondCount = await counter.value
        try check(secondCount == firstCount && reloaded.records.count == 1 && reloaded.requestsToday == 2, "Relaunch queried cached metadata or repeated a missing-title lookup")
        defaults.set(900, forKey: "omdbQuotaCount.v1")
        let capped = MovieMetadataStore(defaults: defaults, testKey: "test-only-placeholder", transport: fake)
        do { _ = try await capped.search("Another", series: false); throw Failure.check("Daily safety cap failed") }
        catch is MovieMetadataStore.MetadataError { }
        let afterCap = await counter.value
        try check(afterCap == 2, "Quota cap still made a request")
        let posterFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MacTV-PosterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: posterFolder) }
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aT1sAAAAASUVORK5CYII=")!
        let images = RequestCounter()
        let downloader: @Sendable (URL) async throws -> Data = { _ in await images.increment(); return imageData }
        let imageURL = URL(string: "https://m.media-amazon.com/images/fixture.png")!
        let image1 = await MoviePosterCache.load(imageURL, directory: posterFolder, download: downloader)
        let image2 = await MoviePosterCache.load(imageURL, directory: posterFolder, download: downloader)
        let imageRequests = await images.value
        try check(image1 == imageData && image2 == imageData && imageRequests == 1, "Poster was not reused from disk")
        print("Metadata persistence, missing-title cache, daily safety limit and disk poster reuse passed")

        // App-local pointer works without global event posting or Accessibility.
        let clickTarget = PointerClickTarget()
        let root = NSView(frame: NSRect(x: 0,y: 0,width: 1000,height: 700))
        let button = NSButton(title: "Pointer click fixture", target: clickTarget, action: #selector(PointerClickTarget.clicked(_:)))
        button.frame = NSRect(x: 350,y: 310,width: 300,height: 80); root.addSubview(button)
        window.contentView = root; window.makeKeyAndOrderFront(nil)
        try check(model.pointer.execute(["kind":"key", "key":"click"], window: window).0 == "dispatched", "App-local click rejected")
        try await wait("App-local pointer did not activate native button") { clickTarget.clicks == 1 }
        window.contentView = NSHostingView(rootView: Button("SwiftUI touchpad fixture") { clickTarget.clicked(nil) }
            .buttonStyle(TVButtonStyle(selected: false)).frame(maxWidth: .infinity, maxHeight: .infinity))
        model.pointer.reset()
        _ = model.pointer.execute(["kind":"key", "key":"click"], window: window)
        try await wait("App-local pointer did not activate SwiftUI button") { clickTarget.clicks == 2 }
        _ = model.pointer.execute(["kind":"pointer", "dx":12.0, "dy":-8.0], window: window)
        try check(model.pointer.location == CGPoint(x: 524,y: 366), "Pointer movement coordinates incorrect")
        try check(model.pointer.execute(["kind":"pointer", "dx":Double.nan, "dy":0.0], window: window).0 == "unsupported", "Invalid pointer accepted")
        let scroll = NSScrollView(frame: root.bounds); scroll.hasVerticalScroller = true
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0,y: 0,width: 1000,height: 2000))
        window.contentView = scroll
        let beforeScroll = scroll.contentView.bounds.origin.y
        _ = model.pointer.execute(["kind":"scroll", "delta":100.0], window: window)
        try await wait("App-local scroll did not move the document") { scroll.contentView.bounds.origin.y != beforeScroll }
        print("Local touchpad click, movement and scroll passed; no Accessibility required")

        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let movie = LocalMovie(url: file, relativePath: "Generated playback fixture", size: 1)
        let clicks = RemoteInput.primaryClick(at: CGPoint(x: 20, y: 30))
        try check(clicks.count == 2 && clicks[0].type == .leftMouseDown && clicks[1].type == .leftMouseUp, "Tap did not generate a primary click")
        try check(clicks.allSatisfy { $0.flags.isEmpty && $0.getIntegerValueField(.mouseEventButtonNumber) == 0 && $0.getIntegerValueField(.mouseEventClickState) == 1 }, "Primary click inherited modifier flags / wrong button")
        try check(ProviderControls.isMediaButton(["Pause (k)"], action: "play_pause"), "YouTube pause button matching failed")
        try check(ProviderControls.isMediaButton(["Pause keyboard shortcut k"], action: "play_pause"), "Expanded YouTube pause label failed")
        try check(ProviderControls.isMediaButton(["Play keyboard shortcut k"], action: "play_pause"), "Expanded YouTube play label failed")
        try check(!ProviderControls.isMediaButton(["Search", "Play playlist"], action: "play_pause"), "Search/result button could be mistaken for a player control")
        history.save(movie, seconds: 12, duration: 35)
        try check(history.continuing([movie]).first == movie, "Continue Watching missed an unfinished movie")
        try check(PlaybackHistory(defaults: playbackDefaults).position(movie) == 12, "Resume position did not survive history reload")
        model.playMovie(movie)
        let player = model.moviePlayer!
        try check(window.fullscreenRequests == 1, "Movie did not request fullscreen automatically")
        window.contentView = NSHostingView(rootView: MoviePlayerView(model: model, player: player))
        window.orderFront(nil)
        try await wait("SwiftUI VLC video surface did not start") { player.playing && player.snapshot.width == 640 && !player.surface.subviews.isEmpty }
        try await wait("Playback did not restore saved position") { player.snapshot.milliseconds > 11000 }
        player.updateControls(now: .distantFuture)
        try check(!player.controlsVisible, "Playing video controls did not auto-hide")
        _ = model.receiveRemote(["kind":"key", "key":"controls"])
        try check(player.controlsVisible && player.controlsFocused, "Phone could not reveal controls")
        player.updateControls(now: .distantFuture)
        try check(player.controlsVisible, "Explicit phone controls vanished during selection")
        for _ in 0..<2 { _ = model.receiveRemote(["kind":"key", "key":"right"]) }
        try check(player.controlIndex == 5, "Fullscreen button not reachable with D-pad")
        _ = model.receiveRemote(["kind":"key", "key":"ok"])
        try check(window.fullscreenRequests == 2, "D-pad fullscreen selection failed")
        _ = model.receiveRemote(["kind":"key", "key":"fullscreen"])
        try check(window.fullscreenRequests == 3, "Dedicated phone fullscreen key failed")
        _ = model.receiveRemote(["kind":"key", "key":"down"])
        try check(!player.controlsVisible && !player.controlsFocused, "Phone could not hide controls")
        try check(model.receiveRemote(["kind":"key", "key":"play_pause"]).0 == "dispatched", "Play/pause not routed")
        try await wait("Phone pause failed") { player.snapshot.state == 4 }
        player.updateControls(now: .distantFuture)
        try check(player.controlsVisible, "Paused controls should remain visible")
        _ = model.receiveRemote(["kind":"key", "key":"next"])
        try await wait("Phone seek failed") { player.snapshot.milliseconds > 8000 }
        _ = model.receiveRemote(["kind":"key", "key":"mute"])
        try await wait("Phone mute failed") { volume.muted }
        _ = model.receiveRemote(["kind":"key", "key":"volume_down"])
        try await wait("Phone volume failed") { volume.level == 90 }
        _ = model.receiveRemote(["kind":"key", "key":"back"])
        try check(model.moviePlayer == nil && model.showsMovies && player.closed, "Back did not stop playback and return to Movies")
        try check(history.position(movie) > 10, "Closing playback lost its checkpoint")
        model.playMovie(movie)
        let finished = model.moviePlayer!
        finished.accept(VLCSnapshot(state: 6, duration: 35_000, seekable: true))
        try check(model.moviePlayer == nil && finished.closed && history.position(movie) == 0, "EOF failed to close player / clear resume position")
        window.contentView = NSView()
        try await wait("Back left a hidden VLC view") { player.surface.subviews.isEmpty }
        _ = model.receiveRemote(["kind":"key", "key":"home"])
        try check(!model.showsMovies && model.moviePlayer == nil && model.browser == nil, "Home did not clear playback")
        if let show = MovieLibrary.group(model.movies.movies).first(where: { $0.isSeries && $0.files.count > 1 }) {
            let episode = show.files[0]
            try check(model.followingEpisode(episode) == show.files[1], "Next-episode ordering failed")
            let old = model.autoplayNext
            defer { model.autoplayNext = old }
            model.autoplayNext = true
            model.finished(episode)
            try check(model.nextEpisode == show.files[1], "Autoplay countdown not offered")
            model.handle(.back)
            try check(model.nextEpisode == nil, "Back did not cancel autoplay")
            model.autoplayNext = false
            model.finished(episode)
            try check(model.nextEpisode == nil, "Autoplay ran while disabled")
        }
        window.orderOut(nil)
    }
}
