# Kestrel bug diagnosis and fix handoff

## Optimisation continuation

The subsequent optimisation pass is tracked in [PERFORMANCE_HANDOFF.md](PERFORMANCE_HANDOFF.md), with PERF-001/002/003 and a separate PR on top of this branch. It reuses this worktree on `codex/performance-optimisations`; verify the actual branch before resuming the earlier bug work.

## Resume here

- **Owner:** Codex (GPT-6).
- **Started:** 30 September 2026, 08:28 BST (07:28 UTC).
- **Request:** “In a new work tree can we diagnose potential errors focusing on the passkey errors that are being thrown in other chats and move on to other things. Keep a bug fix handoff where you label bugs you found as you find them so that another model can take over when you run out of usage”.
- **Scope:** diagnose, integrate the authorised repairs and deliver a reviewable PR; preserve the labelled findings for continuation. Investigate Apple Passwords/extensions/nearby-device QR without bypassing platform requirements.
- **Worktree:** `~/.codex/worktrees/passkey-diagnosis/kestrel-webkit`.
- **Branch:** `codex/passkey-diagnosis`.
- **Baseline:** `fc1689c14484ecd3da5b5e1431d5d1609a9a776e`; clean `main`, `origin/main` and fetched GitHub head agreed before creating the worktree.
- **Host:** macOS 27.0 (26A428), arm64; Xcode 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer`.
- **Evidence directory:** `/private/tmp/kestrel-passkey-diagnosis-20260930/`. Temporary build products/logs are not durable; record essential results here and keep reusable probes in the repository.
- **Checkpoint:** extended audit complete, delivered on [PR #4](https://github.com/shay2000/kestrel-webkit/pull/4). Six additional confirmed bugs (OP-002/003, NAV-002/003, URL-001 and PK-005) are repaired. All 500 tests passed, including 24 native WebKit regressions; Xcode, SwiftPM packaging, strict signatures and targeted native UI checks passed. PK-002 and CI-001 remain external. Read back the current remote branch head for the exact delivery SHA; main is not merged by this pass.


Statuses: **reported**, **suspected**, **confirmed**, **external limitation**, **fixed, unverified**, **verified fixed**, **not reproduced**. Severity describes user impact, not certainty. Preserve IDs when updating entries. Each continuation must update this section, the relevant bug entry and the work log before stopping.

## Bug register

| ID | Priority | Status | Finding |
| --- | --- | --- | --- |
| PK-001 | P1 | Fixed; native regression and multi-tab/split smoke passed | Shared user-content controller causes duplicate `kestrelPasskey` registration and process termination |
| PK-002 | P2 | External limitation, verified in fresh signature | Arbitrary-site Apple Passwords passkeys require capabilities absent from the local build |
| PK-003 | P2 | Fixed; native JS regression passed, real authentication unverified | A successful ceremony can still produce the “cannot use” banner |
| PK-004 | P2 | Fixed; injected launch failure/success regression passed | Failed external opening dismisses the only automatic handoff prompt |
| PK-005 | P2 | Fixed; injected launch/dismissal regression passed | A failed ordinary external-browser launch is incorrectly labelled as a passkey failure |
| QA-001 | P2 | Verified fixed | Two assertions in one scrollbar test disagree with current hidden-scrollbar policy |
| OP-001 | P1 | Fixed; native mutation-during-animation regression passed | Click target can change while the cursor animates; activation selects a different duplicate |
| NAV-001 | P2 | Fixed; native delegate and failure-banner UI checks passed | Navigation failures leave the page labelled “Loading…” and discard the error |
| CI-001 | P2 | External account blocker | GitHub macOS workflow cannot start because of account billing/spending restrictions |
| OP-002 | P1 | Fixed; native GET/override/mutation/cancellation and submitter hit-test regressions passed | Search submitter overrides bypass the same-origin GET check; target can change during animation or remain covered |
| NAV-002 | P1 | Fixed; overlap/cancellation/timeout/close regressions passed | A manual navigation can satisfy an older assistant waiter; pre-cancelled tasks still load |
| URL-001 | P2 | Fixed; parsing regressions and native address-bar check passed | Bare host ports and localhost/IPv6 paths are misclassified as searches |
| NAV-003 | P2 | Fixed; native title/ownership regressions and UI check passed | Initial and dynamically changed document titles can leave a generic tab title |
| OP-003 | P1 | Fixed; native blocked/offscreen/nested-label regressions passed | Click targeting accepts controls disabled by a fieldset, inert ancestors or a covering overlay |

### Extended audit — 30 September 2026, 16:06 BST

- **OP-002:** native WebKit fixtures showed `search_page` returning success and changing the input for a button with `formmethod=post`, cross-origin `formaction`, or `formtarget=_blank`. The original implementation only checks the form, then clicks the submitter. The test prevents submission, so no unsafe request was sent. Re-querying after animation and dispatching arbitrary page handlers are additional gaps being addressed at the same boundary.
- **NAV-002:** a deterministic fixture using real WebKit navigation identities showed a manual page's completion returning `true` to an earlier assistant load. A task cancelled before entry also called `load`. This can capture the wrong page or navigate after Stop. Test overlapping loads, late callbacks, cancellation, timeout and tab-close cleanup before marking fixed.
- **URL-001:** five bare addresses (`example.com:8443/path`, IPv4 with a port, localhost with a port/path and bracketed IPv6 with port/path) became search queries. The scheme detector confuses a host's port separator with a URI scheme, and host classification examines the full path instead of the authority. Preserve rejection of non-HTTP schemes and invalid ports.
- **NAV-003 (16:15 BST):** a native HTML fixture with an initial title, followed by a JavaScript title change, never updated the published title to either value. The store samples the title only on navigation completion; WebKit can publish it later. Observe the attached view's title and reject observations from a replaced view or a failed/loading page.
- **OP-003 (16:15 BST):** three native targeting cases accepted a button inside a disabled fieldset, an inert document and beneath a full-page overlay. Checking only `el.disabled` and its rectangle misses inherited restrictions and hit-testing. Check these conditions before highlighting and again before activation, while preserving scrolling to an offscreen control.

### Submitter hit-test follow-up — 30 September 2026, 22:55 BST

- Review found that `search_page` hit-tested the field but only checked the submitter for visibility. It now requires both targets to pass hit-testing when the action is proposed and again after approval. A native WebKit regression covers the submitter before proposal and after proposal; both cases reject without navigating.

### PK-005 — ordinary browser-launch failure mislabelled as a passkey failure

- **First recorded:** 30 September 2026, 16:23 BST, following [PR review](https://github.com/shay2000/kestrel-webkit/pull/4#discussion_r4146137257).
- **Confirmed:** a regression with an ordinary article URL and an injected failed external opener set `passkeyHandoffNeeded` despite no passkey attempt. The old banner then claimed sign-in did not finish.
- **Repair:** external-launch failure now preserves the actual passkey flag and sets a separate general browser error. The banner chooses a neutral external-browser title/icon for ordinary launches; an existing passkey notice remains retryable. Dismissal, success and new navigation clear the notice. No system default-browser setting is changed.
- The same review independently reported NAV-002's old timer stopping a newer load. The navigation ownership/timeout cancellation repair addresses that finding; hosted review must evaluate the new commit before its previous verdict is considered current.

### PK-001 — duplicate passkey bridge registration

- **Repair / current evidence (30 September 2026):** Each configuration now owns its user-content controller while retaining baseline scripts, the shared extension controller and website data store. Native tests cover two stores, two live tabs, close/reopen cycles, stable script counts and message ownership after closing a sibling. An explicitly permitted fixture extension injects into both tab controllers. Native QA opened multiple tabs and a split without the exception.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:28 BST.
- **Prior evidence:** chat **Explain assistant sidebar icon**, thread `01a0f102-13ed-7c32-948a-3e3e50fb173d`, reports a live page-opening crash and 16 test failures with `Attempt to add script message handler with name 'kestrelPasskey' when one already exists. (NSInvalidArgumentException)` at `TabStore.swift:608`. This is not a WebAuthn rejection or missing entitlement error.
- **Confirmed cause:** `BrowserExtensionHost.makeWebViewConfiguration()` (`BrowserExtensionHost.swift:63–69`) copies the outer `WKWebViewConfiguration`, but its `userContentController` is shared. `TabStore.webView(for:)` (`TabStore.swift:598–608`) adds the same named message handler for every tab. The shared host is used on macOS 15.4+ even with no installed extensions.
- **Fresh evidence:** 474-test baseline produced 16 duplicate-handler exceptions. The standalone probe prints `distinct_configuration_objects=true`, `shared_user_content_controller=true`, `shared_website_data_store=true`, `shared_extension_controller=true`. Adding the first tab's watcher grows the second configuration's script list from 1 to 2. With `--register-second`, the disposable process exits on SIGABRT (`-6` in Python) with exactly the reported exception. No website or actual passkey is needed.
- **Lifecycle consequence:** `discardPage(for:)` (`TabStore.swift:169–181`) removes the handler from that shared controller but leaves user scripts behind. Sequential create/close cycles can accumulate wrappers; replacing/removing a shared handler is not safe tab isolation. Preserve callback ownership when fixing.
- **Repair direction:** preserve the shared extension controller and website data store while giving each tab its own user-content controller and the required baseline scripts. Prove per-tab callback ownership and lifecycle.
- **Causal control:** the same standalone process with `--isolated-control --register-second` installs independent content controllers only on its disposable configurations. It prints `shared_user_content_controller=false`, leaves the second configuration's script count at 1, preserves shared website/extension controllers and registers both handlers successfully (exit 0). This proves the registration repair direction; it is not a shipped fix or evidence that real installed extension content scripts still work.

### PK-002 — native general-site passkeys remain unavailable

- **Repair / current evidence (30 September 2026):** The signature still lacks both capabilities. Apple requires an organisation Account Holder to apply for the managed browser-passkey entitlement. The extension and QR investigation is in [PASSKEY_SUPPORT.md](../../PASSKEY_SUPPORT.md); background/focus and generic context rejections make the QR runtime check inconclusive. Official iCloud Passwords 3.4.0 inspection confirmed a native connection to `com.apple.passwordmanager`; Kestrel has no delegate for that connection. No approved profile, real registration or successful assertion exists.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:28 BST.
- **Prior evidence:** `HANDOFF.md`, “Passkey hand-off to the default browser — 26 September 2026”, records missing `com.apple.developer.web-browser` and `com.apple.developer.web-browser.public-key-credential` in an ad-hoc signed app. This is separate from PK-001.
- **Fresh evidence:** strict signature verification passed for the Xcode and packaged apps. The Xcode entitlement read-back contains sandbox, picker read, network client/server and the exact Codex configuration exception, but neither managed browser capability. Settings correctly gates the manager and request on both capabilities. This limitation does not explain PK-001.
- **Repair/verification boundary:** do not enable the approval-only template. Obtain Apple's approval and matching signed profile through the project owner, then test website registration and assertion. A permission state, JS availability result or successful build is not a successful ceremony. [Apple entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).

### PK-003 — availability probe incorrectly treated as ceremony failure

- **Repair / current evidence (30 September 2026):** The watcher waits for the actual outcome, requires a confirmed false availability result after eligible rejection, ignores abort/conditional calls and unknown probes, and clears the notice on success. It retains original arguments, receiver and promise identity. Latest-attempt tokens suppress delayed results. Native JS tests cover ten outcome combinations and installation in the page world. The copy avoids classifying user dismissal as unsupported credentials.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:33 BST.
- **Evidence:** `PasskeyHandoff.swift:73–85` signals immediately when the platform authenticator probe returns false, without waiting for the actual ceremony outcome. A probe rejection is also classified as unavailable (`:52–62`). `scripts/diagnose-passkey-watcher.mjs` executes the unchanged watcher and reproduces a `platform-unavailable` signal both when a synthetic external-authenticator ceremony succeeds with no platform authenticator and when only the availability probe fails.
- **Impact:** false “This page needs a passkey Kestrel cannot use” banner during/after success or cancellation. The signal carries no terminal outcome and the banner persists until navigation/dismissal. Platform availability is not proof that every authenticator or credential request must fail.
- **Reference:** the [WebAuthn specification's platform availability method](https://www.w3.org/TR/webauthn-3/#dom-publickeycredential-isuserverifyingplatformauthenticatoravailable) describes that particular authenticator capability; it is not the result of the requested ceremony.
- **Repair direction:** distinguish platform capability, probe failure and actual ceremony outcome. Avoid claiming the request failed before it settles; suppress/clear the banner after success and treat cancellations separately. Keep conditional mediation quiet and preserve the exact original promise and arguments.
- **Acceptance:** exercise resolved, rejected, aborted, conditional and non-public-key calls; false/true/rejected availability probes; external-authenticator flow on suitable real hardware. JS fixture evidence does not establish real-device WebAuthn support.

### PK-004 — failed external opening loses the prompt

- **Repair / current evidence (30 September 2026):** The app now checks the external launch result, retains a readable retry message on failure and clears on success. It refuses an external target resolving to Kestrel. Native tests inject a failed launch followed by success and verify assistant-tab exclusion; no default-browser preference was changed.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:33 BST.
- **Evidence:** `ContentView.swift:770–773` discards the Bool returned by `openPageInDefaultBrowser(for:)` and unconditionally dismisses the banner. `TabStore.swift:440–446` returns false for an unavailable URL or failed `NSWorkspace.open`. The watcher sets `notified = true` for the document (`PasskeyHandoff.swift:43–47`), so another attempt in the same document cannot restore the prompt.
- **Impact:** a failed browser handoff appears to do nothing and removes the actionable prompt. The menu command remains available.
- **Repair direction:** keep the prompt and show a retryable error when opening fails. Inject the URL opener for deterministic false/true tests; dismiss only on confirmed launch acceptance. `NSWorkspace.open` success still does not prove successful sign-in.
- **Additional hypothesis, not confirmed:** if Kestrel is the default HTTP(S) handler, `NSWorkspace.open` can route back to Kestrel. Inspect the resolved application before promising an external passkey-capable browser; do not change the user's default browser for a test.

### QA-001 — scrollbar test failures

- **Repair / current evidence (30 September 2026):** The regression now starts with both scrollers enabled and verifies that the native page scrollers are disabled/hidden while retaining full content width and height. The obsolete overlay/autohide expectations were removed.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:28 BST.
- **Prior evidence:** the same chat reports two scrollbar-style expectation failures alongside PK-001.
- **Fresh evidence:** `TabModelTests.testOverlayScrollbarsRetainTheFullContentWidth` fails only at lines 574 (`scrollerStyle == .overlay`) and 575 (`autohidesScrollers == true`). `BrowserScrollbars.apply` (`BrowserView.swift:9–18`) deliberately removes both native scrollers. The remaining width/content-height assertions pass. This is two failed assertions in one test, not two broken scrollbar behaviours.
- **Repair direction:** update the test to assert hidden/disabled horizontal and vertical scrollers, unchanged document geometry and full content width. Keep native UI scrolling/gesture verification separate. Do not restore visible scrollbars just to satisfy the old assertion; the current AGENTS.md explicitly requires hidden webpage scrollbars.

### OP-001 — click activation does not revalidate unique identity

- **Repair / current evidence (30 September 2026):** Targeting retains the exact DOM element, document, app-generated token and control signature in a named isolated content world. Activation consumes the token and rejects replacement, duplicates, removal, relabelling, disabling, hiding or navigation. Page-world spoofing cannot replace the retained target. Public async WebKit evaluation awaits the targeting promise. Native tests exercise each mutation plus a replacement during the real operator animation.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:35 BST.
- **Evidence:** `BrowserOperator.swift:198–231` requires a unique target and obtains its rectangle after 320 ms. `performCursorAction` (`:366–412`) then waits another 480 ms for animation. Activation runs a separate query (`:234–273`) and clicks the first matching element without checking uniqueness or that it is the previously highlighted element.
- **Reproduction:** `node scripts/diagnose-operator-target.mjs` executes both unchanged production templates. Start with one Continue button, obtain its target, insert a second Continue before it, then activate. A fresh target query correctly returns null, but activation returns true and clicks `inserted-during-animation`.
- **Impact:** after the user approves a generic click, a dynamic page can change which control receives it. This does not bypass the initial approval gate; it undermines target identity after approval/highlighting.
- **Repair direction:** retain an app-owned opaque identity for the specific DOM element in bounded page state; immediately before activation verify the same document, connected target, current label, visibility and uniqueness. Do not merely query the first match again. Abort when the page/target changes, and clear bounded state after completion/navigation.
- **Acceptance:** native WKWebView fixture with insertion, removal, relabelling, replacement and navigation during animation; assert no wrong element is clicked. Current reproduction is synthetic JS, not full native operator execution.

### NAV-001 — load failure leaves a stale loading title

- **Repair / current evidence (30 September 2026):** The store records a bounded, fixed error category and renders a Try Again banner. It preserves the main-frame request URL for retry, handles cancellation without erasing a timeout, stops loading/waiters after failure or process termination and clears errors on new/successful navigation. Native delegate tests and a closed-loopback-port UI check confirm the failure title/banner; raw failing URLs/error descriptions are not rendered.
- **Baseline evidence below:** source line references and causal experiments describe `fc1689c`, not the repaired files.

- **First recorded:** 30 September 2026, 08:35 BST.
- **Source evidence:** `BrowserStore.loadAddress` sets `pageTitle = "Loading…"` at line 300. Both failure delegates at lines 380–394 clear `isLoading` but neither update the title nor retain the error. `ContentView.webPage` exposes a progress indicator but no navigation error surface.
- **Fresh reproduction:** `scripts/diagnose-navigation-failure.swift` compiles the real BrowserStore, URLNormalisation and TabModel. Its non-persistent WKWebView subclass intercepts network loading and feeds the real navigation delegate a synthetic `URLError(.cannotFindHost)`. Output: `before_error_loading=true, title=Loading…`; `after_error_loading=false, title=Loading…`; attempted address retained. No network request or real profile is involved. This is a native state/delegate test, not a screenshot or actual DNS failure.
- **Impact:** the tab can retain “Loading…” after loading has ended, with no app-owned explanation of the failure. The error is discarded. Verify the visible page state separately because WebKit's own failed-page rendering can differ by failure type.
- **Repair direction:** model a bounded navigation failure state, restore the appropriate title and expose a retry action without leaking credentials in URLs/error text. Treat cancellation separately from failures; clear errors on successful retry. Test provisional and committed failure, cancellation, timeout, process termination and recovery.

### CI-001 — hosted checks cannot start

- **First recorded:** 30 September 2026, 16:00 BST.
- **Evidence:** [macOS run 36733116604](https://github.com/shay2000/kestrel-webkit/actions/runs/36733116604), head `16ee2990cb72e4e321d87a4efd6363071329f081`, failed with no executed steps or build log. Check-run annotations explicitly report that recent account payments failed or the spending limit needs increasing. A second notice mentions runner capacity; the explicit start blocker is the billing/spending restriction.
- **Impact:** hosted CI has not tested the PR. This is separate from the passing local Mac verification. Do not describe the PR as green or weaken the workflow to hide the blocker.
- **Next owner action:** resolve GitHub Billing & plans, then rerun the workflow. No billing changes or purchases were made in this task. Greptile review was still in progress at the checkpoint.

## Original diagnosis ledger — baseline `fc1689c`

| Gate | Result |
| --- | --- |
| Baseline SwiftPM build | Passed; 24.14 seconds |
| Baseline SwiftPM tests | **Failed:** 474 tests, 18 assertions (16 PK-001 exceptions; 2 QA-001 stale assertions) |
| Baseline Xcode Debug build | Passed |
| `./build.sh` package / strict signature | Passed for package and Xcode product |
| Signed entitlement read-back | Verified sandbox; managed browser/passkey capabilities absent |
| Native configuration / duplicate-handler probe | Confirmed shared controller and SIGABRT on second registration |
| Synthetic watcher probe | Confirmed PK-003; conditional and non-public-key calls remain quiet |
| Synthetic operator target probe | Confirmed OP-001: duplicate introduced after targeting receives the click |
| Native failure delegate probe | Confirmed NAV-001: title remains “Loading…” after failure |
| `bash -n build.sh` / `git diff --check` | Passed |
| Website registration/assertion | Not attempted |
| Product UI / real-account authentication | Not attempted |

The pre-existing Xcode build warnings are Foundation Models sampling-initialiser deprecations and skipped AppIntents metadata extraction. They did not fail the build and are not classified as passkey bugs. No test was skipped to make this diagnosis appear green.

## Reproduce without changing product code

Run from this worktree with the selected Xcode toolchain. The native probes use macOS frameworks. The JS probes require Node and synthetic objects only. Binaries are disposable; the source probes and this document are the durable evidence.

```bash
KESTREL_DIAG_DIR=$(mktemp -d /private/tmp/kestrel-diagnosis.XXXXXX)
swiftc -parse-as-library -o "$KESTREL_DIAG_DIR/configuration-probe" \
  KestrelWebKit/WebKitConfiguration.swift KestrelWebKit/BrowserExtensionHost.swift \
  KestrelWebKit/ExtensionsSettings.swift KestrelWebKit/PasskeyHandoff.swift \
  scripts/diagnose-passkey-configuration.swift
"$KESTREL_DIAG_DIR/configuration-probe"
"$KESTREL_DIAG_DIR/configuration-probe" --isolated-control --register-second
node scripts/diagnose-passkey-watcher.mjs
node scripts/diagnose-operator-target.mjs
swiftc -parse-as-library -o "$KESTREL_DIAG_DIR/navigation-probe" \
  KestrelWebKit/BrowserStore.swift KestrelWebKit/URLNormalisation.swift \
  KestrelWebKit/TabModel.swift scripts/diagnose-navigation-failure.swift
"$KESTREL_DIAG_DIR/navigation-probe"
```

On the repaired branch, `"$KESTREL_DIAG_DIR/configuration-probe" --register-second` must register both handlers successfully. On baseline `fc1689c` it deliberately terminated with SIGABRT. The isolated-control flag is retained as a historical causal control and changes only the disposable objects.

The JS probes now assert corrected behaviour; the native navigation probe asserts the error state. The regular `WebKitBugRegressionTests` suite adds real WebKit evaluation and controller/extension lifecycle coverage. Synthetic credentials and bridge signals never prove real authentication.

Baseline commands used the single scratch directory and no sandbox workaround:

```bash
swift build --scratch-path /private/tmp/kestrel-passkey-diagnosis-20260930/spm
swift test --scratch-path /private/tmp/kestrel-passkey-diagnosis-20260930/spm
xcodebuild -project KestrelWebKit.xcodeproj -scheme Kestrel -configuration Debug \
  -derivedDataPath /private/tmp/kestrel-passkey-diagnosis-20260930/xcode build
KESTREL_SWIFTPM_BUILD_DIR=/private/tmp/kestrel-passkey-diagnosis-20260930/spm \
  KESTREL_BUILD_DIR=/private/tmp/kestrel-passkey-diagnosis-20260930/package ./build.sh
```

## Verification and next model

1. Read the latest PR/remote head and this register; preserve IDs. Check for new main commits and unrelated work before editing.
2. The baseline had **474 tests and 18 failed assertions**: 16 duplicate-handler exceptions and two stale scrollbar assertions. The latest suite has **500 tests, zero failures** on macOS. It includes 24 native WebKit regression tests; this extended pass added 15 native tests and two URL tests to the previously passing 483-test checkpoint.
3. Xcode and `build.sh` have built on this Mac with strict signatures; both still carry the local sandbox and lack the managed browser capabilities. A separate ad-hoc QA bundle has a unique bundle identifier and no imported user profile.
4. Native UI evidence: multiple tabs and a left/right split opened without crashing; a closed local port displayed the fixed failure text and Try Again; synthetic bridge buttons showed and cleared the neutral passkey banner. These are repair smoke checks, not a full visual audit or an authenticated website session.
5. Keep **PK-002** open until approved provisioning and real website creation/assertion exist. Repeat the QR fixture manually with a foreground, focused window. A generic `NotAllowedError` does not establish why the platform rejected a request.
6. Broader audit candidates remain popup/target-blank handling and loaded-extension runtime permissions. The overlapping navigation and late-title candidates are now diagnosed and repaired as NAV-002/003. The native regression suite uses real navigation identities with controlled callbacks; real-account sign-in and a comprehensive extension compatibility audit remain outside its evidence.

## Delivery and scope

The branch includes the original six repairs plus six extended-audit repairs, updated regressions/diagnostic scripts and authentication support notes. Product entitlements, user credentials, profile data and default-browser preferences were not changed. Temporary QA builds/logs live outside Git. The primary checkout remains on main; this branch is delivered for review and is not merged by this pass.

Diagnosis checkpoints: `64de1755b443dcb57f4192a7f93d38ee0137bd1d` and `3d7fbcee490658df403eab911642ce186a208548`. The final implementation commit and PR are discoverable from the branch/GitHub; read back the remote SHA rather than relying on a self-referential hash in this file.

## Extended verification — 30 September 2026, 16:27 BST

- **Commands/results:** `swift build`, `swift test` (500 tests, zero failures), Xcode Debug build and `build.sh` passed with the selected Xcode 27 toolchain. SwiftPM scratch, Xcode derived data and packaging stayed under the evidence directory. No sandbox workaround was needed. Both exact final app bundles passed strict deep signature checks; sandbox present, both managed browser capabilities absent.
- **Focused native edges:** safe GET parameter encoding (including literal plus, ampersand, quotes and placeholder-shaped text), successful HTML controls, submitter overrides, target/submitter replacement, duplicates, password/file controls, disabled/read-only/inert/covered targets, offscreen scrolling and nested labels. A cancelled search does not alter the field or navigate. The real operator animation rejects a replaced search field.
- **Navigation/title edges:** pre-cancelled load, manual/overlapping navigation, an expired old timer while a newer page still loads, late start/commit/failure/success callbacks, cancellation ownership, timeout, tab closure, initial/dynamic/empty titles and view replacement. Real WebKit objects supply navigation identities; delegate ordering is controlled in those race tests.
- **Native UI:** launched the final packaged app as `com.shayprasad.Kestrel.ExtendedQA20260930`, with its own empty profile. A local fixture changed `Initial title fixture` to `Updated title fixture`; the tab and window updated visibly. A new tab submitted `localhost:18766/check`, retained `https://localhost:18766/check` in the address bar and showed the expected page-unavailable/Try Again banner for the closed port. Screenshots and AX output were inspected. The QA app and loopback fixture server were stopped afterwards.
- **Other checks:** both Node probes, the compiled navigation-failure probe, `bash -n build.sh` and `git diff --check` passed. Final Xcode log had only the skipped AppIntents extraction warning. No generated build, fixture, screenshot or raw log is committed.
- **Boundaries:** PK-005's general launch-failure state is verified with an injected failed opener; it was not forced through an OS default-browser change. This pass does not establish real passkey/Apple Passwords support or a full visual/menu audit. Hosted CI remains blocked by CI-001; the existing Greptile findings were evaluated and repaired, but its previous verdict covers the earlier commit.

## Work log

- **22:55 BST, Codex (GPT-6), PR review repair:** fixed the follow-up submitter hit-test finding, added a native overlay regression for both proposal and activation, and passed all 501 SwiftPM tests, the SwiftPM and Xcode Debug builds, packaged build, shell syntax and diff checks. Hosted CI still cannot start because of the account billing/spending restriction recorded under CI-001.

- **16:27 BST, Codex (GPT-6), extended delivery:** completed six additional repairs, reviewed the intended diff and passed the final gates above. Updated PR #4 and the labelled continuation register; intended delivery is the same working branch, with remote SHA read-back and a clean tree. No main merge. Final logs: `extended-delivery-{build,tests,xcode,package}.log`; focused reproduction and edge logs remain in the same temporary evidence directory.

- **16:22 BST, Codex (GPT-6), extended repairs:** fixed OP-002/003, NAV-002/003 and URL-001. The focused run passed 69 tests, including 21 native WebKit tests and positive offscreen/nested-label/form-encoding cases. Added cancellation-during-animation and replaced-view ownership checks before the full suite. Search now uses retained plain HTML controls for a same-origin GET without arbitrary page submission handlers; documented this compatibility boundary. Full native builds, signing and delivery remain pending.

- **16:06 BST, Codex (GPT-6), extended audit:** refreshed branch/PR status, preserved the clean starting point and passed all 483 baseline tests. Added failing native and URL regressions for OP-002, NAV-002 and URL-001 before product edits. No real account or external form submission was used.

- **16:00 BST, Codex (GPT-6), remote-check audit:** verified PR #4 is open and its head matches the clean working branch. GitHub's visual-smoke job could not start because of its account billing/spending restriction; recorded **CI-001** with the exact run and annotation. Hosted CI is unverified, independent of the 483 passing local tests and signed local builds. Greptile review remained pending. Temporary QA app and loopback fixture server are no longer running.

- **15:58 BST, Codex (GPT-6), delivery:** committed implementation as `c6305cc8cc7b4617862de86da8b602b5534ba095`, pushed it and read back the exact remote SHA. Created [PR #4](https://github.com/shay2000/kestrel-webkit/pull/4) and attached it to this task. This closing handoff note is a documentation-only follow-up on the same PR. PK-002 remains open; the six actionable findings have the verification described above. Read the PR's current head for the latest checkpoint.

- **09:51 BST, Codex (GPT-6), final verification:** 483 tests passed after the retry-URL correction; Xcode build and `build.sh` passed. Both exact final app bundles passed strict codesign verification, with sandbox present and both managed browser capabilities absent. Both Node probes, both compiled native probes, `bash -n build.sh` and `git diff --check` passed. Fresh origin/main is still `fc1689c`; no open PR existed. Preparing the intended source/tests/docs/fixtures for commit and PR creation.

- **09:49 BST, Codex (GPT-6), implementation checkpoint:** all nine focused native regression tests passed, including an approved extension content-script fixture in two tabs. The earlier full run passed 481 tests; final full rerun follows the two additional tests and retry-URL correction. Native Xcode/SwiftPM packaging and strict signature checks passed before that correction. Isolated UI verified multi-tab/split survival, the page-error banner and synthetic passkey banner show/clear. Apple Passwords/extension research and an assertion-only QR fixture are documented separately; no real authentication is claimed.

- **09:24 BST, Codex (GPT-6), implementation start:** verified the clean diagnosis worktree and remote heads. Reusing this session's exact-source baseline (474 tests, 18 failed assertions; builds/signatures passed). Fixing controller isolation first, followed by truthful/retryable handoff, stable operator targeting and navigation failure recovery. User authorised implementation and PR delivery; Apple-managed entitlements remain gated.

- **08:28 BST, Codex (GPT-6):** created this handoff before investigation changes; created the isolated branch from verified GitHub main, read project guidance and prior chat evidence, and started fresh macOS baseline checks. Product source is unchanged.
- **08:33 BST, Codex (GPT-6):** reproduced the earlier chat's 18 assertions, isolated the shared controller as PK-001's cause, read fresh signed entitlements for PK-002, recorded PK-003/PK-004 and classified QA-001 as a stale test. Added reusable diagnosis scripts. No product fix has been applied.
- **08:37 BST, Codex (GPT-6):** confirmed OP-001 with the actual script templates and NAV-001 with the actual native failure delegate. A disposable independent-controller control removed the registration exception while preserving shared extension/data controllers. Recorded repair order, reproduction commands, verification limits and the follow-on audit queue. Preparing the six diagnosis files for a working-branch checkpoint; product fixes remain open.
- **08:39 BST, Codex (GPT-6), end checkpoint:** pushed and read back the diagnostic commit, verified the primary checkout still clean at `fc1689c`, and queued this handoff in the Codex file panel. The six diagnosis files contain no credential-shaped values in a targeted manual check; raw logs/builds remain outside Git. The next model can start with PK-001 without repeating this investigation. No claim of repaired app behaviour or real website passkey verification is made.
