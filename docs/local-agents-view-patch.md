# Local patch: Agents view

This patch is stacked after
`docs/local-drop-and-menubar-placement-patch.md`. It adds one place inside the
popup to see every sub-worker a session currently owns.

Persistent rebuild, installation, and hook verification for the complete local
stack are documented in `docs/local-custom-build-install-runbook.md`.

## Purpose

A single Claude Code session spawns work beneath it: in-process Claude subagents
(the `Agent` tool: Explore, general-purpose, codex-rescue, expert-review, fork),
Codex processes it delegates, and — in the other direction — `claude -p` runs a
Codex thread launches. cctop deliberately keeps all of that out of Active/Idle,
the notch indicator, notifications, Navigate mode, and Stream Deck. The **Agents**
selector is the one surface where it becomes visible: who spawned each sub-worker
and what it is doing right now. It is read-only and it is not on the Stream Deck.

The patch also fixes two defects found while building it:

1. `HookHandler` attributed a subagent's tool to its parent, so a parent card
   flickered with its children's tool names.
2. `plugins/cctop/hooks/run-hook.sh` re-emitted the buffered payload with
   `echo "$INPUT"`. macOS `/bin/sh`'s builtin `echo` expands backslash escapes,
   so any payload containing `\n` inside a JSON string — every `Agent` tool call,
   any multi-line prompt — reached `cctop-hook` as invalid JSON and was dropped
   (`~/.cctop/logs/_errors.log`: `failed to parse JSON ... Unescaped control
   character '0xa'`). Upstream v0.21.3 still has the `echo` form.

## Detection contract (delegation, both directions)

Delegation is decided from the hook process environment. Each rule is scoped to
the **opposite** harness, so an inherited key can never hide the session that
owns it.

| Hook harness | Environment evidence | Result | Parent recorded |
|---|---|---|---|
| `codex` | `CLAUDE_CODE_CHILD_SESSION` key present (value may be empty) | delegated, hidden | `("cc", $CLAUDE_CODE_SESSION_ID)` when that value is non-empty |
| `cc` | `CODEX_THREAD_ID` present and non-empty | delegated, hidden | `("codex", $CODEX_THREAD_ID)` |
| any | payload `is_subagent: true` | delegated | none, unless an environment rule also matched |

Notes:

- Claude Code exports `CLAUDE_CODE_SESSION_ID` to its own children, so for a
  `cc` hook that value is the session's **own** reference and is never parent
  evidence. Only the `codex` rule reads it.
- Codex exports `CODEX_THREAD_ID`, `CODEX_SANDBOX`, `CODEX_SANDBOX_NETWORK_DISABLED`,
  and `CODEX_CI` to processes its exec tool launches. `CODEX_THREAD_ID` is the same
  reference Codex sends to `cctop-hook` as `session_id`, so it matches a Codex
  record's `harness_session_id` exactly.
- Terminal metadata is still ignored for delegation in both directions: a child
  inherits `TERM_PROGRAM`/`__CFBundleIdentifier` from its parent.
- `SessionData.shouldAutoHide` remains the canonical persistence policy. A `cc`
  delegate is hidden by exactly the same rule that already hides a Codex one.
- Parent fields are written only when evidence is present. A later event without
  the evidence never clears them.

Before this patch, Codex-spawned Claude sessions were not handled at all: eight
`cc` records from 2026-09-06 (`claude -p --safe-mode ...` runs Codex launched)
persisted as `is_subagent: false, hidden: false` and appeared as normal sessions.

## Attribution contract (in-process subagents)

Claude Code 2.1.263 sends `agent_id` and `agent_type` on **any** hook fired from
inside a subagent, not only `SubagentStart`/`SubagentStop`. The binary's own
schema text: "Subagent identifier. Present only when the hook fires from within a
subagent."

- An agent-scoped `PreToolUse` updates that subagent's `last_tool`,
  `last_tool_detail` (same extraction rule as the session's), and `last_activity`.
  It never touches the parent's `last_tool`/`last_tool_detail`.
- An agent-scoped `PostToolUse` / `PostToolUseFailure` advances `last_activity`
  only. A failure still surfaces its `error` as the session's
  `notification_message`, as before.
- A missing entry is created from `agent_type ?? "agent"`, because a subagent's
  first observed event can beat (or replace) its `SubagentStart`.
- Parent `last_activity`, status transitions, session naming, and every other
  side effect are unchanged.
- An agent-scoped `PreToolUse` also increments `tool_call_count`, appends to the
  5-entry `recent_tools` ring buffer, and clears `waiting_message` (running a tool
  proves the subagent is no longer blocked). Ring-buffer entries are
  whitespace-collapsed display copy, so a multi-line Bash command stays one line;
  `last_tool_detail` keeps the raw value.
- An agent-scoped `PermissionRequest` writes that subagent's `waiting_message`
  and leaves the parent's `notification_message` and running tool alone: the
  subagent is the one waiting. An agent-scoped `Notification` protects the same
  parent fields but only advances the child's `last_activity` — types such as
  `auth_success` and `agent_completed` are not a block, and treating them as one
  would leave a permission dot and a "waiting" count on a working subagent. The
  parent's status transition is unchanged in both cases, so the card and counts
  still show that the session needs attention.
- `SubagentStart` carries no task label, model, or prompt. The parent's own
  `PreToolUse` for `tool_name == "Agent"` (legacy `"Task"`) fires just before it
  with `tool_input.description`, `.model`, `.subagent_type`, and `.prompt`, so
  those are queued in `pending_subagent_spawns` and paired FIFO. A spawn is queued
  whenever any of those fields is present, so pairing stays aligned even when a
  call omits its description. `prompt_excerpt` is the whitespace-collapsed first
  400 characters. The queue is capped at 16 and cleared on `SessionStart`,
  `UserPromptSubmit`, and `Stop`.

All of this stays inside the existing locked read-modify-write; nothing new is
written outside it. Field-level defaults are in
[session-files.md](session-files.md).

## Tree rules (`Models/SubworkerTree.swift`)

Pure functions over the published projections; no file access.

- **Roots** are the visible `UserSession` values in canonical order. Dropped
  sessions are already absent from `SessionManager.userSessions`; acknowledged
  rows are mirrors of rows that remain there. A root with no children is omitted.
- **Children of a root** are its `active_subagents` entries (ordered by
  `started_at`) followed by delegated records whose
  `(parent_harness, parent_harness_session_id)` equals the root's
  `(source, harness_session_id)`.
- A delegated record can own children by the same rule, so Claude → Codex →
  Claude nests. Depth is capped at 3; deeper levels flatten onto level 3.
- Matching is an exact byte comparison. Codex keys files `codex-<id>` but links
  by the raw id in `harness_session_id`.
- A record already placed is never placed again, which is also the cycle guard.
- Delegated records whose parent resolves to no root and no other delegated
  record land in a trailing **Unattributed** group, with their own subtrees
  intact.

## What the Agents selector excludes

`SessionManager.delegatedSessionRecords` is published beside `userSessions`, not
inside it. It contains records with `is_subagent == true` whose derived lifecycle
is `active` or `dormant` (hidden records are lifecycle-classified by the same
policy as visible ones, in `buildCandidates`), deduplicated by stable key.

It feeds the Agents view and nothing else. It does not reach:

- `StatusCounts`, the header chips, or any selector count other than Agents
- notifications or `syncTransitionNotifications`
- Navigate mode numbering and its frozen identity snapshot
- the notch pill, the menu-bar status item, or `MenubarIconRenderer`
- `DisplayStateWriter` / `~/.cctop/display-state.json` / the Stream Deck plugin
- Recent Projects, Cleanup, or history archiving

Agents rows themselves carry no navigate number and no acknowledge, drop, or hide
action. Keyboard selection skips the view entirely; the group header runs the
exact focus action the session row already uses, and a row click only expands or
collapses that row.

## Row detail

Each group header is followed by a summary line — "1 running · 1 stale ·
2 waiting" — from `SubworkerTree.summary(for:now:)`. Its categories are exclusive
and ranked waiting > stale > running, so they always total the group's row count;
the line is omitted when everything is simply running. Delegated records are never
counted stale, because they carry their own lifecycle and status instead of being
inferred from silence.

Every row expands in place on click, with a rotating chevron affordance.
Expansion is `@State` inside `SubworkerGroupView`, keyed by node id; nothing is
persisted. Toggling calls `PopupView.notifyLayoutChanged` — the panel's existing
refit path, already deferred to the next main-queue turn — so the `NSPanel`
grows to the new content height instead of squeezing the detail into its
collapsed frame. The recent-tools block renders one capped line per entry. An in-process row shows task, type/subagent type/model, absolute start
time plus elapsed, last activity, tool-call count, the recent-tools buffer,
`waiting_message` in the permission color, and the spawning prompt in a bordered
block capped at six lines. A delegated row shows project path (tilde-abbreviated),
branch, PID, start time, last activity, its permission message when it is
waiting, and the same bordered block over `last_prompt`. A waiting row also gets a
permission-colored dot on its title line.

## Regression coverage

Keep these when rebasing or reapplying. Delegation cases extend the list in
[local-claude-codex-delegation-patch.md](local-claude-codex-delegation-patch.md).

Delegation (`HookInputTests`, `HookHandlerTests`):

1. A `cc` hook with a non-empty `CODEX_THREAD_ID` is hidden, marked
   `is_subagent`, and stamped `("codex", <thread id>)`.
2. A `cc` hook without it (absent or empty) stays visible and unlinked, even when
   `CLAUDE_CODE_SESSION_ID` is present.
3. A `codex` hook with the Claude markers is stamped `("cc", <session id>)`; the
   marker alone still delegates but records no parent.
4. Parent fields survive later events that carry no environment evidence,
   including `SessionEnd`.
5. A marked `SessionEnd` can hide and stamp a previously unlinked record.
6. `CODEX_THREAD_ID` does not delegate a `codex` hook to itself, and
   `CLAUDE_CODE_SESSION_ID` does not delegate a `cc` hook to itself.

Attribution (`HookHandlerTests`):

7. An agent-scoped `PreToolUse` updates the child and leaves the parent's
   `last_tool` untouched; a missing child is created.
8. An agent-scoped `PostToolUse` advances only the child's `last_activity`.
9. Two parallel spawns pair their descriptions FIFO; the legacy `Task` name also
   queues; an agent-scoped spawn does not queue for its own parent; `model`,
   `subagent_type`, and the collapsed `prompt_excerpt` pair with them; a spawn
   with no description still queues.
10. The queue clears on `UserPromptSubmit`, `Stop`, and `SessionStart`, and is
    bounded at 16 with the oldest dropped first.
11. `SubagentInfo` JSON without any of the optional keys still decodes.
12. Six agent-scoped `PreToolUse` events leave `tool_call_count == 6` and the last
    five tool lines in order, with the parent's own tool untouched.
13. An agent-scoped `PermissionRequest` sets the child's `waiting_message`, leaves
    the parent's `notification_message` nil, keeps the parent's
    `waiting_permission` transition, and is cleared by the child's next tool call.
    A parent-scoped `PermissionRequest` still writes the parent's message. An
    agent-scoped `Notification` never sets `waiting_message`, does not clear the
    parent's running tool, and an agent-scoped `idle_prompt` does not clear the
    parent's message. A multi-line Bash command collapses to one `recent_tools`
    entry while `last_tool_detail` stays raw.

Tree and projection (`SubworkerTreeTests`, `SessionManagerVisibilityTests`):

14. cc root with in-process subagents + a delegated Codex child + that Codex
    thread's own Claude grandchild; codex root with a Claude child.
15. Unattributed grouping, exact-match rejection, cycle safety, unique node ids,
    childless roots omitted, depth cap at 3.
16. Group summary counts are exclusive and total the row count, the line is
    omitted when everything is running, and a waiting delegated record counts as
    waiting and never as stale.
17. A hidden delegated active record is published in `delegatedSessionRecords`
    and is absent from `userSessions`, `StatusCounts`, and
    `DisplayStateWriter.snapshot`; a finished delegated record is in neither.

Shim (`scripts/test-cc-hook-shim.sh`, wired into `make contract`):

18. A payload with `\n` inside a JSON string reaches a stub `cctop-hook` byte for
    byte under a throwaway `HOME`, and the negative control proves the old `echo`
    form still corrupts it.

## Upgrade and reapplication checklist

After updating cctop from upstream:

1. Search upstream for `agent_id` attribution in `HookHandler.applySideEffects`,
   for `CODEX_THREAD_ID`, and for `printf` in `plugins/cctop/hooks/run-hook.sh`.
   Prefer any equivalent upstream implementation and keep only missing coverage
   or docs.
2. Reapply the Claude-launched Codex filter patch, the notch and acknowledgement
   patch, the drop and menu-bar placement patch, then this one.
3. Confirm `HookInput.delegatedSessionEvidence(environment:)` still keeps each
   rule scoped to the opposite harness, and that
   `hasDelegatedSessionEvidence(environment:)` remains a thin wrapper so the
   existing delegation tests stay meaningful.
4. Confirm the new `SessionData` and `SubagentInfo` keys are still optional and
   still decode from records written by older hooks. Update the stored-property
   tripwire in `SessionTests` deliberately, never to make a build pass.
5. Confirm `delegatedSessionRecords` is still published outside `userSessions`
   and still absent from counts, notifications, Navigate, the indicators, Recent,
   and `DisplayStateWriter`.
6. Reapply by symbol, not by line number. New Swift files need hand-written
   24-character ids in `project.pbxproj`; follow the pattern in `git show d125c0f`.
7. Under cctop's private runtime lease, run `make all`, then `make snapshots` if
   any public UI image changed. Install only the assembled `dist/cctop.app` by
   following `docs/local-custom-build-install-runbook.md`.

For live behavior verification, inspect the resulting session JSON rather than
relying only on the panel:

- Codex-launched Claude: `source == "cc"`, `is_subagent == true`,
  `hidden == true`, `parent_harness == "codex"`, and `parent_harness_session_id`
  equal to the spawning thread's `harness_session_id`.
- Claude-launched Codex: `source == "codex"`, `is_subagent == true`,
  `hidden == true`, and `parent_harness == "cc"` when the parent exported its
  session id.
- A directly started session of either harness: `is_subagent == false`,
  `hidden == false`, and both parent fields absent.
- A parent running subagents: its `active_subagents` entries carry their own
  `last_tool`/`last_tool_detail`, `tool_call_count`, and `recent_tools`, while the
  parent's stay on the parent's own tool. A subagent blocked on a permission
  prompt carries `waiting_message` while the parent's `notification_message`
  stays nil.
