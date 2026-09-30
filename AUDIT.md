# Radio — Knowledge Audit

Audit date: 2026-09-30 · Commit audited: `86e0f64` (main, v4.4.9)
Repo: https://github.com/pom11/Radio · Bundle ID: `ro.pom.radio` · macOS 14.0+ · Swift 5.9

Purpose: refresh working knowledge of the Radio codebase — what it does, how the
pieces fit, and the notable risks/gotchas a future agent should know.

---

## 1. What it is

A lightweight, native macOS menu-bar app (SwiftUI + AVFoundation + AppKit) for
internet radio and live video streams. No Electron, no third-party frameworks.
Streams resolve through three installed CLI tools: **ffmpeg**, **yt-dlp**, and
**streamlink** (Homebrew, checked at launch).

Recent v4.4.x milestones (from git log tail): popover opening at login, ghost
hidden windows, hotkeys in single-stream mode, Chromecast casting, HLS stream
stability, app icon in About.

## 2. Layout & key files

```
Package.swift            SwiftPM manifest (.executableTarget, path=Sources)
Makefile                 build/install/setup; copies Info.plist, Resources, extension
Info.plist               CFBundleShortVersionString = 4.4.9; LSUIElement(true)
Sources/ (17 Swift files, ~5.9k LOC)   see per-file notes below
extension/               MV3 browser extension (popup.js, background.js, content.js)
scripts/generate_appintents_metadata.sh
Resources/               AppIcon.icns, menubar*.png, Assets.car, Metadata.appintents/
```

16 Swift source files (Sources contains only .swift + Assets.xcassets):

| File | Lines | Role |
|------|------:|------|
| StreamPlayer.swift | 402 | AVPlayer playback, reconnect, header injection, proxy fallback |
| PlayerManager.swift | 328 | Multi-stream coordinator, active player, solo, video windows |
| OutputManager.swift | 325 | Device discovery (CoreAudio + Bonjour), cast routing, volume |
| RadioView.swift | 1187 | Settings window: all sidebar sections + UpdateChecker + sheets |
| VideoWindow.swift | 491 | Floating NSPanel video window (audio/cast aware) |
| CastController.swift | 882 | Chromecast Cast protocol, NWConnection TLS, hand-rolled protobuf |
| CastProxy.swift | 402 | Local ffmpeg HLS→fragmented-MP4 HTTP proxy for cast |
| StreamProbe.swift | 862 | URL resolution: pattern, HTTP/ICY probe, yt-dlp, streamlink, DAI |
| RadioApp.swift | 732 | App lifecycle, status item, URL scheme, menu bar, crash/update check |
| HeaderProxy.swift | 275 | HTTP header-injection proxy for HLS (m3u8 playlist stabilization) |
| RadioIntents.swift | 411 | App Intents: 14 intents, AppShortcutsProvider |
| HotKeyManager.swift | 287 | Carbon global hotkeys (EventHotKey) |
| MenuBarPopover.swift | 228 | Popover UI + stream list |
| StreamStore.swift | 168 | Stream model + JSON persistence + Spotlight indexing |
| YouTubeLoungeAPI.swift | 105 | YouTube Lounge API for casting YouTube |
| PlayerControlCard.swift | 230 | Unified control card (popover/overlay/settings) |
| URLResolver.swift | 69 | Thin facade: detectType/probe/resolve → StreamProbe |

## 3. Data model & persistence

- `Stream` (StreamStore.swift:35): `id: UUID`, `name`, `url`, `type`
  (audio/video/channel), `pageUrl?`, `referer?`, `headers?`. Decodable is
  hand-written for backward compatibility (missing `type` → `.audio`).
- `StreamPlatform` computed from URL (youtube/twitch/kick/other).
- Persisted to `~/.config/radio/streams.json` (StreamStore.swift:98). Save is
  async/detached, pretty-printed + sorted keys. `load()` re-indexes Spotlight.
- `sharedStore` is a global singleton defined in **RadioIntents.swift:4**
  (not a static on StreamStore). Both app UI and intents reference it.
- Spotlight indexing: domain `ro.pom.radio.streams`; delete-then-index on each
  save (StreamStore.swift:148-152).
- Per-stream volume persists in UserDefaults under `playerVolume_<url>`
  (StreamPlayer.swift:54,246).

## 4. Playback pipeline

1. `PlayerManager.play(stream:)` — toggle-off if same URL already playing; in
   single-stream mode stops all first; enforces `maxStreams` (default 4);
   creates a `StreamPlayer`; sets output device; handles Chromecast takeover.
2. `StreamPlayer.play` → `URLResolver.resolve` (async) → `StreamProbe.resolve`.
3. `startPlayback` branches on device:
   - **Cast**: builds cast URL (YouTube watch URL if `youtube_id`), allocates
     a proxy port, `OutputManager.castURL(...)`.
   - **Local**: resolves to playable URL; builds custom headers; if HLS or
     proxy-fallback, spins up `HeaderProxy` (native header injection only covers
     the initial manifest, not segment requests); else native
     `AVURLAssetHTTPHeaderFieldsKey`.
4. Reconnect (`observeStatus`): `.failed` → retry with proxy fallback if headers
   present, else `reconnect()`. Paused/waiting → nudging (3s) + scheduled
   reconnect (8s paused / 20s waiting / 30s proxied).

## 5. Resolution chain (StreamProbe.resolve)

Order: direct audio stream → direct HLS (`.m3u8`) → direct DASH (`.mpd`, with
Google DAI → HLS via SSAI) → yt-dlp → streamlink → scrape page → as-is fallback.
Type detection is heuristic: URL patterns + HTTP/ICY probe + yt-dlp.

Detection (`detect`): HTTP/ICY probe catches icecast/shoutcast/direct streams;
yt-dlp for YouTube/pages; scrape for embedded URLs.

## 6. Output & casting

- `OutputManager` discovers local CoreAudio devices (skips built-in, Virtual,
  Aggregate) + Chromecast via Bonjour `_googlecast._tcp.`
  (CastController.discoverDevices).
- `OutputDevice`: local (CoreAudio UID) or chromecast (device IP as id, port 8009).
- Cast stack is a full native reimplementation:
  - `CastController` — NWConnection TLS (cert verification disabled), framed
    protobuf CastMessage, heartbeat, namespaces (connection/heartbeat/receiver/
    media/youtube), LAUNCH/LOAD/PLAY/PAUSE/STOP/SET_VOLUME, 3x retry.
  - `CastProxy` — in-process NWListener HTTP server wrapping ffmpeg with
    `-c copy` HLS→fragmented-MP4; port allocator (default 9723); auto-proxy for
    any `.m3u8`/`mpegurl` cast; YouTube cast via `YouTubeLoungeAPI`
    (getLoungeToken → bind → setPlaylist).
- Chromecast takeover: starting a new stream (or changing output) on a device
  already casting; the old player is bounced back to local `macbook`, stopping
  the session and cleaning its proxy.
- `shutdownAll()` on terminate stops all proxies + cast connections
  (semaphore-bounded to 3s to avoid deadlock).

## 7. Header injection & the HeaderProxy

Two paths (StreamPlayer.swift:120-144):
- **Native**: `AVURLAssetHTTPHeaderFieldsKey` — zero overhead, but only applies
  to the initial manifest. Used for non-HLS direct URLs with headers.
- **HeaderProxy** (NWListener): when HLS needs headers on segment requests, or
  as fallback when native fails. Includes **m3u8 playlist stabilization**
  (HeaderProxy.swift:179-215): rewrites segment URLs so AVPlayer keeps a stable
  URL per media-sequence number across playlist refreshes (avoids `-12312`
  errors on CDN edge rotation).

## 8. App surface

- Menu-bar status item + popover (`MenuBarPopover`); Settings window
  (`RadioView`, NavigationSplitView with 7 sections). Popover is `.transient`,
  closes on resign-active/hide/space-change.
- Hotkeys: Carbon `RegisterEventHotKey`, 10 configurable slots, persisted in
  UserDefaults; dispatch to onX closures set in `RadioApp.setupHotKeys`.
  Video-window keyboard (space/m/f/tab/arrows) handled in
  `VideoWindowRoot.handleKeyDown`, routed via `FloatingPanel.keyDown`.
- URL scheme `radio://`: add/update/meta/remove/play (RadioApp.handleURL) — how
  the browser extension adds streams.
- App Intents: 14 total; 10 get Siri phrases (AppShortcutsProvider limit);
  Solo/Show/Hide/Fullscreen are Shortcuts-only.
- On-launch: strips menu bar to Quit+Edit+File, updates bundled extension if
  newer than Application Support copy, checks crash reports, optional update
  check, checks CLI dependency versions (parses + semver-compares).

## 9. Hygiene & security findings

- **No real infra addresses baked in.** Only IP-like matches are the Chrome UA
  string and `100.0` volume math — nothing needs redaction. Clean.
- `CastConnection` TLS verification disabled
  (`sec_protocol_options_set_verify_block` returns `true`,
  CastController.swift:164-168). Expected for Cast protocol (self-signed certs)
  but cast traffic is unauthenticated — worth noting.
- `HeaderProxy` listens on `127.0.0.1` (acceptLocalOnly); `CastProxy` proxies on
  the LAN IP; ffmpeg UA is a fixed desktop Chrome string.
- No external Swift dependencies — dependency surface is the 3 CLI tools + the
  native reimplementations (Cast, Lounge, proxy).

## 10. Known issues / future work (TODO.md + code)

- Audio-only cast to Chromecast (JBL soundbar etc.) not implemented.
- Chromecast-only devices aren't reachable via AirPlay — no cast-audio path that
  extracts audio from HLS to a Cast receiver.
- Extension `location.href = "radio://..."` unreliable to trigger the URL scheme.
- Stream detection misses dynamically loaded players / MSE blobs / WebAudio.
- antena3.ro/live: local plays, cast fails (2 streams found, neither casts).
- **Build note:** could not verify a clean compile in this environment — Xcode
  app is installed but `xcode-select` points at CommandLineTools, so `actool`
  and the SwiftUI `@State` macro plugin both fail. Environmental, not a code
  defect. `sudo xcode-select -s /Applications/Xcode.app` fixes it.
- **Swift 6 readiness:** CastController has multiple concurrency warnings
  (`#SendableClosureCaptures` on `resumed`, `resolveConns`, `discovered`; NSLock
  used from async contexts). Package is Swift 5.9 language mode, so these are
  warnings today but become errors under Swift 6.

## 11. Operational notes for future agents

- Config lives at `~/.config/radio/streams.json` (user-editable; Reload button
  re-reads it). Extension auto-updates from the bundled copy when the bundled
  manifest version differs from the Application Support copy.
- The three CLI tools are required at runtime (checked at launch); missing or
  outdated tools trigger an alert offering a `brew upgrade` command.
- `make build` ad-hoc codesigns; `make install` drops the .app in /Applications
  and seeds a default streams.json if the user has none.
