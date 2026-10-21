# Privacy and security

MacTV is a local entertainment hub and remote-control application. It does not provide a cloud account, an analytics service or a remote screen-streaming service.

## Information stored on your devices

| Information | Storage |
| --- | --- |
| Mac pairing credentials and optional OMDb key | macOS Keychain |
| Android pairing credential | Encrypted private preferences, protected by Android Keystore and excluded from backup/transfer |
| Preferences, library bookmark, resume history and cached metadata | Local macOS application preferences |
| Cached posters | `~/Library/Application Support/MacTV/Posters` |
| Video and subtitle files | The folders selected by the user; not copied into the app |
| Provider login sessions | The provider's native app or browser |

Release packages contain application code and resources. They do not include the developer's library, watch history, OMDb key, paired devices, browser profiles, passwords or signing private keys. The APK's public signing certificate is included so Android can verify it; that certificate is not the private signing key.

## Local network

The Mac advertises a local discovery service and receives controls on TCP port 8765. Discovery exposes an installation identifier and service name to devices on the network. Trust requires a sensitive short-lived invitation, mutual authentication and explicit approval on the Mac.

Commands, text input, acknowledgements and heartbeats are encrypted at the application layer. The WebSocket itself is not TLS/WSS. The protocol has not received an independent security audit and does not provide forward secrecy. Use it on a trusted local network; it is not designed for an Internet-facing listener. See the [protocol specification](protocol/README.md).

Text entry is held in memory and sent to the paired Mac. It is not included in normal application logs. Queued commands are discarded on disconnect rather than replayed. The Mac can revoke paired remotes; Android can forget its saved pairing.

## Optional external requests

- **OMDb:** title/year queries and the user's OMDb key are sent over HTTPS for artwork and details. Responses and posters are cached locally.
- **Spotify artwork:** images are requested from the artwork URLs supplied by Spotify. Track control and metadata use local macOS Automation.
- **Open-Meteo:** requests use the configured weather coordinates. MacTV does not request device location permission.
- **RainViewer and OpenStreetMap:** map and radar tile requests reveal the map region being viewed to those services.
- **Sports feeds:** fixture/calendar requests go to ESPN and Jolpica.
- **Streaming services:** opening a service uses its own application/browser, account, privacy policy and cookies.

As with ordinary network requests, these services can receive the requester’s IP address and request metadata. No shared service API key is bundled with MacTV.

## Permissions

Local-network access is needed for the remote. macOS Accessibility/device-control access is needed for input to other apps. Automation is used for Spotify and pausing other supported players when local video starts. Local folders need normal filesystem approval. These permissions are granted through the operating system, never by the phone bypassing consent.

## Removing data

Use **Forget** on Android to remove its saved pairing, or **Forget all remotes** on the Mac to revoke approved phones. Remove the OMDb key through its connection settings. Application preferences and poster caches can be removed separately from the app. Uninstalling the app does not delete the user's movie folders or provider accounts.

## Release limitations

The Mac preview is ad-hoc signed, not Developer ID signed or notarized. See [Apple's distribution guidance](https://developer.apple.com/developer-id/). The Android release uses a dedicated signing certificate; updates must preserve the signing identity, as described in [Android's signing documentation](https://developer.android.com/studio/publish/app-signing).

Source and packages are checked for common secret patterns and personal build metadata before release. This check is not a guarantee that no security defect exists. Published branches and release tags start from a clean V2.0 snapshot with personal development notes and IDE state excluded. Older clones and private recovery backups may retain previous history. Hosting-service caches are managed separately by the hosting provider.
