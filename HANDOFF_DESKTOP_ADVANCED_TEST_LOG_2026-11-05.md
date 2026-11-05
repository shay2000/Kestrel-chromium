# Kestrel desktop and advanced workflow test log — 5 November 2026

This is a test-only comparison of the Chromium build against the original Kestrel WebKit 1.0.0 release. No application fixes are included.

## Scope and runner

- Chromium source under test: `757a17f779ea6dfe01527500c1189e4cebaedc09` (published 1.0.2 preview).
- Comparison baseline: the original `Kestrel-Browser` v1.0.0 Mac release, run on the same hosted Mac.
- The current execution workspace is Linux and cannot operate AppKit or macOS window controls. The audit is being run on the repository's hosted macOS 26 workflow.
- Existing CI already covers first-click focus, page/header geometry, drag/minimise/restore, window ownership, lifecycle cancellation, extension actions and a basic same-page visual comparison. This pass adds repeated desktop workflows, native menu/submenu inspection and a full native unit run.

## Progress

| Review / setup | Result | Evidence |
|---|---|---|
| Existing desktop coverage reviewed | Focus, first-click, drag, minimise/restore, address field, overlay ownership and one-page visual comparison are in the current macOS workflow. The repeated split/Assistant/file-picker harness existed but was not invoked by that workflow. | `.github/workflows/macos-chromium-build.yml`, `scripts/test-window-integration-macos.swift`, `scripts/macos-user-stress.py` |
| New test-only coverage prepared | The macOS workflow now invokes the existing repeated UI stress harness on both app bundles, inspects common menus and seeded Chats submenus, checks Chromium's in-app History/Downloads/Site Settings menu actions, and runs all SwiftPM tests. | `scripts/test-desktop-menus-macos.py`, updated macOS workflow |
| Local harness validation | Python syntax, YAML parsing, every workflow Bash block and `git diff --check` pass. This Linux host cannot execute the native macOS UI probes. | Pre-run checks in this task; hosted runner remains pending |

| Check | Chromium | WebKit 1.0.0 | Evidence |
|---|---|---|---|
| Common menu bar and nested Chats menus | Pending | Pending | Hosted Mac artifacts |
| Split view, resize/separate, navigation and tab recovery stress | Pending | Pending | Hosted Mac stress events and screenshots |
| Assistant sidebar/page, draft persistence, Agent toggle and file attachment | Pending | Pending | Hosted Mac stress events and screenshots |
| Chromium History, Downloads and site-permission pages | Pending | Not applicable to the WebKit engine menu | Hosted Mac menu probe |
| Existing native lifecycle, passkey and extension acceptance | Pending | Not applicable | Hosted Mac workflow logs |
| Complete SwiftPM regression suite | Pending | Shared sources | Hosted Mac test log |

## Findings

Results will be appended from the actual runner after it completes. A passing harness step will not be treated as proof for flows it does not exercise, including real provider-backed Agent actions, profile filling, page-image delivery, Codex helper sign-in, or physical phone passkey ceremonies.
