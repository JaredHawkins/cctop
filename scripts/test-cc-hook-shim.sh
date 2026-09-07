#!/bin/bash
# Regression guard for plugins/cctop/hooks/run-hook.sh payload fidelity.
#
# The shim buffers stdin and re-emits it. macOS /bin/sh's builtin echo expands backslash
# escapes, so re-emitting with `echo "$INPUT"` turns any payload carrying \n inside a JSON
# string (every Agent tool call, any multi-line prompt) into invalid JSON and the event is
# silently dropped. This test runs the shim against a stub cctop-hook under a throwaway
# HOME and asserts the stub received the payload byte for byte.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SHIM="$ROOT_DIR/plugins/cctop/hooks/run-hook.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# A realistic Agent PreToolUse payload: the description and prompt carry escaped newlines.
PAYLOAD='{"session_id":"shim-fidelity-test","cwd":"/tmp/p","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Check the shim","prompt":"first line\nsecond line\ttabbed"}}'

install_stub_home() {
    local home="$1"
    rm -rf "$home"
    mkdir -p "$home/.cctop/bin"
    cat > "$home/.cctop/bin/cctop-hook" <<'STUB'
#!/bin/sh
cat > "$CCTOP_STUB_CAPTURE"
printf '%s\n' "$*" > "$CCTOP_STUB_ARGS"
STUB
    chmod +x "$home/.cctop/bin/cctop-hook"
}

run_shim() {
    local shim="$1" home="$2" capture="$3"
    rm -f "$capture"
    HOME="$home" \
    CCTOP_STUB_CAPTURE="$capture" \
    CCTOP_STUB_ARGS="$TMP_DIR/args" \
        /bin/sh "$shim" PreToolUse <<< "$PAYLOAD"
}

HOME_DIR="$TMP_DIR/home"
install_stub_home "$HOME_DIR"

# printf writes the buffered payload plus one trailing newline, exactly like the input line.
printf '%s\n' "$PAYLOAD" > "$TMP_DIR/expected"

run_shim "$SHIM" "$HOME_DIR" "$TMP_DIR/captured"

if ! cmp -s "$TMP_DIR/expected" "$TMP_DIR/captured"; then
    echo "run-hook.sh altered the payload before dispatch:"
    echo "--- expected ---"; cat "$TMP_DIR/expected"
    echo "--- received ---"; cat "$TMP_DIR/captured"
    exit 1
fi

if ! grep -q -- "PreToolUse --harness cc" "$TMP_DIR/args"; then
    echo "run-hook.sh did not dispatch with the expected arguments:"
    cat "$TMP_DIR/args"
    exit 1
fi

if grep -q 'echo "\$INPUT"' "$SHIM"; then
    echo "run-hook.sh must re-emit \$INPUT with printf, never echo."
    exit 1
fi

# Negative control: prove the assertion above actually catches the escape-expanding form.
BROKEN_SHIM="$TMP_DIR/run-hook-broken.sh"
sed "s|printf '%s\\\\n' \"\$INPUT\"|echo \"\$INPUT\"|g" "$SHIM" > "$BROKEN_SHIM"
chmod +x "$BROKEN_SHIM"
if ! grep -q 'echo "\$INPUT"' "$BROKEN_SHIM"; then
    echo "Negative control did not produce an echo-based shim; update this test."
    exit 1
fi
run_shim "$BROKEN_SHIM" "$HOME_DIR" "$TMP_DIR/captured-broken"
if cmp -s "$TMP_DIR/expected" "$TMP_DIR/captured-broken"; then
    echo "Negative control passed unexpectedly: /bin/sh echo no longer expands escapes."
    echo "Re-check this guard before relaxing it."
    exit 1
fi

echo "Claude Code hook shim payload fidelity tests passed."
