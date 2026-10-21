import SwiftUI
import AppKit

struct MoviesLibraryView: View {
    let model: MacTVModel
    @Bindable var library: MovieLibrary
    @FocusState private var searchFocused: Bool
    @State private var showsMetadata = false
    @State private var showsMatch = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.collection?.title ?? "Your collection").font(.system(size: 34, weight: .bold, design: .rounded)).lineLimit(1)
                    let all = MovieLibrary.group(library.movies)
                    Text("\(all.filter { !$0.isSeries }.count) movies · \(all.filter(\.isSeries).count) series · On this Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Artwork & details") { showsMetadata = true }.focusable(false)
                Menu {
                    Button("Choose folder…") { library.chooseFolder(window: model.window) }
                    Button("Refresh library") { library.refresh() }
                    Text(library.folder.path)
                } label: { Label("Library", systemImage: "folder") }.fixedSize()
            }
            if let notice = library.notice { Label(notice, systemImage: "info.circle").foregroundStyle(.orange).font(.callout) }
            if let collection = library.collection {
                collectionDetail(collection)
            } else {
                HStack(spacing: 12) {
                    ForEach(MovieLibrary.Section.allCases, id: \.self) { section in
                        Button { library.section = section; model.area = .movies; model.libraryTabsFocused = true } label: {
                            Text(section.rawValue).font(.headline).padding(.horizontal, 22).padding(.vertical, 10)
                                .background(library.section == section ? Color.white.opacity(0.13) : .clear, in: Capsule())
                        }.buttonStyle(TVButtonStyle(selected: model.area == .movies && model.libraryTabsFocused && library.section == section)).focusable(false)
                    }
                    Spacer()
                    TextField("Search your collection", text: $library.query).textFieldStyle(.roundedBorder).frame(maxWidth: 290)
                        .focused($searchFocused).onSubmit { searchFocused = false; model.area = .movies; model.libraryTabsFocused = false }
                }
                if library.isScanning { ProgressView("Reading your collection…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if library.titles.isEmpty {
                    ContentUnavailableView("No \(library.section.rawValue.lowercased()) found", systemImage: library.section == .movies ? "film" : "tv",
                        description: Text(library.query.isEmpty ? "Add videos to your Movies folder, then refresh." : "Try another search or switch Movies / Series."))
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: library.columns), alignment: .leading, spacing: 28) {
                                ForEach(Array(library.titles.enumerated()), id: \.element.id) { index, title in
                                    Button { library.selection = index; library.collection = title; model.libraryTabsFocused = false } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            CollectionCover(title: title, metadata: model.metadata.records[title.id]).id(title.id).aspectRatio(2.0 / 3, contentMode: .fit)
                                            Text(model.metadata.records[title.id]?.Title ?? title.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                            Text(title.isSeries ? "\(title.seasons.count) \(title.seasons.count == 1 ? "season" : "seasons") · \(title.files.count) \(title.files.count == 1 ? "episode" : "episodes")" : (title.year ?? "Movie"))
                                                .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                                        }.padding(8).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
                                    }.buttonStyle(CollectionCardStyle(selected: model.area == .movies && !model.libraryTabsFocused && library.selection == index)).focusable(false).id(title.id)
                                }
                            }.padding(8)
                        }.scrollIndicators(.hidden)
                            .onChange(of: library.selection) { _, value in if library.titles.indices.contains(value) { reader.scrollTo(library.titles[value].id, anchor: .center) } }
                    }.id(library.section)
                }
            }

        }
        .task { library.refresh() }
        .task(id: "\(model.metadata.enabled)|\(model.metadata.revision)|\(library.movies.map(\.id).joined())") { await model.metadata.enrich(MovieLibrary.group(library.movies)) }
        .sheet(isPresented: $showsMetadata) { MetadataConnectionView(store: model.metadata) }
        .sheet(isPresented: $showsMatch) { if let collection = library.collection { MetadataMatchView(store: model.metadata, title: collection) } }
        .onChange(of: searchFocused) { _, focused in model.movieSearchEditing = focused }
        .onChange(of: model.moviePlayer?.movie.id) { _, id in if id != nil { searchFocused = false } }
        .onDisappear { model.movieSearchEditing = false }
    }
    private func collectionDetail(_ title: MediaCollection) -> some View {
        let metadata = model.metadata.records[title.id]
        return HStack(alignment: .top, spacing: 34) {
            CollectionCover(title: title, metadata: metadata).aspectRatio(2.0 / 3, contentMode: .fit).frame(width: 220)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(title.isSeries ? "SERIES" : "MOVIE").tracking(2).foregroundStyle(.mint)
                    Text(metadata?.Year ?? title.year ?? "Local video")
                    if let runtime = MovieMetadata.meaningful(metadata?.Runtime) { Text(runtime) }
                    if let rating = MovieMetadata.meaningful(metadata?.imdbRating) { Label("\(rating) IMDb", systemImage: "star.fill").foregroundStyle(.yellow) }
                }.font(.caption.weight(.semibold))
                if let genres = MovieMetadata.meaningful(metadata?.Genre) { Text(genres).foregroundStyle(.secondary) }
                ScrollView { Text(MovieMetadata.meaningful(metadata?.Plot) ?? "Your local copy. Connect OMDb in Artwork & details to add a synopsis, rating and poster.").font(.title3).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                HStack(spacing: 16) {
                    Button { library.collection = nil } label: { Label("Collection", systemImage: "chevron.left") }.focusable(false)
                    if let url = metadata?.imdbURL { Link("View on IMDb", destination: url) }
                    else { Link("Search IMDb", destination: imdbSearch(title.title)) }
                    Button(metadata == nil ? "Find details" : "Change match") { if model.metadata.enabled { showsMatch = true } else { showsMetadata = true } }.focusable(false)
                }
                if title.isSeries {
                    HStack {
                        Text("Season").foregroundStyle(.secondary)
                        Picker("Season", selection: $library.selectedSeason) { ForEach(title.seasons, id: \.self) { Text("Season \($0)").tag($0) } }.labelsHidden().frame(width: 145).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(library.seasonFocused ? Color.mint : .clear, lineWidth: 2))
                        // Phone left/right at the first episode remains episode navigation; explicit season buttons are also pointer accessible.
                        Button("Previous season") { shiftSeason(-1, title: title) }.disabled(library.selectedSeason == title.seasons.first)
                        Button("Next season") { shiftSeason(1, title: title) }.disabled(library.selectedSeason == title.seasons.last)
                    }
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(Array(library.episodes.enumerated()), id: \.element.id) { index, movie in
                                    Button { library.selection = index; model.playMovie(movie) } label: {
                                        HStack(spacing: 14) {
                                            Text(String(format: "%02d", movie.info.episode ?? index + 1)).font(.title2.monospacedDigit()).foregroundStyle(.mint).frame(width: 40)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(movie.info.episodeTitle ?? "Episode \(movie.info.episode ?? index + 1)").font(.headline)
                                                if model.history.position(movie) > 0 {
                        Button("Start over") { model.playMovie(movie, restart: true) }.focusable(false)
                    }
                    Text("\(movie.format) · \(ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if model.history.isCompleted(movie) { Label("Watched", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.mint) }
                                            else if model.history.position(movie) > 0 { Text(model.history.label(movie)).font(.caption).foregroundStyle(.mint) }
                                            Image(systemName: "play.fill")
                                        }.padding(16).frame(maxWidth: .infinity)
                                    }.buttonStyle(TVButtonStyle(selected: model.area == .movies && !library.seasonFocused && library.selection == index)).focusable(false).id(index)
                                }
                            }.padding(6)
                        }.onChange(of: library.selection) { _, index in reader.scrollTo(index, anchor: .center) }
                    }
                } else if let movie = title.files.first {
                    Button { model.playMovie(movie) } label: { Label(model.history.label(movie), systemImage: "play.fill").font(.title3.bold()).padding(.horizontal, 24).padding(.vertical, 14) }
                        .buttonStyle(TVButtonStyle(selected: model.area == .movies)).focusable(false)
                    if model.history.position(movie) > 0 {
                        Button("Start over") { model.playMovie(movie, restart: true) }.focusable(false)
                    }
                    Text("\(movie.format) · \(ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file)) · VLC playback").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 10)
    }
    private func shiftSeason(_ delta: Int, title: MediaCollection) {
        guard let index = title.seasons.firstIndex(of: library.selectedSeason), title.seasons.indices.contains(index + delta) else { return }
        library.selectedSeason = title.seasons[index + delta]
    }
    private func imdbSearch(_ title: String) -> URL {
        var url = URLComponents(string: "https://www.imdb.com/find/")!; url.queryItems = [URLQueryItem(name: "q", value: title), URLQueryItem(name: "s", value: "tt")]; return url.url!
    }
}

struct CollectionCover: View {
    let title: MediaCollection
    let metadata: MovieMetadata?
    @State private var poster: NSImage?
    private var tint: Color {
        let palette: [Color] = [.indigo, .teal, .purple, .blue, .brown]
        return palette[title.title.utf8.reduce(0) { ($0 + Int($1)) % palette.count }]
    }
    var body: some View {
        GeometryReader { size in
            ZStack {
                LinearGradient(colors: [tint.opacity(0.85), Color(red: 0.04, green: 0.05, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: title.isSeries ? "tv" : "film").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(title.title).font(.system(size: max(17, min(29, size.size.width / 8)), weight: .bold, design: .rounded)).lineLimit(5)
                    Text(title.isSeries ? "SERIES" : title.year ?? "FILM").font(.caption).tracking(3).foregroundStyle(.white.opacity(0.6))
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                if let poster { Image(nsImage: poster).resizable().scaledToFill().frame(width: size.size.width, height: size.size.height) }

            }.frame(width: size.size.width, height: size.size.height).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        }.task(id: title.localPoster?.absoluteString ?? metadata?.posterURL?.absoluteString ?? title.id) {
            poster = nil
            if let local = title.localPoster {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    guard let size = try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000 else { return nil }
                    return try? Data(contentsOf: local)
                }.value
                if !Task.isCancelled, let data { poster = NSImage(data: data) }
            } else if let url = metadata?.posterURL, let data = await MoviePosterCache.load(url), !Task.isCancelled { poster = NSImage(data: data) }
        }
    }
}

struct CollectionCardStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.mint : Color.white.opacity(0.06), lineWidth: selected ? 3 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .shadow(color: selected ? .mint.opacity(0.15) : .clear, radius: 12)
    }
}
