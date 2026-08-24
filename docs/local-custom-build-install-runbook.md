# Local custom cctop build and install runbook

Use this runbook after rebasing or changing any of the local cctop patches. It
covers the persistent custom installation at `/Applications/cctop.app`, which
is also the copy expected to launch at login.

The local patch stack is documented in:

1. `docs/local-claude-codex-delegation-patch.md`
2. `docs/local-notch-and-session-ack-patch.md`
3. `docs/local-drop-and-menubar-placement-patch.md`

## Critical packaging invariant

Never install either raw Xcode product directly:

- `menubar/build/Build/Products/Debug/CctopMenubar.app`
- `menubar/build/Build/Products/Release/CctopMenubar.app`

Those products contain the menu bar executable but are not the complete cctop
distribution. In particular, they do not contain the assembled
`Contents/MacOS/cctop-hook` helper or all packaged integration resources.

Always build the persistent installation with:

```bash
./scripts/bundle-macos.sh
```

That script builds the app and hook separately, copies the hook and integration
resources into `dist/cctop.app`, and signs the assembled bundle. The persistent
installation source is therefore only `dist/cctop.app`.

`script/build_and_run.sh --verify` is for a temporary developer runtime under
the cctop runtime lane. It is not the persistent `/Applications` installation
and must not be used as the source of an app copy.

## Rebuild after an upstream update

1. Reapply the local patches in the order listed above. Preserve their stable
   behavior contracts rather than old line numbers.
2. Obtain cctop's private runtime lease before any build, app restart, or hook
   replacement.
3. From the final stacked worktree, run the required tests and `make all`.
4. Build the complete persistent bundle:

   ```bash
   ./scripts/bundle-macos.sh
   ```

5. Verify the bundle before touching the installed app:

   ```bash
   test -x dist/cctop.app/Contents/MacOS/cctop-hook
   dist/cctop.app/Contents/MacOS/cctop-hook --version
   codesign --verify --strict --verbose=2 dist/cctop.app
   ```

## Persistent installation

1. Quit cctop and verify that no `CctopMenubar` process remains.
2. Preserve the existing installed app in a dated backup outside
   `/Applications`.
3. Replace the entire `/Applications/cctop.app` container with
   `dist/cctop.app`. Do not merge the assembled bundle into a raw Xcode app.
   Merging leaves Debug dylibs and XCTest frameworks behind and invalidates the
   release signature.
4. If macOS App Management blocks a shell move or replacement, stop and use
   Finder's Replace operation. Do not work around the restriction by copying
   only `CctopMenubar`; that recreates the missing-hook failure.
5. Launch exactly `/Applications/cctop.app`.

A recoverable shell replacement, when App Management permits it, has this
shape:

```bash
archive_root=/Users/jared/code/infrastructure/.local-app-backups/cctop-YYYYMMDD-HHMM
mkdir -p "$archive_root"
mv /Applications/cctop.app "$archive_root/cctop.app"
ditto dist/cctop.app /Applications/cctop.app
open /Applications/cctop.app
```

Use a real timestamp in `archive_root`, and confirm the target does not already
exist before moving anything.

## Required post-install proof

Do not declare the custom app ready from the visible menu bar alone. Verify all
of the following from the exact final worktree:

```bash
test -x /Applications/cctop.app/Contents/MacOS/cctop-hook
/Applications/cctop.app/Contents/MacOS/cctop-hook --version
test -x "$HOME/.cctop/bin/cctop-hook"
readlink "$HOME/.cctop/bin/cctop-hook"
codesign --verify --strict --verbose=2 /Applications/cctop.app
shasum -a 256 \
  dist/cctop.app/Contents/MacOS/cctop-hook \
  /Applications/cctop.app/Contents/MacOS/cctop-hook
pgrep -fl CctopMenubar
```

The two hook hashes must match. The running path must be
`/Applications/cctop.app/Contents/MacOS/CctopMenubar`, with only one cctop app
process.

Then verify one real hook event from both an in-scope Codex session and, when
available, a Claude Code session:

- A newer `HOOK` entry appears in `~/.cctop/logs/<session-id>.log`.
- No newer `cctop-hook not found` entry appears in
  `~/.cctop/logs/_errors.log`.
- The matching `~/.cctop/sessions/*.json` file receives a current
  `last_activity` and status.

Old error lines remain in the append-only log. Compare timestamps instead of
checking whether the text exists anywhere. A session that emitted events while
the helper was missing remains stale until its next real event.

## Missing-hook failure signature

Treat this combination as an installation failure before changing lifecycle or
status logic:

- Live client logs show `SHIM ... dispatching` followed by
  `cctop-hook not found`.
- `~/.cctop/bin/cctop-hook` is a dangling symlink into
  `/Applications/cctop.app`.
- Session JSON timestamps stop advancing even though Claude Code or Codex is
  actively emitting events.
- The UI shows contradictory stale projections, such as an old Codex permission
  record rendered green while active Claude Code work remains grey.

Repair the complete application bundle first. Only investigate status policy if
fresh hook events and session JSON updates are proven after the repair.
