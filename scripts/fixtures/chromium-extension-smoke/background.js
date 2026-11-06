chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.kind !== "kestrel-extension-smoke") return false;
  chrome.storage.local.set({ kestrelSmokeReady: true }, () => {
    chrome.storage.local.get("kestrelSmokeReady", value => {
      sendResponse({
        ok: value.kestrelSmokeReady === true,
        extensionId: chrome.runtime.id
      });
    });
  });
  return true;
});
