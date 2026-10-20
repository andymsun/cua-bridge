# Barista reliability and interaction

## Scope and work window

The owner requested continued work from 2026-10-20 03:07 to 11:07 local time (UTC−05:00). Tested commits and pushes are authorized. Keep one live GUI operator. Do not replace another session's work or restart unrelated services.

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
- Existing cursor-first feature: checkpoint pending.
- First implementation batch: completion feedback, mark cleanup, and display choice.
