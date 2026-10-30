# WorkBuddy natural-language sidebar acceptance

Status: **helper connection, clarification and buying-page navigation passed through the Assistant sidebar; phone configuration/basket failed**. Earlier CLI/WebKit harness results are separate evidence. This pass must use the visible Kestrel Assistant sidebar, WorkBuddy / DeepSeek v4.1 Flash, medium reasoning and the Agent mode button. Requests below are typed into the composer as ordinary user language.

## Native helper gate — 11 October 2026

The user made the ordinary Kestrel build available to Computer Use. The earlier sandbox consent wait is no longer the active blocker. The visible error was “Kestrel couldn’t connect to its Mac CLI helper”. Login Items already allowed the helper, while launchd repeatedly failed its old registration with EX_CONFIG.

Refreshing a development-signed build replaced the registration but exposed a Launch Constraint Violation: launchd's generated constraint had an empty CDHash list. The companion executable did not embed its Info.plist. Packaging now embeds the final helper identity in `__TEXT,__info_plist` and signs the helper with hardened runtime. The browser launches a fresh companion instance from its bundle, waits up to ten seconds for registration to finish, then requires an authenticated five-second XPC readiness response before reporting connection success. No permission reset, global background-item reset, credential copying or signature-check bypass was used.

Native acceptance: build 202610111400 opened visibly; Settings showed “Mac CLI helper connected.” launchd showed the same build running, with the helper's signing identifier, development validation category and team in its launch requirement. Both sides retain designated-signature verification. Strict deep signing passed. The signed app remains open at its temporary Xcode build path, with the installed copy preserved.

## Test matrix

Use a separate website tab and open the Assistant sidebar beside it. Preserve the user's existing tabs and unsent drafts. Start each independent journey in a new chat; keep follow-ups in the same chat. Record the exact visible model, prompt, approvals, actual destination, observations and response. Explicitly approve bounded shopping actions in Kestrel, stop before checkout and do not enter account/payment information. Any basket change stays in the test session.

| Case | Starting public page | Natural request | Required evidence |
| --- | --- | --- | --- |
| Current-model discovery | Samsung UK smartphones | “I'm after the newest Galaxy S phone. Can you find it here and show me the buying page?” | Model comes from the current catalogue; actual destination matches; legacy demo products do not count |
| Vague shopping and clarification | Apple UK iPhone catalogue | “Find the new iPhone in the new colour and put it in my basket.” | Discover current product first; ask about ambiguous colour/storage/model rather than guessing; never claim basket success without the actual item |
| Budget and colour constraints | Apple UK iPhone catalogue | “I'd like a pink iPhone for under £800. Find an option here and check the price and colours before adding anything.” | Site evidence supports the exact model, price and colour; no basket addition |
| Follow-up reference | Same Apple conversation | “Does that one come in black too? Keep me on its buying page.” | Resolve “that one” to the chosen model; current-page evidence supports answer; no unrelated model switch |
| Cross-page policy finding | A selected product buying page | “Before I buy, find the returns policy and tell me how long I've got to send it back.” | Navigate to the relevant official policy; retain original product context; evidence supports the period and material exceptions |
| Ordinary research navigation | GOV.UK | “Find what it costs to renew an adult passport online and show me the official page.” | Official destination and observed fee; no memory-only answer or unrelated application submission |
| Interruption/reset | During an active public-page task | Click Stop, then New Chat and type a different request | Old action/reply does not resume; new sidebar chat and draft remain independent |

For every case record **passed**, **failed**, **blocked**, or **not run**. Separate application errors, provider failures, model decision errors, website blocks and approval denials. Six-action exhaustion is incomplete unless the requested outcome has already been visibly established. A fluent answer or proposed action is not execution evidence.

## Results

All requests below were typed into the real Assistant sidebar with WorkBuddy / DeepSeek v4.1 Flash and Agent mode armed. Medium reasoning was visible in Settings. Computer Use screenshots and accessibility output recorded the actual browser state.

- **Clarification passed:** Apple UK iPhone catalogue; exact request “Find the new iPhone in the new colour and put it in my basket.” WorkBuddy identified two New products (Duo and 18 Pro), asked which model/colour, and made no basket change. Minor finding: the flattened page excerpt made it present separate Glacier and Silver finishes as “Glacier Silver”.
- **Buying-page navigation and evidence recovery passed:** exact follow-up “The iPhone 18 Pro in Burgundy. Take me to its buying page first and check the available sizes and storage before adding anything.” WorkBuddy opened `/uk/shop/buy-iphone/iphone-18-pro`, then used `find_text` for “1TB” after recognising the excerpt ended mid-list. Its final answer listed the observed 256GB/512GB/1TB/2TB prices of £1,199/£1,399/£1,799/£2,399. No configuration or basket change was made.
- **Phone configuration/basket failed:** exact follow-up “256GB please, the regular Pro, Burgundy, no trade-in or extra cover. Put just that phone in the bag and check it, but do not go to checkout.” WorkBuddy replied that it would select Burgundy, but returned without proposing or performing an action. The page still had no model selected and disabled finish/storage controls. Kestrel's fixed `click_text` selector currently supports links/buttons, not labelled native radio controls. This is an operator capability gap plus a model promise without execution, not a helper failure. No item was added. Add bounded, approval-gated radio/variant support and regression coverage before repeating this gate.
- **New Chat reset passed after completion:** New conversation visibly cleared the prior transcript and produced an empty composer; the following policy request contained no revived shopping messages. Cancellation during active work remains not run.
- **Returns FAQ action/evidence passed:** a fresh conversation on the buying page asked “Before I buy, find the returns policy and tell me how long I have to send it back.” WorkBuddy proposed the exact “Can I return my iPhone?” button; Kestrel paused for approval. After approval the actual FAQ expanded. WorkBuddy used `find_text` for “14 days” and reported the observed period from receipt, original packaging/accessories and good-condition requirements. The full linked policy page was not opened, so the cross-page policy case remains partial.

Samsung discovery, budget/colour constraints, black-colour follow-up, GOV.UK and active Stop/New Chat cases remain **not run**. The helper connection failure is fixed for the tested signed build; shopping is not end-to-end ready.

Validation: native SwiftPM suite **616 tests, 13 optional skips, zero failures** (37.8 s); native Xcode build, standalone packaging, Swift build, shell syntax and strict deep signature passed. Logs are `/private/tmp/kestrel-helper-refresh-tests.log`, `kestrel-helper-identity-build.log` and the Computer Use transcript. This evidence supersedes the previous launch/consent blocker without changing historical harness results.
