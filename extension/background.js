// Click the toolbar button on a tab to start recording just that tab; click again to stop.
// Recording happens in an offscreen document because service workers can't use MediaRecorder.

const OFFSCREEN_URL = "offscreen.html";
let recordingTabId = null;

async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });
  if (contexts.length === 0) {
    await chrome.offscreen.createDocument({
      url: OFFSCREEN_URL,
      reasons: ["USER_MEDIA"],
      justification: "Record the selected tab's picture and sound",
    });
  }
}

async function setBadge(recording) {
  await chrome.action.setBadgeText({ text: recording ? "REC" : "" });
  await chrome.action.setBadgeBackgroundColor({ color: "#DC2626" });
  await chrome.action.setTitle({ title: recording ? "Stop recording this tab" : "Record this tab" });
}

async function start(tab) {
  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id });
  await ensureOffscreen();
  const reply = await chrome.runtime.sendMessage({ target: "offscreen", type: "start", streamId, title: tab.title || "Tab" });
  if (reply && reply.error) throw new Error(reply.error);
  recordingTabId = tab.id;
  await setBadge(true);
}

async function stop() {
  await chrome.runtime.sendMessage({ target: "offscreen", type: "stop" });
  recordingTabId = null;
  await setBadge(false);
}

chrome.action.onClicked.addListener(async (tab) => {
  try {
    if (recordingTabId !== null) {
      await stop();
    } else {
      await start(tab);
    }
  } catch (err) {
    console.error("StreamCapture:", err);
    recordingTabId = null;
    await setBadge(false);
    await chrome.action.setBadgeText({ text: "ERR" });
  }
});

// Stop cleanly if the recorded tab is closed.
chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === recordingTabId) stop();
});

// The offscreen document hands back a finished file to save.
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.target !== "background") return;
  if (msg.type === "save") {
    chrome.downloads.download({ url: msg.url, filename: msg.filename, saveAs: false, conflictAction: "uniquify" });
  } else if (msg.type === "ended") {
    recordingTabId = null;
    setBadge(false);
  }
});
