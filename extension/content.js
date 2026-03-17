// Radio Extension — Content Script
// Scans the current page for stream URLs (HLS, DASH, Icecast, media elements)
// Also intercepts network requests to catch dynamically loaded streams
// Runs in all frames (including cross-origin iframes)

const api = typeof browser !== "undefined" ? browser : chrome;
const interceptedURLs = new Set();

// Tracking, analytics, and non-stream domains to ignore
const junkDomains = [
  "jwpltx.com",
  "google-analytics.com",
  "googletagmanager.com",
  "doubleclick.net",
  "googlesyndication.com",
  "facebook.net",
  "scorecardresearch.com",
  "chartbeat.net",
  "newrelic.com",
  "hotjar.com",
  "segment.io",
  "amplitude.com",
  "mixpanel.com",
  "sentry.io",
];

function isJunk(url) {
  try {
    const u = new URL(url);
    if (junkDomains.some((d) => u.hostname === d || u.hostname.endsWith("." + d))) return true;
    if (/status-json\.xsl|status\.xsl|admin\/|stats\?/i.test(u.pathname + u.search)) return true;
    return false;
  } catch {
    return false;
  }
}

// Report stream from iframe to background.js
function reportToBackground(url, source, type) {
  if (isJunk(url)) return;
  try {
    api.runtime.sendMessage({
      action: "streamFound",
      url,
      source,
      type,
      frameOrigin: location.origin,
    });
  } catch (e) {}
}

// Inject network interceptor into the page context (may fail due to CSP)
try {
  const interceptor = document.createElement("script");
  interceptor.textContent = `
  (function() {
    try {
      const streamPattern = /\\.(m3u8|mpd)(\\?|$)|dai\\.google\\.com\\/linear|\\/manifest\\//i;
      const captured = new Set();

      function capture(url) {
        if (typeof url === "string" && streamPattern.test(url) && !captured.has(url)) {
          captured.add(url);
          window.postMessage({ type: "RADIO_STREAM_FOUND", url: url }, "*");
        }
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        capture(url);
        return origOpen.apply(this, arguments);
      };

      var origFetch = window.fetch;
      window.fetch = function(input) {
        var url = typeof input === "string" ? input : (input && input.url);
        if (url) capture(url);
        return origFetch.apply(this, arguments);
      };
    } catch(e) {}
  })();
  `;
  document.documentElement.appendChild(interceptor);
  interceptor.remove();
} catch (e) {}

// Listen for intercepted URLs from the page context
window.addEventListener("message", (event) => {
  if (event.data && event.data.type === "RADIO_STREAM_FOUND") {
    const url = event.data.url;
    if (!isJunk(url)) {
      interceptedURLs.add(url);
      // In iframes, also report to background for cross-origin aggregation
      if (window !== window.top) {
        if (/\.m3u8/i.test(url)) reportToBackground(url, "HLS stream", "video");
        else if (/\.mpd/i.test(url)) reportToBackground(url, "DASH stream", "video");
      }
    }
  }
});

// PerformanceObserver catches all network resources (works even with CSP)
try {
  const streamMatch = /\.(m3u8|mpd)(\?|$)/i;
  const daiMatch = /dai\.google\.com\/linear\/(dash|hls)\/.*\/(manifest\.mpd|master\.m3u8)/i;
  const exclude = /\.json$|\.js$|\.css$|\.png$|\.jpg$|\.gif$|\.svg$|\.woff|\.wasm/i;
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      const url = entry.name;
      if (exclude.test(url) || isJunk(url)) continue;
      if (streamMatch.test(url) || daiMatch.test(url)) {
        interceptedURLs.add(url);
        if (window !== window.top) {
          if (/\.m3u8/i.test(url)) reportToBackground(url, "HLS stream", "video");
          else if (/\.mpd/i.test(url)) reportToBackground(url, "DASH stream", "video");
        }
      }
    }
  });
  observer.observe({ type: "resource", buffered: true });
} catch (e) {}

// ── findStreams — comprehensive on-demand scan (top frame only) ──

function findStreams() {
  const streams = [];
  const seen = new Set();
  let hasDai = false;

  // 1. Check for DAI presence (intercepted or in scripts)
  interceptedURLs.forEach((url) => {
    if (/dai\.google\.com/i.test(url)) hasDai = true;
  });
  if (!hasDai) {
    document.querySelectorAll("script").forEach((script) => {
      const text = script.textContent || "";
      if (text.length > 500000) return;
      if (/dai\.google\.com|assetKey/i.test(text)) hasDai = true;
    });
  }

  // DAI pages: just offer the page URL — StreamProbe resolves the HLS session
  if (hasDai) {
    add(location.href, "Live stream", "video");
  }

  // 2. Video and audio elements (direct src, not blob)
  document.querySelectorAll("video, audio").forEach((el) => {
    const type = el.tagName === "VIDEO" ? "video" : "audio";
    [el.src, el.currentSrc].forEach((url) => {
      if (url && !url.startsWith("blob:") && !isJunk(url) && !isDai(url))
        add(url, "Media element", type);
    });
    el.querySelectorAll("source").forEach((src) => {
      if (src.src && !src.src.startsWith("blob:") && !isJunk(src.src) && !isDai(src.src))
        add(src.src, "Media source", type);
    });
  });

  // 3. Intercepted network requests — non-DAI HLS and DASH
  const interceptedHLS = [];
  const interceptedDASH = [];
  interceptedURLs.forEach((url) => {
    if (isDai(url)) return;
    if (/\.m3u8/i.test(url)) interceptedHLS.push(url);
    else if (/\.mpd/i.test(url)) interceptedDASH.push(url);
  });

  interceptedHLS.forEach((url) => add(url, "HLS stream", "video"));
  if (interceptedHLS.length === 0) {
    interceptedDASH.forEach((url) => add(url, "DASH stream", "video"));
  }

  // 4. Scan inline scripts for non-DAI stream URLs
  document.querySelectorAll("script").forEach((script) => {
    const text = script.textContent || "";
    if (text.length > 500000) return;

    // HLS (skip DAI URLs)
    const m3u8 = text.match(/https?:\/\/[^\s"'<>\\]+\.m3u8[^\s"'<>\\]*/g);
    if (m3u8) m3u8.forEach((u) => {
      const c = clean(u);
      if (!isJunk(c) && !isDai(c)) add(c, "HLS stream", "video");
    });

    // DASH (skip DAI URLs, only if no HLS found)
    if (streams.filter((s) => s.source === "HLS stream").length === 0) {
      const mpd = text.match(/https?:\/\/[^\s"'<>\\]+\.mpd[^\s"'<>\\]*/g);
      if (mpd) mpd.forEach((u) => {
        const c = clean(u);
        if (!isJunk(c) && !isDai(c)) add(c, "DASH stream", "video");
      });
    }

    // Audio: require port pattern (8xxx) to avoid false positives from /stream in JS
    const audio = text.match(/https?:\/\/[^\s"'<>\\]+:8\d{3}\/[^\s"'<>\\]*/g);
    if (audio) audio.forEach((u) => {
      const c = clean(u);
      if (!isJunk(c)) add(c, "Audio stream", "audio");
    });
  });

  function isDai(url) {
    return /dai\.google\.com/i.test(url);
  }

  function add(url, source, type) {
    if (seen.has(url)) return;
    seen.add(url);
    streams.push({ url, source, type });
  }

  function clean(url) {
    return url.replace(/\\+$/, "").replace(/["']+$/, "");
  }

  return streams;
}

// Detect page type from URL
function detectPageType(url) {
  const lower = url.toLowerCase();

  const channelPatterns = [
    "youtube.com/@", "youtube.com/channel/", "youtube.com/c/",
    "twitch.tv/", "kick.com/",
  ];
  const notChannel = ["/watch", "/live/", "/video", "/clip", "/directory", "/category", "/following"];
  if (channelPatterns.some((p) => lower.includes(p)) && !notChannel.some((p) => lower.includes(p))) {
    return "channel";
  }

  const videoPatterns = ["youtube.com/watch", "youtube.com/live", "youtu.be/", "vimeo.com/", "dailymotion.com/", ".m3u8", ".mpd"];
  if (videoPatterns.some((p) => lower.includes(p))) return "video";

  const audioPatterns = [".mp3", ".aac", ".ogg", ".opus", ".pls", ":8443/", ":8000/", ":8080/", "/stream", "/listen", "icecast", "shoutcast"];
  if (audioPatterns.some((p) => lower.includes(p))) return "audio";

  return null;
}

// Respond to popup scan requests (top frame only)
if (window === window.top) {
  const handler = (msg, sender, sendResponse) => {
    if (msg.action === "scan") {
      sendResponse({
        streams: findStreams(),
        title: document.title,
        pageUrl: location.href,
        pageType: detectPageType(location.href),
      });
    }
  };

  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener(handler);
  } else if (typeof browser !== "undefined" && browser.runtime) {
    browser.runtime.onMessage.addListener((msg) => {
      if (msg.action === "scan") {
        return Promise.resolve({
          streams: findStreams(),
          title: document.title,
          pageUrl: location.href,
          pageType: detectPageType(location.href),
        });
      }
    });
  }
}
