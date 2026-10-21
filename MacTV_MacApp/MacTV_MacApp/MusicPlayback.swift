import AppKit
import SwiftUI
import Observation

nonisolated enum MusicSource: String, CaseIterable, Identifiable, Sendable {
    case spotify
    var id: String { rawValue }
    var title: String { "Spotify" }
    var bundleID: String { "com.spotify.client" }
}

nonisolated struct MusicTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var artworkURL: URL?
    var artworkData: Data?
}

/// Public, fixed AppleScript commands only. Never starts an app just to poll it.
/// Work is serialized off the UI thread, including macOS Automation permission prompts.
nonisolated enum MusicScripting {
    private static let queue = DispatchQueue(label: "MacTV.MusicPlayback")
    static func perform(source: MusicSource, action: String?, completion: @escaping @Sendable (MusicTrack?, String?) -> Void) {
        queue.async {
            let command: String
            switch action {
            case "play_pause": command = "playpause"
            case "previous": command = "previous track"
            case "next": command = "next track"
            case nil: command = ""
            default: completion(nil, "Unsupported music control"); return
            }
            let artwork = "set cover to artwork url of current track"
            let script = """
            with timeout of 3 seconds
                tell application id "\(source.bundleID)"
                    \(command)
                    if player state is stopped then return {"", "", "", false, ""}
                    set cover to ""
                    \(artwork)
                    return {name of current track, artist of current track, album of current track, player state is playing, cover}
                end tell
            end timeout
            """
            var error: NSDictionary?
            guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil else {
                let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
                completion(nil, denied ? "Allow MacTV to control \(source.title) in Privacy & Security → Automation." : "\(source.title) is unavailable. Open it and select a track.")
                return
            }
            let title = result.atIndex(1)?.stringValue ?? ""
            guard !title.isEmpty else { completion(nil, nil); return }
            let art = result.atIndex(5)
            let url = source == .spotify ? art?.stringValue.flatMap(URL.init(string:)) : nil
            let data: Data? = nil
            completion(MusicTrack(title: title, artist: result.atIndex(2)?.stringValue ?? "", album: result.atIndex(3)?.stringValue ?? "", playing: result.atIndex(4)?.booleanValue ?? false, artworkURL: url?.scheme == "https" ? url : nil, artworkData: data), nil)
        }
    }
}

@MainActor @Observable final class MusicPlayback {
    var source: MusicSource = .spotify
    var track: MusicTrack?
    var notice: String?
    var busy = false
    var running: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).contains { !$0.isTerminated } }
    private var generation = 0
    func select(_ value: MusicSource) {
        guard value != source else { return }
        source = value; generation += 1; track = nil; notice = nil; busy = false
        refresh()
    }
    func observe() async {
        while !Task.isCancelled {
            refresh()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
    func refresh() { perform(nil) }
    func control(_ action: String) { perform(action) }
    private func perform(_ action: String?) {
        guard !busy else { return }
        guard running else { track = nil; notice = nil; return }
        busy = true
        let expected = generation
        MusicScripting.perform(source: source, action: action) { [weak self] track, notice in
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.busy = false; self.track = track; self.notice = notice
            }
        }
    }
    func open() {
        let preferred = "/Applications/Spotify.app"
        let url = URL(fileURLWithPath: preferred)
        guard Bundle(url: url)?.bundleIdentifier == source.bundleID else { notice = "Install \(source.title) to play music."; return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

struct MusicBar: View {
    let playback: MusicPlayback
    var selectedControl: Int? = nil
    var body: some View {
        HStack(spacing: 16) {
            artwork.frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(playback.track?.title ?? "Your music, always within reach")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(playback.notice ?? playback.track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "Open \(playback.source.title) and choose a track")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                musicButton("Previous track", symbol: "backward.end.fill", action: "previous")
                musicButton(playback.track?.playing == true ? "Pause music" : "Play music", symbol: playback.track?.playing == true ? "pause.fill" : "play.fill", action: "play_pause", prominent: true)
                musicButton("Next track", symbol: "forward.end.fill", action: "next")
            }
            Divider().frame(height: 32).padding(.horizontal, 8)
            Button { playback.open() } label: {
                Label("Spotify", systemImage: "music.note").font(.system(size: 14, weight: .medium))
            }.buttonStyle(.plain).help("Open Spotify")

        }
        .padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
        .task { await playback.observe() }
    }
    @ViewBuilder private var artwork: some View {
        if let data = playback.track?.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = playback.track?.artworkURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else { placeholder }
    }
    private var placeholder: some View {
        ZStack { Color.mint.opacity(0.12); Image(systemName: "music.note").font(.system(size: 25)).foregroundStyle(.mint) }
    }
    private func musicButton(_ label: String, symbol: String, action: String, prominent: Bool = false) -> some View {
        Button { playback.control(action) } label: {
            Image(systemName: symbol).font(.system(size: prominent ? 21 : 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .foregroundStyle(prominent ? Color.black : .white)
                .background(prominent ? Color.mint : .white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
        .overlay(Circle().stroke(selectedControl == ["previous": 0, "play_pause": 1, "next": 2][action] ? Color.mint : .clear, lineWidth: 3).padding(-4))
        .disabled(playback.busy || playback.track == nil)
    }
}
