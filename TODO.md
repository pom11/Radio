# Radio TODO

## Casting
- [ ] Audio-only casting to Chromecast devices (JBL soundbar, etc.) — YouTube channels and audio streams should cast audio without requiring video support
- [ ] Chromecast-only devices not available via AirPlay — need a cast-audio path that extracts audio from HLS and sends to Cast receiver

## Browser Extension
- [ ] `location.href = "radio://..."` unreliable for triggering URL scheme — consider `chrome.tabs.create` + auto-close, or native messaging
- [ ] Stream detection not reliable — some pages don't expose stream URLs in XHR/fetch interception or DOM scanning (dynamically loaded players, Web Audio API, MSE blobs)
- [ ] antena3.ro/live — local playback works, casting fails (finds 2 streams, neither casts)
