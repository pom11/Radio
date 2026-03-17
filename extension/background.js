// Radio Extension — Background Service Worker
// Aggregates intercepted streams from content scripts and webRequest API

const tabStreams = new Map();

// Intercept .m3u8 and .mpd requests at the browser network level.
// This catches streams from cross-origin iframes, CSP-blocked pages,
// and JS-rewritten URLs that content scripts can't see.
const streamPattern = /\.(m3u8|mpd)(\?|$)/i;
const junkDomains = [
  "googlevideo.com", "googleads", "doubleclick", "googlesyndication",
  "facebook.net", "scorecardresearch", "chartbeat", "newrelic",
];

chrome.webRequest.onBeforeRequest.addListener(
  (details) => {
    const url = details.url;
    if (details.tabId < 0) return;
    if (!streamPattern.test(url)) return;
    if (junkDomains.some((d) => url.includes(d))) return;

    if (!tabStreams.has(details.tabId)) tabStreams.set(details.tabId, {});
    const streams = tabStreams.get(details.tabId);
    if (!streams[url]) {
      const type = /\.mpd(\?|$)/i.test(url) ? "DASH stream" : "HLS stream";
      // initiator is the origin of the frame that made the request
      const initiator = details.initiator || details.documentUrl || null;
      streams[url] = {
        url,
        source: type,
        type: "video",
        frameOrigin: initiator,
      };
    }
  },
  { urls: ["<all_urls>"] }
);

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.action === "streamFound" && sender.tab) {
    const tabId = sender.tab.id;
    if (!tabStreams.has(tabId)) tabStreams.set(tabId, {});
    const streams = tabStreams.get(tabId);
    streams[msg.url] = {
      url: msg.url,
      source: msg.source,
      type: msg.type,
      frameOrigin: msg.frameOrigin || null,
    };
  }

  if (msg.action === "getStreams") {
    const streams = tabStreams.get(msg.tabId);
    sendResponse({ streams: streams ? Object.values(streams) : [] });
    return false;
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabStreams.delete(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading") {
    tabStreams.delete(tabId);
  }
});
