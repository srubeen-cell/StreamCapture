// Captures one tab with chrome.tabCapture and records it with MediaRecorder.

let recorder = null;
let chunks = [];
let stream = null;
let audioContext = null;
let fileTitle = "Tab";

// MP4 (H.264 + AAC) where Chrome supports it, otherwise WebM. StreamCapture can convert either.
function pickFormat() {
  const options = [
    { mime: "video/mp4;codecs=avc1.640028,mp4a.40.2", ext: "mp4" },
    { mime: "video/mp4", ext: "mp4" },
    { mime: "video/webm;codecs=vp9,opus", ext: "webm" },
    { mime: "video/webm", ext: "webm" },
  ];
  return options.find((o) => MediaRecorder.isTypeSupported(o.mime)) || options[options.length - 1];
}

function safeName(text) {
  return text.replace(/[\\/:*?"<>|]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 80) || "Tab";
}

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} at ${p(d.getHours())}.${p(d.getMinutes())}.${p(d.getSeconds())}`;
}

async function start(streamId, title) {
  fileTitle = safeName(title);
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
    video: {
      mandatory: {
        chromeMediaSource: "tab",
        chromeMediaSourceId: streamId,
        maxWidth: 1920,
        maxHeight: 1080,
        maxFrameRate: 30,
      },
    },
  });

  // Capturing a tab mutes it for you; play it back so you keep hearing it while it records.
  audioContext = new AudioContext();
  audioContext.createMediaStreamSource(stream).connect(audioContext.destination);

  const format = pickFormat();
  chunks = [];
  recorder = new MediaRecorder(stream, {
    mimeType: format.mime,
    videoBitsPerSecond: 8_000_000,
    audioBitsPerSecond: 192_000,
  });
  recorder.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data); };
  recorder.onstop = () => {
    const blob = new Blob(chunks, { type: format.mime });
    const url = URL.createObjectURL(blob);
    chrome.runtime.sendMessage({
      target: "background",
      type: "save",
      url,
      filename: `StreamCapture/Tab ${timestamp()} - ${fileTitle}.${format.ext}`,
    });
    cleanUp();
    // Keep the blob alive long enough for the download to start.
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  };
  // If the tab navigates away or capture ends, finish the file.
  stream.getVideoTracks()[0].addEventListener("ended", () => {
    if (recorder && recorder.state !== "inactive") recorder.stop();
    chrome.runtime.sendMessage({ target: "background", type: "ended" });
  });
  recorder.start(1000);
}

function cleanUp() {
  if (stream) stream.getTracks().forEach((t) => t.stop());
  if (audioContext) audioContext.close();
  stream = null;
  audioContext = null;
  recorder = null;
  chunks = [];
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.target !== "offscreen") return;
  if (msg.type === "start") {
    start(msg.streamId, msg.title)
      .then(() => sendResponse({ ok: true }))
      .catch((err) => { cleanUp(); sendResponse({ error: String(err) }); });
    return true;
  }
  if (msg.type === "stop") {
    if (recorder && recorder.state !== "inactive") recorder.stop();
    sendResponse({ ok: true });
  }
});
