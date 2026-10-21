import Foundation
import Darwin

// The installed VLC 3 library's public C ABI. No VLC executable or remote-control port is launched.
nonisolated final class VLCAPI: @unchecked Sendable {
    typealias Pointer = OpaquePointer
    typealias New = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Pointer?
    typealias Release = @convention(c) (Pointer?) -> Void
    typealias NewPlayer = @convention(c) (Pointer?) -> Pointer?
    typealias NewMedia = @convention(c) (Pointer?, UnsafePointer<CChar>?) -> Pointer?
    typealias SetMedia = @convention(c) (Pointer?, Pointer?) -> Void
    typealias SetDrawable = @convention(c) (Pointer?, UnsafeMutableRawPointer?) -> Void
    typealias GetInt = @convention(c) (Pointer?) -> Int32
    typealias SetInt = @convention(c) (Pointer?, Int32) -> Void
    typealias SetUInt = @convention(c) (Pointer?, UInt32) -> Void
    typealias Volume = @convention(c) (Pointer?, Int32) -> Int32
    typealias GetTime = @convention(c) (Pointer?) -> Int64
    typealias SetTime = @convention(c) (Pointer?, Int64) -> Void
    typealias VideoSize = @convention(c) (Pointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    typealias GetTracks = @convention(c) (Pointer?) -> UnsafeMutableRawPointer?
    typealias FreeTracks = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias AddSlave = @convention(c) (Pointer?, Int32, UnsafePointer<CChar>?, Bool) -> Int32
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    static let installed: Result<VLCAPI, Error> = Result { try VLCAPI() }
    let library: UnsafeMutableRawPointer
    let version: String
    let new: New, release: Release, mediaRelease: Release, playerRelease: Release, stop: Release
    let playerNew: NewPlayer, mediaNew: NewMedia, setMedia: SetMedia, setDrawable: SetDrawable
    let play: GetInt, state: GetInt, seekable: GetInt, getVolume: GetInt, getMute: GetInt
    let setPause: SetInt, setMute: SetInt, setVolume: Volume, getTime: GetTime, getLength: GetTime, setTime: SetTime
    let subtitleDescriptions: GetTracks, releaseDescriptions: FreeTracks
    let getSubtitle: GetInt, setSubtitle: Volume, addSlave: AddSlave
    let videoSize: VideoSize
    let setMouseInput: SetUInt, setKeyInput: SetUInt

    private init() throws {
        let root = "/Applications/VLC.app/Contents/MacOS"
        guard let handle = dlopen(root + "/lib/libvlc.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw VLCFailure.message("VLC could not be loaded. Install VLC 3 for this Mac in /Applications/VLC.app, then restart MacTV.")
        }
        library = handle
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw VLCFailure.message("The installed VLC is missing \(name). Reinstall VLC 3.") }
            return unsafeBitCast(address, to: T.self)
        }
        let versionFunction = try symbol("libvlc_get_version", Version.self)
        version = versionFunction().map { String(cString: $0) } ?? "Unknown"
        guard version.hasPrefix("3.") else { throw VLCFailure.message("MacTV's installed-VLC adapter requires VLC 3. Installed version: \(version)") }
        new = try symbol("libvlc_new", New.self)
        release = try symbol("libvlc_release", Release.self)
        mediaRelease = try symbol("libvlc_media_release", Release.self)
        playerRelease = try symbol("libvlc_media_player_release", Release.self)
        stop = try symbol("libvlc_media_player_stop", Release.self)
        playerNew = try symbol("libvlc_media_player_new", NewPlayer.self)
        mediaNew = try symbol("libvlc_media_new_path", NewMedia.self)
        setMedia = try symbol("libvlc_media_player_set_media", SetMedia.self)
        setDrawable = try symbol("libvlc_media_player_set_nsobject", SetDrawable.self)
        play = try symbol("libvlc_media_player_play", GetInt.self)
        state = try symbol("libvlc_media_player_get_state", GetInt.self)
        seekable = try symbol("libvlc_media_player_is_seekable", GetInt.self)
        getVolume = try symbol("libvlc_audio_get_volume", GetInt.self)
        getMute = try symbol("libvlc_audio_get_mute", GetInt.self)
        setPause = try symbol("libvlc_media_player_set_pause", SetInt.self)
        setMute = try symbol("libvlc_audio_set_mute", SetInt.self)
        setVolume = try symbol("libvlc_audio_set_volume", Volume.self)
        getTime = try symbol("libvlc_media_player_get_time", GetTime.self)
        getLength = try symbol("libvlc_media_player_get_length", GetTime.self)
        setTime = try symbol("libvlc_media_player_set_time", SetTime.self)
        subtitleDescriptions = try symbol("libvlc_video_get_spu_description", GetTracks.self)
        releaseDescriptions = try symbol("libvlc_track_description_list_release", FreeTracks.self)
        getSubtitle = try symbol("libvlc_video_get_spu", GetInt.self)
        setSubtitle = try symbol("libvlc_video_set_spu", Volume.self)
        addSlave = try symbol("libvlc_media_player_add_slave", AddSlave.self)
        videoSize = try symbol("libvlc_video_get_size", VideoSize.self)
        setMouseInput = try symbol("libvlc_video_set_mouse_input", SetUInt.self)
        setKeyInput = try symbol("libvlc_video_set_key_input", SetUInt.self)
        // VLC locates its own codec plugins alongside the installed library.
        setenv("VLC_PLUGIN_PATH", root + "/plugins", 1)
        // Keep the library loaded for the process lifetime: VLC's plugins can outlive individual players.
    }
}

nonisolated enum VLCFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

nonisolated struct VLCSubtitle: Sendable, Equatable, Identifiable { let id: Int32; let name: String }
nonisolated private struct VLCTrackDescription { var id: Int32; var name: UnsafePointer<CChar>?; var next: UnsafeMutableRawPointer? }

nonisolated struct VLCSnapshot: Sendable {
    var subtitles: [VLCSubtitle] = []
    var subtitleID: Int32 = -1
    var state: Int32 = 0
    var milliseconds: Int64 = 0
    var duration: Int64 = 0
    var volume: Int32 = 100
    var muted = false
    var seekable = false
    var width: UInt32 = 0
    var height: UInt32 = 0
}

// Every libVLC call is serialized off the main thread. In particular stop/release must not block
// AppKit while VLC is asking the main thread to remove its video subview.
nonisolated final class VLCBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacTV.VLC", qos: .userInitiated)
    private var api: VLCAPI?
    private var instance: OpaquePointer?
    private var player: OpaquePointer?
    private var closed = false
    func open(_ file: URL, drawable: UnsafeMutableRawPointer, initialVolume: Int32 = 100,
              completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let handle = Drawable(pointer: drawable)
        queue.async {
            guard !self.closed else { return }
            do {
                guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else {
                    throw VLCFailure.message("This video is missing or unreadable. Refresh Movies or choose the folder again.")
                }
                let api = try VLCAPI.installed.get(); self.api = api
                let arguments = ["--no-video-title-show", "--no-osd", "--vout=macosx"]
                let allocated = arguments.map { strdup($0) }
                defer { allocated.forEach { free($0) } }
                let argv = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
                guard let instance = argv.withUnsafeBufferPointer({ api.new(Int32(argv.count), $0.baseAddress) }) else {
                    throw VLCFailure.message("VLC could not initialize its plugins. Reinstall VLC 3 and restart MacTV.")
                }
                self.instance = instance
                guard let player = api.playerNew(instance) else { throw VLCFailure.message("VLC could not create a player.") }
                self.player = player
                guard let media = file.withUnsafeFileSystemRepresentation({ api.mediaNew(instance, $0) }) else { throw VLCFailure.message("VLC could not open this video.") }
                api.setDrawable(player, handle.pointer)
                api.setMouseInput(player, 0); api.setKeyInput(player, 0)
                api.setMedia(player, media); api.mediaRelease(media)
                _ = api.setVolume(player, min(100, max(0, initialVolume)))
                guard api.play(player) == 0 else { throw VLCFailure.message("VLC could not start playback. Try another video or reinstall VLC.") }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.shutdown()
                let message = error.localizedDescription
                DispatchQueue.main.async { completion(message) }
            }
        }
    }
    func sample(_ completion: @escaping @MainActor @Sendable (VLCSnapshot) -> Void) {
        queue.async {
            guard !self.closed, let api = self.api, let player = self.player else { return }
            var width: UInt32 = 0, height: UInt32 = 0
            _ = api.videoSize(player, 0, &width, &height)
            var tracks: [VLCSubtitle] = []
            let list = api.subtitleDescriptions(player)
            var cursor = list
            while let node = cursor, tracks.count < 256 {
                let item = node.load(as: VLCTrackDescription.self)
                tracks.append(VLCSubtitle(id: item.id, name: item.name.map { String(cString: $0) } ?? "Track \(item.id)"))
                cursor = item.next
            }
            api.releaseDescriptions(list)
            let sample = VLCSnapshot(subtitles: tracks, subtitleID: api.getSubtitle(player),state: api.state(player), milliseconds: max(0, api.getTime(player)),
                duration: max(0, api.getLength(player)), volume: max(0, api.getVolume(player)), muted: api.getMute(player) == 1,
                seekable: api.seekable(player) == 1, width: width, height: height)
            DispatchQueue.main.async { completion(sample) }
        }
    }
    func subtitle(_ id: Int32) { perform { api, player in _ = api.setSubtitle(player, id) } }
    func addSubtitle(_ url: URL) {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return }
        perform { api, player in _ = url.absoluteString.withCString { api.addSlave(player, 0, $0, true) } }
    }
    func pause(_ paused: Bool) { perform { $0.setPause($1, paused ? 1 : 0) } }
    func play() { perform { api, player in
        if api.state(player) == 6 { api.stop(player) }
        _ = api.play(player)
    } }
    func toggle() { perform { api, player in
        if api.state(player) == 3 { api.setPause(player, 1) }
        else { if api.state(player) == 6 { api.stop(player) }; _ = api.play(player) }
    } }
    func seek(seconds: Double, absolute: Bool = false) {
        guard seconds.isFinite else { return }
        perform { api, player in
            guard api.seekable(player) == 1 else { return }
            let target = (absolute ? 0 : Double(api.getTime(player))) + seconds * 1000
            let end = api.getLength(player)
            api.setTime(player, Int64(min(Double(max(0, end - 1)), max(0, target))))
        }
    }
    func volume(_ value: Int32, relative: Bool = false) {
        perform { api, player in _ = api.setVolume(player, min(100, max(0, value + (relative ? api.getVolume(player) : 0)))) }
    }
    func mute() { perform { $0.setMute($1, $0.getMute($1) == 1 ? 0 : 1) } }
    private func perform(_ action: @escaping @Sendable (VLCAPI, OpaquePointer) -> Void) {
        queue.async { if !self.closed, let api = self.api, let player = self.player { action(api, player) } }
    }
    func close(_ completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { self.closed = true; self.shutdown(); DispatchQueue.main.async { completion() } }
    }
    private func shutdown() {
        if let api {
            if let player { api.stop(player); api.setDrawable(player, nil); api.playerRelease(player) }
            if let instance { api.release(instance) }
        }
        player = nil; instance = nil
    }
    private struct Drawable: @unchecked Sendable { let pointer: UnsafeMutableRawPointer }
}
