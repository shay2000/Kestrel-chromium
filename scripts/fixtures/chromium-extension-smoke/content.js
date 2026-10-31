chrome.runtime.sendMessage({ kind: "kestrel-extension-smoke" }, response => {
  const marker = document.createElement("div");
  marker.id = "kestrel-extension-smoke-result";
  marker.textContent = response?.ok
    ? "Kestrel MV3 extension smoke passed"
    : "Kestrel MV3 extension smoke failed";
  marker.style.cssText = [
    "position:fixed",
    "right:16px",
    "bottom:16px",
    "z-index:2147483647",
    "padding:8px 12px",
    "border-radius:8px",
    "background:#14532d",
    "color:white",
    "font:14px -apple-system,BlinkMacSystemFont,sans-serif",
    "box-shadow:0 2px 8px #0005"
  ].join(";");
  document.documentElement.appendChild(marker);
});
