# Kestrel optimisation handoff

- **Owner:** Codex (GPT-6).
- **Request:** “Can you do any code optimisations? Then push as a pr”.
- **Started:** 30 September 2026, 22:30 BST.
- **Branch:** `codex/performance-optimisations`, reusing this task’s clean worktree at `~/.codex/worktrees/passkey-diagnosis/kestrel-webkit`.
- **Baseline:** `977d713b107ef9b445705905456fece677ed46a8` from open PR #4. The optimisation PR will target `codex/passkey-diagnosis` so its diff contains only this pass; PR #4 remains the integration path to main.
- **Verification baseline:** all 500 tests, SwiftPM build/package and Xcode Debug build passed again before product edits. Same macOS 27.0 / Xcode 27.0 host. Build products remain outside Git.
- **Evidence:** `/private/tmp/kestrel-optimisation-20260930/`; baseline build logs use the `optimisation-baseline-*` prefix under `/private/tmp/kestrel-passkey-diagnosis-20260930/`.
- **Checkpoint:** all three optimisations implemented and locally verified; 504 tests, native builds, strict signatures and the isolated app smoke passed. Delivered on `codex/performance-optimisations` for review against `codex/passkey-diagnosis`. Read the remote branch for the exact latest commit SHA. Preserve the earlier bug IDs and external limitations in `BUG_FIX_HANDOFF.md`.

| ID | Finding | Status |
| --- | --- | --- |
| PERF-001 | Fixed intent-router expressions compile on every check; the nil-model path repeats the deterministic classification | Implemented; identical benchmark outputs, 372.33 ms → 40.45 ms median per synthetic batch |
| PERF-002 | Visible-control capture evaluates all matching DOM nodes before slicing to 40 visible controls | Implemented; native fixture reduced geometry reads from 1,009 to 45 with identical output |
| PERF-003 | Repeated identical browser metadata causes unnecessary published tab-collection updates | Implemented; 42 metadata assignments now publish only the two actual changes |

## Work log

- **22:30 BST, Codex (GPT-6):** verified clean working/remote heads and the still-open PR #4, created the optimisation branch from its head, reread project/build guidance and completed baseline checks. Selected bounded changes that can be verified without credentials, live providers or altered browser permissions.

## Measurement and behaviour contract

- **PERF-001:** a finite set of immutable, app-owned regular expressions is compiled lazily once. The nil-model route no longer runs the same deterministic rules twice. The order and contents of all 30 expressions are unchanged; prompt text is never cached. The synthetic corpus checks all five model-decision cases, extracted image subjects, stripped search instructions and country qualification. Baseline and changed output/checksum are identical. Unicode requests also pass a 100-task concurrency regression.
- **PERF-002:** stop geometry/style inspection after the first 40 visible candidates. Preserve DOM order and the original quota semantics: unlabelled and unsupported-scheme controls still consume a visible slot, though they are omitted from the returned labels. Tests verify query/fragment removal, no input-value capture, hidden/offscreen filtering, empty pages and small pages. This is a reduction in layout/style queries, not a claim that WebKit never materialises the selector’s NodeList.
- **PERF-003:** deduplicate the combined title/address/favicon stream before mutating the published tab collection. A real change back to an earlier value still emits; no timer or delayed update is introduced.

The router benchmark uses `swiftc -O`, five warmed samples of 340 synthetic prompts (each exercises all five model-decision cases plus helper functions). Median batch time fell from **372.33 ms to 40.45 ms**, about **9.2×** faster. This measures deterministic helper CPU work, not model response time, network latency or overall browser speed. The control fixture deliberately contains 1,009 matching nodes to expose the previous unbounded traversal. No machine-dependent speed threshold is put in the test suite.

Reproduce the router comparison without a second checkout:

```bash
git show 977d713:KestrelWebKit/AssistantIntentRouter.swift > /private/tmp/KestrelRouterBefore.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -O -parse-as-library \
  /private/tmp/KestrelRouterBefore.swift scripts/benchmark-intent-router.swift -o /private/tmp/kestrel-router-before
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -O -parse-as-library \
  KestrelWebKit/AssistantIntentRouter.swift scripts/benchmark-intent-router.swift -o /private/tmp/kestrel-router-after
/private/tmp/kestrel-router-before
/private/tmp/kestrel-router-after
```

Compare the `corpus` and `checksum` values as well as median timing. The stub in the benchmark is only a link dependency for the unused model entry point; it does not replace production routing code. No provider or Keychain is accessed.

## Final verification and continuation — 30 September 2026, 22:37 BST

- **Local gates:** 504 tests passed (27 native WebKit regressions), SwiftPM build, Xcode Debug build and `build.sh` passed. Both exact app bundles passed `codesign --verify --deep --strict`. Entitlement read-back confirms the sandbox remains present and managed browser/passkey capabilities remain absent. The only final Xcode warning was skipped AppIntents metadata extraction.
- **Native smoke:** launched the final packaged app under isolated bundle ID `com.shayprasad.Kestrel.OptimisationQA20260930`; New Tab rendered, and a navigation to a closed loopback port updated the address and tab title and displayed the existing failure/retry banner. Inspected the screenshot and accessibility state. No live provider or user profile was used; this is a startup/navigation smoke, not a general performance or visual audit. The QA app was quit afterwards.
- **Other checks:** 23 focused tests passed before the full suite. Both existing Node diagnosis scripts, `bash -n build.sh` and `git diff --check` passed. Router corpus/checksum equality and unchanged expression order were checked independently of timing.
- **Hosted checks:** the latest base-PR workflow, run `36771744254`, did not start; its check annotations still report failed payments/spending limits (CI-001). Local passes do not establish hosted CI success. Do not alter billing or claim the optimisation PR is CI-green without a fresh successful run.
- **Scope/delivery:** three production files, four regression tests across two existing test files, a reusable standalone benchmark and continuation documentation. No new app source file or Xcode membership change. The focused PR depends on PR #4; merge it into the fixes branch first, or retarget/rebase after PR #4 reaches main. No merge is authorised by this delivery.
- **Next model:** inspect the current PR/base heads and preserve both this log’s PERF IDs and the bug register’s existing IDs. Whole-browser CPU/memory profiling, popup behaviour, extension runtime permissions and real passkey/QR authentication remain separate work. Do not infer whole-app speed from this synthetic routing benchmark.

- **22:37 BST, Codex (GPT-6), completion:** reviewed the intended diff, recorded measurements and passed all local gates. Preparing the reviewed files for commit/push and focused PR creation; final delivery checks read back the remote SHA and confirm a clean tree. Temporary logs/builds remain outside Git.
