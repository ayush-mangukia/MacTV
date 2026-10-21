# MacTV local remote protocol v1

The existing SwiftUI hub and Compose remote share this protocol. macOS receives with Network.framework WebSocket; Android connects with OkHttp. The Mac listens on TCP 8765 and advertises `_mactv._tcp` with TXT `v=1` and `id=<server UUID>`. Discovery supplies addresses, never trust. No cloud service, account, screen streaming, nested repository, shell-command endpoint, or arbitrary app-launch endpoint is involved.

## Pairing and trust

1. Keep both apps open on the same reachable local network. In MacTV Settings, verify the Mac Wi-Fi address and create an invitation.
2. Privately copy the complete `mactv1:...` invitation into Android **Devices → MacTV invitation** and tap **Pair with Mac** within 120 seconds.
3. Approve the phone in the sheet shown on the Mac. A request expires after 60 seconds. Rejection closes the connection. Only one approval can be pending.
4. Android shows **Connected · authenticated** only after the encrypted `ready` message. A WebSocket upgrade alone is not a connection success.

An invitation is `mactv1:` followed by standard padded Base64 of UTF-8 JSON:

```json
{"v":1,"host":"192.0.2.2","port":8765,"id":"<Mac UUID>","secret":"<32 random bytes, standard Base64>"}
```

This is a high-entropy secret invitation, not a guessable PIN. It is sensitive until consumed or expired. There is no camera/QR implementation. Never post an invitation or send it through an untrusted channel. Editing the address before generating a new invitation supports Macs with multiple interfaces. One successful pairing consumes the invitation; rotating it cancels in-flight requests. **Forget all remotes** on the Mac revokes stored credentials and disconnects every remote. Android **Forget** removes its own credential only; use Mac revocation for a lost phone. Up to eight paired installations are supported.

The transport deliberately uses `ws://` with application-level authenticated encryption, **not TLS/WSS**. The bootstrap exchanges public IDs, names, and random challenges; every command, text entry, acknowledgement, heartbeat, and issued credential is AES-256-GCM encrypted. Mutual HMAC proofs authenticate the invitation or saved credential before the session is used. There is no disabled certificate validation or trust-all TLS manager. The design does not provide forward secrecy: compromise of a pairing secret plus recorded traffic exposes those sessions. Do not expose the listener through router port forwarding. An Internet-facing or distributed product should undergo security review and consider a standard pinned TLS identity/pairing design.

The Mac stores credentials in Keychain with device-only accessibility. Android encrypts the saved device/credential with an AES-GCM key in Android Keystore; credential preferences are excluded from cloud backup and device transfer. Invitations are held in memory and cleared after use. Text and credentials are not logged. Android backgrounding disconnects the socket and stops discovery; foregrounding reconnects using the stored credential.

## Handshake

All frames are UTF-8 JSON objects with `v:1`. UUIDs and nonces below are strings. Base64 uses the standard alphabet with padding. Each nonce and secret is exactly 32 random bytes.

Client sends:

```json
{"v":1,"type":"hello","mode":"pair","serverId":"<Mac UUID>","clientId":"<installation UUID>","nonce":"<client nonce>","name":"Samsung remote"}
```

`mode` is `pair` for an invitation, `auth` for a saved credential. For `auth`, the server selects the credential by `clientId`. Neither the invitation nor the credential is transmitted in this handshake.

The server sends `{"v":1,"type":"challenge","nonce":"<server nonce>","proof":"<HMAC>"}`. The proof is HMAC-SHA256, encoded as Base64, with the selected secret as key and this exact UTF-8 string as input:

```
server|1|serverId|mode|clientId|clientNonce|serverNonce
```

After validating that proof, the client sends `{"v":1,"type":"proof","proof":"<HMAC>"}`, replacing `server` with `client` in the same transcript. The server verifies it with a constant-time authentication check. Unsupported versions, invalid IDs/nonces, missing or expired invitations, invalid proofs, and unexpected messages close the connection. Handshake connections time out after 15 seconds, checked every five seconds.

Both peers derive a 32-byte session key using HKDF-SHA256:

- Input key material: invitation secret or saved credential.
- Salt: decoded client nonce concatenated with decoded server nonce.
- Info: UTF-8 `MacTV/v1`.

Fresh nonces make every connection use a fresh session key. Pairing uses encrypted `pending`, then after explicit local approval `paired` with a fresh 32-byte `token` and `serverId`, followed by `ready`. Reconnection uses the stored token as the secret and sends `ready` directly. Credentials are not issued before approval.

## Authenticated envelopes

Each direction starts its own `seq` at 1 and increments by exactly one per encrypted message:

```json
{"v":1,"type":"secure","seq":1,"body":"<Base64 ciphertext followed by 16-byte GCM tag>"}
```

The GCM nonce is 12 bytes: ASCII `C2S!` or `S2C!` followed by the sequence as an unsigned 64-bit big-endian integer. Associated authenticated data is UTF-8 `MacTV/1/C2S!/1` (substitute direction and decimal sequence). Plaintext is the payload's UTF-8 JSON. Wrong sequences, direction, tag, or version close the connection; commands are never replayed across reconnection.

Payloads:

| type | Fields / meaning |
| --- | --- |
| `pending` | Waiting for local approval; no commands allowed |
| `paired` | `token`, `serverId`; persist credential securely |
| `ready` | `serverId`, `heartbeatSeconds:5`; authenticated session usable |
| `ping`, `pong` | Authenticated application heartbeat |
| `command` | Positive increasing integer `id`, `command` object |
| `ack` | Matching `id`, `status`, human-readable `message` |

`ack.status` is `dispatched`, `unsupported`, `permission_required`, or `error`. Dispatched means the receiver accepted and routed the input; it does not assert a playback state, volume value, successful provider action, or completed asynchronous app launch. MacTV reports launch/player failures on its own screen. Android only reports acknowledgement after receiving the matching encrypted ack.

## Commands

| command object | Semantics |
| --- | --- |
| `{"kind":"key","key":"up"}` | `up`, `down`, `left`, `right`, `ok`, `home`, `back`, `play_pause`, `previous`, `next`, `volume_up`, `volume_down`, `mute`, `click`, `fullscreen`, `controls`, `input_settings`, `activate_app`, `subtitles`, `restart`, `seek_back`, `seek_forward`, `app_search`, `backspace`, `erase_field` |
| `{"kind":"launch","app":"youtube"}` | Allowlist: `netflix`, `youtube`, `spotify`, `prime`, `f1`, `football`, `movies`; F1 TV and Foxtrend Football open in Chrome |
| `{"kind":"pointer","dx":12,"dy":-4}` | Relative pointer movement, each finite component limited to ±500 |
| `{"kind":"scroll","delta":10}` | Relative pixel scrolling, finite and limited to ±500 |
| `{"kind":"text","text":"search text"}` | 1–2,000 UTF-16 units; no shell interpolation or clipboard insertion |

The `movies` launch command opens the configured local Movies library. It never accepts a network-provided filesystem path. D-pad/OK select and play local entries; media controls operate the embedded VLC player; volume/mute control the default Mac audio output, Back stops and returns to the library, and Home stops and returns to the hub. Text while browsing filters the library. These internal controls do not require Accessibility.

Internal D-pad/OK/Home/Back reuse `MacTVModel.handle`. Local library navigation groups movies and series; `controls` reveals a selectable player action row and `fullscreen` toggles the app window. Local pointer/scroll/click uses a visible cursor and events scoped to the MacTV window, without Accessibility. No network-provided file paths are accepted.

YouTube launches Chrome; Prime launches its installed app with Safari fallback; Spotify prefer native where configured, and Netflix uses Safari. External input requires Accessibility and targets only the launched app while it is frontmost. Safari/Chrome Back sends Command-[; other apps receive Escape. Provider media and fullscreen actions prefer allowlisted Accessibility controls so focused text fields do not receive playback shortcut characters. Some actions fall back to guarded application shortcuts. `controls`, `restart` and local subtitle cycling are MacTV-player-specific commands; `app_search` sends Spotify’s Command-Shift-L shortcut. Home always returns to MacTV. External media keys are ordinary macOS media events and the active session determines their effect. Accessibility is requested only through the explicit Mac Settings button; Input Monitoring is not requested; Spotify/media integration separately uses macOS Automation approval.

The macOS target is now a locally distributed, unsandboxed app because cross-app Accessibility/input control is incompatible with App Sandbox. Keychain and TCC permission checks remain in effect. Use a stable signing identity for reliable Accessibility authorization; re-signing development builds may require re-adding the app in System Settings. Distribution signing/notarization is not configured by this integration.

DRM-protected services keep using supported Safari/native routes. No protected content is copied, decrypted, captured, or forced into WKWebView. The retained embedded browser is no longer the YouTube shortcut route.

## Limits, recovery, and platform permissions

Frames are limited to 16 KiB; the receiver permits eight simultaneous connections and 120 commands/second per authenticated connection. Android combines pointer/scroll input at about 30 Hz, uses a bounded command queue, and drops overflow with feedback. Queued commands carry the connection generation and are discarded on disconnect or mode changes. There is no offline replay. A missing acknowledgement fails after four seconds and invalidates the connection; an unacknowledged action may already have happened, so it is never retried automatically.

Both peers use authenticated heartbeats. The Mac drops idle peers after 16 seconds, checked on a five-second timer. Android checks every five seconds and reconnects after stale/error connections with exponential backoff and jitter, capped near 30 seconds. A pending approval gets 65 seconds on Android. Restarting MacTV reuses port 8765; DNS-SD refreshes saved endpoints when discovered server IDs match. Discovery can never replace the saved authentication secret. Discovery runs for 20 seconds per scan and stops in the background. If multicast is blocked, use a fresh invitation with a reachable Mac IP. Mac sleep, Android backgrounding, permission denial, firewall rules, guest/client-isolated Wi-Fi, and VPN routing can prevent connectivity.

macOS declares its local-network purpose and Bonjour service in `RemoteInfo.plist`. Android declares INTERNET and ACCESS_LOCAL_NETWORK; API 37+ requests local-network permission from Pair/Discover/Reconnect, and handles denial with feedback. Earlier supported Android versions use their normal INTERNET local access. See [Android local-network permissions](https://developer.android.com/privacy-and-security/local-network-permission), [NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager), [Apple Accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), and [App Sandbox limitations](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

## Tests

`crypto-vector.json` is a deterministic public test vector, not a credential. Swift and Kotlin tests verify matching HMAC, HKDF, and AES-GCM output, and reject tampering, wrong direction, and replay.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer protocol/tests/run-swift-tests.sh
cd MacTV_AndroidApp
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

`protocol/tests/run-integration.py` compiles `ServerHarness.swift` and runs the opt-in JVM receiver tests. The harness uses memory-only credentials on port 8766 and records commands without invoking desktop input. It automatically approves ordinary test clients, rejects the name `reject-test`, and restarts on the test-only text `__mactv_test_drop__`; this behavior is confined to the harness and is never compiled into the macOS app.

```sh
python3 protocol/tests/run-integration.py
# Android emulator over its normal host bridge:
python3 protocol/tests/run-integration.py --android emulator-5554 --host 10.0.2.2
# Real phone, with the Mac's reachable Wi-Fi address:
python3 protocol/tests/run-integration.py --android PHONE_SERIAL --host MAC_WIFI_IP
# Also test real multicast discovery on the same reachable LAN:
python3 protocol/tests/run-integration.py --android PHONE_SERIAL --host MAC_WIFI_IP --discovery
```

Android mode builds and installs debug/test APKs, grants the test app local-network permission, and runs `TransportIntegrationTest`: approval, every exposed key/launch command, pointer/scroll/Unicode text, 18-second heartbeat survival, automatic recovery after a test receiver restart, explicit authenticated reconnect, and local forgetting. Its credential namespace is separate from the real app's pairing. It does not test streaming playback or consent dialogs. The tests do not change Wi-Fi, firewall, Accessibility, or system media state.

The optional `--discovery` check also runs `DiscoveryIntegrationTest`, verifying that Android discovers the isolated receiver's advertised UUID and a usable WebSocket endpoint. It needs multicast reachability; a passing direct transport test alone does not establish discovery.

`input_settings` opens the system input-control permission screen and requests consent; it never grants permission. `activate_app` brings forward only the retained, still-running application MacTV launched. Both are handled before external input routing so a phone can recover from a settings/foreground interruption. External event synthesis is gated by CGPreflightPostEventAccess. On macOS 27 the UI names Device Control and Data Access; earlier versions name Accessibility. Removed Apple TV and Disney+ launch identifiers return unsupported.

Gesture ordering: Android flushes accumulated pointer and scroll deltas before enqueueing a click or other discrete command. The bounded queue retains transport-generation checks and modes clear pending gesture input. Input errors are shown above the touchpad rather than only at the bottom of the page.

## Optional context.v1 (October 2026)

New Android clients advertise `capabilities:["context.v1"]` in `hello`. After encrypted `ready`, only authenticated peers that advertised this capability receive encrypted `context` messages. Older remotes receive the existing messages unchanged. A context has allowlisted `app` (`home`, `settings`, `library`, `player`, `spotify`, `youtube`, `netflix`, `prime`, `f1`, `football`), a display `title`, supported shortcut `keys`, `foreground` and optional `subtitle` / `playing`. Context is refreshed after commands and at heartbeats, and only changes are sent. No file paths or credentials are included. Android clears context whenever the session ends; unsupported keys are never executed dynamically.

Local playback checkpoints are device-local, written every five seconds and at pause/stop/quit. Completed files return to the library and reset their resume offset. System volume uses CoreAudio, independent of Accessibility; fixed-volume HDMI/receiver outputs report that limitation. VLC remains at normal gain. Subtitle selection uses the public libVLC 3 track ABI; files are chosen locally with an Open panel.

Shortcut references: [Spotify](https://support.spotify.com/dk-en/article/keyboard-shortcuts/), [YouTube](https://support.google.com/youtube/answer/7631406?hl=en), [Netflix](https://help.netflix.com/en/node/24855).

Context now includes `volumeAvailable`, `audioOutput` and `volumeNotice`, bounded on the phone and cleared with the session. A fixed output with MonitorControl uses Mac volume-key events, dispatched before provider focus routing. All explicit volume commands are global output controls. Browser playback no longer injects K into a focused search field: Play/Pause presses a bounded, process-scoped Accessibility button. `backspace` and `erase_field` require a focused text control; neither accepts selectors, scripts, file paths or arbitrary keys from the network.


Football context exposes `unmute_stream`, `refresh` and `fullscreen`. `unmute_stream` presses an allowlisted Unmute/Enable sound Accessibility control; it never toggles system mute. Refresh uses the browser Reload control, or Command-R only when the retained browser is frontmost. Fullscreen presses the provider control when available. Regular volume remains global Mac output control. Unsupported/missing provider controls return an error rather than typing into a field.

Reconnection discovery repeats during longer retries and on Android default-network/link-property changes while foregrounded. MacTV updates its displayed Wi-Fi address after interface changes unless the user entered an override. Multicast-blocked networks cannot guarantee automatic locator recovery; a stale address does not invalidate the saved pairing.

Football context also advertises `close_tab`. It maps to Command-W only for Football's retained Google Chrome process, subject to the existing permission and foreground guards. No URL, script, window ID or tab selector is accepted from the network. The normal browser Close current tab behaviour applies.
