# Local patch: hide Claude-launched Codex delegation

## Purpose

This local patch keeps cctop focused on sessions that Jared starts explicitly.
Codex Desktop sessions and Codex CLI sessions started directly in a terminal such
as Ghostty remain visible. Delegated runs in either direction — Codex processes
launched by Claude Code, and Claude sessions launched by a Codex thread — are
persisted as hidden subagent records, linked back to the session that spawned
them, and excluded from cctop's published session list. The Agents view built on
that linkage is documented in
[local-agents-view-patch.md](local-agents-view-patch.md).

The patch lives on the local branch `codex/filter-claude-codex-subagents`. It is
not an upstream cctop behavior unless that branch is later published and merged.
Use `git log -1 -- docs/local-claude-codex-delegation-patch.md` to locate the
local patch commit after future rebases or upstream updates.

Persistent rebuild, installation, and hook verification for the complete local
stack are documented in `docs/local-custom-build-install-runbook.md`.

## Detection contract

Delegation is read from the hook process environment, in both directions. Each
rule is scoped to the **opposite** harness, so an inherited key can never hide the
session that owns it.

| Hook harness | Environment evidence | Result | Parent persisted |
|---|---|---|---|
| `codex` | `CLAUDE_CODE_CHILD_SESSION` key present (value may be empty) | delegated, hidden | `parent_harness = "cc"`, `parent_harness_session_id = $CLAUDE_CODE_SESSION_ID`, when that value is non-empty |
| `cc` | `CODEX_THREAD_ID` present and non-empty | delegated, hidden | `parent_harness = "codex"`, `parent_harness_session_id = $CODEX_THREAD_ID` |
| any | `CCTOP_PARENT_HARNESS` and `CCTOP_PARENT_SESSION_ID` both non-empty, harness in the allowlist, pair not naming the session itself | delegated, hidden | `parent_harness = $CCTOP_PARENT_HARNESS`, `parent_harness_session_id = $CCTOP_PARENT_SESSION_ID` |
| `cc` | none of the above matched, and the **harness process's own** environment (read via `KERN_PROCARGS2` for the captured pid) has `CLAUDE_CODE_CHILD_SESSION` plus a `CLAUDE_CODE_SESSION_ID` that is not this session's id | delegated, hidden | `parent_harness = "cc"`, `parent_harness_session_id` = that id |
| `codex` | none of the above matched, and the harness process's own environment has a `CODEX_THREAD_ID` that is not this session's id | delegated, hidden | `parent_harness = "codex"`, `parent_harness_session_id` = that id |
| any | payload `is_subagent: true` | delegated | none, unless an environment rule also matched |

The process-environment rows exist because the hook's own environment cannot see
same-harness delegation: a child `claude` re-exports `CLAUDE_CODE_SESSION_ID` as
its own id to everything it spawns, hooks included. The harness process itself
still carries what its launcher gave it, and the kernel hands that over for a
same-user pid. This links any bare `claude -p` or nested `codex exec` a session
launches, wrapper or not (2026-09-11: a lane writer launched with
`env -u CLAUDE_CONFIG_DIR claude -p …` sat on the Stream Deck as a top-level
session). One sysctl per hook event, and only when the cheap rules found nothing.

The explicit pair is a fallback evaluated after the two native rules. It exists
because same-harness delegation has no native marker: a `claude -p` launched by
Claude overwrites `CLAUDE_CODE_SESSION_ID` with its own id, and a nested
`codex exec` does the same with `CODEX_THREAD_ID`. `claude-delegate` and
`codex-delegate` (`infrastructure/laptop/delegate/`) export the pair from the
caller's environment before launching. Because the pair is inherited by every
descendant, a delegated child that launches a bare `claude -p` (not through the
wrapper) attributes that grandchild to the grandparent; the wrappers recompute
the pair, so going through them is exact.

- Claude Code adds `CLAUDE_CODE_CHILD_SESSION` to the child processes it launches.
  The key can have an empty value, so detection tests for key presence rather than
  a non-empty string. Its *value* is still neither read nor persisted; the parent
  reference comes from the separate `CLAUDE_CODE_SESSION_ID` key.
- Claude Code exports `CLAUDE_CODE_SESSION_ID` to its own children, so for a `cc`
  hook that value is the session's own reference and is never parent evidence.
  Only the `codex` rule reads it.
- Codex exports `CODEX_THREAD_ID` (plus `CODEX_SANDBOX`,
  `CODEX_SANDBOX_NETWORK_DISABLED`, `CODEX_CI`) to the processes its exec tool
  launches. `CODEX_THREAD_ID` is the same reference Codex sends to `cctop-hook` as
  `session_id`, so it matches a Codex record's `harness_session_id` byte for byte.
- Terminal metadata is deliberately ignored for delegation in both directions: a
  child inherits `TERM_PROGRAM=ghostty` and Ghostty's bundle identifier from its
  parent even though the user did not start it directly.
- Parent fields are written only when the environment proves the link, and a later
  event that lacks the evidence never clears them.
- Environment-proved parent linkage is first-hand provenance and outranks a
  client's own later self-classification. Codex's thread database calls a
  Claude-launched `exec` thread an interactive `cli`/`vscode` root with no spawn
  edge, so the sticky-classification repair must refuse any record carrying parent
  fields; otherwise the delegate is unhidden back into the published projection.

## Implementation map

- `HookInput.delegatedSessionEvidence(environment:)` returns the evidence: the
  matched parent harness and reference, or an unattributed result for an explicit
  `is_subagent` payload. `hasDelegatedSessionEvidence(environment:)` is a thin
  boolean wrapper over it.
- `HookHandler.handleHook` reads the current hook environment, stamps
  `is_subagent = true`, and applies `parent_harness` /
  `parent_harness_session_id` before the existing auto-hide policy runs.
- `HookHandler.handleSessionEnd` applies the same classification and linkage
  during its locked final write. This lets a marked final event hide a record
  written by an older hook.
- `SessionData.hasDelegationParentEvidence` is the guard consulted by
  `SessionManager.repairStickyCodexDelegationState` (pre-lock filter) and
  `repairedCodexInteractiveRootSessionSnapshot` (re-checked under the lock).
- `SessionData.shouldAutoHide` remains the canonical persistence policy. No
  second display-only filter or parallel session-state path is introduced.

Hidden records remain available for lifecycle and diagnostic purposes, but
`SessionManager` excludes them from the user-visible projection. A completed
pre-patch record that never emits another marked event cannot be identified
retroactively from persisted data alone; it remains until normal retention or a
separately approved cleanup.

## Regression coverage

Keep these cases in `HookHandlerTests` and `HookInputTests` when rebasing or
reapplying the patch:

1. A Codex hook with an empty `CLAUDE_CODE_CHILD_SESSION` value is delegated.
2. A Claude-launched Codex session with inherited Ghostty metadata is hidden.
3. Direct Codex Desktop and Ghostty sessions without the marker stay visible.
4. The marker alone does not hide a `source: "cc"` session.
5. A marked `SessionEnd` hides and ends an existing Codex record atomically.
6. The legacy `source: "codex"` fallback and current `harness_name: "codex"`
   resolution both retain their existing compatibility behavior.
7. A `cc` hook with a non-empty `CODEX_THREAD_ID` is hidden and stamped with the
   codex parent.
8. A `cc` hook without it — absent or empty, even alongside
   `CLAUDE_CODE_SESSION_ID` — stays visible and unlinked.
9. A `codex` hook with the Claude markers is stamped with the `cc` parent; the
   child marker alone still delegates but records no parent.
10. Parent fields survive a later event that carries no environment evidence,
    including `SessionEnd`.
13. A `cc` hook whose harness process environment carries the child marker and a
    foreign `CLAUDE_CODE_SESSION_ID` is hidden and linked to it; the session's own
    id, a missing marker, or an unreadable environment leaves it visible.
12. An explicit `CCTOP_PARENT_HARNESS`/`CCTOP_PARENT_SESSION_ID` pair delegates a
    same-harness child; it is ignored when incomplete, unknown, or self-naming,
    and a native rule that also matches outranks it.
11. Sticky-classification repair refuses a hidden `is_subagent` Codex record that
    carries parent fields, while a record without them is still repaired.

## Upgrade and reapplication checklist

After updating cctop from upstream:

1. Search upstream for `CLAUDE_CODE_CHILD_SESSION`, `CODEX_THREAD_ID`,
   `delegatedSessionEvidence`, and `hasDelegatedSessionEvidence`. If equivalent
   source-scoped behavior has landed, prefer the upstream implementation and
   retain only missing coverage or docs.
2. Confirm `plugins/codex/cctop-shim.sh` still `exec`s `cctop-hook` without
   clearing the inherited environment.
3. Confirm `HookInput.resolvedHarnessName` still resolves both `harness_name`
   and the allowlisted legacy `source` fallback.
4. Confirm `SessionData.shouldAutoHide` still includes `isSubagentSession` and
   that persisted hidden records are excluded before session publication.
5. Confirm sticky Codex delegation repair cannot re-show Claude-launched `exec`
   threads. Interactive root repair should remain limited to positively proven
   direct roots such as `cli` and `vscode`.
6. Reapply the implementation and tests by symbol rather than relying on old
   line numbers. Resolve conflicts against the current lifecycle contracts in
   `docs/session-files.md` and `docs/session-lifecycle.md`.
7. Under cctop's private runtime lease, run `make all` from the exact worktree.
8. Verify the temporary developer runtime through
   `script/build_and_run.sh --verify`, then confirm the running app path and
   installed hook version/hash point to that worktree. For the persistent
   auto-start installation, follow `docs/local-custom-build-install-runbook.md`
   and install only the assembled `dist/cctop.app`.

For live behavior verification, inspect the resulting session JSON rather than
relying only on the panel:

- Claude-launched Codex: `source == "codex"`, `is_subagent == true`, and
  `hidden == true`, even if terminal metadata says Ghostty; plus
  `parent_harness == "cc"` when the parent exported its session id.
- Codex-launched Claude: `source == "cc"`, `is_subagent == true`,
  `hidden == true`, `parent_harness == "codex"`, and `parent_harness_session_id`
  equal to the spawning thread's `harness_session_id`.
- Direct Ghostty or Codex Desktop: `source == "codex"`,
  `is_subagent == false`, and `hidden == false` when no independent auto-hide
  reason applies.

## Validation record

On 2026-08-23, `make all` passed under an exclusive local runtime lock with
SwiftLint 0.65.1, `check-jsonschema` 0.38.0, and Xcode 26.6. Both app and hook
builds succeeded, all JavaScript extension suites passed, and the isolated Swift
suite executed 1,217 tests with zero failures. Xcode package resolution used its
documented `netrc` authorization provider because the default Keychain provider
blocked while fetching Sparkle's public binary artifact.

The same worktree was then installed with `script/build_and_run.sh --verify`.
The installed `cctop-hook` reported version 0.21.3 and matched the release build
at SHA-256 `e434daf9c09ab50289973f996bb486c9db1e63d8e44a0a920095cb981cc2d716`.
An isolated live-hook proof produced the expected persisted states: the
Claude-marked Codex event with Ghostty metadata was hidden and marked as a
subagent, while unmarked direct Ghostty and Codex Desktop events remained
visible. The verified developer-facing app ran from the worktree Debug product.
