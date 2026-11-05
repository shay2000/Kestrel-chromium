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

| First native run | GitHub Actions run [42119250848](https://github.com/shay2000/Kestrel-chromium/actions/runs/42119250848), commit `5830086312a64d520e2864870c860a49980c77a8`, on `macos-26`. The Chromium app built; the interactive checks were skipped because of the SwiftPM discovery error below. | Live GitHub Actions status |
| First-run issue | The Chromium app build succeeded. The added root `swift test` step stopped during SwiftPM resource discovery, reporting duplicate Chromium `locale.pak` and Sparkle `.strings` names and a missing `defaultLocalization`; no Kestrel tests ran in that command. That failure skipped the GUI steps in this first workflow revision. The next revision preserves the error but continues the desktop comparison. | [Run 42119250848](https://github.com/shay2000/Kestrel-chromium/actions/runs/42119250848) |

| Second native run | GitHub Actions run [42120207482](https://github.com/shay2000/Kestrel-chromium/actions/runs/42120207482), commit `941299aa3886c3e8e335b7e3bf1c840be6a9a442`, on `macos-26`. The app built; CEF lifecycle tests (11), CRX signature/package tests and the 17 first-click/window-focus assertions passed. The synthetic WebAuthn round trip passed, but no FIDO QR appeared on this hosted Mac. | [Run 42120207482](https://github.com/shay2000/Kestrel-chromium/actions/runs/42120207482), native and runtime artifacts |
| Chrome Web Store | Native installs of Dark Reader and Google Translate both passed and survived a cold app restart. Google Translate’s genuine extension popup reached `readyState=complete`; the run also exercised its extension options page, toolbar action and sidebar action. `runtimeUserAgentProbe=false` means the store’s native install button appeared without the fallback UA probe. Window census reported the embedded popup under Kestrel’s process; no standalone Chrome window appeared. | `Kestrel-Chromium-web-store-acceptance` and `Kestrel-Chromium-extension-actions` artifacts from run 42120207482 |
| Same-page visual comparison | Chromium and WebKit 1.0.0 rendered the same example.com page at the same 1200×800 desktop geometry. Toolbar, sidebar, pinned sites and page content align closely. The Chromium screenshot still contains the prior extension-smoke toast, so that overlay is test residue rather than a parity difference. | `Kestrel-WebKit-versus-Chromium` artifact from run 42120207482 |

| Check | Chromium | WebKit 1.0.0 | Evidence |
|---|---|---|---|
| Common menu bar and nested Chats menus | Chromium failed to show the seeded chats; it displayed “No saved chats”. WebKit showed all 12 fixtures in three nested groups, and the 5/5/2 submenu entries and long-title ellipsis passed. | Passed all common menus, split menu disabled states, 3 nested submenus and title ellipsis | `Kestrel-desktop-webkit-comparison` artifact; menu screenshots and JSON results |
| Split view, resize/separate, navigation and tab recovery stress | The first pass stopped at a false AX focus assertion: screenshot showed the address editor and suggestions open. Before stopping, page navigation had not yet been verified. | Navigation, back/forward, move-to-split, two independent addresses, narrow resize, equal widths and separation passed. Cmd-W then left no accessible app window, so “close one tab and keep the other” failed. | `chromium-workflows` and `webkit-workflows` events/screenshots; run log around 22:28:01–22:28:57 UTC |
| Assistant sidebar/page, draft persistence, Agent toggle and file attachment | Not reached in the first stress pass. | Not reached in the first stress pass. | Test harness stopped at the earlier Cmd-W assertion |
| Chromium History, Downloads and site-permission pages | All three menu entries opened their corresponding `chrome://` pages in Kestrel; the app remained running. | Not applicable to the WebKit engine menu | `chromium-menu/events.json` in desktop comparison artifact |
| Existing native lifecycle, passkey and extension acceptance | Lifecycle/extension acceptance passed; synthetic WebAuthn passed. Native FIDO QR was not visible. | Not applicable to the WebKit engine menu | Run 42120207482 logs and extension artifacts |
| Complete SwiftPM regression suite | Did not execute: root `swift test --parallel` failed in package resource discovery before compilation. | Shared sources | `Kestrel-native-regression-tests` artifact from run 42120207482 |

## Findings

The Chromium “No saved chats” result is a product-level comparison finding because WebKit displayed the same seeded preferences. Its root cause is not established yet. The Chromium focus timeout is a harness false negative: its failure screenshot shows the address editor open with the typed destination and suggestion list. The WebKit Cmd-W result remains an observed desktop failure: after the close command, accessibility found no app window; a targeted replay is needed to confirm whether this is an app behaviour or a runner interaction issue. A revised test-only pass is being prepared to record defaults before and after startup, verify address focus through successful navigation, and reach the Assistant and attachment workflows without repeating the early close-tab gate.

No product fixes are included. A passing harness step will not be treated as proof for flows it does not exercise, including real provider-backed Agent actions, profile filling, page-image delivery, Codex helper sign-in, or physical phone passkey ceremonies.
