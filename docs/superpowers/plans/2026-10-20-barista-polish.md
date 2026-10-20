# Barista reliability and interaction

## Scope and work window

The owner requested continued work from 2026-10-20 03:07 local time (UTC-05:00), then extended the deadline to 12:30 CST (UTC-06:00), or 13:30 on the current local CDT clock. Tested commits and pushes are authorized. Keep one live GUI operator. Do not replace another session's work or restart unrelated services.

The goals are a reliable desktop companion, a useful home on external monitors and the MacBook notch, clear model choices, accurate drawing, natural cursor motion, and better task guidance. Reproduce observable Clicky behavior with original code and compatible licensed OSS. Do not copy proprietary implementation or artwork, read private Clicky account/history stores, or bypass privacy permissions.

## Evidence at the start

- The daemon answered in 6 ms. The GUI main thread was idle in the AppKit event loop, not blocked during the sample.
- The native popup was hidden. The existing show notification reopened it without a restart. Its native input was readable and empty; voice capture was inactive.
- The most recent guide had completed. Its instruction and two circles remained visible more than ten minutes later. Clearing that completed session's marks preserved its history.
- The hub was on the built-in display while the main display was an external monitor.
- These observations do not prove the cause of every reported freeze. Preserve the distinction between an unresponsive process, hidden UI, stale output, and a guide that stopped waiting.
- The saved conversations now contain 4 and 14 messages. Do not restore an older backup over these updates.

## Work batches

1. **Checkpoint and recovery:** push the existing reviewed feature. Add clear completion/continuation states, easy mark cleanup, and recovery that preserves drafts. Cover disconnects and stale UI state.
2. **Display home:** add an explicit display choice and a top-edge capsule on external monitors. Keep safe notch geometry, passive focus, and a predictable fallback when a display disappears.
3. **Model controls:** show the actual model ID, next-turn scope, supported effort/speed controls, reported model, and local-versus-model route. Use measured differences or authoritative catalog data, not invented performance claims.
4. **Drawing and motion:** check real geometry, stroke progress, cancellation, target movement, and return behavior before adding anticipation, easing, or idle motion. Honor Reduce Motion. Never move the real mouse.
5. **Task guidance:** use owned study, homework, learning, photo-adjustment, unfamiliar-site, and agentic-workflow fixtures. Add useful guide continuation and controls. Label simulations as simulations, not real user studies.
6. **Integration and parity:** deepen static/public Clicky research. Add only permission-safe, verified integration paths. Installed-provider discovery is not live conversation attachment.

## Checks and delivery

Use one failing behavioral check for each defect, then run the affected checks and one safe live flow. Do not repeat broad reviews after a covered fix. Capture owned windows or verified owned fixture regions only. Record concrete blockers and untested cases.

Commit coherent tested batches with explicit source/test/docs paths. Exclude runtime files, drafts, recordings, credentials, worktrees, and private provider code. Push without force. Do not open or merge a PR without a separate request.

## Progress

- Initial live diagnosis and private backup completed. The popup reopened, and stale completed marks were removed without a process restart or history change.
- Existing cursor-first feature pushed as `5173d00` on `feat/andy-barista`.
- Completion feedback: completed labels expire without removing selected areas. Reloading old output does not revive its instruction. The compact native composer exposes a per-conversation Clear marks action and keeps drafts/history intact.
- Completion checks passed: companion state, local/model route, process lifecycle, native/web bridge, real AppKit composer, and live synthetic-pointer motion. The stale-label and missing-control checks failed before the fix. Packaged UI coverage will run with the display update.
- Display choice: automatic placement now uses the main monitor. The hub picker and menu can pin a display by stable UUID. A disconnected display falls back without erasing the choice. All 121 headless hub cases passed.
- Live `build/overnight-v1` checks passed: switch to the MacBook notch, read the saved display UUID, restore the external main monitor, circle a stable native control, and clear its marks while keeping a draft. The current conversations stayed intact. The live fixture now waits for actual window movement rather than a fixed 250 ms delay; Send was replaced as a target because the composer hides that button during a turn.
- Monitor support is pushed as `977e47f`.
- Model controls: per-conversation selection applies to the next turn. A submitted turn keeps its selected model. Old histories inherit the configured default; an unsupported saved choice stays visible and cannot silently fall back. Local cursor requests still use no model. The existing drawer holds details, not the compact composer. No effort or Fast control will appear without a supported CLI contract.
- Model checks passed: companion, model selection, local lookup, child-process lifecycle, authenticated web state, and native/web UI scripts. The native compile first caught an error-payload type mismatch; the corrected UI check and signed `build/overnight-v2` passed. The existing macOS 27 voice API deprecation warning remains.
- Live model controls passed in `overnight-v2`: select Sol and Astra in the native drawer, keep separate drafts, switch conversations, and send one no-tool arithmetic request to each provider. Both requested/reported IDs matched. The replies took 6,181 ms for Astra and 3,850 ms for Sol. These are single arithmetic turns, not a general speed ranking. A subsequent local circle published in 82 ms with no requested or reported model. Original histories and config stayed byte-for-byte unchanged. Owned-window captures showed the controls without overlap.
- Native automation note: rapid UI changes sometimes produced a stale-target read error while the same app process remained alive. The driver never retried input. It can repeat one passive read after a fresh matching identity and executable check. Hub selections gave an acknowledged session change; popup-menu automation did not do so reliably. This does not establish the cause of the reported app freezes.
- Next batch: guide continuation and drawing reliability.
