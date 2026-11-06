#!/usr/bin/env python3
"""Visible-user stress on a disposable GitHub Mac. No provider credentials.

Uses native keyboard commands, accessibility readback and a real file
picker. Local HTTP fixtures make navigation observable without external-site
flakiness. A screenshot or a live process alone never counts as a state check.
"""
import http.server
import json
import os
import pathlib
import plistlib
import socketserver
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse

OUT = pathlib.Path(os.environ["KESTREL_STRESS_OUT"])
APP = pathlib.Path(os.environ["KESTREL_STRESS_APP"])
CYCLES = int(os.environ.get("KESTREL_STRESS_CYCLES", "12"))
ENGINE = os.environ.get("KESTREL_STRESS_ENGINE", "unknown")
assert 1 <= CYCLES <= 30
OUT.mkdir(parents=True, exist_ok=True)
events, hits = [], []
observed_mismatches = []
started = time.monotonic()
AX_CLIENT = OUT / "macos-accessibility"
PID = None


def command(argv, timeout=30):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()


def script(body):
    return command(["osascript", "-e", body])


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def ui(body):
    assert PID is not None
    return script(f'tell application "System Events" to tell (first application process whose unix id is {PID})\n' + body + "\nend tell")


def record(action, **data):
    entry = dict(action=action, elapsed=round(time.monotonic() - started, 3), **data)
    events.append(entry)
    (OUT / "events.json").write_text(json.dumps(events, indent=2))
    print(json.dumps(entry), flush=True)


def wait(check, description, timeout=12):
    end = time.monotonic() + timeout
    last = None
    prompt_check = time.monotonic() + 1
    while time.monotonic() < end:
        try:
            if check():
                record("assert", state=description)
                return
        except (subprocess.SubprocessError, ValueError) as error:
            last = getattr(error, "stderr", None) or str(error)
        if PID and time.monotonic() >= prompt_check:
            prompt = json.loads(command([str(AX_CLIENT), PID, "dismiss-local-network", str(OUT / "local-network-prompt.png")]))
            if prompt["dismissed"]:
                record("local_network_prompt", **prompt)
                ui('set frontmost to true')
            prompt_check = time.monotonic() + 3
        time.sleep(0.15)
    raise AssertionError(f"State not reached: {description}; last error: {last}")


def fields(label):
    return json.loads(command([str(AX_CLIENT), PID, "fields", label]))


def count(label):
    return json.loads(command([str(AX_CLIENT), PID, "count", label]))["count"]


def focused(label):
    return json.loads(command([str(AX_CLIENT), PID, "focused", label]))["focused"]


def resize_window(width, height):
    target = json.loads(command([str(AX_CLIENT), PID, "resize", f"{width},{height}"]))
    def resized():
        frame = json.loads(command([str(AX_CLIENT), PID, "window_frame"]))
        return all(abs(frame[dimension] - target[dimension]) < 2 for dimension in ("width", "height"))
    wait(resized, "main document resized")
    record("document_resized", requested_width=width, requested_height=height, **target)


def menu_rows(menu_name):
    apple_menu = quote(menu_name)
    body = f'''click menu bar item {apple_menu} of menu bar 1
delay 0.15
set encodedRows to ""
repeat with oneItem in menu items of menu 1 of menu bar item {apple_menu} of menu bar 1
    try
        set itemTitle to (name of oneItem) as text
        set itemEnabled to (enabled of oneItem) as text
        set encodedRows to encodedRows & itemTitle & (ASCII character 31) & itemEnabled & (ASCII character 30)
    end try
end repeat
key code 53
encodedRows'''
    raw = ui(body)
    rows = []
    for entry in raw.split("\x1e"):
        if not entry:
            continue
        title, _, enabled_value = entry.partition("\x1f")
        rows.append({"title": title, "enabled": enabled_value.lower() == "true"})
    record("menu_opened", menu=menu_name, items=rows)
    return rows


def verify_menu_state(menu_name, expected):
    rows = {row["title"]: row["enabled"] for row in menu_rows(menu_name)}
    for title, value in expected.items():
        observed = rows.get(title)
        record("menu_state_assert", menu=menu_name, item=title, expected=value, actual=observed, passed=observed == value)
        assert observed == value, f"{menu_name} menu item {title!r}: expected enabled={value}, got {observed}"


def select_menu_item(menu_name, item_name):
    ui('set frontmost to true')
    command([str(AX_CLIENT), PID, "menu_select", menu_name + "|" + item_name])
    record("menu_command", menu=menu_name, item=item_name)


def click(label):
    command([str(AX_CLIENT), PID, "click", label])
    record("click", control=label)


def pointer_click(label):
    point = json.loads(command([str(AX_CLIENT), PID, "pointer", label]))
    record("pointer_click", **point)


def invoke(group, item):
    # Use the real command bindings; AX menu selection on hosted macOS can
    # leave tracking menus open without committing the selected command.
    shortcuts = {
        "Focus Address Bar": ("l", ["command", "control"]),
        "Go Back": ("[", ["command", "control"]),
        "Go Forward": ("]", ["command", "control"]),
        "Separate Split View": ("s", ["command", "control", "option"]),
        "Equal Split Widths": ("0", ["command", "control", "option"]),
        "Close Tab": ("w", ["command"]),
        "Reopen Closed Tab": ("t", ["command", "shift"]),
        "Show Assistant": ("e", ["command"]),
        "Hide Assistant": ("e", ["command"]),
        "Open Assistant Page": ("p", ["command", "control", "option"]),
    }
    if item in ("Next Tab", "Previous Tab", "Move Tab to Left Split"):
        code = 124 if item == "Next Tab" else 123
        modifiers = "command down" if item == "Move Tab to Left Split" else "command down, control down, option down"
        ui(f"key code {code} using {{{modifiers}}}")
    else:
        key(*shortcuts[item])
    record("keyboard_command", group=group, item=item)


def key(text, modifiers=None):
    suffix = " using {" + ", ".join(x + " down" for x in modifiers) + "}" if modifiers else ""
    ui("set frontmost to true\nkeystroke " + quote(text) + suffix)


def enter():
    ui("key code 36")


def snapshot(name):
    assert command(["pgrep", "-x", "Kestrel"])
    assert int(ui("return count windows")) > 0
    command(["screencapture", "-x", str(OUT / (name + ".png"))])
    record("screenshot", name=name)


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append(self.path)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        page = query.get("page", ["A"])[0]
        body = f'''<!doctype html><title>Stress fixture {page}</title>
        <h1>Kestrel stress fixture {page}</h1><p>Visible local navigation evidence.</p>
        <label>Editable note <input name="note" autocomplete="off"></label>
        <a href="/?page=B">Next fixture</a><div style="height:1400px"></div>
        <button onclick="this.textContent='Clicked'">Below-fold control</button>'''.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class LoopbackServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer otherwise performs reverse-DNS hostname discovery. This
        # fixture needs only loopback; avoid macOS's Python local-network prompt.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = LoopbackServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"


def navigate(path):
    invoke("Navigate", "Focus Address Bar")
    key("a", ["command"])
    target = base + path
    key(target)
    try:
        # Wait for the edit itself, not only the eventual page load. This
        # preserves evidence when the focus shortcut opens suggestions but
        # the following keystrokes do not replace the address.
        wait(lambda: any(path in value for value in fields("Address bar")),
             "address field accepted " + path, timeout=2)
    except AssertionError:
        values = fields("Address bar")
        mismatch = f"Focus Address Bar followed by typing did not place {path!r} in the address field; values: {values}"
        observed_mismatches.append(mismatch)
        record("address_shortcut_input_mismatch", path=path, address_values=values)
        snapshot("address-shortcut-input-mismatch")
        # Retry with a real pointer click only when the layout exposes one
        # address control. The original keyboard attempt remains a reported
        # mismatch even if this diagnostic retry succeeds.
        if count("Address bar") != 1:
            raise AssertionError(mismatch)
        pointer_click("Address bar")
        key("a", ["command"])
        key(target)
        wait(lambda: any(path in value for value in fields("Address bar")),
             "address field accepted " + path + " after pointer focus")
    enter()
    wait(lambda: path in hits and any(path in value for value in fields("Address bar")), "loaded " + path)
    record("address_focus_verified_by_navigation", path=path)


def message_value():
    values = fields("Assistant message")
    return values[0] if values else ""


def accessibility_dump():
    return command([str(AX_CLIENT), PID, "dump"])


result = {"cycles_requested": CYCLES, "kind": "visible UI with local HTTP fixtures; no live model requests"}
if os.environ.get("KESTREL_UI_PROBE"):
    result["kind"] = "diagnostic only; not stress acceptance"
try:
    command(["swiftc", str(pathlib.Path(__file__).with_name("macos-accessibility.swift")), "-o", str(AX_CLIENT)], timeout=120)
    subprocess.run(["pkill", "-TERM", "-x", "Kestrel"], capture_output=True)
    wait(lambda: subprocess.run(["pgrep", "-x", "Kestrel"], capture_output=True).returncode != 0, "previous app exited before seeding preferences")
    # Only this disposable runner's synthetic app profile is replaced. The
    # three otherwise unbound commands receive ordinary configurable bindings.
    overrides = {name: {"key": key, "modifiers": ["command", "control", "option"]}
                 for name, key in {"separateSplit": "s", "equalSplit": "0", "assistantPage": "p"}.items()}
    preferences = OUT / "synthetic-preferences.plist"
    preferences.write_bytes(plistlib.dumps({"kestrel.shortcuts.browser.v1": json.dumps(overrides).encode()}))
    bundle_id = command(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(APP / "Contents/Info.plist")])
    if ENGINE == "chromium":
        command(["swift", str(pathlib.Path(__file__).with_name("seed-macos-preferences.swift")), bundle_id, str(preferences)])
    else:
        command(["defaults", "import", bundle_id, str(preferences)])
    record("synthetic_profile_configured", bundle_id=bundle_id, shortcut_overrides=overrides,
           close_tab_checks_skipped=os.environ.get("KESTREL_STRESS_SKIP_CLOSE_TAB") == "1")
    command(["open", "-a", str(APP), "--stderr", str(OUT / "runtime.log"), "--args", "--kestrel-desktop-audit"])
    wait(lambda: bool(command(["pgrep", "-x", "Kestrel"])), "app running")
    pid = command(["pgrep", "-x", "Kestrel"]).splitlines()[0]
    PID = pid
    ui('set frontmost to true')
    wait(lambda: int(ui("return count windows")) > 0, "browser window")
    active_pid = script('tell application "System Events" to get unix id of first application process whose frontmost is true')
    assert active_pid == PID, f"Expected frontmost PID {PID}, got {active_pid}"
    executable = command(["ps", "-o", "command=", "-p", pid])
    assert str(APP / "Contents/MacOS/Kestrel") in executable, executable
    record("verified_executable", path=executable)
    resize_window(1200, 800)
    if os.environ.get("KESTREL_UI_PROBE") == "1":
        invoke("Navigate", "Focus Address Bar")
        wait(lambda: focused("Address bar"), "probe address editor focused")
        key("a", ["command"])
        key(base + "/?page=A&round=probe")
        enter()
        wait(lambda: "/?page=A&round=probe" in hits, "probe fixture received navigation")
        (OUT / "raw-accessibility.txt").write_text(accessibility_dump())
        record("probe_address_values", values=fields("Address bar"))
        snapshot("accessibility-probe")
        result.update(kind="diagnostic only; not stress acceptance", diagnostic_completed=True)
        key("q", ["command"])
        sys.exit(0)
    navigate("/?page=A&round=start")
    verify_menu_state("Tabs", {"Separate Split View": False, "Equal Split Widths": False})
    snapshot("stress-start")
    notes = OUT / "stress-notes.txt"
    notes.write_text("Synthetic unsent attachment for visible draft preservation checks.")
    for cycle in range(CYCLES):
        a, b = f"/?page=A&round={cycle}", f"/?page=B&round={cycle}"
        navigate(a)
        navigate(b)
        invoke("Navigate", "Go Back")
        wait(lambda: any(a in value for value in fields("Address bar")), "back to A")
        invoke("Navigate", "Go Forward")
        wait(lambda: any(b in value for value in fields("Address bar")), "forward to B")
        invoke("Tabs", "Move Tab to Left Split")
        try:
            wait(lambda: count("Address bar") == 2, "two independent address controls", timeout=3)
        except AssertionError:
            values = fields("Address bar")
            mismatch = f"Move Tab to Left Split shortcut did not create two address controls; visible address values: {values}"
            observed_mismatches.append(mismatch)
            record("shortcut_mismatch", item="Move Tab to Left Split", address_values=values)
            select_menu_item("Tabs", "Move Tab to Left Split")
            wait(lambda: count("Address bar") == 2, "two independent address controls after using the Tabs menu")
        verify_menu_state("Tabs", {"Separate Split View": True, "Equal Split Widths": True})
        invoke("Tabs", "Next Tab")
        if cycle == 0:
            (OUT / "split-after-next-tab.json").write_text(accessibility_dump())
        wait(lambda: json.loads(command([str(AX_CLIENT), PID, "selected", "Right pane: New Tab"]))["selected"], "right split pane selected")
        navigate(a)
        wait(lambda: any(a in value for value in fields("Address bar")) and any(b in value for value in fields("Address bar")), "both split destinations retained")
        resize_window(780, 620)
        invoke("Tabs", "Equal Split Widths")
        if cycle == 0:
            snapshot("stress-narrow-split")
        invoke("Tabs", "Previous Tab")
        invoke("Tabs", "Next Tab")
        invoke("Tabs", "Separate Split View")
        wait(lambda: count("Address bar") == 1, "split separated")
        verify_menu_state("Tabs", {"Separate Split View": False, "Equal Split Widths": False})
        if os.environ.get("KESTREL_STRESS_SKIP_CLOSE_TAB") != "1":
            invoke("File", "Close Tab")
            wait(lambda: int(ui("return count windows")) > 0 and any(b in value for value in fields("Address bar")), "Cmd-W closes only the selected tab")
            invoke("File", "Reopen Closed Tab")
            wait(lambda: any(a in value for value in fields("Address bar")), "closed tab reopened with its destination")
        resize_window(1200, 800)
        invoke("Assistant", "Show Assistant")
        wait(lambda: count("Assistant message") == 1, "sidebar composer available")
        assert "Hide Assistant" in [row["title"] for row in menu_rows("Assistant")]
        click("Assistant message")
        draft = f"Unsent stress draft {cycle}"
        key(draft)
        wait(lambda: message_value() == draft, "typed draft read back")
        if ENGINE == "chromium":
            click("Agent mode")
            wait(lambda: fields("Agent mode") == ["On"], "Agent mode On in the sidebar")
            click("Agent mode")
            wait(lambda: fields("Agent mode") == ["Off"], "Agent mode Off in the sidebar")
        elif ENGINE == "webkit":
            # The archived 1.0.0 comparison uses a Browse composer control,
            # while the Chromium build exposes Agent mode. Record the old
            # surface without applying newer semantics to it.
            browse_count = count("Browse")
            record("webkit_baseline_composer_mode", control="Browse", visible=browse_count == 1,
                   accessibility_count=browse_count)
        if cycle == 0:
            pointer_click("Attach files")
            wait(lambda: count("Open") == 1, "native file picker opened")
            key("g", ["command", "shift"])
            wait(lambda: json.loads(command([str(AX_CLIENT), PID, "focused_text"]))["count"] > 0, "Go to Folder input focused")
            key("a", ["command"])
            key(notes)
            enter()
            wait(lambda: count("Remove stress-notes.txt") == 1 or json.loads(command([str(AX_CLIENT), PID, "enabled", "Attach"]))["enabled"], "synthetic file selected")
            if count("Remove stress-notes.txt") == 0:
                pointer_click("Attach")
            wait(lambda: count("Remove stress-notes.txt") == 1, "file picker attached synthetic text")
            wait(lambda: message_value() == draft, "attachment selection leaves draft unsent")
        invoke("Assistant", "Hide Assistant")
        wait(lambda: count("Assistant message") == 0, "sidebar hidden")
        assert "Show Assistant" in [row["title"] for row in menu_rows("Assistant")]
        invoke("Assistant", "Show Assistant")
        wait(lambda: message_value() == draft, "draft survives sidebar replacement")
        invoke("Assistant", "Open Assistant Page")
        wait(lambda: message_value() == draft, "draft survives opening full chat page")
        if cycle == 0:
            wait(lambda: count("Remove stress-notes.txt") == 1, "attachment survives switching Assistant surfaces")
            snapshot("stress-draft-and-attachment")
        click("Start a new chat")
        wait(lambda: count("Assistant message") == 1 and message_value() == "" and count("Remove stress-notes.txt") == 0, "New Chat clears draft and attachment")
        if cycle == 0:
            snapshot("stress-reset")
        if os.environ.get("KESTREL_STRESS_SKIP_CLOSE_TAB") != "1":
            invoke("File", "Close Tab")
            # Close the extra fixture tab from this cycle; keep the other one.
            invoke("File", "Close Tab")
        if ENGINE == "chromium" and cycle == 0:
            select_menu_item("Tabs", "Move Tab to Right Split")
            wait(lambda: count("Address bar") == 2, "native menu creates both split cards")
            snapshot("stress-menu-split")
            select_menu_item("Tabs", "Separate Split View")
            wait(lambda: count("Address bar") == 1, "native menu separates both split cards")
        if cycle % 3 == 0:
            key(",", ["command"])
            wait(lambda: ui('return name of window 1') == "Kestrel Settings", "Settings window opened")
            key("w", ["command"])
            wait(lambda: int(ui("return count windows")) > 0 and ui('return name of window 1') != "Kestrel Settings", "Cmd-W closes Settings without closing the browser")
        pid = command(["pgrep", "-x", "Kestrel"]).splitlines()[0]
        rss = int(command(["ps", "-o", "rss=", "-p", pid]))
        record("cycle_completed", cycle=cycle + 1, app_rss_kib=rss)
    snapshot("stress-complete")
    key("q", ["command"])
    wait(lambda: subprocess.run(["pgrep", "-x", "Kestrel"], capture_output=True).returncode != 0, "app exited after stress", timeout=10)
    result.update(passed=not observed_mismatches, cycles_completed=CYCLES,
                  observed_mismatches=observed_mismatches,
                  elapsed_seconds=round(time.monotonic() - started, 2))
    if observed_mismatches:
        raise AssertionError("; ".join(observed_mismatches))
except Exception as error:
    result.update(passed=False, error=traceback.format_exc(), elapsed_seconds=round(time.monotonic() - started, 2))
    if getattr(error, "stderr", None):
        result["subprocess_stderr"] = error.stderr
    (OUT / "failure.txt").write_text(result["error"])
    try:
        (OUT / "accessibility-failure.txt").write_text(accessibility_dump())
    except Exception as diagnostic_error:
        (OUT / "accessibility-failure.txt.error.txt").write_text(getattr(diagnostic_error, "stderr", None) or str(diagnostic_error))
    try:
        command(["screencapture", "-x", str(OUT / "stress-failure.png")])
    except Exception as diagnostic_error:
        (OUT / "failure-screenshot.error.txt").write_text(getattr(diagnostic_error, "stderr", None) or str(diagnostic_error))

    raise
finally:
    (OUT / "result.json").write_text(json.dumps(result, indent=2))
    (OUT / "fixture-requests.json").write_text(json.dumps(hits, indent=2))
    server.shutdown()
