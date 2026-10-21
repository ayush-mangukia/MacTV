import SwiftUI
import AppKit

/// Three useful things at a glance, with equal-height cards and no duplicate player.
struct HomeDashboard: View {
    let model: MacTVModel
    let availableWidth: CGFloat
    var body: some View {
        let dashboardHeight = min(620, max(460, availableWidth * 0.32))
        let cardHeight = dashboardHeight - 38
        let columnsWidth = max(0, availableWidth - 36)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                dashboardHeading("Continue Watching", symbol: "clock.arrow.circlepath")
                ContinueWatchingPoster(model: model).frame(height: cardHeight)
            }.frame(width: columnsWidth * 0.25).id(MacTVModel.Area.continueWatching)
            VStack(alignment: .leading, spacing: 14) {
                dashboardHeading("Now Playing", symbol: "music.note")
                MusicDashboardCard(playback: model.music, reducedMotion: model.reducedMotion, selectedControl: model.area == .music ? model.musicIndex : nil).frame(height: cardHeight)
            }.frame(width: columnsWidth * 0.25).id(MacTVModel.Area.music)
            VStack(alignment: .leading, spacing: 14) {
                dashboardHeading("Weather", symbol: "cloud.sun")
                WeatherSummaryCard(weather: model.weather, onRadar: model.openRadar, selected: model.area == .weather, selectedAction: model.area == .weather ? model.weatherIndex : nil).frame(height: cardHeight)
            }.frame(width: columnsWidth * 0.5).id(MacTVModel.Area.weather)
        }.frame(height: dashboardHeight)
    }
    private func dashboardHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 20, weight: .semibold)).labelStyle(.titleOnly)
    }
}

struct ContinueWatchingPoster: View {
    let model: MacTVModel
    private var movie: LocalMovie? { model.continueMovies.first }
    var body: some View {
        GeometryReader { size in
            if let movie {
                Button { model.playMovie(movie) } label: {
                    ZStack(alignment: .bottomLeading) {
                        if let collection = model.collection(for: movie) {
                            CollectionCover(title: collection, metadata: model.metadata.records[collection.id]).id(collection.id)
                                .frame(width: size.size.width, height: size.size.height)
                        }
                        LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.4), location: 0.6), .init(color: .black.opacity(0.95), location: 1)], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(movie.title).font(.system(size: 23, weight: .semibold)).lineLimit(3)
                            if movie.info.isSeries { Text("S\(movie.info.season ?? 1) · E\(movie.info.episode ?? 1)").font(.callout).foregroundStyle(.white.opacity(0.7)) }
                            HStack {
                                Text(model.history.label(movie)).font(.system(size: 14, weight: .medium)).foregroundStyle(.mint)
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill").font(.system(size: 32)).foregroundStyle(.mint)
                            }
                            if let entry = model.history.entries[model.history.key(movie)] {
                                ProgressView(value: min(entry.duration, entry.seconds), total: max(1, entry.duration)).tint(.mint).accessibilityHidden(true)
                            }
                        }.padding(22)
                    }.frame(width: size.size.width, height: size.size.height).clipShape(RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).focusable(false).accessibilityLabel("Resume \(movie.title), \(model.history.label(movie))")

            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Spacer()
                    Image(systemName: "play.rectangle").font(.system(size: 42, weight: .light)).foregroundStyle(.mint)
                    Text("Pick up where you left off").font(.title2.weight(.semibold))
                    Text("Your latest unfinished movie or episode will appear here.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(24).frame(width: size.size.width, height: size.size.height, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            }
        }.overlay(RoundedRectangle(cornerRadius: 18).stroke(model.area == .continueWatching ? Color.mint : .white.opacity(0.075), lineWidth: model.area == .continueWatching ? 2 : 1))
    }
}

struct MusicDashboardCard: View {
    let playback: MusicPlayback
    var reducedMotion = false
    var selectedControl: Int?
    var body: some View {
        GeometryReader { size in
            let artworkSize = max(80, min(size.size.width - 40, size.size.height - 170))
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                ZStack(alignment: .trailing) {
                    VinylRecord(track: playback.track, reducedMotion: reducedMotion)
                        .frame(width: artworkSize * 0.88, height: artworkSize * 0.88)
                        .offset(x: artworkSize * 0.08)
                    AlbumCover(track: playback.track)
                        .frame(width: artworkSize * 0.82, height: artworkSize * 0.82)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.4), radius: 15, y: 8)
                        .offset(x: -artworkSize * 0.16)
                }.frame(width: artworkSize, height: artworkSize)
                Spacer(minLength: 0)
                VStack(spacing: 5) {
                    Text(playback.track?.title ?? "Set the soundtrack")
                        .font(.system(size: 21, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(playback.track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "Choose a track in Spotify")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                }
                HStack(spacing: 20) {
                    control("Previous track", symbol: "backward.end.fill", index: 0)
                    control(playback.track?.playing == true ? "Pause music" : "Play music", symbol: playback.track?.playing == true ? "pause.fill" : "play.fill", index: 1)
                    control("Next track", symbol: "forward.end.fill", index: 2)
                }.padding(.top, 5)
                if let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.padding(20).frame(width: size.size.width, height: size.size.height)
        }
        .background(LinearGradient(colors: [Color.mint.opacity(0.10), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.075)))
        .task { await playback.observe() }
    }
    private func control(_ label: String, symbol: String, index: Int) -> some View {
        Button {
            if playback.track == nil { playback.open() } else { playback.control(["previous", "play_pause", "next"][index]) }
        } label: {
            Image(systemName: symbol).font(.system(size: index == 1 ? 19 : 15, weight: .semibold))
                .frame(width: 38, height: 38).foregroundStyle(index == 1 ? Color.black : .white)
                .background(index == 1 ? Color.mint : .white.opacity(0.06), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
            .disabled(playback.busy || (index != 1 && playback.track == nil))
            .overlay(Circle().stroke(selectedControl == index ? Color.mint : .clear, lineWidth: 3).padding(-4))
    }
}

struct VinylRecord: View {
    let track: MusicTrack?
    var reducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0
    @State private var started = Date()
    private var spinning: Bool { track?.playing == true && !reduceMotion && !reducedMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { context in
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.19), .black, Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(0..<8) { ring in
                    Circle().stroke(.white.opacity(ring % 2 == 0 ? 0.07 : 0.025), lineWidth: 1).padding(CGFloat(8 + ring * 5))
                }
                cover.frame(width: 53, height: 53).clipShape(Circle())
                Circle().fill(.black).frame(width: 7, height: 7).overlay(Circle().stroke(.white.opacity(0.3)))
            }
            .rotationEffect(.degrees(phase + (spinning ? context.date.timeIntervalSince(started) * 20 : 0)))
        }
        .onChange(of: spinning) { previous, current in
            let now = Date()
            if previous { phase = (phase + now.timeIntervalSince(started) * 20).truncatingRemainder(dividingBy: 360) }
            if current { started = now }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5).accessibilityHidden(true)
    }
    @ViewBuilder private var cover: some View {
        if let data = track?.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = track?.artworkURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.mint.opacity(0.6) }
        } else { ZStack { Color.mint.opacity(0.6); Image(systemName: "music.note").foregroundStyle(.black) } }
    }
}


struct AlbumCover: View {
    let track: MusicTrack?
    var body: some View {
        if let url = track?.artworkURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else { placeholder }
    }
    private var placeholder: some View {
        ZStack { LinearGradient(colors: [.mint.opacity(0.5), .teal.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 45)).foregroundStyle(.white.opacity(0.7)) }
    }
}
