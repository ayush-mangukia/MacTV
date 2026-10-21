import SwiftUI
import AppKit

struct SettingsScreen: View {
    let model: MacTVModel
    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("MacTV V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")").font(.caption).foregroundStyle(.secondary)
                Text("Settings").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Playback, display and remote controls.").font(.title3).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 12) {
                        SettingRow(title: "Midnight appearance", subtitle: "A quieter background with no ambient glow.", symbol: "moon.fill", enabled: model.midnight, selected: model.settingIndex == 0) { model.toggleSetting(0) }.id(0)
                        SettingRow(title: "Reduce motion", subtitle: "Keep transitions instant.", symbol: "sparkles", enabled: model.reducedMotion, selected: model.settingIndex == 1) { model.toggleSetting(1) }.id(1)
                        SettingRow(title: "Prefer native apps", subtitle: "Use the installed Spotify app. Prime Video always uses its app when available.", symbol: "app.badge", enabled: model.preferNative, selected: model.settingIndex == 2) { model.toggleSetting(2) }.id(2)
                        SettingRow(title: "Start in fullscreen", subtitle: "Applies the next time MacTV opens.", symbol: "arrow.up.left.and.arrow.down.right", enabled: model.startsFullscreen, selected: model.settingIndex == 3) { model.toggleSetting(3) }.id(3)
                        SettingRow(title: "Keep Mac awake", subtitle: "Prevent idle sleep and the screen saver while MacTV is open. Manual locking stays available.", symbol: "sun.max", enabled: model.keepAwake, selected: model.settingIndex == 4) { model.toggleSetting(4) }.id(4)
                        SettingRow(title: "Autoplay next episode", subtitle: "After a series episode, show an 8-second countdown. Back cancels it.", symbol: "play.rectangle.on.rectangle", enabled: model.autoplayNext, selected: model.settingIndex == 5) { model.toggleSetting(5) }.id(5)
                        Button { model.handle(.back) } label: {
                            Label("Back to home", systemImage: "arrow.left").padding(16).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TVButtonStyle(selected: model.settingIndex == 6))
                        .focusable(false)
                        .id(6)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 48)).foregroundStyle(.mint)
                        Text("Wi-Fi remote").font(.title2.bold())
                        Text(model.systemVolume.outputName).font(.caption)
                        if let notice = model.systemVolume.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                        Button("Mac sound output settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) } }
                        Text(model.remote.status).font(.caption)
                        Button("Restart remote") { model.remote.restart() }
                        Text("\(model.remote.connectedCount) connected · \(model.remote.pairedCount) paired").font(.caption)
                        TextField("Mac Wi-Fi address", text: Binding(get: { model.remote.host }, set: { model.remote.host = $0 }))
                        Button("Create 2-minute invitation") { model.remote.newInvitation() }
                        if !model.remote.invitation.isEmpty {
                            Text("Copy this invitation to Android Devices, then approve the phone here.").font(.caption)
                            Text(model.remote.invitation).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                            Button("Copy invitation") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.remote.invitation, forType: .string)
                            }
                        }
                        Button("Forget all remotes", role: .destructive) { model.remote.revokeAll() }
                        Label(model.inputPermission ? "External touchpad enabled" : "External touchpad blocked", systemImage: model.inputPermission ? "checkmark.shield" : "hand.raised")
                            .foregroundStyle(model.inputPermission ? Color.mint : .orange)
                        Button("Open \(RemoteInput.permissionName) settings") { RemoteInput.requestPermission() }
                        Text("Enable the MacTV switch there to control Netflix, Chrome, Spotify and Prime Video.").font(.caption)
                        Text("MacTV navigation works without Accessibility. External apps require this system permission; the MacTV touchpad works here without it. Pair only on a trusted network; keep invitations private.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Use your phone or keyboard: ↑ ↓ moves between preferences and OK changes them.").foregroundStyle(.secondary)
                        Text("To return from a streaming app, reveal the macOS menu bar and choose TV → Bring MacTV Home. Command-Tab also works.").foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .frame(width: 280, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding(8)
        }
        .task {
            while !Task.isCancelled { model.refreshInputPermission(); try? await Task.sleep(for: .seconds(1)) }
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.settingIndex) { _, index in reader.scrollTo(index) }
        }
    }
}

struct SettingRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let enabled: Bool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(enabled ? "On" : "Off").font(.headline).foregroundStyle(enabled ? .mint : .gray)
            }
            .padding(22)
            .background(.white.opacity(selected ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? .mint : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityValue(enabled ? "On" : "Off")
    }
}
