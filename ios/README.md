# Radio-iOS

The iOS companion to the macOS Radio app (same repo, `ios/` directory). A
lightweight native app that plays your saved radio / live streams and lets you
cast to AirPlay and CarPlay.

## What plays in-app

| Stream type | In-app playback |
|-------------|-----------------|
| Audio (Icecast/Shoutcast/MP3/AAC/direct) | ✅ AVPlayer |
| Video / live direct URLs (`.mp4`, `.m3u8`, `.mpd`) | ✅ AVPlayer |
| **Channel** whose page embeds a literal HLS/DASH manifest | ✅ AVPlayer (via `ChannelResolver` scrape) |
| **Channel** — YouTube / Twitch / Kick live | ⚠️ **Open in Browser instead** |

## Channel streams: the honest story

A `.channel` stream's stored `url` is a **source page** (e.g.
`https://www.youtube.com/@channel`) — AVPlayer cannot play a page. On macOS the
app resolves these with yt-dlp/streamlink subprocesses. iOS forbids spawning
subprocesses, so the iOS app uses a two-layer approach:

### Layer 1 — best-effort in-app resolution (`Radio/ChannelResolver.swift`)
Pure native (URLSession + regex, no dependency, App-Store-safe): fetch the
channel page and search its HTML for a literal `.m3u8` / `.mpd` manifest URL,
then hand that to AVPlayer. This makes channels whose page literally embeds a
manifest (many TV / independent streamers) play in-app.

### Layer 2 — graceful "Open in Browser" fallback
When a channel can't resolve in-app (returns no literal manifest), tapping it no
longer ends in a dead "Failed": the app shows a clear **"Open in Browser"**
alert, and long-pressing a channel row always offers **Open in Browser** too.
That loads the channel's page in an `SFSafariViewController` so the user watches
the live stream in Safari.

### Known limits (documented honestly)
- **YouTube / Twitch / Kick live streams do NOT play in-app.** Their streams
  are served from signed, DRM-protected URLs that change per request; they
  cannot be extracted reliably in pure Swift, and the pages do not embed literal
  manifests. These open in the browser instead. (The macOS app CAN play them
  because it shells out to yt-dlp.)
- **Playback in Safari is not app playback**: it does not appear in the app's
  player bar, does not AirPlay/CarPlay from the app, and stops when Safari
  stops. This is the honest iOS constraint, not a workaround we hide.
- Resolution is best-effort and web content changes; a channel that used to
  embed a manifest may stop. On failure it always falls back to Open in Browser.

## Building

```
cd ios
xcodegen generate --spec project.yml   # after first clone / after adding files
xcodebuild -project Radio.xcodeproj -scheme Radio -destination 'generic/platform=iOS' build
```

Tests: `xcodebuild test -project Radio.xcodeproj -scheme Radio -destination 'generic/platform=iOS'`.
