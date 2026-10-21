# MacTV

**Your Mac, made for the big screen. Controlled from Android.**

MacTV is a native macOS entertainment hub with a companion Android remote. Browse local movies and series, resume playback, control Spotify, check the weather and launch streaming or sports services from one interface.

**Current release: V2.0 · command protocol: v1**

[Downloads](https://github.com/ayush-mangukia/MacTV/releases) · [Changelog](CHANGELOG.md) · [Privacy](PRIVACY.md) · [Protocol](protocol/README.md)

## Features

- **Movies and series:** separate library views, full-screen playback through VLC, subtitles, saved progress and optional next-episode autoplay.
- **Continue Watching:** resume the most recent unfinished movie or episode directly from Home.
- **Artwork and details:** optional OMDb integration with persistent metadata and poster caching.
- **Spotify:** album artwork, an animated vinyl record and previous/play-pause/next controls.
- **Weather:** current conditions, the next six forecast hours and animated recent rain radar.
- **Streaming shortcuts:** Netflix, YouTube, Spotify and Prime Video in supported browsers or native apps.
- **Sports:** F1 TV and Football shortcuts, upcoming fixtures and in-app reminders for selected teams and races.
- **Android remote:** D-pad, OK, Home, Back, touchpad, scrolling, keyboard and controls tailored to the active app.
- **Mac volume:** remote volume buttons control the Mac output; compatible fixed-volume displays can use MonitorControl.
- **Local connection:** device discovery, approval-based pairing, authenticated encrypted commands and reconnection.

## Downloads and requirements

Get the DMG and APK from the [V2.0 release](https://github.com/ayush-mangukia/MacTV/releases/tag/v2.0.0).

| Platform | Requirements |
| --- | --- |
| macOS | macOS 14 or later on Apple silicon (arm64) |
| Android | Android 15 / API 35 or later |
| Network | Both devices must be mutually reachable on the local network |
| Local video | VLC 3 installed at `/Applications/VLC.app` |
| Optional services | Chrome, Spotify, Prime Video, MonitorControl and an OMDb key as needed |

The Mac preview is ad-hoc signed and **not notarized**. It does not have Developer ID distribution approval, so macOS Gatekeeper may block it. The release notes state this limitation. VLC and streaming-service accounts are separate downloads; they are not included.

### Install

1. Open the DMG and drag **MacTV** into **Applications**.
2. Install VLC 3 if you want to play local video.
3. Install the **MacTV Remote** APK on Android using Android's app-install approval flow.
4. Open both apps and pair them using the steps below.

The release APK uses a dedicated release signing key. Android cannot update a development-signed installation with an APK signed by a different key. Existing development users need to remove that installation before installing the release APK, then pair again. This is not necessary for a new installation.

### Pair the remote

1. On the Mac, open **Settings → Wi-Fi remote** and create a two-minute invitation.
2. On Android, open **Devices**, paste the invitation and select **Pair with Mac**.
3. Approve the phone on the Mac.
4. Wait for **Connected · authenticated** in Android's Devices screen.

Allow local-network access when requested. For control of other apps, enable MacTV in macOS **Privacy & Security → Accessibility**; newer macOS versions may call this **Device Control and Data Access**. Spotify control also needs macOS Automation approval. Internal library and player navigation work without cross-app input permission.

Discovery helps find the paired Mac after address changes. Guest networks, client isolation, VPN routing or blocked multicast can prevent discovery or connectivity. The Android app disconnects in the background and reconnects when brought forward.

## Your library

By default, MacTV reads the following folders in place:

```text
~/Downloads/Movies/
├── Movies/
│   └── Movie Title (Year)/
│       └── Movie Title.mkv
└── Series/
    └── Series Title/
        └── Season 01/
            └── Series Title S01E01.mkv
```

Use the library's folder chooser to select another location. MacTV does not copy videos into the app or stream them to the phone. The phone sends commands; playback happens on the Mac.

Add an OMDb key through MacTV's artwork settings to fetch posters and descriptions. Metadata and images are cached locally, including remembered misses, with a daily request safety cap. Local cover images can also be used.

## Streaming and sports

| Service | Launch route |
| --- | --- |
| YouTube | Google Chrome |
| Netflix | Safari |
| Spotify | Native Spotify when preferred; browser fallback |
| Prime Video | Native Prime Video when available; browser fallback |
| F1 TV | Google Chrome |
| Football | Configured Football website in Chrome |

Protected streaming plays in the provider's supported app or browser. MacTV does not bundle media, subscriptions or provider accounts, and does not bypass DRM. Some player actions depend on the site's available Accessibility controls.

The sports agenda supports favourite teams, selected Champions League fixtures and F1 race starts. Reminders appear **inside MacTV only**. Weather uses Open-Meteo; rain radar uses RainViewer with OpenStreetMap tiles. Radar shows recent observations, while the hourly weather card provides the forecast. The default weather location and sports selections can be changed in the source/configuration; there is no automatic device-location tracking.

## Architecture

```text
Android remote ── local Wi-Fi / WebSocket ── macOS hub
  Compose UI          protocol v1              SwiftUI UI
  Android Keystore    encrypted commands       macOS Keychain
                                             VLC / native apps / browser
```

The Mac advertises `_mactv._tcp` and listens on port `8765`. Pairing requires a short-lived invitation and explicit Mac approval. Commands, text, acknowledgements and heartbeats use application-level AES-GCM encryption with mutual authentication. The transport is `ws://` with encrypted payloads, not TLS/WSS. Discovery is a locator, not an authority. See the [protocol specification](protocol/README.md) for the security model and limits.

## Build from source

The repository contains both applications; no nested repositories are required.

```text
MacTV_MacApp/       SwiftUI macOS application and native tests
MacTV_AndroidApp/   Kotlin / Jetpack Compose Android application
protocol/          Shared wire specification, vectors and integration tests
branding/          Icon-generation source
scripts/           Release packaging
```

### macOS

Open `MacTV_MacApp/MacTV_MacApp.xcodeproj` in Xcode and select the `MacTV_MacApp` scheme. Configure your own signing identity for development. For an ad-hoc local Release build:

```sh
xcodebuild \
  -project MacTV_MacApp/MacTV_MacApp.xcodeproj \
  -scheme MacTV_MacApp -configuration Release \
  -derivedDataPath build/macOS \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

The output is `build/macOS/Build/Products/Release/MacTV.app`. Distribution with normal Gatekeeper approval requires your own Developer ID signing and notarization.

### Android

Open `MacTV_AndroidApp` in Android Studio. Install the SDK requested by Gradle and use JDK 25, as configured by the project toolchain.

```sh
cd MacTV_AndroidApp
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

The development APK is `app/build/outputs/apk/debug/app-debug.apk`. The release packaging script signs a non-debuggable Release APK using a keystore supplied outside the repository; private signing files are never committed.

```sh
# macOS preview DMG
python3 scripts/package-release.py --platform macos

# Android: provide private file paths through the environment
export MACTV_ANDROID_KEYSTORE=/secure/path/mactv-release.p12
export MACTV_ANDROID_PASSWORD_FILE=/secure/path/signing-password
export MACTV_ANDROID_KEY_ALIAS=mactv
python3 scripts/package-release.py --platform android
```

`ANDROID_HOME` must point to the installed SDK. Keep the keystore and its password outside the repository and back them up privately for future updates. Generated downloads go to `dist/`.

### Tests

```sh
protocol/tests/run-swift-tests.sh
MacTV_MacApp/Tests/run-local-movie-tests.sh
python3 protocol/tests/run-integration.py
```

Local-video tests require VLC 3 and FFmpeg for a generated fixture. Android instrumentation and real-provider tests need a device, explicit opt-in arguments and the appropriate running receiver/provider. Build or command acknowledgements alone do not prove account-specific streaming playback. Fresh-install, foreground reconnection and live-provider behaviour should be tested on the receiving devices.

## Privacy and project status

API keys and pairing credentials are stored in platform key stores, not included in downloads. Library history, bookmarks, metadata and preferences remain local. Optional online services receive the requests needed for their features. See [PRIVACY.md](PRIVACY.md) for details.

MacTV is an independent project and is not affiliated with the services it launches. No project licence has been selected yet; third-party software and services retain their own licences and terms.
