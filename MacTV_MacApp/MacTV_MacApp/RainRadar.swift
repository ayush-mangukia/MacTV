import AppKit
import SwiftUI
import Observation

nonisolated struct RadarFrame: Codable, Equatable, Identifiable, Sendable {
    let time: Int
    let path: String
    var id: Int { time }
    var date: Date { Date(timeIntervalSince1970: Double(time)) }
    var label: String {
        let format = DateFormatter(); format.timeZone = TimeZone(identifier: "Europe/Berlin"); format.dateFormat = "HH:mm"
        return format.string(from: date)
    }
}
nonisolated struct RadarManifest: Decodable {
    struct Radar: Decodable { let past: [RadarFrame] }
    let host: String
    let radar: Radar
    var safeFrames: [RadarFrame] {
        guard URL(string: host)?.scheme == "https", URL(string: host)?.host == "tilecache.rainviewer.com" else { return [] }
        return Array(radar.past.filter { frame in
            frame.time > 0 && frame.path.range(of: #"^/v2/radar/[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil && frame.date <= Date().addingTimeInterval(60)
        }.sorted { $0.time < $1.time }.suffix(6))
    }
}

@MainActor @Observable final class RainRadar {
    var frames: [RadarFrame] = []
    var index = 0
    var playing = false
    var loading = false
    var notice: String?
    var tileNotice: String?
    var recenter = 0
    var revision = 0
    @ObservationIgnored private var attempted: Date?
    var frame: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }
    func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        index = (index + delta + frames.count) % frames.count
    }
    func load(force: Bool = false) async {
        guard !loading, force || attempted.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        loading = true; attempted = .now; defer { loading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.rainviewer.com/public/weather-maps.json")!); request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 100_000 else { throw URLError(.badServerResponse) }
            let manifest = try JSONDecoder().decode(RadarManifest.self, from: data)
            let available = manifest.safeFrames
            guard !available.isEmpty else { throw URLError(.cannotParseResponse) }
            frames = available; index = max(0, frames.count - 1); revision += 1; notice = nil; tileNotice = nil
        } catch { notice = frames.isEmpty ? "Rain radar is unavailable. Try refreshing shortly." : "Offline · showing the last available radar frames" }
    }
    func observe() async {
        await load()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
            if playing { step(1) }
            await load()
        }
    }
}

/// Shared cache prevents animation loops from redownloading tiles. Limit first-load/pan
/// bursts to 60 new tile requests/minute, below the provider's public free-tier limit.
private actor RadarTileCache {
    static let shared = RadarTileCache()
    private var data: [URL: Data] = [:]
    private var requests: [Date] = []
    private var inflight: [URL: Task<Data?, Never>] = [:]
    func tile(_ url: URL) async -> Data? {
        if let cached = data[url] { return cached }
        if let existing = inflight[url] { return await existing.value }
        requests.removeAll { Date().timeIntervalSince($0) >= 60 }
        guard requests.count < 60 else { return nil }
        requests.append(.now)
        let operation = Task<Data?, Never> {
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000, NSImage(data: data) != nil else { return nil }
                return data
            } catch { return nil }
        }
        inflight[url] = operation
        let result = await operation.value
        inflight[url] = nil
        if let result {
            if data.count >= 180 { data.removeAll(keepingCapacity: true) }
            data[url] = result
        }
        return result
    }
}

/// A small raster map avoids relying on the system MapKit renderer, which can
/// remain blank on this Mac. Only tiles currently visible in the viewport load.
private actor RadarBasemapCache {
    static let shared = RadarBasemapCache()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16_000_000, diskCapacity: 80_000_000, diskPath: "MacTVRadarBasemap")
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }()
    private var cached: [URL: Data] = [:]
    private var inflight: [URL: Task<Data?, Never>] = [:]
    func tile(_ url: URL) async -> Data? {
        if let data = cached[url] { return data }
        if let task = inflight[url] { return await task.value }
        let session = session
        let task = Task<Data?, Never> {
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 12
                request.setValue("MacTV/1.0 (personal macOS weather dashboard)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 1_000_000, NSImage(data: data) != nil else { return nil }
                return data
            } catch { return nil }
        }
        inflight[url] = task
        let value = await task.value; inflight[url] = nil
        if let value {
            if cached.count >= 64 { cached.removeAll(keepingCapacity: true) }
            cached[url] = value
        }
        return value
    }
}

nonisolated struct RadarMapPosition {
    let x: Double
    let y: Double
    init(latitude: Double, longitude: Double, zoom: Int) {
        let scale = pow(2.0, Double(zoom))
        let lat = min(85.0511, max(-85.0511, latitude)) * .pi / 180
        x = (longitude + 180) / 360 * scale
        y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * scale
    }
}
private struct RadarMapTile: Identifiable {
    let x: Int, y: Int, z: Int
    let centre: CGPoint
    var id: String { "\(z)/\(x)/\(y)" }
}
private struct RadarRasterCell: View {
    let tile: RadarMapTile
    let framePath: String?
    let revision: Int
    let radar: RainRadar
    @State private var base: NSImage?
    @State private var rain: NSImage?
    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let base { Image(nsImage: base).resizable().interpolation(.high).colorInvert().hueRotation(.degrees(180)).saturation(0.15).brightness(-0.1) }
            if let rain { Image(nsImage: rain).resizable().interpolation(.high).opacity(0.8) }
        }
        .task(id: revision) {
            let url = URL(string: "https://tile.openstreetmap.org/\(tile.z)/\(tile.x)/\(tile.y).png")!
            let data = await RadarBasemapCache.shared.tile(url)
            guard !Task.isCancelled else { return }
            base = data.flatMap(NSImage.init(data:))
            if base == nil { radar.tileNotice = "Some map tiles could not load. Try again shortly." }
        }
        .task(id: "\(framePath ?? ""):\(revision)") {
            rain = nil
            guard let framePath else { return }
            let url = URL(string: "https://tilecache.rainviewer.com\(framePath)/256/\(tile.z)/\(tile.x)/\(tile.y)/2/1_1.png")!
            let data = await RadarTileCache.shared.tile(url)
            guard !Task.isCancelled else { return }
            rain = data.flatMap(NSImage.init(data:))
            if rain == nil { radar.tileNotice = "Some radar tiles could not load. Pause and refresh, or try again shortly." }
        }
    }
}
struct RainRadarMap: View {
    let radar: RainRadar
    @State private var zoom = 7
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    // Upscaling keeps the public radar at its supported maximum zoom of 7 and
    // bounds the initial six-frame animation to at most 36 visible radar tiles.
    private let tilePoints: CGFloat = 512
    private var city: RadarMapPosition { RadarMapPosition(latitude: 47.9959, longitude: 7.85222, zoom: zoom) }
    private var offset: CGSize { CGSize(width: pan.width + drag.width, height: pan.height + drag.height) }
    private func tiles(in size: CGSize) -> [RadarMapTile] {
        let cx = city.x - Double(offset.width / tilePoints)
        let cy = city.y - Double(offset.height / tilePoints)
        let left = Int(floor(cx - Double(size.width / (2 * tilePoints))))
        let right = Int(floor(cx + Double(size.width / (2 * tilePoints))))
        let top = Int(floor(cy - Double(size.height / (2 * tilePoints))))
        let bottom = Int(floor(cy + Double(size.height / (2 * tilePoints))))
        let maximum = (1 << zoom) - 1
        return (top...bottom).flatMap { y in (left...right).compactMap { x in
            guard (0...maximum).contains(x), (0...maximum).contains(y) else { return nil }
            return RadarMapTile(x: x, y: y, z: zoom, centre: CGPoint(x: size.width / 2 + CGFloat(Double(x) + 0.5 - cx) * tilePoints, y: size.height / 2 + CGFloat(Double(y) + 0.5 - cy) * tilePoints))
        } }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                ForEach(tiles(in: geometry.size)) { tile in
                    RadarRasterCell(tile: tile, framePath: radar.frame?.path, revision: radar.revision, radar: radar)
                        .frame(width: tilePoints, height: tilePoints).position(tile.centre)
                }
                VStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, .red)
                    Text("Freiburg").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.8), in: Capsule())
                }.position(x: geometry.size.width / 2 + offset.width, y: geometry.size.height / 2 + offset.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                pan = CGSize(width: min(1024, max(-1024, pan.width + value.translation.width)), height: min(1024, max(-1024, pan.height + value.translation.height)))
            })
            .overlay(alignment: .topTrailing) {
                HStack {
                    Button { zoom = max(5, zoom - 1); pan = .zero } label: { Image(systemName: "minus") }.disabled(zoom == 5).accessibilityLabel("Zoom out")
                    Button { zoom = min(7, zoom + 1); pan = .zero } label: { Image(systemName: "plus") }.disabled(zoom == 7).accessibilityLabel("Zoom in")
                }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    .font(.caption).padding(6).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(8)
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .onChange(of: radar.recenter) { _, _ in pan = .zero; zoom = 7 }
    }
}

struct RainRadarView: View {
    let radar: RainRadar
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Rain radar · Freiburg").font(.title.bold())
                    Text("Recent observed rain · Europe/Berlin").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Centre on Freiburg") { radar.recenter += 1 }
                Button { Task { await radar.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh radar").disabled(radar.loading)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            ZStack {
                RainRadarMap(radar: radar).clipShape(RoundedRectangle(cornerRadius: 16))
                if radar.loading && radar.frames.isEmpty { ProgressView("Loading rain radar…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }.frame(minHeight: 420)
            HStack(spacing: 14) {
                Button { radar.playing.toggle() } label: { Label(radar.playing ? "Pause" : "Play", systemImage: radar.playing ? "pause.fill" : "play.fill") }.disabled(radar.frames.isEmpty)
                Button { radar.playing = false; radar.step(-1) } label: { Image(systemName: "backward.frame.fill") }.accessibilityLabel("Previous radar frame")
                Slider(value: Binding(get: { Double(radar.index) }, set: { radar.playing = false; radar.index = Int($0) }), in: 0...Double(max(1, radar.frames.count - 1)), step: 1).disabled(radar.frames.isEmpty)
                Button { radar.playing = false; radar.step(1) } label: { Image(systemName: "forward.frame.fill") }.accessibilityLabel("Next radar frame")
                Text(radar.frame?.label ?? "—").font(.title3.monospacedDigit()).frame(width: 65)
            }
            HStack {
                Text("Light rain").font(.caption)
                LinearGradient(colors: [.cyan.opacity(0.4), .blue, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing).frame(width: 110, height: 8).clipShape(Capsule())
                Text("Heavier rain").font(.caption)
                Spacer()
                Link("Radar: RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
            }.foregroundStyle(.secondary)
            if let notice = radar.notice ?? radar.tileNotice { Text(notice).font(.callout).foregroundStyle(.orange) }
            if let frame = radar.frames.last, Date().timeIntervalSince(frame.date) > 1800 {
                Text("The latest radar image is more than 30 minutes old.").font(.callout).foregroundStyle(.orange)
            }
            Text("← → frames · OK play/pause · Back closes. Radar shows rainfall observations; the hourly cards show the forecast.").font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 1000, height: 720)
            .task { radar.playing = !reduceMotion; await radar.observe() }
            .onDisappear { radar.playing = false }
    }
}
