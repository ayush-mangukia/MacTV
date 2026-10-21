import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class MoviePlayer {
    let movie: LocalMovie
    private(set) var snapshot = VLCSnapshot()
    private(set) var error: String?
    var waitingForAudio = false
    var audioNotice: String?
    private(set) var started = false
    private(set) var closed = false
    private(set) var controlsVisible = true
    var controlsFocused = false
    var controlIndex = 2
    var hoveringControls = false
    @ObservationIgnored private var controlsUntil = Date.now.addingTimeInterval(3)
    func revealControls(now: Date = .now) { controlsVisible = true; controlsUntil = now.addingTimeInterval(3) }
    func hideControls() { controlsFocused = false; controlsVisible = !playing }
    func updateControls(now: Date = .now) {
        if !playing || error != nil { controlsVisible = true }
        else if !hoveringControls && !controlsFocused && now >= controlsUntil { controlsVisible = false; controlsFocused = false }
    }
    let history: PlaybackHistory
    let systemVolume: SystemVolume
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var checkpoint = Date.distantPast
    @ObservationIgnored private var completed = false
    @ObservationIgnored let surface = MovieVideoSurface()
    @ObservationIgnored private let backend = VLCBackend()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var openedAt: Date?
    init(movie: LocalMovie, history: PlaybackHistory? = nil, systemVolume: SystemVolume? = nil) {
        self.movie = movie; self.history = history ?? PlaybackHistory(); self.systemVolume = systemVolume ?? SystemVolume(); surface.owner = self
    }
    func accept(_ sample: VLCSnapshot, now: Date = .now) {
        guard !closed else { return }
        let duration = max(sample.duration, snapshot.duration)
        snapshot = sample
        systemVolume.refresh()
        if sample.state == 6, !completed {
            completed = true
            history.save(movie, seconds: Double(duration) / 1000, duration: Double(duration) / 1000, completed: true)
            onEnded?()
            return
        }
        if !restored, sample.seekable, sample.duration > 0 {
            restored = true
            let seconds = history.position(movie)
            if seconds > 0, seconds < Double(sample.duration) / 1000 - 5 {
                backend.seek(seconds: seconds, absolute: true)
                checkpoint = now
                return
            }
        }
        if restored, now.timeIntervalSince(checkpoint) >= 5 { saveProgress(); checkpoint = now }
    }
    func saveProgress() {
        guard restored, !completed, snapshot.milliseconds >= 1000 else { return }
        history.save(movie, seconds: Double(snapshot.milliseconds) / 1000, duration: Double(snapshot.duration) / 1000)
    }
    var subtitleLabel: String { snapshot.subtitles.first { $0.id == snapshot.subtitleID }?.name ?? "Off" }
    func selectSubtitle(_ id: Int32) { backend.subtitle(id); revealControls() }
    func restart() {
        history.restart(movie); checkpoint = .now; snapshot.milliseconds = 0
        backend.seek(seconds: 0, absolute: true); revealControls()
    }
    func cycleSubtitle() {
        let tracks = [VLCSubtitle(id: -1, name: "Off")] + snapshot.subtitles.filter { $0.id != -1 }
        let current = tracks.firstIndex { $0.id == snapshot.subtitleID } ?? 0
        selectSubtitle(tracks[(current + 1) % tracks.count].id)
    }
    func chooseSubtitleFile(window: NSWindow?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "srt")!, .init(filenameExtension: "ass")!, .init(filenameExtension: "vtt")!]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.backend.addSubtitle(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
    var playing: Bool { snapshot.state == 3 }
    var busy: Bool { error == nil && (!started || snapshot.state == 0 || snapshot.state == 1 || snapshot.state == 2) }
    var status: String {
        if let error { return error }
        switch snapshot.state {
        case 3: return "Playing · VLC"
        case 4: return "Paused · VLC"
        case 6: return "Finished · VLC"
        case 7: return "VLC could not decode this video. Return to Movies and try another file."
        default: return "Opening with VLC…"
        }
    }
    func startIfAttached() {
        guard !waitingForAudio, !started, !closed, surface.window != nil else { return }
        started = true; openedAt = Date()
        backend.open(movie.url, drawable: Unmanaged.passUnretained(surface).toOpaque()) { [weak self] message in
            guard let self, !self.closed else { return }
            self.error = message
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.backend.sample { [weak self] snapshot in
                    guard let self, !self.closed else { return }
                    self.accept(snapshot)
                    guard !self.closed else { return }
                    self.updateControls()
                    if snapshot.state == 7 { self.error = "VLC could not play this video. Return to Movies and try another file." }
                    if self.busy, let openedAt = self.openedAt, Date().timeIntervalSince(openedAt) > 25 {
                        self.error = "VLC is taking too long to open this file. Return to Movies and retry, or check the file in VLC."
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
    func toggle() { saveProgress(); revealControls(); backend.toggle() }
    func play() { backend.play() }
    func pause() { saveProgress(); revealControls(); backend.pause(true) }
    func seek(_ seconds: Double) { revealControls(); backend.seek(seconds: seconds) }
    func setTime(_ seconds: Double) { backend.seek(seconds: seconds, absolute: true) }
    func changeVolume(_ delta: Int32) { systemVolume.change(Double(delta)) }
    func setVolume(_ value: Double) { systemVolume.set(value) }
    func mute() { systemVolume.toggleMute() }
    func stop() {
        guard !closed else { return }
        saveProgress()
        closed = true; poll?.cancel(); poll = nil
        // Keep the drawable alive until VLC finishes tearing its NSView down off the main thread.
        backend.close { [self] in snapshot = VLCSnapshot(); surface.owner = nil }
    }
}

final class MovieVideoSurface: NSView {
    weak var owner: MoviePlayer?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.startIfAttached() }
}

struct VLCVideoView: NSViewRepresentable {
    let player: MoviePlayer
    func makeNSView(context: Context) -> MovieVideoSurface { player.surface }
    func updateNSView(_ nsView: MovieVideoSurface, context: Context) { player.startIfAttached() }
}

struct MoviePlayerView: View {
    let model: MacTVModel
    let player: MoviePlayer
    @State private var compact = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    var body: some View {
        ZStack {
            Color.black
            VLCVideoView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
            if player.busy { ProgressView().padding(20).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16)) }
            if let error = player.error {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 540)
                    Button("Back to Movies") { model.closeMovie() }
                }.padding(30).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
            }
            if player.controlsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Text(player.movie.title).font(.system(size: compact ? 20 : 28, weight: .bold)).lineLimit(1)
                        Spacer()
                        Text(player.status).font(.caption).foregroundStyle(.secondary)
                    }.padding(30).background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 16) {
                        HStack {
                            Text(clock(scrubbing ? scrub : Double(player.snapshot.milliseconds) / 1000)).monospacedDigit()
                            Slider(value: Binding(get: { scrubbing ? scrub : Double(player.snapshot.milliseconds) / 1000 }, set: { scrub = $0; if !scrubbing { player.setTime($0) }; player.revealControls() }),
                                   in: 0...max(1, Double(player.snapshot.duration) / 1000), onEditingChanged: { editing in
                                player.hoveringControls = editing
                                if editing { scrub = Double(player.snapshot.milliseconds) / 1000; scrubbing = true }
                                else { scrubbing = false; player.setTime(scrub); player.revealControls() }
                            }).disabled(!player.snapshot.seekable || player.error != nil).accessibilityLabel("Playback position")
                            Text(clock(Double(player.snapshot.duration) / 1000)).monospacedDigit()
                        }
                        HStack(spacing: 14) {
                            control(0, "Movies", "chevron.left")
                            control(1, "−10s", "gobackward.10")
                            control(2, player.playing ? "Pause" : "Play", player.playing ? "pause.fill" : "play.fill")
                            control(3, "+10s", "goforward.10")
                            Spacer(minLength: 4)
                            control(5, "Fullscreen", "arrow.up.left.and.arrow.down.right")
                            control(6, "Home", "house")
                            Menu {
                                Button("Off") { player.selectSubtitle(-1) }
                                ForEach(player.snapshot.subtitles.filter { $0.id != -1 }) { track in
                                    Button((track.id == player.snapshot.subtitleID ? "✓ " : "") + track.name) { player.selectSubtitle(track.id) }
                                }
                                Divider()
                                Button("Open subtitle file…") { player.chooseSubtitleFile(window: model.window) }
                            } label: { Label("Subtitles", systemImage: "captions.bubble").padding(10) }
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(player.controlsFocused && player.controlIndex == 7 ? Color.mint : .clear, lineWidth: 2))
                            .help(player.subtitleLabel)
                        }
                        Text("Subtitles: \(player.subtitleLabel)").font(.caption).foregroundStyle(.secondary)
                        Text("Phone: ↑ / Player controls shows buttons · ← → choose · OK select · ↓ hide · Back returns to library")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(28).background(LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                        .onHover { if $0 { player.revealControls() } }
                }.transition(.opacity)
            }
        }.background(.black).foregroundStyle(.white).ignoresSafeArea()
            .background { GeometryReader { geometry in
                Color.clear.onAppear { compact = geometry.size.width < 1100 }
                    .onChange(of: geometry.size.width) { _, width in compact = width < 1100 }
            } }
            .animation(model.reducedMotion ? nil : .easeOut(duration: 0.2), value: player.controlsVisible)
    }
    private func control(_ index: Int, _ title: String, _ symbol: String) -> some View {
        Button { model.performMovieAction(index, player: player) } label: {
            Label(title, systemImage: symbol).font(.system(size: compact ? 14 : 20, weight: .semibold)).padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 12 : 16)
        }.buttonStyle(TVButtonStyle(selected: player.controlsFocused && player.controlIndex == index)).focusable(false)
    }
    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}
