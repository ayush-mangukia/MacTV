import Foundation

enum YouTubeVideo {
    static func id(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if validID(value) { return value }
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "youtu.be" {
            candidate = parts.first
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "www.youtube-nocookie.com"].contains(host) {
            if parts.first == "watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if let first = parts.first, ["embed", "shorts", "live"].contains(first), parts.count == 2 {
                candidate = parts[1]
            } else { candidate = nil }
        } else { candidate = nil }
        return candidate.flatMap { validID($0) ? $0 : nil }
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    static func errorMessage(_ code: Int) -> String {
        switch code {
        case 2: "YouTube rejected this video ID."
        case 5: "YouTube could not play this video in WebKit."
        case 100: "This video is unavailable, private, or removed."
        case 101, 150: "The owner does not allow embedded playback. Open this video in Safari."
        case 153: "YouTube could not verify MacTV’s app identity. Open in Safari."
        default: "YouTube reported player error \(code). Try Safari."
        }
    }
}

/// Only documented IFrame Player API methods are called. No iframe DOM access.
enum YouTubePage {
    static func html(videoID: String, origin: URL, token: String) -> String {
        func json(_ string: String) -> String {
            // JSON encoding prevents values from becoming executable JavaScript.
            let data = try? JSONEncoder().encode(string)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        return """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;width:100%;height:100%;background:#080b12;color:white}
        #player{width:100%;height:100%;min-height:270px}</style></head>
        <body><div id="player"></div><script>
        let player, ready = false;
        const send = (kind, value = 0) =>
          window.webkit.messageHandlers.youtube.postMessage({token:\(json(token)),kind,value});
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width:'100%', height:'100%', videoId:\(json(videoID)),
            playerVars:{playsinline:1, controls:1, fs:1, autoplay:0, origin:\(json(origin.absoluteString))},
            events:{
              onReady:()=>{ready=true;send('ready');},
              onStateChange:e=>send('state',e.data),
              onError:e=>send('error',e.data),
              onAutoplayBlocked:()=>send('blocked')
            }
          });
        }
        window.macTV = {
          command: function(name, value) {
            if (!ready) return false;
            switch(name) {
              case 'play': player.playVideo(); break;
              case 'pause': player.pauseVideo(); break;
              case 'toggle': player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo(); break;
              case 'seek': player.seekTo(Math.max(0,Math.min(player.getDuration() || Infinity,player.getCurrentTime()+value)),true); break;
              case 'volume': player.setVolume(Math.max(0,Math.min(100,player.getVolume()+value))); break;
              case 'mute': player.isMuted() ? player.unMute() : player.mute(); break;
              default: return false;
            }
            return true;
          }
        };
        const script = document.createElement('script');
        script.src='https://www.youtube.com/iframe_api';
        script.onerror=()=>send('network');
        document.head.appendChild(script);
        </script></body></html>
        """
    }
}

enum PlaybackCompatibility {
    static func embeddedPlaybackAllowed(_ service: Service) -> Bool { false }

    static func reason(for service: Service) -> String {
        switch service {
        case .youtube: "YouTube opens in Google Chrome. Use the touchpad and keyboard to browse."
        case .spotify: "Spotify is ready. Use track controls, Search or the touchpad on your phone."
        case .netflix: "Netflix opens in Safari. Use your phone to browse and control playback."
        case .prime: "Prime Video opens in the installed Prime Video app, with Safari as a fallback."
        case .f1: "F1 TV opens in Google Chrome. Use the touchpad to choose a session."
        case .football: "Football opens Foxtrend in Google Chrome. Use the touchpad to choose a match."
        }
    }

    static func externalService(for url: URL) -> Service? {
        guard let host = url.host?.lowercased() else { return nil }
        let domains: [(String, Service)] = [
            ("netflix.com", .netflix), ("primevideo.com", .prime),
            ("amazon.com", .prime), ("amazon.de", .prime), ("amazon.co.uk", .prime),
            ("spotify.com", .spotify), ("f1tv.formula1.com", .f1), ("foxtrend.app", .football)
        ]
        return domains.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }
}
