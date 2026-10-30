# PR and branch consolidation — 30 October 2026

The maintainer requested consolidation of all open PRs into main and removal of old branches. At audit time this private repository had one open PR, #10, and three backup branches. PRs #2–#9 were already merged; #1 was already closed. No other open PR needs combining or closing.

## Completed outcome

PR #10 was merged into main with merge commit `63641b0676b95f812cb20c873060734ac0ee73ff`. Its full history is retained. The merged tree exactly matched the reviewed PR head, and its application, tests, resources and workflow matched the passing verification head below. After verifying all three archive tags on the remote, the four audited branches were deleted with exact-tip leases. The remote then had only main and no open PRs. The local checkout tracks main and has no uncommitted changes; this outcome record is a documentation-only follow-up.

## Keep and remove decisions

Keep PR #10's current implementation, including bounded Assistant operation, native helper/provider integration, locally approved profile filling, lifecycle fixes and the verified maintenance changes. Its source/workflow matches the passing Mac run at `850a9405d0bc54da0aaafb82d86328cfe8d33580`; later commits change documentation only. No application changes are introduced by this consolidation.

| Branch | Audited tip | Decision |
| --- | --- | --- |
| `codex/agentic-browsing-reliability` | `104d490f1f319b6ceb59d2ef7d6a00bac5bb9408` before this audit | Merge PR #10 with a merge commit to preserve its history, then delete the branch. |
| `backup/pre-erase-2026-10-23/refinement-worktree` | `9aedd057fbdbf44296aca6502d22f2227c07419a` | Retain the newer sidebar attachment implementation and dark active-control colours already present in PR #10. Do not restore view-local attachment state over the shared chat draft. Archive the original snapshot, then delete its branch. |
| `backup/pre-erase-2026-10-23/stash-0` | `d44ddc0e19ceeae0efd3022464de903408ada907` | Its softer dark glow/edge changes are already present. Its handoff text is historical. Archive the original stash commit, then delete its branch. |
| `backup/pre-erase-2026-10-23/stash-1` | `961b7e3ee8cac34319157b6adcfc35d74b55b27b` | Keep the newer passkey handoff implementation and tests, including success/abort handling, unknown availability probes and retryable external-browser failures. Do not reintroduce the old proactive watcher or blanket claims about default-browser authentication. Archive the stash, including its index and untracked-file parents, then delete its branch. |

The three original backup tips are retained under annotated tags in this same private repository:

- `archive/pre-erase-2026-10-23/refinement-worktree`
- `archive/pre-erase-2026-10-23/stash-0`
- `archive/pre-erase-2026-10-23/stash-1`

These are preservation tags, not release tags. They keep the exact snapshots recoverable without leaving obsolete development branches active. Verify each remote tag's peeled commit before deleting its branch; delete branches only while their tips still match the audited SHAs. Main and the merged PR preserve the current development history.

## Verification and acceptance limits

- Linux Swift 6.0.3: build passed; 412 tests, five skips, zero failures.
- macOS 26.6.2 / Xcode 26.6 / Swift 6.3.3: 654 tests, 13 skips, zero failures; Xcode build, standalone packaging and strict signatures of both app bundles passed.
- [Passing Mac run](https://github.com/shay2000/kestrel-webkit/actions/runs/41042363692): all 18 final captures inspected (17 app views and the intentional wallpaper fixture).
- Consolidation changes documentation and refs only. Reuse the verified code/workflow tree and check that main retains it after merging.

The maintainer's instruction authorises promoting this implementation to main despite the earlier draft-only delivery plan. It does not establish release readiness or close the live shopping, helper, document and cancellation acceptance gates recorded in HANDOFF.md. Keep those limits and the existing action approvals. No public release, public-source push or authentication-capability change is part of this consolidation.
