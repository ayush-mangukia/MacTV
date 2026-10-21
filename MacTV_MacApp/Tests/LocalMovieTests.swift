import AppKit
import Foundation

@MainActor @main struct LocalMovieTests {
    enum Failure: Error { case check(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }
    static func sample(_ backend: VLCBackend) async -> VLCSnapshot {
        await withCheckedContinuation { continuation in backend.sample { continuation.resume(returning: $0) } }
    }
    static func wait(_ backend: VLCBackend, _ message: String, predicate: (VLCSnapshot) -> Bool) async throws -> VLCSnapshot {
        var latest = VLCSnapshot()
        for _ in 0..<100 {
            latest = await sample(backend)
            if predicate(latest) { return latest }
            if latest.state == 7 { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Failure.check("\(message); state \(latest.state), time \(latest.milliseconds), video \(latest.width)x\(latest.height)")
    }
    static func open(_ backend: VLCBackend, _ file: URL, view: NSView) async -> String? {
        await withCheckedContinuation { continuation in
            backend.open(file, drawable: Unmanaged.passUnretained(view).toOpaque(), initialVolume: 0) { continuation.resume(returning: $0) }
        }
    }
    static func close(_ backend: VLCBackend) async {
        await withCheckedContinuation { continuation in backend.close { continuation.resume() } }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("Local movie tests passed"); fflush(stdout); exit(0) }
            catch { fputs("Local movie tests failed: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    static func run() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = fixture.deletingLastPathComponent().appendingPathComponent("library", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("Season"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixture, to: folder.appendingPathComponent("Season/Episode 02.mp4"))
        try fm.copyItem(at: fixture, to: folder.appendingPathComponent("Movie 01.MKV"))
        try Data().write(to: folder.appendingPathComponent("poster.jpg"))
        try Data().write(to: folder.appendingPathComponent("subtitles.srt"))
        try Data().write(to: folder.appendingPathComponent(".hidden.mp4"))
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked.mp4"), withDestinationURL: fixture)
        let scan = MovieLibrary.scan(folder)
        try check(scan.error == nil && scan.movies.count == 2, "Recursive scan must ignore hidden/support files and symlinks")
        try check(scan.movies[0].relativePath == "Movie 01.MKV", "Natural library sorting failed: \(scan.movies.map(\.relativePath))")
        let library = MovieLibrary(folder: folder)
        library.refresh()
        while library.isScanning { try await Task.sleep(for: .milliseconds(50)) }
        library.query = "episode"
        try check(library.filtered.count == 1 && library.selected?.relativePath == "Season/Episode 02.mp4", "Search/selection failed")
        try check(MovieLibrary.scan(folder.appendingPathComponent("missing")).error != nil, "Missing folder must report an error")

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        window.contentView = surface
        window.title = "MacTV — isolated VLC playback test"
        window.orderFront(nil)
        let backend = VLCBackend()
        let error = await open(backend, fixture, view: surface)
        try check(error == nil, error ?? "Open failed")
        let started = try await wait(backend, "VLC did not decode an embedded video") { $0.state == 3 && $0.width == 640 && $0.height == 360 && $0.milliseconds > 0 }
        try check(started.duration > 30000, "Duration did not come from the media")
        try check(!surface.subviews.isEmpty, "VLC did not attach a video view inside the supplied NSView")
        print("Embedded VLC: \(started.width)x\(started.height), duration \(started.duration) ms")
        let subtitles = fixture.deletingLastPathComponent().appendingPathComponent("test-subtitles.srt")
        try "1\n00:00:00,000 --> 00:00:34,000\nMacTV subtitle fixture\n".write(to: subtitles, atomically: true, encoding: .utf8)
        backend.addSubtitle(subtitles)
        let withSubtitles = try await wait(backend, "External subtitle file did not appear") { $0.subtitles.contains { $0.id >= 0 } }
        let track = withSubtitles.subtitles.first { $0.id >= 0 }!
        backend.subtitle(track.id)
        _ = try await wait(backend, "Subtitle track selection failed") { $0.subtitleID == track.id }
        backend.subtitle(-1)
        _ = try await wait(backend, "Turning subtitles off failed") { $0.subtitleID == -1 }
        print("External subtitle loading, track enumeration, selection and Off passed")
        backend.pause(true)
        _ = try await wait(backend, "Pause failed") { $0.state == 4 }
        backend.seek(seconds: 12, absolute: true)
        _ = try await wait(backend, "Absolute seek failed") { abs($0.milliseconds - 12000) < 1800 }
        backend.mute()
        _ = try await wait(backend, "Mute failed") { $0.muted }
        backend.volume(35)
        _ = try await wait(backend, "Volume failed") { $0.volume == 35 && $0.muted }
        backend.volume(0); backend.mute(); backend.play()
        _ = try await wait(backend, "Resume failed") { $0.state == 3 && !$0.muted && $0.volume == 0 }
        backend.seek(seconds: 8)
        _ = try await wait(backend, "Relative seek failed") { $0.milliseconds > 18000 }
        await close(backend)
        try check(surface.subviews.isEmpty, "Video subview survived stop/release")
        print("Pause, seek, volume, mute, resume and stop/release passed")

        let bad = VLCBackend()
        let missingError = await open(bad, folder.appendingPathComponent("missing.mkv"), view: surface)
        try check(missingError != nil, "Missing media must produce an error")
        await close(bad)

        if CommandLine.arguments.count > 2 {
            let actual = MovieLibrary.scan(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            try check(actual.error == nil && !actual.movies.isEmpty, "Actual Movies folder could not be read")
            print("Actual Movies library: \(actual.movies.count) video files")
            if let movie = actual.movies.first(where: { $0.format == "MKV" }) {
                let mkv = VLCBackend()
                let mkvError = await open(mkv, movie.url, view: surface)
                try check(mkvError == nil, mkvError ?? "MKV open failed")
                let decoded = try await wait(mkv, "Actual MKV did not decode") { $0.state == 3 && $0.width > 0 && $0.height > 0 }
                print("Actual MKV decoded inside NSView: \(decoded.width)x\(decoded.height)")
                await close(mkv)
            }
        }
        window.orderOut(nil)
    }
}
