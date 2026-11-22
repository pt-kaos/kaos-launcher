#!/usr/bin/env bash
# Tests for install.sh. Everything happens in a temp directory (HOME, XDG dirs, --bin-dir and --share-dir are temporary); the real
# ~/.local/bin, ~/.local/share, the real config and state, and any real quickshell instance are never touched (KAOS_INSTALL_NO_IPC=1).
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
inst="$here/install.sh"
repo_wrapper="$here/kaos-launcher"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kl-install-test.XXXXXX") || exit 1
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_STATE_HOME="$tmp/home/.local/state" KAOS_INSTALL_NO_IPC=1
unset KAOS_BIN_DIR KAOS_SHARE_DIR XDG_DATA_HOME
mkdir -p "$HOME"
bin="$tmp/bin"
share="$tmp/share/kaos-launcher"
link="$bin/kaos-launcher"
marker="$share/.kaos-launcher-install"
pass=0 fail=0

# cleanup without any recursive delete: remove files and links level by level, then rmdir
cleanup() {
  local d f
  for d in "$tmp"/share/kaos-launcher "$tmp"/share2 "$tmp"/share3 "$tmp"/xdg/kaos-launcher "$tmp"/envshare "$tmp"/share "$tmp"/xdg \
    "$tmp"/home/.config/kaos-launcher "$tmp"/home/.local/state/kaos-launcher "$tmp"/home/.config "$tmp"/home/.local/state \
    "$tmp"/home/.local "$tmp"/home "$bin" "$tmp"/other "$tmp"; do
    for f in "$d"/* "$d"/.[!.]*; do { [ -f "$f" ] || [ -L "$f" ]; } && rm -f -- "$f"; done
    rmdir "$d" 2>/dev/null
  done
}
trap cleanup EXIT

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
run() { out=$("$inst" "$@" 2>&1); rc=$?; }
has() { case $out in *"$1"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1"; }
rc_is() { [ "$rc" -eq "$1" ]; }
none_at() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
link_is() { [ "$(readlink -f "$link")" = "$(readlink -f "$1")" ]; }
listing() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
wrapper_rejects_bad_style() { "$link" --style cube >/dev/null 2>&1; [ $? -eq 2 ]; }

# the expected runtime file set
expected="CHANGELOG.md Glow.qml DotMaterial.qml LICENSE.md Launcher.qml README.md SolarScene.qml SphereScene.qml config.example.toml dot.frag dot.vert kaos-launcher kaos_launcher.py search.js shell.qml sphere.js"

# 1. copy install (default)
run --bin-dir "$bin" --share-dir "$share"
check "install: exit 0" rc_is 0
check "install: says Installed" has "Installed 16 files"
installed=$(find "$share" -mindepth 1 -maxdepth 1 -not -name '.*' -printf '%f\n' | sort | tr '\n' ' ')
want=$(printf '%s\n' "$expected" | tr ' ' '\n' | sort | tr '\n' ' ')
check "install: exactly the runtime files" [ "$installed" = "$want" ]
check "install: no tests, screenshots, install scripts, git, caches" bash -c "! find '$share' -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -E 'test|screenshots|install\.sh|^\.git|__pycache__' >/dev/null"
check "install: wrapper keeps its exec bit" [ -x "$share/kaos-launcher" ]
check "install: other files are not executable" [ ! -x "$share/Launcher.qml" ]
check "install: marker exists" [ -f "$marker" ]
check "install: marker records version, source and files" bash -c "grep -q '^source=$here\$' '$marker' && grep -q '^version=[0-9]' '$marker' && grep -q '^shell.qml\$' '$marker'"
check "install: link points to the copy" link_is "$share/kaos-launcher"
check "install: wrapper works through the link from the copy" wrapper_rejects_bad_style
check "install: copied files equal the source" bash -c "cmp -s '$here/SphereScene.qml' '$share/SphereScene.qml' && cmp -s '$here/dot.frag' '$share/dot.frag'"

# 2. idempotent
run --bin-dir "$bin" --share-dir "$share"
check "install again: exit 0" rc_is 0
check "install again: Already up to date" has "Already up to date"

# 3. upgrade: a changed file is updated, a stale file we installed is removed, an unknown file is kept
echo "stale" > "$share/old-runtime.js"
printf 'old-runtime.js\n' >> "$marker"
echo "mine" > "$share/user-notes.txt"
echo "// changed" >> "$share/search.js"
run --bin-dir "$bin" --share-dir "$share"
check "upgrade: exit 0 and says Updated" has "Updated"
check "upgrade: changed file restored from the source" cmp -s "$here/search.js" "$share/search.js"
check "upgrade: stale installed file removed" none_at "$share/old-runtime.js"
check "upgrade: unknown file kept" [ -f "$share/user-notes.txt" ]
rm -f "$share/user-notes.txt"
run --bin-dir "$bin" --share-dir "$share"
check "after upgrade: Already up to date again" has "Already up to date"

# 4. link and file in the way
rm -f "$link"
mkdir -p "$tmp/other"
echo x > "$tmp/other/f"
ln -s "$tmp/other/f" "$link"
run --bin-dir "$bin" --share-dir "$share"
check "foreign link: refused (exit 1)" rc_is 1
check "foreign link: left alone" [ "$(readlink "$link")" = "$tmp/other/f" ]
run --bin-dir "$bin" --share-dir "$share" --force
check "foreign link: --force replaces" link_is "$share/kaos-launcher"
rm -f "$link"
echo precious > "$link"
run --bin-dir "$bin" --share-dir "$share"
check "regular file: refused (exit 1)" rc_is 1
check "regular file: untouched" [ "$(cat "$link")" = precious ]
run --bin-dir "$bin" --share-dir "$share" --force
check "regular file: --force replaces" link_is "$share/kaos-launcher"

# 5. a hand-made link to this repo's wrapper is ours: replaced without --force
rm -f "$link"
ln -s "$repo_wrapper" "$link"
run --bin-dir "$bin" --share-dir "$share"
check "hand-made link to the repo wrapper: replaced without --force" bash -c "[ '$rc' -eq 0 ]"
check "hand-made link: now points to the copy" link_is "$share/kaos-launcher"

# 6. marker refusal: a non-empty directory that is not ours
mkdir -p "$tmp/share2"
echo keep > "$tmp/share2/theirs.txt"
run --bin-dir "$bin" --share-dir "$tmp/share2"
check "share dir without marker: refused (exit 1)" rc_is 1
check "share dir without marker: untouched" [ "$(listing "$tmp/share2")" = "theirs.txt " ]
run --bin-dir "$tmp/bin3" --share-dir "$tmp/share2" --force
check "share dir without marker: --force installs into it" [ -f "$tmp/share2/Launcher.qml" ]
check "share dir with --force: its own file is kept" [ -f "$tmp/share2/theirs.txt" ]
run uninstall --bin-dir "$tmp/bin3" --share-dir "$tmp/share2"
check "uninstall there: leaves the unknown file and says so" has "did not install"
check "uninstall there: unknown file kept, installed files gone" bash -c "[ -f '$tmp/share2/theirs.txt' ] && [ ! -e '$tmp/share2/Launcher.qml' ] && [ ! -e '$tmp/share2/.kaos-launcher-install' ]"
rm -f "$tmp/share2/theirs.txt"
rmdir "$tmp/share2" "$tmp/bin3" 2>/dev/null
mkdir -p "$tmp/share3"   # empty directory is fine
run --bin-dir "$tmp/bin3" --share-dir "$tmp/share3"
check "empty share dir is accepted" [ -f "$tmp/share3/Launcher.qml" ]
run uninstall --bin-dir "$tmp/bin3" --share-dir "$tmp/share3"
check "uninstall removes an installed-only share dir completely" none_at "$tmp/share3"
rmdir "$tmp/bin3" 2>/dev/null
run --bin-dir "$bin" --share-dir "$share" --force

# 7. --link (development) mode
run uninstall --bin-dir "$bin" --share-dir "$share"
run --bin-dir "$bin" --share-dir "$share" --link
check "--link: exit 0" rc_is 0
check "--link: link points to the repo wrapper" link_is "$repo_wrapper"
check "--link: nothing copied" none_at "$share"
run status --bin-dir "$bin" --share-dir "$share"
check "status in --link mode says link" has "mode: link"
run --bin-dir "$bin" --share-dir "$share"
check "link mode then copy install: switches without --force" link_is "$share/kaos-launcher"
run status --bin-dir "$bin" --share-dir "$share"
check "status in copy mode says copy" has "mode: copy"
check "status shows the share dir and the marker info" has "installed copy: version"

# 8. uninstall
run uninstall --bin-dir "$bin" --share-dir "$share"
check "uninstall: exit 0" rc_is 0
check "uninstall: link gone" none_at "$link"
check "uninstall: share dir gone (only our files were there)" none_at "$share"
check "uninstall: config and state kept message" has "were kept"
run uninstall --bin-dir "$bin" --share-dir "$share"
check "uninstall when absent: exit 0" rc_is 0
check "uninstall when absent: message" has "Not installed"
ln -s "$tmp/other/f" "$link"
run uninstall --bin-dir "$bin" --share-dir "$share"
check "uninstall foreign link: refused (exit 1) and kept" bash -c "[ '$rc' -eq 1 ] && [ -L '$link' ]"
rm -f "$link"
echo precious > "$link"
run uninstall --bin-dir "$bin" --share-dir "$share"
check "uninstall regular file: refused and untouched" bash -c "[ '$rc' -eq 1 ] && [ \"\$(cat '$link')\" = precious ]"
rm -f "$link"
mkdir -p "$tmp/share2"
echo keep > "$tmp/share2/theirs.txt"
run uninstall --bin-dir "$bin" --share-dir "$tmp/share2"
check "uninstall: share dir without marker is not touched (exit 1)" bash -c "[ '$rc' -eq 1 ] && [ -f '$tmp/share2/theirs.txt' ]"
rm -f "$tmp/share2/theirs.txt"
rmdir "$tmp/share2"

# 9. dry run for everything
run --bin-dir "$bin" --share-dir "$share" --dry-run
check "dry-run install: exit 0" rc_is 0
check "dry-run install: no share dir and no link created" bash -c "[ ! -e '$share' ] && [ ! -L '$link' ]"
check "dry-run install: prints what it would do" has "would run"
run --bin-dir "$bin" --share-dir "$share"
echo "// changed" >> "$share/search.js"
run --bin-dir "$bin" --share-dir "$share" --dry-run
check "dry-run upgrade: nothing changed" bash -c "tail -n 1 '$share/search.js' | grep -q 'changed'"
run uninstall --bin-dir "$bin" --share-dir "$share" --dry-run
check "dry-run uninstall: link and files still there" bash -c "[ -L '$link' ] && [ -f '$share/Launcher.qml' ] && [ -f '$marker' ]"
run --bin-dir "$bin" --share-dir "$share" --link --dry-run
check "dry-run --link: link unchanged" link_is "$share/kaos-launcher"
run uninstall --bin-dir "$bin" --share-dir "$share"

# 10. purge
mkdir -p "$XDG_CONFIG_HOME/kaos-launcher" "$XDG_STATE_HOME/kaos-launcher"
echo 'x = 1' > "$XDG_CONFIG_HOME/kaos-launcher/config.toml"
echo '{}' > "$XDG_STATE_HOME/kaos-launcher/state.json"
run --bin-dir "$bin" --share-dir "$share"
out=$("$inst" uninstall --bin-dir "$bin" --share-dir "$share" --purge < /dev/null 2>&1); rc=$?
check "--purge without a terminal and without --yes: refused (exit 1)" rc_is 1
check "--purge refused: config and state kept" [ -f "$XDG_STATE_HOME/kaos-launcher/state.json" ]
run --bin-dir "$bin" --share-dir "$share"
run uninstall --bin-dir "$bin" --share-dir "$share" --purge --yes --dry-run
check "--purge --dry-run: nothing removed" [ -f "$XDG_CONFIG_HOME/kaos-launcher/config.toml" ]
run --bin-dir "$bin" --share-dir "$share"
run uninstall --bin-dir "$bin" --share-dir "$share" --purge --yes
check "--purge --yes: exit 0, config and state removed" bash -c "[ '$rc' -eq 0 ] && [ ! -e '$XDG_CONFIG_HOME/kaos-launcher' ] && [ ! -e '$XDG_STATE_HOME/kaos-launcher' ]"

# 11. share dir from --share-dir, KAOS_SHARE_DIR, XDG_DATA_HOME; bin dir from KAOS_BIN_DIR
out=$(KAOS_BIN_DIR="$bin" KAOS_SHARE_DIR="$tmp/envshare" "$inst" install 2>&1); rc=$?
check "KAOS_SHARE_DIR and KAOS_BIN_DIR are honoured" bash -c "[ -f '$tmp/envshare/Launcher.qml' ] && [ \"\$(readlink -f '$link')\" = \"\$(readlink -f '$tmp/envshare/kaos-launcher')\" ]"
out=$(KAOS_BIN_DIR="$bin" KAOS_SHARE_DIR="$tmp/envshare" "$inst" uninstall 2>&1); rc=$?
out=$(XDG_DATA_HOME="$tmp/xdg" "$inst" install --bin-dir "$bin" 2>&1); rc=$?
check "XDG_DATA_HOME sets the default share dir" [ -f "$tmp/xdg/kaos-launcher/Launcher.qml" ]
out=$(XDG_DATA_HOME="$tmp/xdg" "$inst" uninstall --bin-dir "$bin" 2>&1); rc=$?
check "uninstall via XDG_DATA_HOME" none_at "$tmp/xdg/kaos-launcher"
run status --bin-dir "$bin" --share-dir "$share"
check "status when absent: exit 1" rc_is 1

# 12. PATH warning, usage errors, a missing required runtime file
run --bin-dir "$bin" --share-dir "$share"
check "PATH warning when the bin dir is not in PATH" has "not in your PATH"
run uninstall --bin-dir "$bin" --share-dir "$share"
out=$(PATH="$bin:$PATH" "$inst" install --bin-dir "$bin" --share-dir "$share" 2>&1)
check "no PATH warning when it is" lacks "not in your PATH"
run uninstall --bin-dir "$bin" --share-dir "$share"
run --bogus
check "unknown option: exit 2" rc_is 2
run --share-dir
check "--share-dir without a value: exit 2" rc_is 2
run --help
check "--help: exit 0 and usage" has "Usage: install.sh"
check "nothing was written under the temporary HOME's .local/bin or .local/share" bash -c "[ ! -e '$HOME/.local/bin/kaos-launcher' ] && [ ! -e '$HOME/.local/share/kaos-launcher' ]"
# a source without a required file: run a copy of the script in a directory that lacks it
src="$tmp/other/src"
mkdir -p "$src"
cp "$inst" "$src/install.sh"
run_in_src() { out=$("$src/install.sh" "$@" 2>&1); rc=$?; }
run_in_src --bin-dir "$bin" --share-dir "$share"
check "incomplete source: fails loudly (exit 1), names a missing file, copies nothing" bash -c "[ '$rc' -eq 1 ] && [ ! -e '$share' ]"
check "incomplete source: message" has "required runtime file is missing"
rm -f "$src/install.sh"
rmdir "$src"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
