import SwiftUI

struct HomeScreen: View {
    let model: MacTVModel
    let availableWidth: CGFloat
    private var titles: [MediaCollection] { MovieLibrary.group(model.movies.movies) }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your library").font(.system(size: 32, weight: .semibold)).tracking(-0.6)
                        Spacer()
                        Text("On this Mac").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        libraryCard(.movies, index: 0, symbol: "film", count: titles.filter { !$0.isSeries }.count)
                        libraryCard(.series, index: 1, symbol: "tv", count: titles.filter(\.isSeries).count)
                    }.id(MacTVModel.Area.hero)
                    HomeDashboard(model: model, availableWidth: availableWidth - 16)
                    serviceRow("Streaming", services: Service.allCases.filter { !$0.isSport }, area: .services)
                    serviceRow("Sports", services: Service.allCases.filter(\.isSport), area: .sports)
                    SportsAgendaView(model: model, agenda: model.sports, availableWidth: availableWidth - 16).id(MacTVModel.Area.agenda)

                }.padding(8)
            }.scrollIndicators(.hidden)
                .onChange(of: model.area) { _, area in
                    if [.hero, .continueWatching, .music, .weather, .services, .sports, .agenda].contains(area) { reader.scrollTo(area, anchor: .top) }
                }
        }
        .task { if model.movies.movies.isEmpty && !model.movies.isScanning { model.movies.refresh() } }
        .task(id: "\(model.metadata.enabled)|\(model.metadata.revision)|\(model.movies.movies.map(\.id).joined())") { await model.metadata.enrich(titles) }
    }
    private func serviceRow(_ title: String, services: [Service], area: MacTVModel.Area) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.system(size: 22, weight: .semibold))
            HStack(spacing: 16) {
                ForEach(services) { service in
                    Button {
                        model.serviceIndex = Service.allCases.firstIndex(of: service) ?? 0
                        model.area = area; model.handle(.launch(service))
                    } label: {
                        HStack(spacing: 14) {
                            ServiceMark(service: service).frame(width: 46, height: 46)
                            Text(service.name).font(.system(size: 20, weight: .semibold))
                            Spacer(minLength: 0)
                            if service.isSport { Text(service == .f1 ? "F1 TV · Chrome" : "Foxtrend · Chrome").font(.system(size: 13)).foregroundStyle(.secondary) }
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, minHeight: 88)
                    }.buttonStyle(HomeCardStyle(selected: model.area == area && model.selectedService == service))
                        .focusable(false).disabled(model.isLaunching).accessibilityLabel("Open \(service.name)")
                }
            }
        }.id(area)
    }
    private func libraryCard(_ section: MovieLibrary.Section, index: Int, symbol: String, count: Int) -> some View {
        Button {
            model.homeLibraryIndex = index; model.openMovies(); model.movies.section = section; model.libraryTabsFocused = false
        } label: {
            HStack(spacing: 24) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.mint).frame(width: 54)
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.rawValue).font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                    Text("\(count) \(section == .movies ? "titles" : "shows") in your collection").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.callout).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        }.buttonStyle(HomeCardStyle(selected: model.area == .hero && model.homeLibraryIndex == index)).focusable(false)
    }
}

struct HomeCardStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(Color.white.opacity(selected ? 0.085 : 0.035), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.mint : .white.opacity(0.075), lineWidth: selected ? 2 : 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct ServiceMark: View {
    let service: Service
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11).fill(service.color.opacity(0.12))
            switch service {
            case .netflix: Text("N").font(.system(size: 30, weight: .black)).foregroundStyle(service.color)
            case .youtube: Image(systemName: "play.rectangle.fill").font(.system(size: 27)).foregroundStyle(service.color)
            case .spotify: Image(systemName: "waveform.circle.fill").font(.system(size: 29)).foregroundStyle(service.color)
            case .prime: Text("prime").font(.system(size: 12, weight: .bold)).foregroundStyle(.cyan)
            case .f1: Text("F1").font(.system(size: 22, weight: .black).italic()).foregroundStyle(service.color)
            case .football: Image(systemName: "soccerball").font(.system(size: 29)).foregroundStyle(service.color)
            }
        }.accessibilityHidden(true)
    }
}
