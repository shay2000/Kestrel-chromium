# BrowserOS agent architecture comparison

Source inspected read-only on 11 October 2026, local BrowserOS commit `68d6e9bbdb82318e4221153670dba3919dad8ccd`. These findings describe that checkout, not a live BrowserOS acceptance test. BrowserOS source was not copied into Kestrel.

## How browser control works

BrowserOS hosts CLI agents through ACP adapters. `packages/browseros-agent/apps/server/src/lib/agents/host-acp/config.ts` selects the Codex ACP npm adapter, which carries its own agent runtime. Updating a host Codex executable alone does not update this adapter. Its local browser MCP server supplies the agent with browser tools; the model does not gain browser control just by being selected.

`agents/acp/mcp-servers.ts` configures a loopback endpoint and conversation-specific tool lease header, including a read-only mode. `agents/acp/acp-agent-policy.ts` supplies model/reasoning and browser instructions. This wiring delegates authentication to the provider runtime; it does not establish that an arbitrary installation is already signed in, nor that usage is free.

`agents/acp/acp-agent-runtime.ts` keeps sessions per agent/conversation, rejects overlapping turns, checks cancellation, and seeds a new session with history. It can reset and retry a failed session resume once before response output begins. Replaying actions after an ambiguous failure would risk duplicate mutations; this is not an unrestricted retry loop.

## Page understanding and execution

| BrowserOS implementation | Reliability benefit | Kestrel implication |
| --- | --- | --- |
| `crates/browseros-mcp/src/tools/snapshot.rs` renders an accessibility tree with element references and interactive/full modes | Roles and ancestor context distinguish controls with identical labels | Native structured targets would improve repeated buttons, sizes and colours; not implemented in this pass |
| `crates/browseros-core/src/snapshot/refs.rs` scopes references to document identity and refreshes stale-node metadata | Navigation cannot reuse a target from the previous document | Keep exact-target revalidation; any new reference protocol must retain the initiating tab and document |
| `crates/browseros-core/src/settle.rs` waits for navigation then DOM quiet within a deadline | Avoids capturing intermediate loading states | Added independently written, fixed isolated-world settling before Agent mode snapshots |
| `crates/browseros-mcp/src/tools/act.rs` returns a post-settle diff | The model observes the effect without redundant reads | Kestrel already supplies a fresh bounded snapshot; WorkBuddy guidance now tells it to use that evidence |
| ACP active-turn lock and bounded pre-response resume recovery | Avoids competing turns and duplicate replies | Preserve Kestrel cancellation/generation guards; persistent ACP would require a separate lifecycle implementation |

One caveat in this BrowserOS checkout: `crates/browseros-mcp/src/response.rs` passes the default settle budget of **50 ms**, while `crates/browseros-core/src/timeouts.rs` sets DOM quiet to **100 ms** and navigation detection to **150 ms**. That default cannot complete the full quiet check; budget exhaustion is logged and readback continues. The architecture is useful, but this checkout does not prove fully settled readback. Kestrel does not copy those timing defaults.

Kestrel remains native WebKit. WorkBuddy currently runs one tool-free CLI inference per proposal; Kestrel owns the six-action loop and all action approvals. This is intentionally different from BrowserOS's broader browser-tool surface. No Chromium runtime, ACP dependency, arbitrary selectors, model JavaScript or bypass-permission mode was added.

## Changes and evidence

Agent snapshots now prioritise site search and main-content controls over large menus, exclude transparent ancestors and stop at the existing control quota. A fixed isolated-world observer waits at least 500 ms and for 250 ms of DOM quiet, with a 1.5-second page-timer budget; it disconnects on completion. Ordinary answer snapshots do not pay this delay. Navigation/loading and cancellation are checked before using the result. A deterministic per-request guard also blocks a repeated standard Add to cart/basket/bag action on the same URL even if incidental text changes. This reduces intermediate snapshots but cannot prove that every future network response has arrived; background timer throttling and a busy WebKit process can extend wall-clock time.

Native regression tests cover delayed basket content and continuously changing pages. Live WorkBuddy/WebKit tests verified Apple UK product comparison, a demo-shop basket, and a follow-up swapping the phone while preserving one basket item. The demo shop has a legacy Samsung catalogue: basket mechanics do not validate finding a current phone on a real retailer. The final guarded replacement journey passed with exactly one S7 and total 800. Repeated live basket replacement also exposed intermittent empty readback and duplicate-add proposals; these failures remain recorded, and duplicate additions now have a separate deterministic regression. The variant-shop attempt was blocked by the site's Cloudflare 526 origin-certificate error; no security bypass was attempted. Packaged-app XPC/helper acceptance remains separate and unverified because new app launches stalled in macOS sandbox initialisation.

## Next priorities

1. Resolve the signed-app launch and helper-registration acceptance gate, then verify picker-to-helper-to-page control in the packaged UI.
2. Add native document-scoped structured controls for repeated labels and explicit variant selection, with stale-target, hit-testing and approval regression coverage.
3. Measure a bounded change-summary format against full snapshots before introducing diffs or persistent CLI sessions. Keep mutation retries disabled unless their outcome can be established.
