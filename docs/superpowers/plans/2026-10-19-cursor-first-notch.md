# Cursor-first Andy and notch integration

> Historical cursor-first implementation record. On 2026-10-20, the owner authorized tested commits and pushes. Any delegated work must select `codex/gpt-6-astra` or `codex/gpt-5.6-sol` explicitly. Do not change global provider settings or restart shared services.

**Goal:** Fast grounded cursor output by default, a minimal native composer, voice routed to the intended conversation, and a native notch hub for companion and connected agent sessions.

**Architecture:** Keep the current daemon, restricted companion MCP adapter, AppKit overlays, speech controller, and authenticated web connection. Add a bounded native accessibility lookup, route exact spatial requests locally, and keep model output secondary. Use the existing WebKit state/transport behind a native input surface. The notch receives bounded session metadata, not another conversation store.

**Tech stack:** Existing Node/Swift/AppKit/WebKit stack, macOS 14+, no new runtime framework dependency.

**Spec:** The user wants the fastest method with enough spatial awareness, cursor-first replies, minimal Clicky-like text/voice behavior, and an Andy hub for Andy Code, Claude Code, Codex, Antigravity, OpenCode, Cursor, and computer use. Full parity is a target, not a claim established by partial static analysis.

## Evidence

- Successful baseline, real signed CuaAgent and a LaunchServices test app, explicit GPT-6 Astra: cursor publication at 20,709 / 12,902 / 11,664 ms. First tool at 7,666 / 5,032 / 4,886 ms. CLI OS spawn at 27 / 1 / 11 ms. These are backend/file-feed timings, not rendered arrival timings.
- Earlier bare-executable fixture runs failed native launch-identity checks and produced no cursor. They are not successful spatial baselines. Production process-identity checks remain intact.
- MacBook screen: AppKit frame `(-1920,0,1920,1243)`, safe top `37.5`, auxiliary left/right widths `856`. Camera gap: `x=-1064…-856`, width `208`, bottom `1205.5`. External screen: `(0,0,2560,1440)`, no notch.
- Official Clicky changelog distinguishes a Home surface that closes on pointer exit from a text composer that stays open after an outside click. Current binary metadata also separates these surfaces, focus retries, speech finalization, cancellation, and playback ownership.
- Historical Clicky source is MIT; current development is private. Boring Notch and notchHUD are GPLv3. Implement original behavior with public Apple APIs; copy no proprietary assets or private-space workarounds.

## Global constraints

- Never move the real pointer. Guide paths send no clicks, keystrokes, scroll, focus change, app launch, or permission request.
- Match an exact fresh target in one verified running process/window. No guessed coordinates or substring ranking.
- Missing, ambiguous, incomplete, secure, disabled, stale, or offscreen targets produce an honest local result, not a false success.
- Preserve conversation history, drafts, current mode, approval boundaries, and cancellation isolation.
- Every model worker and companion benchmark selects an approved model explicitly. No silent Claude fallback. Keep requested and reported model identity distinct.
- Only explicit user input starts microphone capture. Session/focus changes must not redirect a captured phrase.
- Passive notch updates never take keyboard focus. All interactive controls stay below the camera/menu exclusion.
- Lookup excludes CUA's own dedicated guide windows from occlusion, not arbitrary click-through apps. A private-runtime manifest binds window IDs to a live launch identity and the configured preview executable. This trusts the local runtime owner; mode 0600 is not authentication against that same user.
- Integration must pass the selected `CUA_HUD_APP` and `CUA_CONFIG` through NativeClient's LaunchServices helper launch. The sibling preview bundle is the native fallback.
- Discovery is metadata-only. Do not scrape private history/account stores or change installed clients' global hooks/configuration.
- Host focus, saved-session resume, and true live conversation attachment are different capabilities. Do not label one as another.

## Shared interfaces and ownership

### Native lookup

Owner files: `agent/CuaAgent.swift` and new focused native lookup tests/fixtures only.

Add a passive `lookup` request with `pid`, `process`, optional `windowId`, exact `name`, and optional supported role. Return a bounded result:

- `status: "matched"`, `name`, `role`, `windowId`, `target: {windowId,rect:{x,y,w,h}}` for one valid visible match.
- `status: "ambiguous" | "not_found" | "incomplete" | "unavailable"`, a short `message`, and optional bounded candidate/window metadata otherwise.

Validate process identity, lock/permission state, exact window ownership, current name/role, positive geometry and visible scope. Do not auto-launch or raise apps. Explicitly account for traversal/label truncation; partial traversal cannot prove uniqueness. Keep existing protocol behavior backward-compatible.

### Local spatial route and model policy

Owner files: `server/lib/spatial.mjs`, `server/lib/companion.mjs`, `server/lib/native.mjs`, `server/lib/config.mjs`, `server/lib/pointer.mjs`, and related Node tests. The coordinator owns `server/lib/web.mjs` and `server/daemon.mjs` integration.

- `Companion.send()` keeps its synchronous initial-snapshot contract and reserves a turn before async lookup.
- Context accepts `pid`, `process`, `windowId`, `app`, `bundleId`, and an optional validated local cursor origin. Preserve old callers.
- Bounded point/highlight/circle lookup grammar uses the native `lookup` contract. Unsupported goals use the model. Recognized unresolved targets return a brief clarification/error, not a model guess.
- Resolve running processes only. If context lacks identity, use current running-app metadata; never the native resolver's auto-launch branch.
- Check the turn key after each await and immediately before cursor publication. Share bounded completion/cancellation handling with the existing CLI route.
- Add session `route: "local" | "model"` and spatial-stage timing fields. Do not label file publication as visible output. Add session `presentation: "cursor" | "prompt" | "text"`: spatial success uses cursor, local clarification/error uses prompt, and nonspatial output can use text. Keep requested/reported model metadata distinct.
- Add `Companion.warm()` to prepare an empty pointer feed/overlay without app reads or inference; the coordinator exposes `/api/companion/warm`.
- Pin companion model selection explicitly; honor an explicit compatible user configuration. For this deployment use GPT-6 Astra or GPT-5.6 Sol and disable unauthorized fallback. Surface reported model metadata when available.
- Successful spatial output is cursor-first; long chat is secondary. Keep essential errors, clarifications, and approval text accessible.

### Native input and voice route

Owner files: `hud/Companion.swift`, new `hud/CompanionComposer.swift`, `hud/CompanionVoice.swift` if needed, `server/web/companion.html`, and popup/voice/UI tests. The coordinator owns build source-list changes.

- Native editable input is the default visible composer. Keep the existing authenticated web state/transport, but do not present its large answer surface by default.
- Reuse one selected-session/draft state. Expose dedicated JSON-safe JavaScript callbacks for native submit, session choice, stop, and advanced controls.
- Forward a bounded `hubState` message: `connected`, `activeSessionID`, `sessions:[{id,name,status,needsApproval}]`, plus optional `hub` metadata supplied by the coordinator. Never forward tool keys, token, or conversation text to the notch.
- Bridge context includes fresh running-app/window identity before the popup takes focus. Preserve fractional screen coordinates and selected-window context.
- Enter submits only outside IME composition. Shift-Enter/newline behavior and Escape are composition-aware. Outside focus does not dismiss or trigger retry focus steals.
- Bind voice output to the conversation selected at capture start. A changed destination cancels or preserves that destination explicitly, never redirects the phrase. Preserve draft and generation guards.
- Hold/release commands and dictation-to-composer are distinct routes. No automatic typing into unrelated apps.
- Integrate `CompanionHubController` through the interface below. No passive call to `show()`.

### Notch hub

Owner files: new `hud/CompanionHub.swift` and focused geometry/native tests only.

Define `CompanionHubController` with `apply(_ payload:[String:Any])`, `reflow()`, `close()`, and callbacks `onAsk:(()->Void)?`, `onOpenSession:((String)->Void)?`, `onStopSession:((String)->Void)?`, `onOpenHost:((String)->Void)?`.

Payload is the bounded `hubState` above. The coordinator will supply `hub` with connected clients/provider metadata; absent data must work. Compact status expands only through explicit interaction. Selecting a row submits no prompt. Expose only supported actions.

Use fresh public `NSScreen` safe/auxiliary geometry and a strip below the exclusion. Prefer the actual notched display, otherwise a safe capsule. Expand downward; do not cover menu items or the camera. Use public window collection behavior, native accessible controls, Reduce Motion/Transparency, display-change handling, and menu/shortcut fallback. Do not import a notch framework.

### Connected-agent metadata and provider contracts

Owner files: new `server/lib/agent-hub.mjs`, focused tests, and `server/shim.mjs` if needed. The coordinator owns daemon/web wiring.

Define `AgentHub` as an EventEmitter with `register(sessionId,{client,host})`, `activity(sessionId,state)`, `end(sessionId)`, `snapshot()`, and `close()`. Bound metadata and expire stale clients to unknown. Snapshot contains `clients` and `providers` with explicit capabilities. No prompt/history data.

Register MCP `clientInfo` and existing host metadata through `/agent/register`; update activity around existing `/call`; remove on `/end`. Keep existing shim behavior and permission boundaries. Client registration/focus is observation, not conversation reuse.

Inventory user-installed commands without starting inference or services. Keep verified external protocol recipes/capability limits explicit. A live external endpoint requires a user-selected endpoint/session and a separate permission-safe adapter; never invent one or silently launch a replacement session.

## Frozen integration details

- Native lookup role strings use the existing human-readable native role names, such as `button`, `textbox`, and `menuitem`, not an invented second enum.
- Context `process` is exactly `"pid:launchDate.timeIntervalSince1970"`, as `processIdentity()` produces. It is not an executable name. `cursorOrigin` is `{x,y}` in global top-left points.
- HTTP/SSE state adds `version:{instance:String,revision:Int}`. The frontend ignores an older revision in the same instance. All companion/hub change producers share this sequence.
- Hub client records use `{id,name,status,host:{ancestors:[Int],bundleId:String|null}|null,capabilities:{observe,openHost,resume,attach,send,interrupt},updatedAt,source:"mcp"}`. Optional bounded `client:{name,version}` and `stale` are allowed.
- Client status values are `unknown|idle|busy|awaiting_user|error|exited`. These report CUA transport activity, not an external conversation's full state.
- Provider records use `{id,name,available,capabilities,detail?}`. Inventory does not claim attachment. Cache filesystem discovery rather than repeat it per streamed token.
- `onOpenHost` receives a client ID. The native parent resolves a current `NSRunningApplication` from the registered ancestry with matching bundle ID; it does not launch arbitrary paths or guess another process.
- The hub can add `makeMenuItem() -> NSMenuItem` for the existing menu-bar fallback.
- MCP initialize can acknowledge before metadata registration. Registration must not start a daemon solely for discovery, and shutdown must prevent late registration from recreating ended clients.

## Orchestration recovery

The first implementation run was stopped after the hub worker detected overlapping writes. Interface messages to active workflow IDs created separate local-agent tasks alongside the workflow tasks, with the same worktree paths. The exact internal mechanism is not established. Both task sets were stopped. All resumed transcripts still recorded GPT-6 Astra.

Archives and hash manifests are in the session scratchpad under `implementation-recovery`. The reference worktree matched the approved tracked patch and all untracked hashes. Only two slices had source deltas: the composer had new tests and an IME guard; the hub had partial geometry and an inconsistent test API. Nothing from those slices was integrated into the running app.

Restart one writer first. Freeze contracts before parallel work. Do not send live messages to workflow agents; a blocked worker must return a partial result and stop. Review and integrate only owned deltas beyond the baseline, never a whole worktree/HEAD diff.

## Work plan

- [x] Native exact lookup and failing-then-passing cases. Integrated 27 headless checks and eight live fixture modes. A real AppKit bezel caused corner hit tests to fail; the corrected check validates the actual center anchor and still rejects a same-window sibling over that anchor. Live exact matches: 13.8–129.1 ms. Pointer-overlay interaction also passes with empty and populated overlays. Live tests reject malformed/stale manifests, wrong window IDs, broad file permissions, genuine higher windows, and same-window sibling occlusion. Normal overlay exit removes its manifest. These lookup measurements are not visible-cursor latency.
- [x] Local cursor-first route, cancellation/model checks, and zero-spawn tests. Comparable warm feed times were 28.2 / 43.1 / 54.3 ms; the cold-helper case was 516.2 ms. Exact goals used no model. The real packaged model route returned `4` with requested/reported Astra and no tool calls.
- [x] Minimal native input, composition/voice destination tests, and web bridge. Live native input, separate drafts, dismissal, outside focus, session choice, advanced controls, and Stop passed. Real IME ownership and Escape behavior passed in detached AppKit checks. Live microphone and physical shortcut tests remain unrun.
- [x] Notch geometry/controller and passive-focus tests. All 106 headless checks passed. Live hub session choice and passive focus passed. Native light/dark/320-point appearance checks ran.
- [x] Connected-client metadata and provider capability checks. Real daemon, real MCP shim, bounded metadata, overlap/EOF/late-response cases, and authenticated SSE checks pass. These report CUA activity, not live conversation attachment. A real Andy Code calculation-only run also registered, showed busy/idle, and unregistered on exit; it reported `codex/gpt-6-astra`. Its MCP handshake name was `claude-code`, which is client metadata, not model identity.
- [x] Integrate the three slices. Fix cold helper preparation, running-only model-tool resolution, numeric legacy context, native origin consumption, warm bridge, and menu fallback. All 15 Node scripts plus hub, geometry and voice checks pass. Native UI tests use the real hub source.
- [x] Adversarial review `wf_bdde56b7-e9c` completed with explicit Astra workers. All three confirmed cases failed locally, then passed after fixes: deferred IME session ownership, prior-session speech cleanup, and the 32-ancestor host contract. The two minor cases were also fixed because they affect the requested session/host behavior; no new capability was added. No second review pass.
- [x] Complete live accessory-app checks after correcting regular-only discovery. All target cases and passive-state checks passed through the selected packaged helper.
- [x] Repeat comparable live spatial benchmarks, exercise packaged input/notch/cursor flows, and inspect captured frames. The 13-second native demo showed circle, highlight, arrow, freehand, and return motion. Its real-pointer and history checks passed. The full native flow needed a settled fixture activation before showing the popup; covered targets still fail closed.
- [ ] External conversation attachment is not implemented. The verified integration is MCP identity/activity plus explicit host focus. No user-selected Codex/OpenCode endpoint or live conversation was supplied. Installed-provider metadata is not full integration or Clicky parity.

## Final local checks

- All 15 affected Node scripts passed. The native UI script includes real AppKit popup/composer checks. Two tests initially failed on macOS `/var` versus `/private/var`; canonical temp paths corrected the tests without a production path change.
- Live screenshots exposed AppKit title updates that reset icon layout, a low-contrast hub material, nested native drawer scrollbars, an unnamed advanced icon, and a low-contrast send icon. Their regressions failed before the fixes and passed afterward. System button colors raised measured send-icon contrast from 2.09:1 to at least 9.22:1 in the checked dark views and 12.75:1 in light mode.
- Native motion and overlay rebuild/identity/cleanup checks passed. The overlay identity check kept focus and the real pointer unchanged. The longer motion check used a synthetic mouse source; unrelated real-pointer motion was recorded, not attributed to the app.
- Speech synthesis wrote 92,591 frames with the installed Samantha voice and requested no microphone access. This is not a live recognition, audible playback, or full-duplex voice check.
- Both original conversations remain intact with 2 and 14 messages. Config/history hashes stayed unchanged through the app switches and QA cleanup. The separate test runtime was not merged.
- Actual CuaAgent helpers did not exit after an accepted `NSRunningApplication.terminate()` request. The switch then used identity-checked SIGTERM and waited for exit. No unrelated helper or daemon was stopped.
- Native placeholder contrast measured 3.91:1 in light mode before correction, then 5.5:1 light and 8.0:1 dark. The final native input regression passed. Voice permission text now covers both held commands and explicit dictation.
- Signed `build/cursor-first-v7/AndyBarista.app` uses the existing isolated runtime `b76c8bd0116f`, not the normal installed-app runtime. Bundled source hashes, server files, runtime paths, and permission text match the current checkout. The normal `~/Applications` installation was not replaced.
- The final selected-area ring, spotlight, and clear checks passed through the real API and native renderer. Two region captures included another app after focus changed; those files were discarded rather than included in the demo. Physical drag selection remains unrun.
- No commit, push, issue/PR change, global provider configuration change, or publication was made.

## Research references

- https://www.heyclicky.com/changelog
- https://www.heyclicky.com/trust
- https://github.com/farzaa/clicky
- https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications
- https://github.com/mrkai77/DynamicNotchKit
- https://developers.openai.com/codex/app-server/
- https://antigravity.google/docs/cli/headless/
- https://github.com/anomalyco/opencode/blob/v1.18.18/packages/web/src/content/docs/server.mdx
- https://cursor.com/docs/cli/acp
