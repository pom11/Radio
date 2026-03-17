const api = typeof browser !== "undefined" ? browser : chrome;
const streamsDiv = document.getElementById("streams");

let currentTab = null;

api.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  currentTab = tabs[0];
  scan();
});

function scan() {
  streamsDiv.textContent = "";
  const scanning = document.createElement("div");
  scanning.className = "empty";
  scanning.textContent = "Scanning...";
  streamsDiv.appendChild(scanning);

  let responded = false;
  const timeout = setTimeout(() => {
    if (!responded) {
      responded = true;
      // Content script didn't respond — fall back to background streams
      fetchBackgroundStreams([], "");
    }
  }, 3000);

  api.tabs.sendMessage(currentTab.id, { action: "scan" }, (response) => {
    if (responded) return;
    responded = true;
    clearTimeout(timeout);

    if ((api.runtime && api.runtime.lastError) || !response) {
      fetchBackgroundStreams([], "");
      return;
    }

    const { streams, title, pageUrl, pageType } = response;
    // Also fetch streams found in iframes via background.js
    fetchBackgroundStreams(streams, title, pageUrl, pageType);
  });
}

function fetchBackgroundStreams(contentStreams, title, pageUrl, pageType) {
  api.runtime.sendMessage(
    { action: "getStreams", tabId: currentTab.id },
    (response) => {
      const bgStreams = response && response.streams ? response.streams : [];

      // Build path index from content streams for deduplication.
      // When webRequest catches the real CDN URL and content script found
      // the same path on a different domain (from HTML source), prefer the
      // webRequest one since it's the actual network request URL.
      const pathIndex = new Map();
      contentStreams.forEach((s) => {
        try { pathIndex.set(new URL(s.url).pathname, s); } catch {}
      });

      const allStreams = [...contentStreams];
      const seenUrls = new Set(contentStreams.map((s) => s.url));

      bgStreams.forEach((s) => {
        if (seenUrls.has(s.url)) return;
        try {
          const path = new URL(s.url).pathname;
          const existing = pathIndex.get(path);
          if (existing) {
            // Same path, different domain — replace content script URL
            // with the webRequest-caught URL (the real one)
            existing.url = s.url;
            existing.source = s.source;
            seenUrls.add(s.url);
            return;
          }
        } catch {}
        seenUrls.add(s.url);
        allStreams.push(s);
      });

      const url = pageUrl || currentTab.url || "";

      // Detect YouTube channel, Twitch, Kick from page URL
      const pageStream = detectPageStream(url);
      if (pageStream && !seenUrls.has(pageStream.url)) {
        allStreams.push(pageStream);
      }

      renderStreams(allStreams, title || currentTab.title || "", url);
    }
  );
}

function detectPageStream(url) {
  const u = url.toLowerCase();
  const noChannel = ["/videos", "/clip", "/directory", "/category", "/settings", "/following"];
  if (noChannel.some((p) => u.includes(p))) return null;

  if (/youtube\.com\/(watch|live)|youtu\.be\//i.test(url)) {
    return { url, source: "YouTube video", type: "video" };
  }
  if (/youtube\.com\/(@[\w.-]+|channel\/[\w-]+|c\/[\w.-]+|user\/[\w.-]+)(\/|$)/i.test(url)) {
    return { url, source: "YouTube channel", type: "channel" };
  }
  if (/twitch\.tv\/[\w]+$/i.test(url)) {
    return { url, source: "Twitch channel", type: "channel" };
  }
  if (/kick\.com\/[\w]+$/i.test(url)) {
    return { url, source: "Kick channel", type: "channel" };
  }
  return null;
}

function renderStreams(streams, title, pageUrl) {
  streamsDiv.textContent = "";

  if (streams.length === 0) {
    showMessage("No streams detected");
    addRescanButton();
    return;
  }

  const label = document.createElement("div");
  label.className = "section-title";
  label.textContent =
    streams.length === 1
      ? "1 stream found"
      : streams.length + " streams found";
  streamsDiv.appendChild(label);

  streams.forEach((s) => {
    const div = document.createElement("div");
    div.className = "stream";

    const btn = document.createElement("button");
    btn.className = "btn";

    const sourceEl = document.createElement("div");
    sourceEl.className = "source";
    sourceEl.textContent = s.source;

    const urlEl = document.createElement("div");
    urlEl.className = "url";
    urlEl.textContent =
      s.url.length > 70 ? s.url.substring(0, 70) + "..." : s.url;

    btn.appendChild(sourceEl);
    btn.appendChild(urlEl);

    btn.addEventListener("click", () => {
      const name = cleanTitle(title);
      const params = {
        url: s.url,
        name,
        type: s.type,
        pageUrl,
      };

      // Include referer if stream came from a different origin (iframe/CDN)
      if (s.frameOrigin && s.frameOrigin !== location.origin) {
        const origin = s.frameOrigin.replace(/\/$/, "");
        params.referer = origin + "/";
      }

      sendRadio("add", params);

      btn.classList.add("added");
      btn.textContent = "";
      const done = document.createElement("div");
      done.className = "source";
      done.style.color = "#4caf50";
      done.textContent = "Added to Radio";
      btn.appendChild(done);
    });

    div.appendChild(btn);
    streamsDiv.appendChild(div);
  });

  addRescanButton();
}

function sendRadio(action, params) {
  const qs = Object.entries(params)
    .filter(([, v]) => v != null && v !== "")
    .map(([k, v]) => k + "=" + encodeURIComponent(v))
    .join("&");
  location.href = "radio://" + action + "?" + qs;
}

function showMessage(text) {
  const msg = document.createElement("div");
  msg.className = "empty";
  msg.textContent = text;
  streamsDiv.appendChild(msg);
}

function addRescanButton() {
  const div = document.createElement("div");
  div.style.textAlign = "center";
  div.style.paddingTop = "6px";

  const btn = document.createElement("button");
  btn.className = "btn-rescan";
  btn.textContent = "Rescan";
  btn.addEventListener("click", () => scan());

  div.appendChild(btn);
  streamsDiv.appendChild(div);
}

function cleanTitle(title) {
  if (!title) return "";
  const separators = [" | ", " - ", " :: ", " \u2014 ", " \u00b7 "];
  for (const sep of separators) {
    if (title.includes(sep)) {
      return title.split(sep)[0].trim();
    }
  }
  return title.trim();
}
