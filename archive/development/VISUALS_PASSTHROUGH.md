# Kestrel visual passthrough

**Audit date:** 27 September 2026

**Author:** Codex (GPT-6), with three independent Luna subagent passes (`gpt-6-luna`)

**Branch/worktree:** `codex/visuals-fix` — `~/.codex/worktrees/visuals-fix/kestrel-webkit`

**Baseline:** `main` at `72578f8fbc85a8c8bfa6bc5923604e6b0b95886c`
**Build reviewed:** Kestrel `0.1.0`, build `202609272233`; executable SHA-256 `2f997b7709f18ee41055990a0d9a9efb843c123ef5654277502574667e546bb4`.

## Scope and method

The initial visual audit was performed on 27 September 2026 using three byte-identical copies of the newest packaged app so each reviewer could inspect a separate surface:

| Instance | App copy | Assigned surface | Observed window |
| --- | --- | --- | --- |
| 1 | `/private/tmp/kestrel-dark-button-contrast-final5-app/Kestrel.app` | New Tab dashboard, pinned grid, rail, bookmarks and composer | 1200 × 800 |
| 2 | `/private/tmp/kestrel-visuals-pass/instance-2/Kestrel.app` | Settings sections and popovers | 900 × 680 Settings window |
| 3 | `/private/tmp/kestrel-visuals-pass/instance-3/Kestrel.app` | Assistant page, Chats menu, model picker and composer controls | 1200 × 800 |

The two temporary copies have the same executable SHA-256 as instance 1. The original findings below come from live Computer Use screenshots and accessibility state. A focused correction and follow-up review ran on 28 September on `codex/visuals-fix`; results and remaining limits are recorded below. No settings were intentionally changed beyond temporarily checking Light and Dark appearance, then restoring System. No external page was opened during this pass. A pre-existing GitHub pinned page came forward when Settings closed and was left untouched.

Priority is based on how readily the issue affects reading, alignment or visual consistency at the observed window size. It is an audit ranking, not a fix order.

## Findings

### New Tab and browser chrome

#### NT-01 — Bookmark shortcut row has an intentional trailing fade

- **Status:** Intentional behaviour · runtime scroll remains unverified
- **Location:** New Tab dashboard, bookmark shortcut row beneath the composer.
- **Observation:** The rightmost bookmark is partly clipped under a trailing fade so the row reads as horizontally scrollable. The user confirmed this is the intended design. The source uses a horizontal ScrollView and conditional trailing fade.
- **Evidence:** Instance 1 live screenshot and source inspection. Computer Use scroll and drag attempts did not visibly move the row, so runtime scrolling still needs a successful interaction check. This is not a visual defect and no code change is planned.

#### NT-02 — “+ New Tab” has weaker visual hierarchy than adjacent rail items

- **Priority:** Medium · **Confidence:** Medium
- **Location:** Left rail, below the pinned-site grid.
- **Observation:** The small grey icon and label read more like a section caption than an action, while the pinned tiles above and tab rows below receive larger or stronger surfaces. The understated treatment may be intentional, so compare it against the desired hierarchy before changing it.
- **Evidence:** Instance 1 live screenshot.

#### NT-03 — Pinned favicon artwork has uneven optical size

- **Priority:** Low · **Confidence:** Medium
- **Location:** 3 × 2 pinned-site grid.
- **Observation:** Tile dimensions, radii and gaps align consistently, but the Drive, GitHub and X marks appear noticeably smaller or lighter than YouTube, Gmail and Reddit. This may come from the artwork bounds rather than the tile layout.
- **Evidence:** Instance 1 live screenshot. Tile geometry itself looked even.

#### NT-04 — Attach popup’s subsection label has low contrast

- **Priority:** Medium · **Confidence:** High
- **Location:** New Tab composer → Attach popup.
- **Observation:** The “Open tabs” subsection label is very dim against the translucent menu and can nearly disappear. The seven rows are evenly spaced and the menu aligns with the paperclip, but there is little separation between “Choose a file…” and the subsection/list.
- **Evidence:** Instance 1 opened and dismissed the popup with Escape.

#### NT-05 — Pinned-tile context menu gives one command heavier emphasis

- **Priority:** Low · **Confidence:** Medium
- **Location:** Right-click menu for a pinned YouTube tile.
- **Observation:** “Close Page (Keep Pin)” appears noticeably bolder than other enabled commands. The menu container is rounded and its row spacing/dividers looked consistent; the doubled inset tile treatment was not present.
- **Evidence:** Instance 1 opened and dismissed the context menu without selecting a command.

### Settings

#### SET-01 — Helper and disclosure text is small and dense across sections

- **Priority:** High · **Confidence:** High
- **Location:** General, Assistant, Privacy, Connections and Extensions; especially long policy/setup paragraphs.
- **Observation:** Secondary copy is roughly 10–12 px in the 900 × 680 Settings window. Several cards have room to spare but helper text wraps into many short lines, making the body hierarchy hard to scan beneath the headings.
- **Evidence:** Instance 2 live screenshots of General top/lower sections, Assistant, Privacy, Connections and Extensions.

#### SET-02 — Last wrapped lines in expanded disclosures appear centre-aligned

- **Priority:** High · **Confidence:** High
- **Location:** Privacy → Page context → Privacy details; Connections → Manual setup and other MCP clients; Extensions → Compatibility and permissions.
- **Observation:** The final wrapped line of helper paragraphs begins noticeably farther toward the centre than preceding lines, while nearby paragraphs remain left-aligned. The repeated ragged edge reads as an accidental alignment change.
- **Evidence:** Instance 2 observed the same pattern in three expanded disclosures.

#### SET-03 — Native blue popup and checkbox styling conflicts with the lavender card system

- **Priority:** High · **Confidence:** High
- **Location:** General → Default search engine; Assistant → Provider; Connections and Extensions controls.
- **Observation:** Custom purple-glow cards contain stock grey popup fields with saturated blue arrows and blue selected rows. Other sections mix blue checkbox squares and a blue Connect Codex button with grey Import, Save and Remove controls. The colours and control treatments compete with the surrounding lavender surfaces.
- **Evidence:** Instance 2 opened and dismissed the search-engine and provider popovers and inspected Connections/Extensions.

#### SET-04 — Segmented pickers, popup fields and card surfaces do not read as one control family

- **Priority:** Medium · **Confidence:** Medium-high
- **Location:** General → Appearance and New Tab choices, compared with General → Search and Assistant → Provider.
- **Observation:** The segmented choices use grey tracks with a purple selected half, while popup fields remain flat grey with blue arrows. Their visual weight and edges differ sharply inside otherwise similarly styled cards.
- **Evidence:** Instance 2 live screenshots and popovers.

#### SET-05 — Settings title/toolbar band consumes space above the content

- **Priority:** Medium · **Confidence:** Medium
- **Location:** Settings window, all inspected sections.
- **Observation:** A mostly empty title/toolbar band of about 80 px and a full-width divider sit above the cards. At the observed height, the cards begin close below it and lower content is pushed toward the bottom edge. Some of this may be native window chrome.
- **Evidence:** Instance 2 screenshots; confirm whether the band is app-owned before considering a layout change.

### Assistant page and menus

#### AST-01 — Saved Chats menu is very tall and tightly packed

- **Priority:** High · **Confidence:** High
- **Location:** Bottom-left Chats menu on the Assistant page.
- **Observation:** The floating panel spans almost the full window height (about 760 px at 1200 × 800), with roughly 30 prior-chat rows at about 24 px each and small bold text around 12 px. It visually dominates the sidebar and feels denser than the other menus. No saved chat titles are recorded here.
- **Evidence:** Instance 3 opened and dismissed the Chats menu.

#### AST-02 — Model picker text and tiles are much smaller/flatter than the composer

- **Priority:** Medium-high · **Confidence:** Medium-high
- **Location:** Assistant composer → model picker.
- **Observation:** The picker uses a compact two-column grid with small marks and labels (about 12 px) in narrow grey tiles, plus a thinly divided “Model / Automatic” footer. It reads flatter and denser than the pill-like composer around it.
- **Evidence:** Instance 3 opened and dismissed the model picker.

#### AST-03 — Composer controls have weak size and action hierarchy on the empty Assistant page

- **Priority:** Medium · **Confidence:** Medium
- **Location:** Bottom Assistant composer.
- **Observation:** The composer is about 680 × 43 px against a mostly empty canvas, with a small placeholder and several similarly sized 32 px circular controls. Attach and Browse are low-contrast compared with Web’s lavender emphasis; the send control is dim. The icons have little text support at this scale.
- **Evidence:** Instance 3 empty Assistant screenshot. Browse was disabled because no webpage was open.

#### AST-04 — Assistant page header controls and label are small relative to the canvas

- **Priority:** Medium · **Confidence:** Medium
- **Location:** Top-left Assistant page header and top-right new-chat/close controls.
- **Observation:** “Assistant” and the adjacent controls are roughly 12 px and low contrast, so they barely distinguish from browser chrome at 1200 × 800.
- **Evidence:** Instance 3 empty Assistant screenshot.

#### AST-05 — Menu-bar Chats list repeats the same dense, long presentation

- **Priority:** High · **Confidence:** High for density; Medium for visual styling
- **Location:** Menu bar → Chats.
- **Observation:** The menu exposes **New Chat** followed by 30+ compact saved-chat entries, with repeated titles and no additional separators. This is the same high-density pattern as the in-window Chats panel. Individual chat titles are intentionally not reproduced in this audit.
- **Evidence:** Instance 3 accessibility list; native-menu screenshot capture was unavailable, so exact row styling and wrapping were not visually confirmed in this pass.

#### AST-06 — Extensions menu begins with a long disabled explanation

- **Priority:** Medium · **Confidence:** Medium
- **Location:** Menu bar → Extensions.
- **Observation:** One long disabled explanatory paragraph precedes two disabled commands. It may dominate menu width/height compared with shorter menus, but the native-menu screenshot could not be captured to verify wrapping or visual weight.
- **Evidence:** Instance 3 accessibility tree only; visual extent remains unverified.

#### AST-07 — Window menu is substantially longer than the Kestrel-specific menus

- **Priority:** Low · **Confidence:** Low
- **Location:** Menu bar → Window.
- **Observation:** It contains standard macOS window/tiling commands and nested Move & Resize and Full Screen Tile submenus. No Kestrel-specific style defect was established; this is likely standard system menu content.
- **Evidence:** Instance 3 accessibility tree only; native-menu screenshot capture was unavailable.

## Implementation and verification status — 28 September 2026

| Finding | Outcome |
| --- | --- |
| NT-01 | Intentional fade and partial cutoff retained. A synthetic rightward scroll did not move the row, so actual horizontal scrolling remains unverified. |
| NT-02–04 | Rail action hierarchy, favicon sizing and Attach popup subsection treatment updated; inspected in the live QA build. |
| NT-05 | Pinned-tile context-menu command emphasis normalised; right-click menus were inspected live. |
| SET-01–02 | Helper typography increased and disclosure text made leading-aligned; all five Settings sections and relevant disclosures were reviewed live. |
| SET-03 | Lavender tint was reviewed live on native settings controls, including the prominent Connect Codex button. It appeared in the same lavender family as the rest of the Settings surface; the button was not activated. |
| SET-04 | Provider picker tiles and selected-state styling updated; provider picker was reviewed live. |
| SET-05 | Native Settings title/toolbar band left unchanged. |
| AST-01, AST-05 | Saved Chats are grouped into recency submenus of at most five entries. Boundary tests pass. The current QA profile had no saved conversations, so only New Chat and disabled No saved chats were available live; populated submenu styling and selection remain unverified. |
| AST-02–04 | Provider tiles/selection, composer hierarchy and Assistant header hierarchy updated and reviewed in the live QA build. |
| AST-06 | Extensions menu explanation shortened; menu content inspected through accessibility. |
| AST-07 | Standard macOS Window menu left unchanged. |

The current QA pass verified split focus in both panes, one combined sidebar row, divider resizing, equal-width reset, and separation with both tabs retained. At 28% pane width, the narrow-pane More menu stayed on screen and exposed its secondary controls. In the empty New Tab pane, the address placeholder was shortened by the available width; actual page-address readability at that width was not measured. The native menu-bar commands and nested menus were enumerated through accessibility, but Computer Use did not provide a usable screenshot of the native menu popovers. Connections showed Network.NWError error 22 - Invalid argument for the local MCP server; no connection setting was changed.

At the earlier 10:39 checkpoint, Xcode 27.0 and ./build.sh succeeded and 474 tests passed; later entries below supersede its visual-verification status. The current post-fix Xcode and package builds, strict signatures, test totals and cleanup are recorded in the latest continuation entry at the end of this document. Changes remain uncommitted and unpushed.

## Guidance consulted

- [Apple Human Interface Guidelines: Menus](https://developer.apple.com/design/human-interface-guidelines/menus?changes=_4_1_8) recommends consistent styling within groups, prioritising common commands, keeping menus scannable, using one-level submenus sparingly, and considering a separate menu when a submenu contains more than about five items. The saved-chat groups use a five-item cap.
- [Apple Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility?changes=latest_maj_6_3&language=objc) lists 13 pt as macOS's default text size and 10 pt as its minimum, and recommends checking contrast in both appearances. Settings support text uses a system footnote style, leading alignment and wrapped height; the user-visible sections were checked in Light and System-following Dark modes, but larger accessibility text was not tested.
- [Apple Human Interface Guidelines: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus?changes=_3) recommends a small number of directly relevant actions and keeping nested context submenus to one level.
- [Apple Human Interface Guidelines: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars?changes=la) recommends moving less important controls into overflow as width narrows; this informed the split-pane More-menu review.

## Exhaustive menu inventory and live status — 28 September 2026

This inventory maps the source-defined menu surfaces to the existing review evidence. “AX checked” means the accessibility tree exposed the contents; it does not prove visual rendering, popup bounds, hover behavior, or every state-dependent branch.

| Surface | Menus and nested paths | Evidence and remaining check |
| --- | --- | --- |
| macOS menu bar | Kestrel (including Services), File, Edit (including AutoFill), View, Tabs, Navigate, Assistant, Chats, Extensions, Window (Move & Resize and Full Screen Tile), Help | On the current pass, accessibility exposed every menu and nested path. Tabs was checked with a split pair. Extensions commands were disabled because extensions remained off. Help was inspected without navigating away. Native menu popover screenshots remain unavailable, so their visual styling and wrapping are not verified. |
| Tab rail and tab rows | Rail background; New Tab button; pinned and regular tab rows; split row and each split member; Open in Split View With child list; rename/pin/move/close/reopen actions; split-only actions | The live pass opened the New Tab context menu, split context menu and Open in Split View With → Assistant; it also tested split, focus, equal-width reset, separation and closing the temporary Assistant tab. The current target list had one eligible other tab, so other multi-tab child-list states were not populated. The empty Add Pinned Website sheet was cancelled. |
| New Tab dashboard | Attach → Choose a file; Attach → Open tabs; bookmark → Remove Bookmark; bookmark horizontal shelf | The attachment picker displayed the temporary .txt fixture as Plain Text with Attach enabled; it was cancelled without attaching. A fresh screenshot confirmed that the empty Attach menu's “Open tabs” section heading is still low contrast; the source now shows the disabled empty state directly and nests available tabs under an “Open tabs” submenu. A new build and live check are pending. Twelve synthetic bookmarks showed five whole pills and a sixth clipped under the right fade; all were removed. The fade is intentional, but horizontal movement did not respond to Computer Use scroll or drag input. |
| Split-pane toolbar | Narrow-pane More → back/forward, sidebar, Assistant and bookmark controls | At 28% pane width, the More popup stayed within the app window and exposed the controls; pane focus, resizing and equal-width reset were exercised. The empty-page address placeholder appeared shortened at that width; an actual loaded address was not tested there. |
| Assistant sidebar | Chats menu and groups; Previous chats popover, per-chat Delete buttons, Clear → destructive confirmation; model/provider popover; Web options menu | The current Chats menu contained New Chat and disabled No saved chats, so populated history groups, per-chat Delete buttons and clear confirmation were absent. The provider popover showed all ten providers and the manual model field opened; keyed providers were not selected. Web was toggled off and restored on. No conversation was created and no request was sent. |
| Assistant page composer | Provider/model popover → quick picks, Browse all models/search, manual model entry; Web toggle; Attach menu; page-control Browse state | All provider choices and the manual-model disclosure were reviewed; the full searchable catalogue and provider-specific network/key states were not opened. Browse was disabled on the standalone Assistant page and enabled when a webpage pane was present, but was not armed. The file picker test was cancelled and no prompt was submitted. |
| Settings | Appearance and New Tab segmented pickers; Search engine picker; Provider picker; regular ProviderModelPicker; Browser Data file importer; extension importer/approval sheet | General, Assistant, Privacy, Connections and Extensions were reviewed, including relevant Privacy, Manual setup and Compatibility disclosures. Search engines were Google, DuckDuckGo and Bing; appearance was restored to System. Exa, local MCP and extension import remain off. The Browser Data importer accepted two safe HTTP(S) bookmarks, rejected a `javascript:` entry and omitted a duplicate from a generated fixture; all synthetic bookmarks were subsequently removed. The extension permission review overlay was opened in the 23:01 BST continuation addendum below; its synthetic fixture was cancelled without approval. |

The live pass varied the order of Settings, Assistant/model controls, tab context menus, split controls and menu-bar commands. Appearance, Web and split/tab state were restored after checking. No real user file was selected; the synthetic attachment was cancelled. Destructive chat deletion, extension approval, external navigation and submitting an Assistant prompt were excluded.

### Current continuation verification — 28 September 2026, 10:39 BST

The five-item saved-chat grouping passes the updated boundary test. A fresh `swift test --scratch-path /private/tmp/kestrel-visuals-continuation-test` run passed 474 tests with zero failures. Xcode 27 Debug build succeeded, strict codesign passed for the Xcode app, `./build.sh` produced package build `202609281020`, strict codesign passed for the packaged app, and `bash -n build.sh` plus `git diff --check` passed. Both newly produced app bundles were moved into `/private/tmp/kestrel-visuals-archive/`.

The final and earlier QA bundles both timed out when opened through Computer Use and appeared as background processes without usable windows. Activity Monitor was used to stop those processes; the final Computer Use inventory showed no Kestrel process running. Therefore the current five-item Chats menu, every menu's screenshot appearance/click-order behavior, the tab split-target child list, history popover, final Connect Codex tint, actual bookmark scrolling, and narrow-pane More bounds are still unverified live. The prior live screenshots and accessibility checks remain evidence for the earlier eight-item build only.

A further isolated Xcode QA build used bundle identifier `com.shayprasad.KestrelVisualQA` to rule out ambiguity from archived Kestrel bundle IDs. Xcode build and strict signing verification succeeded, but Computer Use returned “Computer Use was not approved to use Kestrel” before launch. The app did not start and its bundle was archived. No alternate UI automation route was used; the exhaustive live pass requires the Computer Use access gate to permit Kestrel.

## Coverage and limits

- Inspected the New Tab dashboard and its pinned/bookmark/composer surfaces; all five Settings sections and selected popovers/disclosures; the empty Assistant page, Chats menu, model picker and composer controls; and right-click menus for a pinned tab, New Tab, bookmark and split panes.
- Menu-bar inventory covered Kestrel, File, Edit, View, Tabs, Navigate, Assistant, Chats, Extensions, Window and Help through accessibility. Visual styling and wrapping of native menu-bar popovers remain unverified because Computer Use did not provide usable menu screenshots.
- The live review included Dark and Light Settings views, then restored System appearance. It does not establish appearance at other window sizes or while results/conversations are populated.
- The Connect Codex lavender tint and the narrow-pane More popup bounds were verified in the latest live pass. The shelf's actual horizontal movement, native menu-bar popup styling, populated saved-chat groups, and a loaded address in the narrowest split pane remain unverified.


### Bookmark shelf runtime follow-up — 28 September 2026, 16:52 BST

A fresh live pass imported a generated HTML fixture containing 12 distinct bookmark entries into the isolated QA app. The 1200 × 800 New Tab screenshot showed the first five pills fully and the sixth partially clipped beneath the trailing edge fade; the accessibility tree exposed all 12 titles. This confirms that the right-edge fade and partial cutoff are the intended overflow treatment.

ContentView.swift implements the shelf through FadingHorizontalScroll and a native horizontal ScrollView. Computer Use horizontal scroll input at the shelf accessibility area and at on-screen coordinates, followed by a drag across the row, produced no visible horizontal displacement. Actual scrolling remains unverified through this input path. No visual defect was established and no product code was changed.

Cleanup removed all 12 imported QA bookmarks and the temporary Kestrel bookmark, unpinned QA test, closed its page and deleted the generated fixture. The isolated QA bundle and earlier builds are in /private/tmp/kestrel-visuals-archive/. The QA app was quit normally and Computer Use reported no Kestrel process. Settings were restored to the starting values: Codex CLI provider, System appearance, Google search, Assistant page reply location, Advanced model picking off, region inclusion on and safe-browsing auto-approval on. No request was sent and no QA URL was opened.

No build or tests were run in this visual-only continuation. Existing source changes on codex/visuals-fix remain uncommitted and unpushed.


### Latest Settings and Assistant visual follow-up — 28 September 2026, 17:24 BST

The General Search picker displayed Google, DuckDuckGo and Bing. Light appearance and the Sidebar New Tab reply location were inspected, then System and Assistant page were restored. Connections showed the Connect Codex button with the lavender tint in the current archived QA app; the button was not activated, and the local server and Exa remained off.

The empty Assistant page screenshot showed Codex CLI selected. Its model/provider popover displayed all ten provider choices and the CLI’s existing missing-executable message; the manual model entry disclosure opened with an empty field and disabled Use model button. The Chats accessibility tree contained New Chat and disabled No saved chats, but the menu itself did not appear in the window screenshot. No saved chat was created and no request was sent.

The native File menu accessibility tree was readable, but Computer Use returned “Screenshot unavailable” for the archived app when asked to capture the open menu. Native menu-bar visual styling and wrapping remain unverified. The narrow-pane More menu fit within the 1200 × 800 screen at 28% pane width in the prior live check. Bookmark overflow appearance was verified in the previous paragraph; actual horizontal movement remains unverified after CUA scroll and drag input produced no visible displacement.

The archived QA app was quit normally and Computer Use reported no Kestrel process. Temporary test bookmarks, pin/tab and fixture were removed. General settings and the Codex CLI provider were restored. No product source changes, builds or tests were made during these visual-only continuations.

### Final visual-fix continuation — 28 September 2026, 21:02 BST

This continuation reconciles the prior handoff with the current codex/visuals-fix build and live Computer Use evidence. The bookmark shelf shows its intended clipped overflow affordance: with twelve synthetic bookmarks, five pills were fully visible and a sixth was partly covered by the right-edge fade. The source uses a native horizontal ScrollView. Computer Use scroll and drag attempts still did not visibly move the shelf, so actual horizontal movement remains unverified; the visual treatment itself is intentional.

The current pass reviewed all five Settings sections and their relevant disclosures; checked the New Tab, split-pane, bookmark and Assistant context menus; exercised split focus, divider resizing, equal-width reset, separation and temporary tab closure; and exposed the Kestrel, File, Edit, View, Tabs, Navigate, Assistant, Chats, Extensions, Window and Help menus through accessibility, including Services, AutoFill, Move & Resize and Full Screen Tile paths. Native menu-bar popover screenshots were not available, so pixel-level appearance and wrapping for those system menus remain unverified. The empty Assistant profile had no saved-chat groups to render; the current menu showed New Chat and disabled No saved chats. The narrow-pane More popup fit on screen at 28% pane width; in the empty split New Tab state, the address placeholder was shortened by the available width.

A fresh post-fix attachment-panel check showed a generated local .txt file as Plain Text with Attach enabled; the panel was cancelled without attaching it. This follows a fix in NewTabAttachment.selectableContentTypes() that lists exact supported text extensions because this macOS runtime maps several of them to dynamic UTTypes that do not conform to generic text families. The regression test now checks every reader-supported text extension. A prior full test run had also exposed host-Keychain assumptions; AIProviderFactory diagnostics now use the injected provider's Keychain capability, and the Keychain integration test skips before asserting when this sandbox cannot create a temporary item.

Apple HIG guidance consulted: menus should use consistent styling, prioritise common commands, remain scannable, and use one-level submenus sparingly; consider another menu for a submenu longer than about five entries. Context menus should contain a small set of relevant actions. Accessibility guidance gives macOS 13 pt as the default text size and 10 pt as the minimum. Toolbar guidance recommends moving less important controls into overflow as width narrows.

Validation: swift test executed 474 tests with 0 failures and 2 skipped because this sandbox cannot create temporary Keychain items (Keychain status and the local MCP handshake). Xcode 27.0 Debug build succeeded and passed strict codesign; ./build.sh produced package build 202609282043, also passing strict codesign and sandbox-entitlement inspection. Both bundles are archived in /private/tmp/kestrel-visuals-archive/. bash -n build.sh and git diff --check passed after this audit update. The QA app was quit normally, the synthetic file and imported bookmarks were removed, original System appearance and Web settings were restored, and no Kestrel instance remains running. Changes remain uncommitted and unpushed.

Remaining evidence limits are the shelf's actual scroll response, native menu-bar popup visuals, populated saved-chat submenu visuals, and address rendering for a loaded site in the narrowest pane. No additional source change was justified by these unresolved runtime-only observations.

### Latest follow-up — 28 September 2026, 21:45 BST

This follow-up supersedes the earlier “remaining gaps” for populated saved-chat groups and loaded-address readability in a narrow split pane.

- **Bookmark shelf:** A disposable profile displayed twelve synthetic bookmarks in accessibility. At full width, three pills were visible; at 50% split width the second pill was clipped under the trailing fade. The fade is the intended horizontal-overflow cue. Computer Use scroll gestures in both directions, at the accessibility area and over the row, plus a leftward drag, did not visibly move the shelf. The source still uses a native `ScrollView(.horizontal)`; this interaction remains unverified through this input path and no code change was justified.
- **Saved chats:** Twelve synthetic conversations populated Recent Chats (1–5), Earlier Chats (6–10), and Chats 11–12. Each submenu was opened and visually inspected. Rows fit; the longest title ended with an ellipsis. No conversation was selected and no Assistant request was sent.
- **Split view:** The context-menu Open in Split View With child created a paired view. A public `https://example.com/` page loaded in the right pane; at 30% pane width its address remained readable and its More popup fit within the card. The blank-pane More popup also fit. Focus switched between panes, and Equal widths restored 50/50.
- **Tabs menu:** With a two-tab split, Select Tab 1 and 2 were enabled, later slots were disabled, and split actions were available. The native View and Tabs menus were read through accessibility. Computer Use did not provide a screenshot for the native menu popover, so pixel-level styling and wrapping remain unverified.
- **Guidance:** Apple’s [Scroll views HIG](https://developer.apple.com/design/human-interface-guidelines/scroll-views?changes=lat_2_6) says default scrolling gestures should work and that partially visible edge content helps indicate overflow.
- **Cleanup:** The single QA app was quit normally and the current Computer Use inventory showed no Kestrel process. The isolated QA preference domain matched its saved baseline exactly, including removal of synthetic bookmarks and chats. Temporary fixture files were removed; the app bundle remains archived under `/private/tmp/kestrel-visuals-archive/`.

No product source changed and no build or test command ran during this follow-up. Existing changes remain uncommitted and unpushed on `codex/visuals-fix`.

### Extension permission review — 28 September 2026, 23:01 BST

On the already archived QA bundle, temporarily enabled ZIP import and selected a generated 284-byte fixture containing only a basic manifest. The review sheet showed “Kestrel Visual QA Fixture”, version 1.0.0, a missing-description warning, and requested `storage`, `tabs` and `https://example.com/*` permissions. Every checkbox started unchecked. The sheet stated that nothing loads until approval and only checked items are granted. The visual hierarchy, warning treatment, section alignment and bottom Cancel / Approve and Load buttons were readable; no visual defect was established. Cancel discarded the staged fixture without loading it. Restored ZIP import to off (Import disabled); the Extensions command menu setting remained on. No extension permission was granted, and the fixture file was removed.

A separate retry opened the Kestrel and File native menus through accessibility, but `getScreenshot()` again returned “Screenshot unavailable” for the archived app. Native menu styling/wrapping remains unverified. Actual horizontal movement of the bookmark shelf also remains unverified through Computer Use; the intentional clipped trailing fade is still confirmed by prior 12-bookmark visual evidence.

### Browser Data and Attach menu review — 28–29 September 2026, 23:12–00:02 BST

In the isolated profile, imported a generated bookmark fixture with two valid HTTP(S) URLs, one `javascript:` URL and one duplicate. The app reported two imported bookmarks. Added ten more generated entries to confirm the shelf overflow treatment, then removed all twelve through their context menus. A live 1200 × 800 screenshot showed the first three pills in full and the next pill clipped under the trailing fade. Horizontal scroll and drag inputs still produced no visible movement, so the cutoff is confirmed intentional but scroll response remains unverified. The temporary HTML fixture was deleted.

The Browser Data section was opened and its file picker inspected. A screenshot with no connectable tabs confirmed NT-04: “Open tabs” remained very dim despite `.foregroundStyle(.primary)`. The source now keeps “No open tabs available” as a directly visible disabled item; when pages are available, it offers “Open tabs” as a submenu containing the page actions. In the fresh Xcode 27.0 Debug build, the empty state remained legible as a disabled row. With one `https://example.com/` page open, “Open tabs” rendered as a readable active submenu and exposed “Example Domain”. Selecting it attached the page to the New Tab composer; the attachment was removed without sending a prompt, and the disposable page was closed. The test build passed strict codesign and is archived at `/private/tmp/kestrel-visuals-archive/Kestrel-20260928-nt04-attach-qa.app`.

`swift test --disable-sandbox` passed all 474 tests with zero failures. The first restricted Xcode attempts could not initialise SwiftUI’s macro sandbox (`sandbox_apply: Operation not permitted`); the isolated build succeeded after the required shell escalation. A fresh Computer Use attempt to capture the native File menu returned “Screenshot unavailable”, so native menu-bar appearance remains unverified. The reused QA app was quit normally and Computer Use confirms no Kestrel process remains.
