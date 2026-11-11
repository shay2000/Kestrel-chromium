#!/usr/bin/env python3
"""Open Kestrel menus and recency submenus on a disposable macOS runner."""
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import time
import uuid

APP = pathlib.Path(os.environ["KESTREL_MENU_TEST_APP"])
OUT = pathlib.Path(os.environ["KESTREL_MENU_TEST_OUT"])
ENGINE = os.environ.get("KESTREL_MENU_TEST_ENGINE", "unknown")
ROOT = pathlib.Path(__file__).resolve().parent
OUT.mkdir(parents=True, exist_ok=True)
events = []
errors = []


def command(argv, timeout=30):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()


def record(action, **data):
    event = {"action": action, "engine": ENGINE, "time": round(time.time(), 3), **data}
    events.append(event)
    (OUT / "events.json").write_text(json.dumps(events, indent=2, ensure_ascii=False))
    print(json.dumps(event, ensure_ascii=False), flush=True)


def apple_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def ui(body):
    source = 'tell application "System Events" to tell process "Kestrel"\n' + body + "\nend tell"
    return command(["osascript", "-e", source])


def menu_rows(menu_name, submenu=None):
    menu_ref = f'menu 1 of menu bar item {apple_quote(menu_name)} of menu bar 1'
    if submenu is None:
        open_menu = f'click menu bar item {apple_quote(menu_name)} of menu bar 1\ndelay 0.15'
        target_ref = menu_ref
    else:
        open_menu = (
            f'click menu bar item {apple_quote(menu_name)} of menu bar 1\n'
            f'delay 0.15\n'
            f'click menu item {apple_quote(submenu)} of {menu_ref}\n'
            "delay 0.20"
        )
        target_ref = f'menu 1 of menu item {apple_quote(submenu)} of {menu_ref}'
    body = f'''set encodedRows to ""
repeat with oneItem in menu items of {target_ref}
    try
        set itemTitle to (name of oneItem) as text
        set itemEnabled to (enabled of oneItem) as text
        set encodedRows to encodedRows & itemTitle & (ASCII character 31) & itemEnabled & (ASCII character 30)
    end try
end repeat
key code 53
key code 53
encodedRows'''
    try:
        # Capture the menu while it is open so the artifact shows the actual
        # native hierarchy that was inspected, including nested rows.
        ui(open_menu)
        time.sleep(0.2)
        image_name = "menu-" + menu_name.lower().replace(" ", "-")
        if submenu is not None:
            image_name += "-" + submenu.lower().replace(" ", "-").replace("–", "-")
        subprocess.run(["screencapture", "-x", str(OUT / (image_name + ".png"))], check=True)
        raw = ui(body)
    except Exception:
        subprocess.run(["osascript", "-e", 'tell application "System Events" to key code 53'], check=False)
        raise
    result = []
    for row in raw.split("\x1e"):
        if not row:
            continue
        title, _, enabled = row.partition("\x1f")
        result.append({"title": title, "enabled": enabled.lower() == "true"})
    return result


def menu_bar_titles():
    body = '''set encodedRows to ""
repeat with oneItem in menu bar items of menu bar 1
    try
        set encodedRows to encodedRows & (name of oneItem as text) & (ASCII character 30)
    end try
end repeat
encodedRows'''
    return [item for item in ui(body).split("\x1e") if item]


def click_menu_command(menu_name, command_name):
    body = (
        f'click menu bar item {apple_quote(menu_name)} of menu bar 1\n'
        "delay 0.15\n"
        f'click menu item {apple_quote(command_name)} of menu 1 of menu bar item {apple_quote(menu_name)} of menu bar 1\n'
        "delay 0.4\nkey code 53"
    )
    ui(body)


def address_values(pid):
    helper = OUT / "macos-accessibility"
    if not helper.exists():
        subprocess.run(["swiftc", str(ROOT / "macos-accessibility.swift"), "-o", str(helper)], check=True, timeout=120)
    return json.loads(command([str(helper), str(pid), "fields", "Address bar"]))


def wait_for_address(pid, prefix, timeout=8):
    deadline = time.monotonic() + timeout
    last = []
    while time.monotonic() < deadline:
        last = address_values(pid)
        if any(value.startswith(prefix) for value in last):
            return last
        time.sleep(0.2)
    raise AssertionError(f"Address bar did not reach {prefix!r}; last values: {last}")


def seed_grouped_chats():
    reference_offset = 978307200
    now = time.time() - reference_offset
    conversations = []
    for index in range(12):
        message_id = str(uuid.uuid4())
        title = (
            "Recent synthetic conversation title intentionally long enough to verify menu ellipsis and clipping"
            if index == 0 else f"Synthetic menu conversation {index + 1:02d}"
        )
        conversations.append({
            "id": str(uuid.uuid4()),
            "title": title,
            "messages": [{"id": message_id, "role": "user", "text": "Disposable menu test entry."}],
            "sourceGroups": [],
            "updatedAt": now - index,
        })
    preferences = {
        "kestrel.assistant.conversations.v1": json.dumps(conversations, ensure_ascii=False).encode(),
        "kestrel.extensions.settings.v1": json.dumps({
            "menuBarVisible": True,
            "allowsUnpackedImports": False,
            "toolbarActionsVisible": True,
            "sidebarActionsVisible": True,
            "sidebarActionIDs": None,
        }).encode(),
    }
    fixture = OUT / "synthetic-menu-preferences.plist"
    fixture.write_bytes(plistlib.dumps(preferences))
    bundle_id = command(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(APP / "Contents/Info.plist")])
    subprocess.run(["defaults", "import", bundle_id, str(fixture)], check=True)
    exported = OUT / "seeded-preferences.plist"
    subprocess.run(["defaults", "export", bundle_id, str(exported)], check=True, capture_output=True)
    seeded = plistlib.loads(exported.read_bytes()).get("kestrel.assistant.conversations.v1")
    count = len(json.loads(seeded)) if isinstance(seeded, bytes) else 0
    record("chat_fixture_seeded", bundle_id=bundle_id, expected=12, stored=count)
    check(count == 12, "synthetic chat fixture was written to the app defaults domain", bundle_id=bundle_id, stored=count)
    return bundle_id


def check(condition, label, **data):
    record("check", label=label, passed=bool(condition), **data)
    if not condition:
        errors.append(label)


def close_app(executable):
    subprocess.run(["pkill", "-TERM", "-x", executable], check=False, capture_output=True)
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if subprocess.run(["pgrep", "-x", executable], capture_output=True).returncode != 0:
            return
        time.sleep(0.2)


def main():
    executable = command(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", str(APP / "Contents/Info.plist")])
    bundle_id = seed_grouped_chats()
    subprocess.run(["open", "-n", "-a", str(APP)], check=True)
    deadline = time.monotonic() + 30
    pid = None
    while time.monotonic() < deadline:
        found = subprocess.run(["pgrep", "-x", executable], capture_output=True, text=True)
        if found.returncode == 0:
            pid = int(found.stdout.splitlines()[0])
            break
        time.sleep(0.3)
    if pid is None:
        raise RuntimeError("Kestrel did not remain running for menu inspection")
    ui('set frontmost to true')
    time.sleep(1.0)

    top = menu_bar_titles()
    record("menu_bar", titles=top, app_executable=executable, bundle_id=bundle_id, pid=pid)
    exported = OUT / "preferences-after-launch.plist"
    subprocess.run(["defaults", "export", bundle_id, str(exported)], check=True, capture_output=True)
    stored = plistlib.loads(exported.read_bytes()).get("kestrel.assistant.conversations.v1")
    stored_count = len(json.loads(stored)) if isinstance(stored, bytes) else 0
    record("chat_fixture_after_launch", expected=12, stored=stored_count)
    check(stored_count == 12, "Chromium retains the seeded chat archive after launch", bundle_id=bundle_id, stored=stored_count)
    common = ["Tabs", "Navigate", "Assistant", "Chats"]
    for label in common:
        check(label in top, f"{label} menu exists", menu_bar=top)

    menus = {}
    for label in common:
        try:
            menus[label] = menu_rows(label)
            record("menu_opened", menu=label, items=menus[label])
        except Exception as error:
            errors.append(f"Could not open {label} menu")
            record("menu_open_failed", menu=label, error=str(error))

    expected = {
        "Tabs": ["Next Tab", "Previous Tab", "Separate Split View", "Equal Split Widths"],
        "Navigate": ["Focus Address Bar", "Find on Page", "Reload Page", "Go Back", "Go Forward", "Zoom In", "Zoom Out", "Actual Size"],
        "Assistant": ["Show Assistant", "Open Assistant Page"],
        "Chats": ["New Chat", "Recent Chats", "Earlier Chats", "Chats 11–12"],
    }
    for menu, titles in expected.items():
        got = [row["title"] for row in menus.get(menu, [])]
        for title in titles:
            check(title in got, f"{menu} contains {title}", items=got)
    tabs_enabled = {row["title"]: row["enabled"] for row in menus.get("Tabs", [])}
    check(tabs_enabled.get("Separate Split View") is False,
          "Separate Split View is disabled when the app opens without a split", items=tabs_enabled)
    check(tabs_enabled.get("Equal Split Widths") is False,
          "Equal Split Widths is disabled when the app opens without a split", items=tabs_enabled)

    try:
        recent = menu_rows("Chats", "Recent Chats")
        earlier = menu_rows("Chats", "Earlier Chats")
        final = menu_rows("Chats", "Chats 11–12")
        for label, rows, wanted in [("Recent Chats", recent, 5), ("Earlier Chats", earlier, 5), ("Chats 11–12", final, 2)]:
            check(len(rows) == wanted, f"{label} submenu has {wanted} entries", items=rows)
            record("submenu_opened", menu="Chats", submenu=label, items=rows)
        check(any(row["title"].endswith("…") for row in recent), "long chat title is visibly truncated with an ellipsis", items=recent)
    except Exception as error:
        errors.append("Could not open grouped Chats submenus")
        record("submenu_open_failed", menu="Chats", error=str(error))

    for label in ["Chromium", "Extensions"]:
        if label not in top:
            record("engine_menu", menu=label, present=False)
            continue
        try:
            rows = menu_rows(label)
            record("engine_menu", menu=label, present=True, items=rows)
            if label == "Chromium":
                wanted = ["Site Permissions & Browser Settings…", "Browsing History…", "Downloads…"]
                for title in wanted:
                    check(title in [row["title"] for row in rows], f"Chromium menu contains {title}")
        except Exception as error:
            errors.append(f"Could not open {label} menu")
            record("engine_menu_open_failed", menu=label, error=str(error))

    if ENGINE == "chromium" and "Chromium" in top:
        for title, prefix in [
            ("Site Permissions & Browser Settings…", "chrome://settings/content"),
            ("Browsing History…", "chrome://history"),
            ("Downloads…", "chrome://downloads"),
        ]:
            try:
                click_menu_command("Chromium", title)
                values = wait_for_address(pid, prefix)
                check(True, f"{title} opens its in-app page", address=values)
                record("internal_page_opened_from_menu", command=title, address=values)
            except Exception as error:
                errors.append(f"{title} did not open its in-app page")
                record("internal_page_failed", command=title, error=str(error))
        check(subprocess.run(["pgrep", "-x", executable], capture_output=True).returncode == 0,
              "Kestrel remains running after internal settings, history and downloads pages")
    else:
        record("chromium_internal_pages", status="not applicable to this engine")

    subprocess.run(["screencapture", "-x", str(OUT / "menu-audit.png")], check=True)
    close_app(executable)
    result = {
        "engine": ENGINE,
        "app": str(APP),
        "passed": not errors,
        "errors": errors,
        "topLevelMenus": top,
        "menus": menus,
        "checks": len([event for event in events if event["action"] == "check"]),
    }
    (OUT / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    if errors:
        raise AssertionError("; ".join(errors))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        record("fatal", error=str(error))
        if not (OUT / "result.json").exists():
            (OUT / "result.json").write_text(json.dumps({"engine": ENGINE, "passed": False, "errors": errors + [str(error)]}, indent=2))
        raise
