import SwiftUI
import AppKit
import Observation

enum RemoteCommand: Equatable {
    case up, down, left, right, ok, back, home
    case launch(Service)
    case play, pause, seek(Double), mute, fullscreen, controls
    case volumeUp, volumeDown, playPause, touchpad(Double, Double), text(String)
}

enum Service: String, CaseIterable, Identifiable {
    case netflix, youtube, spotify, prime, f1, football
    var id: String { rawValue }
    var name: String {
        switch self {
        case .netflix: "Netflix"
        case .youtube: "YouTube"
        case .spotify: "Spotify"
        case .prime: "Prime Video"
        case .f1: "F1 TV"
        case .football: "Football"
        }
    }
    var symbol: String {
        switch self {
        case .netflix: "film.stack.fill"
        case .youtube: "play.rectangle.fill"
        case .spotify: "waveform"
        case .prime: "play.circle.fill"
        case .f1: "flag.checkered"
        case .football: "soccerball"
        }
    }
    var color: Color {
        switch self {
        case .netflix: Color(red: 0.85, green: 0.08, blue: 0.16)
        case .youtube: Color(red: 0.94, green: 0.21, blue: 0.18)
        case .spotify: Color(red: 0.1, green: 0.72, blue: 0.43)
        case .prime: Color(red: 0.08, green: 0.55, blue: 0.87)
        case .f1: Color(red: 0.95, green: 0.15, blue: 0.12)
        case .football: Color(red: 0.25, green: 0.8, blue: 0.48)
        }
    }
    var address: String {
        switch self {
        case .netflix: "https://www.netflix.com"
        case .youtube: "https://www.youtube.com"
        case .spotify: "https://open.spotify.com"
        case .prime: "https://www.primevideo.com"
        case .f1: "https://f1tv.formula1.com/"
        case .football: "https://foxtrend.app/"
        }
    }
    var isSport: Bool { self == .f1 || self == .football }
    var browserBundleID: String { self == .youtube || isSport ? "com.google.Chrome" : "com.apple.Safari" }
    var bundleID: String? {
        switch self {
        case .prime: "com.amazon.aiv.AIVApp"
        case .spotify: "com.spotify.client"
        default: nil
        }
    }
    var tagline: String {
        switch self {
        case .netflix: "Stories worth staying in for."
        case .youtube: "Follow your curiosity."
        case .spotify: "Set the soundtrack to tonight."
        case .prime: "Your next great watch awaits."
        case .f1: "Race weekend starts here."
        case .football: "Your next match, one click away."
        }
    }
}

@MainActor
struct ServiceLauncher {
    func open(_ service: Service, preferNative: Bool) async throws -> NSRunningApplication {
        let workspace = NSWorkspace.shared
        func application(_ id: String, preferred: String) -> URL? {
            let url = URL(fileURLWithPath: preferred)
            if Bundle(url: url)?.bundleIdentifier == id { return url }
            return workspace.urlForApplication(withBundleIdentifier: id)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if (preferNative || service == .prime), let id = service.bundleID,
           let app = application(id, preferred: service == .spotify ? "/Applications/Spotify.app" : "/Applications/Prime Video.app") {
            do {
                return try await workspace.openApplication(at: app, configuration: configuration)
            } catch {
                // Fall back to the service website if an installed app fails to launch.
            }
        }
        guard let url = URL(string: service.address),
              let safari = application(service.browserBundleID, preferred: service.browserBundleID == "com.google.Chrome" ? "/Applications/Google Chrome.app" : "/System/Applications/Safari.app") else {
            throw LaunchError.browserUnavailable(service.browserBundleID == "com.google.Chrome" ? "Google Chrome" : "Safari")
        }
        return try await workspace.open([url], withApplicationAt: safari, configuration: configuration)
    }

    enum LaunchError: LocalizedError {
        case browserUnavailable(String)
        var errorDescription: String? { if case .browserUnavailable(let name) = self { return "Install \(name) to open this service." }; return nil }
    }
}

@MainActor @Observable
final class MacTVModel {
    enum Area { case navigation, hero, services, sports, agenda, continueWatching, settings, movies, music, weather }
    let remote = RemoteServer()
    let movies = MovieLibrary()
    let metadata = MovieMetadataStore()
    let pointer = MacTVPointer()
    let music = MusicPlayback()
    let weather = WeatherSummary()
    let sports = SportsAgenda()
    let radar = RainRadar()
    var showsRadar = false
    func openRadar() { showsRadar = true }
    let history: PlaybackHistory
    let systemVolume: SystemVolume
    let awake = KeepAwake()
    @ObservationIgnored private let pausesOtherAudio: Bool
    init(history: PlaybackHistory? = nil, systemVolume: SystemVolume? = nil, pausesOtherAudio: Bool = true) {
        self.pausesOtherAudio = pausesOtherAudio
        self.history = history ?? PlaybackHistory(); self.systemVolume = systemVolume ?? SystemVolume()
    }
    var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); awake.setEnabled(keepAwake && window?.isVisible == true) }
    }
    var autoplayNext = UserDefaults.standard.bool(forKey: "autoplayNext") {
        didSet { UserDefaults.standard.set(autoplayNext, forKey: "autoplayNext"); if !autoplayNext { cancelNextEpisode() } }
    }
    var nextEpisode: LocalMovie?
    var nextCountdown = 0
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    var agendaIndex = 0
    var agendaEvents: [SportsEvent] {
        let live = sports.live()
        return live + sports.highlights().filter { event in !live.contains(where: { $0.id == event.id }) }
    }
    var weatherIndex = 0
    var musicIndex = 1
    var continueMovies: [LocalMovie] { Array(history.continuing(movies.movies).prefix(1)) }
    func collection(for movie: LocalMovie) -> MediaCollection? { MovieLibrary.group(movies.movies).first { $0.files.contains { $0.id == movie.id } } }
    func followingEpisode(_ movie: LocalMovie) -> LocalMovie? {
        guard let collection = collection(for: movie), collection.isSeries,
            let index = collection.files.firstIndex(where: { $0.id == movie.id }), collection.files.indices.contains(index + 1) else { return nil }
        return collection.files[index + 1]
    }
    func cancelNextEpisode() { nextTask?.cancel(); nextTask = nil; nextEpisode = nil; nextCountdown = 0 }
    func playNextEpisode() { guard let movie = nextEpisode else { return }; cancelNextEpisode(); playMovie(movie, restart: true) }
    func finished(_ movie: LocalMovie) {
        closeMovie()
        guard autoplayNext, let next = followingEpisode(movie) else { return }
        nextEpisode = next; nextCountdown = 8
        nextTask = Task { [weak self] in
            for remaining in stride(from: 8, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self?.nextCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.playNextEpisode()
        }
    }
    var remoteContext: [String: Any] {
        let app: String
        let title: String
        var keys: [String] = []
        if showsRadar { app = "home"; title = "Rain radar" }
        else if let player = moviePlayer { app = "player"; title = player.movie.title; keys = ["seek_back", "seek_forward", "subtitles", "restart"] }
        else if let target = externalTarget, !target.isTerminated, let service = lastOpened {
            app = service.rawValue; title = service.name
            switch service {
            case .spotify: keys = ["previous", "play_pause", "next", "app_search"]
            case .youtube: keys = ["seek_back", "seek_forward", "fullscreen", "subtitles"]
            case .netflix, .prime: keys = ["seek_back", "seek_forward", "fullscreen"]
            case .f1: keys = ["fullscreen"]
            case .football: keys = ["unmute_stream", "refresh", "fullscreen", "close_tab"]
            }
        } else { app = showsMovies ? "library" : (showsSettings ? "settings" : "home"); title = showsMovies ? "Library" : "MacTV" }
        if moviePlayer == nil && externalTarget == nil && browser == nil && music.track != nil { keys += ["previous", "play_pause", "next"] }
        var result: [String: Any] = ["app": app, "title": String(title.prefix(200)), "keys": keys,
            "foreground": NSWorkspace.shared.frontmostApplication?.processIdentifier == (externalTarget?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier)]
        if let player = moviePlayer { result["subtitle"] = player.subtitleLabel; result["playing"] = player.playing }
        systemVolume.refresh()
        result["volumeAvailable"] = systemVolume.available
        result["volumeNotice"] = systemVolume.notice ?? ""
        result["audioOutput"] = systemVolume.outputName
        return result
    }
    var libraryTabsFocused = false
    var showsMovies = false
    var movieSearchEditing = false
    var moviePlayer: MoviePlayer?
    @ObservationIgnored var externalTarget: NSRunningApplication?
    var area: Area = .services
    var serviceIndex = 0
    var homeLibraryIndex = 0
    var inputPermission = RemoteInput.permitted
    func refreshInputPermission() { inputPermission = RemoteInput.permitted }
    var navigationIndex = 0
    var settingIndex = 0
    var showsSettings = false
    var browser: BrowserSession?
    var isLaunching = false
    var message: String?
    var launchError: String?
    var lastOpened: Service?
    var midnight = UserDefaults.standard.bool(forKey: "midnight") {
        didSet { UserDefaults.standard.set(midnight, forKey: "midnight") }
    }
    var reducedMotion = UserDefaults.standard.bool(forKey: "reducedMotion") {
        didSet { UserDefaults.standard.set(reducedMotion, forKey: "reducedMotion") }
    }
    var preferNative = UserDefaults.standard.object(forKey: "preferNative") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferNative, forKey: "preferNative") }
    }
    var startsFullscreen = UserDefaults.standard.object(forKey: "startsFullscreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startsFullscreen, forKey: "startsFullscreen") }
    }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var launchGeneration = 0
    @ObservationIgnored private let launcher = ServiceLauncher()
    var selectedService: Service { Service.allCases[serviceIndex] }

    func startRemote() {
        Task { await LegacySportsNotificationCleanup.clear() }
        remote.command = { [weak self] body in self?.receiveRemote(body) ?? ("error", "MacTV unavailable") }
        remote.context = { [weak self] in self?.remoteContext ?? [:] }
        remote.start()
    }

    func receiveRemote(_ body: [String: Any]) -> (String, String) {
        guard let kind = body["kind"] as? String else { return ("unsupported", "Missing command kind") }
        if kind == "launch" {
            if body["app"] as? String == "movies" { openMovies(); return ("dispatched", "Movies library opened") }
            guard let app = body["app"] as? String, let service = Service(rawValue: app) else { return ("unsupported", "Unknown service") }
            guard !isLaunching else { return ("error", "A service is already opening") }
            handle(.launch(service)); return ("dispatched", "Opening service. If touchpad input is blocked, enable MacTV in Mac Privacy & Security settings.")
        }
        if kind == "key", let key = body["key"] as? String, key == "home" {
            handle(.home); return ("dispatched", "MacTV Home")
        }
        if kind == "key", body["key"] as? String == "input_settings" {
            RemoteInput.requestPermission(); refreshInputPermission()
            return ("dispatched", "Enable MacTV in \(RemoteInput.permissionName), then return to your streaming app")
        }
        if kind == "key", body["key"] as? String == "activate_app" {
            guard let target = externalTarget, !target.isTerminated else { return ("error", "Open a streaming service from MacTV first") }
            return target.activate(options: []) ? ("dispatched", "Streaming app brought forward") : ("error", "Could not activate the streaming app")
        }
        if kind == "key", let key = body["key"] as? String, ["volume_up", "volume_down", "mute"].contains(key) {
            let ok = key == "mute" ? systemVolume.toggleMute() : systemVolume.change(key == "volume_up" ? 10 : -10)
            return ok ? ("dispatched", "Mac output volume updated") : ("error", systemVolume.notice ?? "Mac volume unavailable")
        }
        if showsRadar, kind == "key", let key = body["key"] as? String {
            let navigation: [String: RemoteCommand] = ["left": .left, "right": .right, "ok": .ok, "back": .back, "play_pause": .playPause]
            guard let command = navigation[key] else { return ("unsupported", "Use left/right for radar frames, OK to play/pause, or Back to close") }
            handle(command); return ("dispatched", "Radar control updated")
        }
        if externalTarget == nil, browser == nil, moviePlayer == nil, nextEpisode == nil,
           kind == "key", let key = body["key"] as? String, ["previous", "play_pause", "next"].contains(key) {
            guard music.track != nil else { return ("error", "Open music from the music bar and select a track first") }
            guard !music.busy else { return ("error", "Music is updating. Try again.") }
            music.control(key)
            return ("dispatched", "Music command sent; check the music bar")
        }
        if let externalTarget {
            guard !externalTarget.isTerminated else {
                self.externalTarget = nil
                return ("error", "Streaming app closed. Press Home.")
            }
            if kind == "key", body["key"] as? String == "subtitles", lastOpened != .youtube {
                return ("unsupported", "Select subtitles in this app with the touchpad")
            }
            return RemoteInput.execute(body, target: externalTarget, service: lastOpened)
        }
        if kind == "pointer" || kind == "scroll" || (kind == "key" && body["key"] as? String == "click") {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                return ("error", "MacTV must be in front for pointer input")
            }
            guard let window else { return ("error", "MacTV window unavailable") }
            moviePlayer?.revealControls()
            return pointer.execute(body, window: window)
        }
        if kind == "key", let key = body["key"] as? String, ["backspace", "erase_field"].contains(key), showsMovies, moviePlayer == nil {
            if key == "erase_field" { movies.query = "" } else if !movies.query.isEmpty { movies.query.removeLast() }
            return ("dispatched", "Library search edited")
        }
        if kind == "text", let text = body["text"] as? String, text.utf16.count <= 2000, !text.isEmpty {
            if showsMovies, moviePlayer == nil { movies.collection = nil; libraryTabsFocused = false; movies.query = text; area = .movies; return ("dispatched", "Movies search updated") }
            guard let browser else { return ("unsupported", "Open Movies or focus a page text field first") }
            if browser.editingAddress { browser.address = text }
            else { browser.insertRemoteText(text) }
            return ("dispatched", "Text sent to the focused page field; check the Mac")
        }
        guard kind == "key", let key = body["key"] as? String else { return ("unsupported", "Unsupported command") }
        if key == "subtitles", let player = moviePlayer { player.cycleSubtitle(); return ("dispatched", "Subtitle selection changed") }
        if key == "restart", let player = moviePlayer { player.restart(); return ("dispatched", "Playback restarted") }
        let mapping: [String: RemoteCommand] = ["up": .up, "down": .down, "left": .left, "right": .right,
            "ok": .ok, "back": .back, "play_pause": .playPause, "previous": .seek(-10), "next": .seek(10), "seek_back": .seek(-10), "seek_forward": .seek(10),
            "volume_up": .volumeUp, "volume_down": .volumeDown, "mute": .mute, "fullscreen": .fullscreen, "controls": .controls]
        guard let command = mapping[key] else { return ("unsupported", "Unknown key") }
        if browser == nil && moviePlayer == nil && nextEpisode == nil && ["play_pause", "previous", "next", "seek_back", "seek_forward", "controls"].contains(key) {
            return ("unsupported", "Open a streaming service first")
        }
        handle(command)
        return ("dispatched", "Command dispatched to MacTV")
    }

    func handle(_ command: RemoteCommand) {
        switch command {
        case .volumeUp: systemVolume.change(10); return
        case .volumeDown: systemVolume.change(-10); return
        case .mute: systemVolume.toggleMute(); return
        default: break
        }
        if showsRadar {
            switch command {
            case .home, .launch: showsRadar = false
            case .back: showsRadar = false; return
            case .left: radar.playing = false; radar.step(-1); return
            case .right: radar.playing = false; radar.step(1); return
            case .ok, .playPause: radar.playing.toggle(); return
            default: return
            }
        }
        if nextEpisode != nil {
            if command == .ok || command == .playPause { playNextEpisode(); return }
            cancelNextEpisode()
            if command == .back { return }
        }
        if area == .agenda && moviePlayer == nil && browser == nil {
            switch command {
            case .left: agendaIndex = max(0, agendaIndex - 1); return
            case .right: agendaIndex = min(max(0, agendaEvents.count - 1), agendaIndex + 1); return
            case .up, .back: area = .sports; serviceIndex = max(4, serviceIndex); return
            case .down: return
            case .ok:
                if agendaEvents.indices.contains(agendaIndex) { handle(.launch(agendaEvents[agendaIndex].sport == .f1 ? .f1 : .football)) }
                return
            default: break
            }
        }
        if area == .weather && moviePlayer == nil && browser == nil {
            switch command {
            case .left:
                if weatherIndex == 1 { weatherIndex = 0 }
                else { area = .music; musicIndex = 2 }
                return
            case .right: weatherIndex = 1; return
            case .up, .back: area = .hero; return
            case .down: area = .services; serviceIndex = min(3, serviceIndex); return
            case .ok:
                if weatherIndex == 0 { openRadar() }
                else { Task { await weather.refresh(force: true) } }
                return
            default: break
            }
        }
        if area == .music && moviePlayer == nil && browser == nil {
            switch command {
            case .left:
                if !showsMovies && !showsSettings && musicIndex == 0 { area = .continueWatching }
                else { musicIndex = max(0, musicIndex - 1) }
                return
            case .right:
                if !showsMovies && !showsSettings && musicIndex == 2 { area = .weather; weatherIndex = 0 }
                else { musicIndex = min(2, musicIndex + 1) }
                return
            case .ok:
                if music.track == nil { music.open() }
                else { music.control(["previous", "play_pause", "next"][musicIndex]) }
                return
            case .up, .back: area = showsMovies ? .movies : (showsSettings ? .settings : .hero); return
            case .down: if !showsMovies && !showsSettings { area = .services; serviceIndex = min(3, serviceIndex) }; return
            default: break
            }
        }
        if command != .home {
            if case .launch = command {
                stopMovie(); showsMovies = false
            } else if let player = moviePlayer {
                handleMovie(command, player: player); return
            } else if showsMovies {
                if command == .back {
                    if movies.collection != nil { movies.collection = nil; movies.selection = 0 }
                    else { handle(.home) }; return
                }
                if area == .movies {
                    if libraryTabsFocused {
                        switch command {
                        case .left: movies.section = .movies
                        case .right: movies.section = .series
                        case .down, .ok: libraryTabsFocused = false
                        case .up: area = .navigation; navigationIndex = 1
                        default: break
                        }
                    } else {
                        switch command {
                        case .ok where movies.seasonFocused: movies.seasonFocused = false
                        case .left where movies.seasonFocused: shiftMovieSeason(-1)
                        case .right where movies.seasonFocused: shiftMovieSeason(1)
                        case .down where movies.seasonFocused: movies.seasonFocused = false
                        case .up where movies.seasonFocused: movies.collection = nil; movies.seasonFocused = false
                        case .ok:
                            if let collection = movies.collection {
                                if let movie = movies.selectedEpisode ?? collection.files.first { playMovie(movie) }
                            } else if let selected = movies.selectedTitle { movies.collection = selected; movies.selection = 0 }
                        case .left: movies.selection = max(0, movies.selection - 1)
                        case .right: movies.selection = min(max(0, movies.itemCount - 1), movies.selection + 1)
                        case .up where movies.collection?.isSeries == true && movies.selection == 0: movies.seasonFocused = true
                        case .up:
                            if movies.selection < movies.columns { libraryTabsFocused = movies.collection == nil; if !libraryTabsFocused { movies.collection = nil; movies.selection = 0 } }
                            else { movies.selection -= movies.columns }
                        case .down:
                            if movies.selection + movies.columns >= movies.itemCount { area = .music }
                            else { movies.selection += movies.columns }
                        case .fullscreen: window?.toggleFullScreen(nil)
                        default: break
                        }
                    }
                    return
                }
            }
        }
        if let browser, command != .home {
            if case .launch = command {
                closeBrowser()
            } else {
                handleBrowser(command, session: browser)
                return
            }
        }
        switch command {
        case .home:
            launchGeneration += 1
            isLaunching = false
            externalTarget = nil
            stopMovie(); showsMovies = false
            closeBrowser()
            showsSettings = false
            area = selectedService.isSport ? .sports : .services
            navigationIndex = 0
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .back:
            if launchError != nil { launchError = nil }
            else if showsSettings { showsSettings = false; area = .navigation }
            else { area = .navigation; navigationIndex = 0 }
        case .fullscreen: window?.toggleFullScreen(nil)
        case .launch(let service): launch(service)
        case .ok:
            if showsSettings { toggleSetting(settingIndex) }
            else if area == .hero {
                openMovies(); movies.section = homeLibraryIndex == 0 ? .movies : .series; libraryTabsFocused = false
            } else if area == .continueWatching {
                if let movie = continueMovies.first { playMovie(movie) }
            } else if area == .navigation {
                if navigationIndex == 2 { openSettings() }
                else if navigationIndex == 1 { openMovies() }
                else { handle(.home) }
            } else { launch(selectedService) }
        case .left, .right:
            let delta = command == .left ? -1 : 1
            if showsSettings { return }
            if area == .navigation { navigationIndex = min(2, max(0, navigationIndex + delta)) }
            else if area == .hero { homeLibraryIndex = min(1, max(0, homeLibraryIndex + delta)) }
            else if area == .continueWatching {
                if command == .right { area = .music; musicIndex = 0 }
            }
            else if area == .sports { serviceIndex = min(5, max(4, serviceIndex + delta)) }
            else { serviceIndex = min(3, max(0, serviceIndex + delta)) }
        case .up:
            if showsSettings { settingIndex = max(0, settingIndex - 1) }
            else if area == .sports { area = .services; serviceIndex = min(3, serviceIndex - 4) }
            else { area = (area == .services ? (continueMovies.isEmpty ? .music : .continueWatching) : (area == .continueWatching ? .hero : .navigation)) }
        case .down:
            if showsSettings { if settingIndex == 6 { area = .music } else { settingIndex += 1 } }
            else if showsMovies { area = .movies }
            else if area == .services { area = .sports; serviceIndex = 4 + min(1, serviceIndex) }
            else if area == .sports { area = .agenda }
            else { area = area == .navigation ? .hero : (area == .hero ? (continueMovies.isEmpty ? .music : .continueWatching) : (area == .continueWatching ? .services : .agenda)) }
        default: message = "This remote command will be supported in a future version."
        }
    }

    func openMovies() {
        cancelNextEpisode()
        launchGeneration += 1; isLaunching = false; externalTarget = nil
        closeBrowser(); stopMovie(); showsSettings = false; showsMovies = true
        area = .movies; navigationIndex = 1
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func playMovie(_ movie: LocalMovie, restart: Bool = false) {
        cancelNextEpisode()
        launchGeneration += 1; isLaunching = false; externalTarget = nil
        closeBrowser(); stopMovie()
        showsSettings = false; showsMovies = true; area = .movies
        movieSearchEditing = false
        if restart { history.restart(movie) }
        let player = MoviePlayer(movie: movie, history: history, systemVolume: systemVolume)
        player.onEnded = { [weak self, weak player] in
            guard let self, self.moviePlayer === player else { return }
            self.finished(movie)
        }
        player.waitingForAudio = pausesOtherAudio
        moviePlayer = player
        if pausesOtherAudio {
            OtherAudio.pause { [weak self, weak player] notice in
                guard let self, let player, self.moviePlayer === player, !player.closed else { return }
                player.audioNotice = notice; player.waitingForAudio = false; player.startIfAttached()
            }
        }
        pointer.reset()
        if let window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func stopMovie() { cancelNextEpisode(); moviePlayer?.stop(); moviePlayer = nil }
    func closeMovie() { stopMovie(); showsMovies = true; area = .movies }
    private func handleMovie(_ command: RemoteCommand, player: MoviePlayer) {
        switch command {
        case .back: closeMovie()
        case .ok:
            if player.controlsFocused { performMovieAction(player.controlIndex, player: player) }
            else { player.toggle() }
        case .playPause: player.toggle()
        case .play: player.play()
        case .pause: player.pause()
        case .left:
            if player.controlsFocused { player.controlIndex = player.controlIndex == 5 ? 3 : max(0, player.controlIndex - 1); player.revealControls() } else { player.seek(-10) }
        case .right:
            if player.controlsFocused { player.controlIndex = player.controlIndex == 3 ? 5 : min(7, player.controlIndex + 1); player.revealControls() } else { player.seek(10) }
        case .seek(let seconds): player.seek(seconds)
        case .volumeUp: player.changeVolume(10)
        case .volumeDown: player.changeVolume(-10)
        case .up, .controls: player.controlsFocused = true; player.revealControls()
        case .down: player.controlsFocused = false; player.hideControls()
        case .mute: player.mute()
        case .fullscreen: window?.toggleFullScreen(nil)
        default: message = "Use playback controls, Back, or Home for this video."
        }
    }
    private func shiftMovieSeason(_ delta: Int) {
        guard let collection = movies.collection, let index = collection.seasons.firstIndex(of: movies.selectedSeason), collection.seasons.indices.contains(index + delta) else { return }
        movies.selectedSeason = collection.seasons[index + delta]
    }
    func performMovieAction(_ index: Int, player: MoviePlayer) {
        player.revealControls()
        switch index {
        case 0: closeMovie()
        case 1: player.seek(-10)
        case 2: player.toggle()
        case 3: player.seek(10)
        case 4: break // Retired volume slot; D-pad skips it.
        case 5: window?.toggleFullScreen(nil)
        case 6: handle(.home)
        case 7: player.cycleSubtitle()
        default: break
        }
    }
    func openSettings() { cancelNextEpisode(); closeBrowser(); stopMovie(); showsMovies = false; showsSettings = true; area = .settings; settingIndex = 0 }

    func toggleSetting(_ index: Int) {
        settingIndex = index
        switch index {
        case 0: midnight.toggle()
        case 1: reducedMotion.toggle()
        case 2: preferNative.toggle()
        case 3: startsFullscreen.toggle()
        case 4: keepAwake.toggle()
        case 5: autoplayNext.toggle()
        default: handle(.back)
        }
    }

    func closeBrowser() {
        browser?.close()
        browser = nil
    }

    private func handleBrowser(_ command: RemoteCommand, session: BrowserSession) {
        switch command {
        case .back:
            if session.editingAddress { session.editingAddress = false }
            else if !session.goBack() { handle(.home) }
        case .fullscreen: window?.toggleFullScreen(nil)
        case .play: session.playerCommand("play")
        case .pause: session.playerCommand("pause")
        case .playPause: session.playerCommand("toggle")
        case .seek(let seconds): session.playerCommand("seek", value: seconds)
        case .mute: session.playerCommand("mute")
        case .volumeUp: session.playerCommand("volume", value: 10)
        case .volumeDown: session.playerCommand("volume", value: -10)
        case .text(let text):
            session.address = text
            session.editingAddress = true
        case .left, .right:
            if session.pageNavigation {
                if session.isPlayer { session.playerCommand("seek", value: command == .left ? -10 : 10) }
                else { session.navigatePage(forward: command == .right) }
            } else {
                session.toolbarIndex = min(BrowserAction.allCases.count - 1,
                                           max(0, session.toolbarIndex + (command == .left ? -1 : 1)))
            }
        case .up:
            session.pageNavigation = false
        case .down:
            if session.pageNavigation {
                if session.isPlayer { session.playerCommand("volume", value: -10) }
                else { session.scrollPage() }
            } else { session.pageNavigation = true }
        case .ok:
            if session.editingAddress { session.submitAddress() }
            else if session.pageNavigation {
                if session.isPlayer { session.playerCommand("toggle") }
                else { session.activatePageSelection() }
            } else if let action = BrowserAction(rawValue: session.toolbarIndex) { performBrowserAction(action) }
        default: session.notice = "This input is not supported in the browser yet."
        }
    }

    func performBrowserAction(_ action: BrowserAction) {
        guard let browser else { return }
        switch action {
        case .back: handle(.back)
        case .home: handle(.home)
        case .browse:
            if let url = URL(string: Service.youtube.address) { browser.navigate(to: .page(url)) }
        case .playPause: handle(.playPause)
        case .rewind: handle(.seek(-10))
        case .forward: handle(.seek(10))
        case .volumeDown: handle(.volumeDown)
        case .volumeUp: handle(.volumeUp)
        case .mute: handle(.mute)
        case .fullscreen: handle(.fullscreen)
        case .safari: browser.openInSafari()
        case .retry: browser.retry()
        }
    }

    private func launch(_ service: Service) {
        guard !isLaunching else { return }
        serviceIndex = Service.allCases.firstIndex(of: service) ?? 0
        area = service.isSport ? .sports : .services
        stopMovie(); showsMovies = false
        externalTarget = nil
        if PlaybackCompatibility.embeddedPlaybackAllowed(service) {
            let session = BrowserSession()
            browser = session
            showsSettings = false
            lastOpened = service
            session.start()
            return
        }
        launchGeneration += 1
        let generation = launchGeneration
        isLaunching = true
        message = "Opening \(service.name)…"
        Task {
            defer { if launchGeneration == generation { isLaunching = false } }
            do {
                let target = try await launcher.open(service, preferNative: preferNative)
                guard launchGeneration == generation else { return }
                externalTarget = target
                lastOpened = service
                message = PlaybackCompatibility.reason(for: service)
            } catch {
                guard launchGeneration == generation else { return }
                message = nil
                launchError = "Could not open \(service.name). \(error.localizedDescription)"
            }
        }
    }
}
