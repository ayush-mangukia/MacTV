import SwiftUI
import WebKit

enum BrowserAction: Int, CaseIterable, Identifiable {
    case back, home, browse, playPause, rewind, forward, volumeDown, volumeUp, mute, fullscreen, safari, retry
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .back: "Back"
        case .home: "Home"
        case .browse: "YouTube"
        case .playPause: "Play / Pause"
        case .rewind: "−10 sec"
        case .forward: "+10 sec"
        case .volumeDown: "Volume −"
        case .volumeUp: "Volume +"
        case .mute: "Mute"
        case .fullscreen: "Fullscreen"
        case .safari: "Safari"
        case .retry: "Retry"
        }
    }
    var symbol: String {
        switch self {
        case .back: "chevron.left"
        case .home: "house"
        case .browse: "play.rectangle"
        case .playPause: "playpause"
        case .rewind: "gobackward.10"
        case .forward: "goforward.10"
        case .volumeDown: "speaker.minus"
        case .volumeUp: "speaker.plus"
        case .mute: "speaker.slash"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .safari: "safari"
        case .retry: "arrow.clockwise"
        }
    }
}

struct MediaBrowserView: View {
    let model: MacTVModel
    @Bindable var session: BrowserSession
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Label("MacTV", systemImage: "tv").font(.title2.bold()).foregroundStyle(.mint)
                TextField("HTTPS address or YouTube video link", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { session.submitAddress(); addressFocused = false }
                    .accessibilityLabel("Website address or YouTube video")
                Button("Open") { session.submitAddress(); addressFocused = false }
                    .focusable(false)
            }
            BrowserToolbar(model: model, session: session)
            HStack {
                Text(session.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
            }
            if let notice = session.notice {
                HStack {
                    Image(systemName: "info.circle")
                    Text(notice).font(.callout)
                    Spacer()
                    Button("Open in Safari") { session.openInSafari() }.focusable(false)
                    Button("Retry") { session.retry() }.focusable(false)
                }
                .padding(12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            PersistentWebView(session: session)
                .frame(minWidth: 480, minHeight: 270)
            HStack {
                Text(session.pageNavigation
                     ? (session.isPlayer ? "← → Seek · Return Play/Pause · ↓ Volume down · ↑ Toolbar"
                        : "← → Focus page links · Return Select · ↓ Scroll · ↑ Toolbar")
                     : "← → Toolbar · Return Select · ↓ Page controls · Esc Back")
                Spacer()
                Text("⇧⌘H Home · ⌃⌘F Fullscreen")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(Color(red: 0.025, green: 0.035, blue: 0.06))
        .preferredColorScheme(.dark)
        .onChange(of: addressFocused) { _, value in session.editingAddress = value }
        .onChange(of: session.editingAddress) { _, value in addressFocused = value }
        .onDisappear { addressFocused = false }
    }
}

struct BrowserToolbar: View {
    let model: MacTVModel
    let session: BrowserSession
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(BrowserAction.allCases) { action in
                        Button {
                            session.toolbarIndex = action.rawValue
                            model.performBrowserAction(action)
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .buttonStyle(TVButtonStyle(selected: !session.pageNavigation && session.toolbarIndex == action.rawValue))
                        .focusable(false)
                        .id(action.rawValue)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.toolbarIndex) { _, index in reader.scrollTo(index) }
        }
    }
}

/// SwiftUI updates reuse the same web view, retaining cookies and browser state.
struct PersistentWebView: NSViewRepresentable {
    let session: BrowserSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
