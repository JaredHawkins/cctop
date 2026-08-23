# Local patch: hide Claude-launched Codex delegation

## Purpose

This local patch keeps cctop focused on Codex sessions that Jared starts
explicitly. Codex Desktop sessions and Codex CLI sessions started directly in a
terminal such as Ghostty remain visible. Codex processes launched by Claude Code
for delegated work are persisted as hidden subagent records and are excluded
from cctop's published session list.

The patch lives on the local branch `codex/filter-claude-codex-subagents`. It is
not an upstream cctop behavior unless that branch is later published and merged.
Use `git log -1 -- docs/local-claude-codex-delegation-patch.md` to locate the
local patch commit after future rebases or upstream updates.

## Detection contract

Claude Code adds the `CLAUDE_CODE_CHILD_SESSION` environment key to delegated
child processes. The key can have an empty value, so detection must test for key
presence rather than a non-empty string.

The marker is authoritative only when the hook resolves the harness as `codex`.
This source guard prevents the same inherited key from hiding the owning Claude
Code session. Terminal metadata is deliberately ignored for delegation: a Codex
child can inherit `TERM_PROGRAM=ghostty` and Ghostty's bundle identifier from its
Claude parent even though the user did not start that Codex session directly.

The environment value is neither read nor persisted. Only the presence of the
key is used.

## Implementation map

- `HookInput.hasDelegatedSessionEvidence(environment:)` combines the existing
  explicit `is_subagent` payload flag with the Codex-only Claude child marker.
- `HookHandler.handleHook` reads the current hook environment and stamps
  `is_subagent = true` before the existing auto-hide policy runs.
- `HookHandler.handleSessionEnd` applies the same classification during its
  locked final write. This lets a marked final event hide a record written by an
  older hook.
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
4. The marker does not hide a `source: "cc"` session.
5. A marked `SessionEnd` hides and ends an existing Codex record atomically.
6. The legacy `source: "codex"` fallback and current `harness_name: "codex"`
   resolution both retain their existing compatibility behavior.

## Upgrade and reapplication checklist

After updating cctop from upstream:

1. Search upstream for `CLAUDE_CODE_CHILD_SESSION` and
   `hasDelegatedSessionEvidence`. If equivalent source-scoped behavior has landed,
   prefer the upstream implementation and retain only missing coverage or docs.
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
8. Install and restart through `script/build_and_run.sh --verify`, then confirm
   the running app path and installed hook version/hash point to that worktree.

For live behavior verification, inspect the resulting session JSON rather than
relying only on the panel:

- Claude-launched Codex: `source == "codex"`, `is_subagent == true`, and
  `hidden == true`, even if terminal metadata says Ghostty.
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
