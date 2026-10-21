import SwiftUI

struct SportsAgendaView: View {
    let model: MacTVModel
    let agenda: SportsAgenda
    let availableWidth: CGFloat
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let live = agenda.live(now: timeline.date)
            let upcoming = agenda.highlights(now: timeline.date)
            let cards = live + upcoming.filter { event in !live.contains(where: { $0.id == event.id }) }
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    Text("Live now / Up next").font(.system(size: 22, weight: .semibold))
                    Text("Freiburg · Spurs · Champions League · F1").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Favourites & reminders") { agenda.showingPreferences = true }
                    Button { Task { await agenda.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh sports schedule").accessibilityLabel("Refresh sports schedule").disabled(agenda.busy)
                }
                ForEach(agenda.reminders.due(now: timeline.date)) { event in
                    HStack(spacing: 14) {
                        Image(systemName: "bell.fill").foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Starts in \(max(1, Int(ceil(event.start.timeIntervalSince(timeline.date) / 60)))) min").font(.system(size: 12, weight: .semibold)).foregroundStyle(.mint)
                            Text(event.title).font(.headline)
                        }
                        Spacer()
                        Button("Watch") { model.handle(.launch(event.sport == .f1 ? .f1 : .football)) }
                        Button { agenda.reminders.dismiss(event) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss reminder for \(event.title)")
                    }.padding(18).background(.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                if cards.isEmpty {
                    HStack(spacing: 12) {
                        if agenda.busy { ProgressView().controlSize(.small) }
                        Text(agenda.busy ? "Checking your fixtures…" : "No upcoming fixtures available. Try refreshing the schedule.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(Array(cards.enumerated()), id: \.element.id) { index, event in
                                    eventCard(event, live: live.contains(where: { $0.id == event.id }), selected: model.area == .agenda && model.agendaIndex == index)
                                        .frame(width: min(390, max(260, (availableWidth - 32) / 3))).id(index)
                                }
                            }.padding(4)
                        }.scrollIndicators(.hidden)
                        .onChange(of: model.agendaIndex) { _, index in reader.scrollTo(index, anchor: .center) }
                    }
                }
                HStack(spacing: 10) {
                    Text(agenda.notice ?? (live.isEmpty ? "No live matches reported · times shown in Europe/Berlin" : "Live scores refresh about every minute · Europe/Berlin"))
                    Spacer(minLength: 0)
                    Link("Football: ESPN", destination: URL(string: "https://www.espn.com/soccer/")!)
                    Link("F1: Jolpica", destination: URL(string: "https://jolpi.ca/")!)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .task { await agenda.observe() }
        .sheet(isPresented: Binding(get: { agenda.showingPreferences }, set: { agenda.showingPreferences = $0 })) { SportsPreferences(agenda: agenda) }
    }
    private func eventCard(_ event: SportsEvent, live: Bool, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(live ? "LIVE" : "UP NEXT", systemImage: live ? "dot.radiowaves.left.and.right" : "clock")
                    .font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(live ? Color.red : .mint)
                Spacer(minLength: 0)
                if event.sport == .football {
                    Button {
                        agenda.toggleReminder(event)
                        if !agenda.reminders.enabled { agenda.showingPreferences = true }
                    } label: {
                        Image(systemName: agenda.automaticReminder(event) || agenda.pinned.contains(event.id) ? "bell.fill" : "bell.badge")
                    }.buttonStyle(.plain).foregroundStyle(.mint)
                        .disabled(agenda.automaticReminder(event)).help(agenda.automaticReminder(event) ? "Favourite team reminder" : "Remind me about this match")
                        .accessibilityLabel("Remind me about \(event.title)")
                }
            }
            Text(event.competition).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(event.title).font(.system(size: 19, weight: .semibold)).lineLimit(2).frame(height: 48, alignment: .topLeading)
            if live, let score = event.score { Text("\(score) · \(event.detail)").font(.system(size: 15, weight: .semibold)) }
            else { Text(event.timeConfirmed ? event.berlinTime : "Kick-off time to be confirmed").font(.system(size: 14)).foregroundStyle(.secondary) }
            Button {
                model.handle(.launch(event.sport == .f1 ? .f1 : .football))
            } label: { Label(event.sport == .f1 ? "Open F1 TV" : "Open Football", systemImage: "play.fill").font(.system(size: 14, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.mint).padding(.top, 4)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(selected ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Color.mint : .white.opacity(0.075), lineWidth: selected ? 2 : 1))
    }
}

struct SportsPreferences: View {
    let agenda: SportsAgenda
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your sports").font(.title.bold())
            Text("Favourite teams first, plus featured Champions League fixtures and F1 races.").foregroundStyle(.secondary)
            Toggle("SC Freiburg", isOn: Binding(get: { agenda.followFreiburg }, set: { agenda.followFreiburg = $0 }))
            Toggle("Tottenham Hotspur", isOn: Binding(get: { agenda.followSpurs }, set: { agenda.followSpurs = $0 }))
            Toggle("Champions League featured matches", isOn: Binding(get: { agenda.followChampions }, set: { agenda.followChampions = $0 }))
            Toggle("Formula 1 races", isOn: Binding(get: { agenda.followF1 }, set: { agenda.followF1 = $0 }))
            Divider()
            Picker("Remind me", selection: Binding(get: { agenda.leadMinutes }, set: { agenda.leadMinutes = $0 })) {
                ForEach([10, 15, 30], id: \.self) { Text("\($0) minutes before").tag($0) }
            }
            Text("Reminders cover your favourite teams and F1. Use a match’s bell for individual Champions League games. Reminders appear as countdown banners inside MacTV while you browse Home.").font(.callout).foregroundStyle(.secondary)
            HStack {
                if agenda.reminders.enabled {
                    Label("Following \(agenda.reminders.scheduledCount) upcoming events", systemImage: "bell.fill").foregroundStyle(.mint)
                    Spacer()
                    Button("Disable reminders") { Task { await agenda.disableReminders() } }
                } else {
                    Button("Enable in-app reminders") { Task { await agenda.enableReminders() } }.buttonStyle(.borderedProminent)
                }
            }
            if let notice = agenda.reminders.notice { Text(notice).font(.callout).foregroundStyle(.orange) }
            Text("Reminders stay inside MacTV. Fixtures refresh while Home is open, including changes to start times.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 520)
    }
}
