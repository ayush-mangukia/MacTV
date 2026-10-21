import SwiftUI

struct ContentView: View {
    let model: MacTVModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let inset = max(32, min(100, geometry.size.width * 0.055))
            ZStack {
                model.midnight ? Color.black : Color(red: 0.035, green: 0.043, blue: 0.055)
                VStack(alignment: .leading, spacing: 24) {
                    TopNavigation(model: model)
                    if model.showsSettings {
                        SettingsScreen(model: model)
                    } else if model.showsMovies {
                        MoviesLibraryView(model: model, library: model.movies)
                    } else {
                        HomeScreen(model: model, availableWidth: geometry.size.width - inset * 2)

                    }
                    Spacer(minLength: 0)
                    if model.showsMovies || model.showsSettings {
                        MusicBar(playback: model.music, selectedControl: model.area == .music ? model.musicIndex : nil)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, 30)
                .padding(.bottom, 24)
            }
            .animation(reduceMotion || model.reducedMotion ? nil : .easeInOut(duration: 0.22), value: model.selectedService)
            .animation(reduceMotion || model.reducedMotion ? nil : .easeInOut(duration: 0.18), value: model.showsSettings)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 640)
        .accessibilityHidden(model.moviePlayer != nil || model.browser != nil)
        .allowsHitTesting(model.moviePlayer == nil && model.browser == nil)
        .overlay {
            if let player = model.moviePlayer {
                MoviePlayerView(model: model, player: player)
            } else if let browser = model.browser {
                MediaBrowserView(model: model, session: browser)
            }
        }
        .overlay(alignment: .bottom) {
            if let next = model.nextEpisode {
                VStack(spacing: 12) {
                    Text("Up next in \(model.nextCountdown)s").font(.title2.bold())
                    Text("\(next.info.title) · S\(next.info.season ?? 1) E\(next.info.episode ?? 1)")
                    HStack {
                        Button("Play now · OK") { model.playNextEpisode() }.buttonStyle(.borderedProminent)
                        Button("Cancel · Back") { model.cancelNextEpisode() }
                    }
                }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(36)
            }
        }
        .overlay { RemotePointerView(pointer: model.pointer) }
        .background(WindowBridge(model: model))
        .task { model.startRemote() }
        .sheet(isPresented: Binding(get: { model.showsRadar }, set: { model.showsRadar = $0 })) {
            RainRadarView(radar: model.radar, close: { model.showsRadar = false })
        }
        .sheet(isPresented: Binding(
            get: { model.remote.pendingName != nil },
            set: { if !$0 { model.remote.approve(false) } }
        )) {
            VStack(spacing: 20) {
                Text("Pair Android remote?").font(.title2.bold())
                Text("\(model.remote.pendingName ?? "Android remote") has proved possession of your invitation. Approve only the phone you are pairing.")
                HStack {
                    Button("Reject", role: .cancel) { model.remote.approve(false) }
                    Button("Approve") { model.remote.approve(true) }.buttonStyle(.borderedProminent)
                }
            }.padding(32).frame(width: 420)
        }
        .alert("Unable to open service", isPresented: Binding(
            get: { model.launchError != nil },
            set: { if !$0 { model.launchError = nil } }
        )) {
            Button("OK") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
    }
}

struct TopNavigation: View {
    let model: MacTVModel
    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "tv.fill").foregroundStyle(.mint)
                Text("MacTV").fontWeight(.bold).tracking(-1)
            }
            .font(.system(size: 29))
            .padding(.trailing, 12)
            Button {
                model.handle(.home)
            } label: {
                Text("Home").font(.title3.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 12)
            }
            .buttonStyle(TVButtonStyle(selected: model.area == .navigation && model.navigationIndex == 0))
            .focusable(false)
            Button { model.openMovies() } label: {
                Label("Library", systemImage: "square.stack").font(.title3).padding(.horizontal, 14).padding(.vertical, 12)
            }
            .buttonStyle(TVButtonStyle(selected: model.area == .navigation && model.navigationIndex == 1))
            .focusable(false)
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape").font(.title3).padding(.horizontal, 14).padding(.vertical, 12)
            }
            .buttonStyle(TVButtonStyle(selected: model.area == .navigation && model.navigationIndex == 2))
            .focusable(false)
            Spacer()
            Text(model.remote.connectedCount > 0 ? "Remote connected" : model.remote.status)
                .font(.caption).foregroundStyle(model.remote.connectedCount > 0 ? .mint : .gray)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.title3.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct TVButtonStyle: ButtonStyle {
    let selected: Bool
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(filled ? Color.black : .white)
            .background(filled ? Color.white : Color.white.opacity(selected ? 0.14 : 0.04), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.mint : .clear, lineWidth: 3).padding(-4))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

#Preview("MacTV Home") {
    ContentView(model: MacTVModel()).frame(width: 1440, height: 900)
}
