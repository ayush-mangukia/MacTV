import AppKit
import WebKit
import Observation

@MainActor @Observable
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Destination: Equatable {
        case page(URL)
        case video(String)
    }

    func insertRemoteText(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
            (() => {
              const e = document.activeElement, text = \(json)[0];
              if (!e || !(e instanceof HTMLInputElement || e instanceof HTMLTextAreaElement) ||
                  e.disabled || e.readOnly || !/^(text|search|email|url|tel|password|textarea)$/.test(e.type)) return false;
              e.setRangeText(text, e.selectionStart ?? e.value.length, e.selectionEnd ?? e.value.length, 'end');
              e.dispatchEvent(new Event('input', {bubbles:true}));
              return true;
            })()
            """) { [weak self] value, error in
                Task { @MainActor in
                    if error != nil || value as? Bool != true { self?.notice = "Focus a page text field first. Iframe fields may need normal keyboard input." }
                }
            }
    }

    var address = "https://www.youtube.com"
    private(set) var destination: Destination?
    private(set) var history: [Destination] = []
    private(set) var isLoading = false
    private(set) var playerReady = false
    private(set) var playerState = -1
    var notice: String?
    var fallbackURL: URL?
    var toolbarIndex = 2
    var pageNavigation = false
    var editingAddress = false
    var editingWebField = false
    @ObservationIgnored private var urlObservation: NSKeyValueObservation?
    @ObservationIgnored private var token = UUID().uuidString
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private lazy var messageProxy = PlayerMessageProxy(owner: self)
    @ObservationIgnored lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.tabFocusesLinks = true
        // Playback is initiated by the user through MacTV or YouTube controls.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(messageProxy, name: "youtube")
        configuration.userContentController.add(messageProxy, name: "inputFocus")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const reportFocus = () => {
              const e = document.activeElement;
              window.webkit.messageHandlers.inputFocus.postMessage(
                !!e && (e.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName)));
            };
            document.addEventListener('focusin', reportFocus);
            document.addEventListener('focusout', () => setTimeout(reportFocus, 0));
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        // App-owned history also includes local player documents.
        view.allowsBackForwardNavigationGestures = false
        urlObservation = view.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let url = change.newValue ?? nil else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.closed, !self.isPlayer, self.webView.url == url else { return }
                // YouTube uses same-document navigation, which skips navigation delegates.
                if let id = YouTubeVideo.id(from: url.absoluteString) {
                    self.navigate(to: .video(id))
                } else if url.scheme == "https", self.allowPage(url) {
                    let next = Destination.page(url)
                    if let current = self.destination, current != next {
                        self.history.append(current)
                        self.destination = next
                        self.address = url.absoluteString
                    }
                }
            }
        }
        return view
    }()

    var isPlayer: Bool {
        if case .video = destination { return true }
        return false
    }
    var currentURL: URL? {
        switch destination {
        case .video(let id): URL(string: "https://www.youtube.com/watch?v=\(id)")
        case .page(let url): url
        case nil: nil
        }
    }
    var appOrigin: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return URL(string: "https://\(bundleID.lowercased())")
    }
    var status: String {
        if isLoading { return "Loading…" }
        guard isPlayer else { return "Browse YouTube or paste a video link to use MacTV playback controls." }
        guard playerReady else { return "Waiting for YouTube player" }
        switch playerState {
        case 1: return "Playing"
        case 2: return "Paused"
        case 3: return "Buffering"
        case 0: return "Ended"
        default: return "Ready — press Play to start"
        }
    }

    func start() {
        guard destination == nil, let url = URL(string: "https://www.youtube.com") else { return }
        navigate(to: .page(url))
    }

    func submitAddress() {
        editingAddress = false
        if let id = YouTubeVideo.id(from: address) {
            navigate(to: .video(id))
        } else if let url = URL(string: address), url.scheme == "https", url.host != nil {
            navigate(to: .page(url))
        } else {
            notice = "Enter an HTTPS address, YouTube video link, or 11-character video ID."
        }
    }

    func navigate(to next: Destination, recordHistory: Bool = true) {
        if case .page(let url) = next, !allowPage(url) { return }
        if case .video(let id) = next, !YouTubeVideo.validID(id) {
            notice = YouTubeVideo.errorMessage(2)
            return
        }
        if recordHistory, let destination, destination != next { history.append(destination) }
        readinessTask?.cancel()
        token = UUID().uuidString
        destination = next
        notice = nil
        fallbackURL = nil
        playerReady = false
        playerState = -1
        isLoading = true
        pageNavigation = false
        editingWebField = false
        closed = false
        address = currentURL?.absoluteString ?? ""
        switch next {
        case .page(let url):
            webView.load(URLRequest(url: url))
        case .video(let id):
            guard let origin = appOrigin else {
                isLoading = false
                notice = "MacTV has no bundle identifier. YouTube requires an identifiable app. Use Safari."
                return
            }
            // YouTube explicitly documents baseURL identity for local HTML in WKWebView.
            webView.loadHTMLString(YouTubePage.html(videoID: id, origin: origin, token: token), baseURL: origin)
            let expectedToken = token
            readinessTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.token == expectedToken, !self.playerReady, !self.closed else { return }
                self.isLoading = false
                self.notice = "YouTube did not become ready. Check your connection, retry, or open this video in Safari."
            }
        }
    }

    /// Returns false when the caller should return to MacTV home.
    func goBack() -> Bool {
        guard let previous = history.popLast() else { return false }
        navigate(to: previous, recordHistory: false)
        return true
    }

    func retry() {
        if let destination { navigate(to: destination, recordHistory: false) }
    }

    func close() {
        closed = true
        readinessTask?.cancel()
        token = UUID().uuidString
        urlObservation?.invalidate()
        urlObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        // Detach the navigation policy before unloading, so closed sessions cannot cancel the blank page.
        webView.loadHTMLString("", baseURL: nil)
        playerReady = false
    }

    func playerCommand(_ name: String, value: Double = 0) {
        guard isPlayer, playerReady, value.isFinite else {
            notice = "The YouTube player is not ready. Wait, retry, or use Safari."
            return
        }
        let expectedToken = token
        webView.callAsyncJavaScript(
            "return window.macTV?.command(name, value) ?? false;",
            arguments: ["name": name, "value": value],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.token == expectedToken else { return }
            switch result {
            case .failure(let error): self.notice = "Playback command failed: \(error.localizedDescription)"
            case .success(let value):
                if (value as? Bool) != true { self.notice = "Player unavailable. Retry or open in Safari." }
            }
        }
    }

    func openInSafari() {
        guard let url = fallbackURL ?? currentURL, url.scheme == "https",
              let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            notice = "Safari is unavailable."
            return
        }
        if playerReady { playerCommand("pause") }
        Task {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari,
                                                       configuration: NSWorkspace.OpenConfiguration())
            } catch { notice = "Safari could not open this page: \(error.localizedDescription)" }
        }
    }

    func receive(_ message: WKScriptMessage) {
        if message.name == "inputFocus", message.frameInfo.isMainFrame, message.webView === webView {
            editingWebField = message.body as? Bool ?? false
            return
        }
        guard !closed, isPlayer, message.frameInfo.isMainFrame,
              message.webView === webView,
              let body = message.body as? [String: Any], body["token"] as? String == token,
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            playerReady = true
            isLoading = false
            notice = nil
            readinessTask?.cancel()
        case "state":
            playerState = body["value"] as? Int ?? -1
        case "error":
            isLoading = false
            notice = YouTubeVideo.errorMessage(body["value"] as? Int ?? -1)
            readinessTask?.cancel()
        case "blocked":
            notice = "Playback needs a click on YouTube’s Play button. You can also open this video in Safari."
        case "network":
            isLoading = false
            notice = "The YouTube Player API could not load. Check your connection or use Safari."
            readinessTask?.cancel()
        default: break
        }
    }

    private func allowPage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host != nil else {
            notice = "Only HTTPS pages can open in MacTV."
            return false
        }
        if let service = PlaybackCompatibility.externalService(for: url) {
            notice = PlaybackCompatibility.reason(for: service)
            fallbackURL = url
            return false
        }
        if url.host == "accounts.google.com" {
            notice = "Use Safari for Google sign-in. Safari and MacTV keep separate sessions."
            fallbackURL = URL(string: "https://www.youtube.com")
            return false
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
        // Subframes may load YouTube's own HTTPS player and consent UI.
        if action.targetFrame?.isMainFrame == false {
            decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        if isPlayer, url.host == appOrigin?.host { decisionHandler(.allow); return }
        guard allowPage(url) else { decisionHandler(.cancel); return }
        if let id = YouTubeVideo.id(from: url.absoluteString) {
            decisionHandler(.cancel)
            navigate(to: .video(id))
            return
        }
        if action.navigationType == .linkActivated || action.targetFrame == nil {
            decisionHandler(.cancel)
            navigate(to: .page(url))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        if !isPlayer {
            isLoading = false
            if let url = webView.url, url.scheme == "https" {
                destination = .page(url)
                address = url.absoluteString
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard !closed, (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        notice = "Page could not load: \(error.localizedDescription). Retry or open in Safari."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        readinessTask?.cancel()
        playerReady = false
        isLoading = false
        notice = "The web content process stopped. Retry to restore the page."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { navigate(to: .page(url)) }
        return nil
    }

    /// General pages expose their own focusable elements. Cross-origin iframe controls
    /// remain under the provider's control; no synthetic trusted events are attempted.
    func navigatePage(forward: Bool) {
        webView.callAsyncJavaScript("""
            const nodes = Array.from(document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]'))
              .filter(e=>!e.disabled && e.tabIndex>=0 && e.getClientRects().length>0);
            if (!nodes.length) return;
            let index=nodes.indexOf(document.activeElement);
            index=(index+(forward?1:-1)+nodes.length)%nodes.length;
            nodes[index].focus(); nodes[index].scrollIntoView({block:'center'});
            """, arguments: ["forward": forward], in: nil, in: .page) { _ in }
    }

    func scrollPage() {
        webView.evaluateJavaScript("window.scrollBy(0, 400)", completionHandler: nil)
    }

    func activatePageSelection() {
        webView.evaluateJavaScript("document.activeElement?.click();", completionHandler: nil)
    }
}

/// WKUserContentController retains handlers; the proxy prevents a session/web-view cycle.
@MainActor
final class PlayerMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserSession?
    init(owner: BrowserSession) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
