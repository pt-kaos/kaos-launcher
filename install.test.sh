#!/usr/bin/env bash
# Tests for install.sh. Everything happens in a temp directory (HOME, XDG dirs and --bin-dir are temporary); the real
# ~/.local/bin, the real config and state, and any real quickshell instance are never touched (KAOS_INSTALL_NO_IPC=1).
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
inst="$here/install.sh"
wrapper="$here/kaos-launcher"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kl-install-test.XXXXXX") || exit 1
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_STATE_HOME="$tmp/home/.local/state" KAOS_INSTALL_NO_IPC=1
unset KAOS_BIN_DIR
mkdir -p "$HOME"
bin="$tmp/bin"
link="$bin/kaos-launcher"
pass=0 fail=0
cleanup() {
  local f
  for f in "$tmp"/home/.config/kaos-launcher/* "$tmp"/home/.local/state/kaos-launcher/* "$bin"/* "$tmp"/other/*; do
    { [ -e "$f" ] || [ -L "$f" ]; } && rm -f -- "$f"
  done
  rmdir "$tmp"/home/.config/kaos-launcher "$tmp"/home/.local/state/kaos-launcher "$tmp"/home/.config "$tmp"/home/.local/state \
    "$tmp"/home/.local "$tmp"/home "$bin" "$tmp"/other "$tmp" 2>/dev/null
}
trap cleanup EXIT

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { # check "name" command...
  local n=$1
  shift
  if "$@"; then ok "$n"; else bad "$n"; fi
}
run() { out=$("$inst" "$@" 2>&1); rc=$?; }
has() { case $out in *"$1"*) return 0 ;; esac; return 1; }
rc_is() { [ "$rc" -eq "$1" ]; }
lacks() { ! has "$1"; }
none_at() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
wrapper_rejects_bad_style() { "$link" --style cube >/dev/null 2>&1; [ $? -eq 2 ]; }
target_is() { [ "$(readlink -f "$link")" = "$(readlink -f "$wrapper")" ]; }

# 1. install (default command) creates the link
run --bin-dir "$bin"
check "install: exit 0" [ $rc -eq 0 ]
check "install: link points to the wrapper" target_is
check "install: wrapper runs through the link (--style check exits 2)" wrapper_rejects_bad_style

# 2. idempotent
run install --bin-dir "$bin"
check "install again: exit 0" [ $rc -eq 0 ]
check "install again: says already installed" has "Already installed"

# 3. foreign link and regular file are refused, --force replaces
mkdir -p "$tmp/other"
echo x > "$tmp/other/f"
rm -f "$link"
ln -s "$tmp/other/f" "$link"
run install --bin-dir "$bin"
check "foreign link: refused (exit 1)" [ $rc -eq 1 ]
check "foreign link: left alone" [ "$(readlink "$link")" = "$tmp/other/f" ]
run install --bin-dir "$bin" --force
check "foreign link: --force replaces (exit 0)" rc_is 0
check "foreign link: now ours" target_is
rm -f "$link"
echo "precious" > "$link"
run install --bin-dir "$bin"
check "regular file: refused (exit 1)" [ $rc -eq 1 ]
check "regular file: content untouched" [ "$(cat "$link")" = precious ]
run install --bin-dir "$bin" --force
check "regular file: --force replaces" target_is

# 4. uninstall
run uninstall --bin-dir "$bin"
check "uninstall: exit 0" [ $rc -eq 0 ]
check "uninstall: link gone" none_at "$link"
check "uninstall: says config and state were kept" has "were kept"
run uninstall --bin-dir "$bin"
check "uninstall when absent: exit 0" rc_is 0
check "uninstall when absent: message" has "Not installed"

# 5. uninstall refuses foreign things
ln -s "$tmp/other/f" "$link"
run uninstall --bin-dir "$bin"
check "uninstall foreign link: refused (exit 1)" [ $rc -eq 1 ]
check "uninstall foreign link: still there" [ -L "$link" ]
rm -f "$link"
echo "precious" > "$link"
run uninstall --bin-dir "$bin"
check "uninstall regular file: refused (exit 1)" [ $rc -eq 1 ]
check "uninstall regular file: untouched" [ "$(cat "$link")" = precious ]
rm -f "$link"

# 6. dry run changes nothing
run install --bin-dir "$bin" --dry-run
check "dry-run install: exit 0" rc_is 0
check "dry-run install: no link" none_at "$link"
check "dry-run install: prints what it would do" has "would run"
run install --bin-dir "$bin"
run uninstall --bin-dir "$bin" --dry-run
check "dry-run uninstall: link still there" [ -L "$link" ]
check "dry-run uninstall: prints what it would do" has "would run"
rm -f "$link"

# 7. purge
mkdir -p "$XDG_CONFIG_HOME/kaos-launcher" "$XDG_STATE_HOME/kaos-launcher"
echo 'x = 1' > "$XDG_CONFIG_HOME/kaos-launcher/config.toml"
echo '{}' > "$XDG_STATE_HOME/kaos-launcher/state.json"
run install --bin-dir "$bin"
run uninstall --bin-dir "$bin"
check "no --purge: config and state kept" [ -f "$XDG_CONFIG_HOME/kaos-launcher/config.toml" ]
run install --bin-dir "$bin"
out=$("$inst" uninstall --bin-dir "$bin" --purge < /dev/null 2>&1); rc=$?
check "--purge without a terminal and without --yes: refused (exit 1)" [ $rc -eq 1 ]
check "--purge refused: config and state kept" [ -f "$XDG_STATE_HOME/kaos-launcher/state.json" ]
run install --bin-dir "$bin"
run uninstall --bin-dir "$bin" --purge --yes --dry-run
check "--purge --dry-run: nothing removed" [ -f "$XDG_CONFIG_HOME/kaos-launcher/config.toml" ]
run uninstall --bin-dir "$bin" --purge --yes
check "--purge --yes: exit 0" [ $rc -eq 0 ]
check "--purge --yes: config removed" none_at "$XDG_CONFIG_HOME/kaos-launcher"
check "--purge --yes: state removed" none_at "$XDG_STATE_HOME/kaos-launcher"
# a foreign subdirectory inside the config dir is never deleted recursively
mkdir -p "$XDG_CONFIG_HOME/kaos-launcher/sub"
echo keep > "$XDG_CONFIG_HOME/kaos-launcher/sub/f"
run install --bin-dir "$bin"
run uninstall --bin-dir "$bin" --purge --yes
check "--purge leaves a foreign subdirectory alone" [ -f "$XDG_CONFIG_HOME/kaos-launcher/sub/f" ]
rm -f "$XDG_CONFIG_HOME/kaos-launcher/sub/f"
rmdir "$XDG_CONFIG_HOME/kaos-launcher/sub" "$XDG_CONFIG_HOME/kaos-launcher" 2>/dev/null

# 8. bin dir from the environment, status, PATH warning, usage errors
out=$(KAOS_BIN_DIR="$bin" "$inst" install 2>&1); rc=$?
check "KAOS_BIN_DIR is honoured" target_is
run status --bin-dir "$bin"
check "status: installed (exit 0)" rc_is 0
check "status: shows the target" has "installed: $link"
rm -f "$link"
run status --bin-dir "$bin"
check "status when absent: exit 1" [ $rc -eq 1 ]
run install --bin-dir "$bin"
check "PATH warning when the bin dir is not in PATH" has "not in your PATH"
out=$(PATH="$bin:$PATH" "$inst" install --bin-dir "$bin" 2>&1)
check "no PATH warning when it is" lacks "not in your PATH"
run --bogus
check "unknown option: exit 2" [ $rc -eq 2 ]
run --bin-dir
check "--bin-dir without a value: exit 2" [ $rc -eq 2 ]
run --help
check "--help: exit 0" rc_is 0
check "--help text" has "Usage: install.sh"
rm -f "$link"
check "nothing was written under the temporary HOME's .local/bin" none_at "$HOME/.local/bin/kaos-launcher"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
