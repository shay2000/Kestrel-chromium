#!/usr/bin/env python3
"""Promote one explicitly selected successful Mac artifact, without rebuilding it.

Uses only GITHUB_TOKEN via gh on the standard Mac runner. Refuses conflicting
tags/releases/assets; a matching interrupted draft can be resumed without
overwriting an existing asset. The legacy WebKit publishing script is separate.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile


REPOSITORY = "shay2000/Kestrel-chromium"
WORKFLOW = ".github/workflows/macos-chromium-build.yml"
ARTIFACT_NAME = "Kestrel-Chromium-macOS-DMG"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def validate_request(request):
    require(request["repository"] == REPOSITORY, "Unexpected destination repository")
    version = re.fullmatch(r"v(\d+\.\d+\.\d+)-chromium-preview\.\d+", request["tag"])
    require(version is not None, "Preview tag required")
    require(re.fullmatch(r"[0-9a-f]{40}", request["source"]), "Full source commit required")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", request["artifact_digest"]), "Pinned artifact digest required")
    require(re.fullmatch(r"Kestrel-Chromium-\d+\.\d+\.\d+-arm64\.dmg", request["dmg"]), "Unexpected DMG filename")
    require(request["dmg"] == f"Kestrel-Chromium-{version[1]}-arm64.dmg", "Tag and DMG version mismatch")
    require(request["notes"] == f"docs/releases/{request['tag']}.md", "Unexpected notes path")


def validate_origin(request, run, artifact):
    require(run["status"] == "completed" and run["conclusion"] == "success", "Mac acceptance did not succeed")
    require(run["id"] == request["run_id"] and run["head_sha"] == request["source"], "Run/source mismatch")
    require(run["path"] == WORKFLOW and run["head_repository"]["full_name"] == REPOSITORY, "Wrong build workflow/repository")
    require(artifact["id"] == request["artifact_id"] and artifact["name"] == ARTIFACT_NAME, "Wrong artifact")
    require(not artifact["expired"], "Artifact expired")
    require(artifact["digest"] == request["artifact_digest"], "Artifact digest changed")
    require(artifact["workflow_run"]["id"] == request["run_id"] and artifact["workflow_run"]["head_sha"] == request["source"], "Artifact/source mismatch")


def unpack_verified(request, archive, output):
    require("sha256:" + digest(archive) == request["artifact_digest"], "Downloaded artifact ZIP digest mismatch")
    expected = {request["dmg"], request["dmg"] + ".sha256"}
    with zipfile.ZipFile(archive) as bundle:
        require(len(bundle.infolist()) == 2 and set(bundle.namelist()) == expected, "Unexpected artifact contents")
        # Extract only the two exact basenames, with no path traversal/symlinks.
        for name in sorted(expected):
            with bundle.open(name) as source, (output / name).open("wb") as target:
                shutil.copyfileobj(source, target)
    checksum = (output / (request["dmg"] + ".sha256")).read_text()
    match = re.fullmatch(r"([0-9a-f]{64}) [ *]" + re.escape(request["dmg"]) + r"\n?", checksum)
    require(match is not None, "Unexpected checksum format/filename")
    require(digest(output / request["dmg"]) == match[1], "DMG checksum mismatch")
    return match[1]


def command(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def api(path, payload=None, method="PATCH"):
    args = ["gh", "api", f"repos/{REPOSITORY}/{path}"]
    if payload is not None:
        args += ["--method", method, "--input", "-"]
    result = command(*args, input=json.dumps(payload) if payload is not None else None,
                     text=True, capture_output=True)
    return json.loads(result.stdout)


def verify_mounted_app(dmg, version):
    command("hdiutil", "verify", str(dmg))
    attached = command("hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg), capture_output=True)
    entities = plistlib.loads(attached.stdout)["system-entities"]
    mount = next(Path(item["mount-point"]) for item in entities if "mount-point" in item)
    try:
        app = mount / "Kestrel.app"
        command("codesign", "--verify", "--deep", "--strict", str(app))
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        require(info["CFBundleShortVersionString"] == version, "Wrong application version")
        require(bool(info.get("NSBluetoothAlwaysUsageDescription")), "Bluetooth purpose string missing")
        require(not (app / "Contents/Resources/ChromiumExtensionSmoke").exists(), "CI fixture still bundled")
        architecture = command("lipo", "-archs", str(app / "Contents/MacOS" / info["CFBundleExecutable"]), text=True, capture_output=True).stdout.strip()
        require(architecture == "arm64", "Unexpected application architecture")
        return {"version": info["CFBundleShortVersionString"], "bundle_id": info["CFBundleIdentifier"], "architecture": architecture, "signature_verified": True}
    finally:
        command("hdiutil", "detach", str(mount))


def tag_source(tag):
    ref = api(f"git/ref/tags/{tag}")["object"]
    while ref["type"] == "tag":
        ref = api("git/tags/" + ref["sha"])["object"]
    require(ref["type"] == "commit", "Tag does not name a commit")
    return ref["sha"]


def find_or_create_release(request, notes):
    releases = json.loads(command("gh", "api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases", text=True, capture_output=True).stdout)
    matching = [item for page in releases for item in page if item["tag_name"] == request["tag"]]
    require(len(matching) <= 1, "Ambiguous existing release")
    # The tag endpoint does not expose drafts. Always address drafts by ID.
    release = matching[0] if matching else api("releases", {
        "tag_name": request["tag"], "target_commitish": request["source"],
        "name": request["title"], "body": notes, "draft": True,
        "prerelease": True, "make_latest": "false"}, method="POST")
    return api(f"releases/{release['id']}")


def main(request_path, output_path):
    request = json.loads(Path(request_path).read_text())
    validate_request(request)
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Publish only from the authorized repository")
    require(os.environ.get("GITHUB_REF") == "refs/heads/release/chromium-preview", "Publish only from the release branch")
    require(sys.platform == "darwin", "DMG verification needs the Mac runner")
    output = Path(output_path).resolve()
    output.mkdir(parents=True, exist_ok=True)
    run = api(f"actions/runs/{request['run_id']}")
    artifact = api(f"actions/artifacts/{request['artifact_id']}")
    validate_origin(request, run, artifact)
    archive = output / "verified-artifact.zip"
    with archive.open("wb") as stream:
        command("gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{request['artifact_id']}/zip", stdout=stream)
    checksum = unpack_verified(request, archive, output)
    version = re.fullmatch(r"v(\d+\.\d+\.\d+)-chromium-preview\.\d+", request["tag"])[1]
    application = verify_mounted_app(output / request["dmg"], version)
    notes = Path(request["notes"]).read_text()
    tags = api(f"git/matching-refs/tags/{request['tag']}")
    if not any(item["ref"] == "refs/tags/" + request["tag"] for item in tags):
        api("git/refs", {"ref": "refs/tags/" + request["tag"], "sha": request["source"]}, method="POST")
    require(tag_source(request["tag"]) == request["source"], "Release tag/source mismatch")
    release = find_or_create_release(request, notes)
    require(tag_source(request["tag"]) == request["source"], "Release tag/source mismatch")
    require(release["prerelease"] and release["name"] == request["title"] and release["body"].strip() == notes.strip(), "Conflicting release metadata")
    files = [request["dmg"], request["dmg"] + ".sha256"]
    existing = {item["name"] for item in release["assets"]}
    require(existing <= set(files), "Unexpected existing release assets")
    missing = [name for name in files if name not in existing]
    if missing:
        require(release["draft"], "Refuse to change assets on a published release")
        for name in missing:
            command("gh", "api", "--method", "POST",
                    f"https://uploads.github.com/repos/{REPOSITORY}/releases/{release['id']}/assets?name={name}",
                    "-H", "Content-Type: application/octet-stream", "--input", str(output / name),
                    capture_output=True)
    release = api(f"releases/{release['id']}")
    # Download even on a resumed draft. Never overwrite or trust an existing asset.
    verification = output / "downloaded-assets"
    verification.mkdir()
    for asset in release["assets"]:
        require(asset["name"] in files, "Unexpected release asset")
        with (verification / asset["name"]).open("wb") as stream:
            command("gh", "api", f"repos/{REPOSITORY}/releases/assets/{asset['id']}",
                    "-H", "Accept: application/octet-stream", stdout=stream)
    require({p.name for p in verification.iterdir()} == set(files), "Unexpected published assets")
    for name in files:
        require(digest(verification / name) == digest(output / name), "Uploaded asset hash mismatch: " + name)
    if release["draft"]:
        release = api(f"releases/{release['id']}", {"draft": False, "prerelease": True,
                      "target_commitish": request["source"], "make_latest": "false"})
    release = api(f"releases/{release['id']}")
    require(not release["draft"] and release["prerelease"] and release["published_at"], "Release was not published")
    require({a["name"] for a in release["assets"]} == set(files), "Published asset set mismatch")
    evidence = {"release_url": release["html_url"], "tag": request["tag"], "source": request["source"],
                "run_id": request["run_id"], "artifact_id": request["artifact_id"], "artifact_digest": request["artifact_digest"],
                "dmg_sha256": checksum, "download_hashes_verified": True, "application": application,
                "assets": [{k: a.get(k) for k in ("name", "size", "digest", "browser_download_url")} for a in release["assets"]]}
    (output / "release-verification.json").write_text(json.dumps(evidence, indent=2) + "\n")
    summary = f"Published [{request['tag']}]({release['html_url']}) as a prerelease.\n\nSource: `{request['source']}`\n\nDMG SHA-256: `{checksum}`\n"
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(summary)


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        raise
