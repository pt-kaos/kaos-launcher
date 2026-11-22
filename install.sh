#!/usr/bin/env bash
# kaos-launcher installer. `install` copies the runtime files of the app to a share directory (default ~/.local/share/kaos-launcher)
# and links the `kaos-launcher` command to the copy, so the app no longer depends on this directory. `install --link` (development)
# links straight to this directory's wrapper instead. Re-running `install` upgrades the copy. `uninstall` removes only what was
# installed. It never uses sudo, never installs packages, and never deletes recursively.
set -u

self=$(readlink -f "$0")
dir=$(cd "$(dirname "$self")" && pwd)   # this repository directory (the source)
name=kaos-launcher
marker_name=.kaos-launcher-install

# ---- the runtime file set: the single place to maintain ----------------------------------------------------------------------
# required: must exist in the source, or the install fails. globs: extra files picked up automatically (test files are excluded).
runtime_required=(
  shell.qml Launcher.qml SolarScene.qml SphereScene.qml Glow.qml DotMaterial.qml
  search.js sphere.js dot.vert dot.frag
  kaos_launcher.py kaos-launcher config.example.toml LICENSE.md README.md CHANGELOG.md
)
runtime_globs=('*.qml' '*.js')
runtime_exclude=('*.test.js')
# -------------------------------------------------------------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: install.sh [install|uninstall|status] [options]

  install      copy the runtime files to the share directory and link <bin-dir>/$name to the copy (default).
               Run it again to upgrade. With --link: no copy, link straight to this directory's wrapper (development).
  uninstall    remove the link and the installed files (only what this script installed)
  status       show the mode (copy or link), the share directory, the link target and whether the app is running

Options:
  --share-dir DIR  where the copy goes (default: \$KAOS_SHARE_DIR, else \${XDG_DATA_HOME:-~/.local/share}/$name)
  --bin-dir DIR    where the link lives (default: \$KAOS_BIN_DIR, else ~/.local/bin)
  --link           install: development mode, no copy
  --force          install: replace a link or file in the way, or use a non-empty share directory without our marker
  --purge          uninstall: also remove the config and state directories (asks first)
  --yes            do not ask for confirmation (purge, stopping a running instance)
  --dry-run        print what would happen and change nothing
  -h, --help       this help

Environment: KAOS_SHARE_DIR, KAOS_BIN_DIR, XDG_DATA_HOME, KAOS_INSTALL_NO_IPC=1 (do not look for running instances; for tests).
Exit status: 0 success, 1 refused or failed, 2 usage error.
USAGE
}

cmd=install
mode=copy
bin_dir=${KAOS_BIN_DIR:-$HOME/.local/bin}
share_dir=${KAOS_SHARE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$name}
force=0 purge=0 yes=0 dry=0
while [ $# -gt 0 ]; do
  case $1 in
    install | uninstall | status) cmd=$1 ;;
    --bin-dir | --share-dir)
      [ $# -ge 2 ] || { echo "install.sh: $1 needs a directory" >&2; exit 2; }
      if [ "$1" = --bin-dir ]; then bin_dir=$2; else share_dir=$2; fi
      shift
      ;;
    --bin-dir=*) bin_dir=${1#--bin-dir=} ;;
    --share-dir=*) share_dir=${1#--share-dir=} ;;
    --link) mode="link" ;;
    --force) force=1 ;;
    --purge) purge=1 ;;
    --yes | -y) yes=1 ;;
    --dry-run | -n) dry=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "install.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

link="$bin_dir/$name"
marker="$share_dir/$marker_name"
repo_wrapper="$dir/$name"
share_wrapper="$share_dir/$name"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/$name"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$name"

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}
act() { # run a command, or only print it with --dry-run
  if [ "$dry" -eq 1 ]; then
    say "would run: $*"
  else
    "$@"
  fi
}
canon() { readlink -m -- "$1" 2>/dev/null || printf '%s' "$1"; }

have_pkg() { command -v pacman >/dev/null 2>&1 && pacman -Q "$1" >/dev/null 2>&1; }

check_deps() {
  local missing=0
  say "Dependencies (nothing is installed by this script):"
  if command -v quickshell >/dev/null 2>&1; then
    say "  ok       quickshell"
  else
    say "  MISSING  quickshell          (Arch: sudo pacman -S quickshell)"
    missing=1
  fi
  if python3 -c 'import sys, tomllib; sys.exit(0)' >/dev/null 2>&1; then
    say "  ok       python3 >= 3.11 (tomllib)"
  else
    say "  MISSING  python3 >= 3.11     (Arch: sudo pacman -S python)"
    missing=1
  fi
  if have_pkg qt6-quick3d || [ -d /usr/lib/qt6/qml/QtQuick3D ] || [ -d /usr/lib/qt/qml/QtQuick3D ]; then
    say "  ok       Qt Quick 3D (qt6-quick3d)"
  else
    say "  MISSING  qt6-quick3d         (Arch: sudo pacman -S qt6-quick3d)"
    missing=1
  fi
  if have_pkg qt6-shadertools || command -v qsb >/dev/null 2>&1 || [ -x /usr/lib/qt6/bin/qsb ]; then
    say "  ok       qt6-shadertools (the sphere style compiles its particle shaders at run time)"
  else
    say "  MISSING  qt6-shadertools     (Arch: sudo pacman -S qt6-shadertools)"
    missing=1
  fi
  local t found=""
  for t in "${TERMINAL:-}" kitty alacritty foot wezterm konsole xterm; do
    [ -n "$t" ] && command -v "$t" >/dev/null 2>&1 && { found=$t; break; }
  done
  if [ -n "$found" ]; then
    say "  ok       terminal: $found (optional, for Terminal=true apps)"
  else
    say "  missing  a terminal emulator (optional: only needed for Terminal=true apps)"
  fi
  [ "$missing" -eq 0 ] || warn "required dependencies are missing; the launcher will not start until they are installed"
}

in_path() {
  local real
  real=$(canon "$bin_dir")
  case ":$PATH:" in *":$bin_dir:"* | *":$real:"*) return 0 ;; esac
  return 1
}

# is a resident instance running for this app directory $1? (read-only IPC probe; never toggles anything)
running_at() {
  [ "${KAOS_INSTALL_NO_IPC:-0}" = 1 ] && return 1
  command -v quickshell >/dev/null 2>&1 || return 1
  [ -d "$1" ] || return 1
  quickshell ipc -p "$1" show >/dev/null 2>&1
}

# link state: absent | copy (points to the share wrapper) | repo (points to this directory's wrapper) | foreign-link | file
link_state() {
  if [ -L "$link" ]; then
    local t
    t=$(canon "$link")
    if [ "$t" = "$(canon "$share_wrapper")" ]; then echo copy
    elif [ "$t" = "$(canon "$repo_wrapper")" ]; then echo repo
    else echo foreign-link; fi
  elif [ -e "$link" ]; then
    echo file
  else
    echo absent
  fi
}

confirm() { # confirm "question"; --yes answers yes; a non-interactive stdin answers no
  [ "$yes" -eq 1 ] && return 0
  [ "$dry" -eq 1 ] && { say "(dry run: would ask: $1)"; return 0; }
  [ -t 0 ] || return 1
  local a
  read -r -p "$1 [y/N] " a
  case $a in y | Y | yes | YES) return 0 ;; esac
  return 1
}

# ---- manifest ---------------------------------------------------------------------------------------------------------------
new_manifest() { # prints the sorted list of runtime files in the source; fails loudly if a required one is missing
  local f g x skip missing=0 list=()
  for f in "${runtime_required[@]}"; do
    if [ -f "$dir/$f" ]; then list+=("$f"); else warn "required runtime file is missing in the source: $f"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || return 1
  for g in "${runtime_globs[@]}"; do
    # shellcheck disable=SC2231
    for f in $dir/$g; do
      [ -f "$f" ] || continue
      f=${f##*/}
      skip=0
      for x in "${runtime_exclude[@]}"; do
        # shellcheck disable=SC2254
        case $f in $x) skip=1 ;; esac
      done
      [ "$skip" -eq 1 ] || list+=("$f")
    done
  done
  printf '%s\n' "${list[@]}" | sort -u
}

old_manifest() { # the files recorded in the marker (names only; anything with a slash or a leading dot is ignored)
  [ -f "$marker" ] || return 0
  sed -n '/^files:$/,$ { /^files:$/d; p }' "$marker" | while IFS= read -r f; do
    case $f in "" | */* | .*) continue ;; esac
    printf '%s\n' "$f"
  done | sort -u
}

marker_value() { sed -n "s/^$1=//p" "$marker" 2>/dev/null | head -n 1; }

version_of_source() { sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' "$dir/CHANGELOG.md" 2>/dev/null | head -n 1; }

share_non_empty() { [ -d "$share_dir" ] && [ -n "$(ls -A "$share_dir" 2>/dev/null)" ]; }

file_same() { # same content and same exec bit
  [ -f "$2" ] && cmp -s "$1" "$2" || return 1
  if [ -x "$1" ]; then [ -x "$2" ]; else [ ! -x "$2" ]; fi
}

copy_identical() { # copy_identical new_manifest_file: is the installed copy identical to the source?
  [ -f "$marker" ] || return 1
  [ "$(old_manifest)" = "$(cat "$1")" ] || return 1
  local f
  while IFS= read -r f; do
    file_same "$dir/$f" "$share_dir/$f" || return 1
  done < "$1"
  return 0
}

write_marker() { # write_marker manifest_file
  local tmp
  tmp=$(mktemp "$share_dir/.marker.XXXXXX") || die "could not write the marker in $share_dir"
  {
    echo "kaos-launcher install marker, version 1"
    echo "version=$(version_of_source)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source=$dir"
    echo "mode=copy"
    echo "files:"
    cat "$1"
  } > "$tmp"
  mv -f -- "$tmp" "$marker"
}

# ---- install ----------------------------------------------------------------------------------------------------------------
place_link() { # place_link target: create or replace the command link
  local target=$1 st
  st=$(link_state)
  case $st in
    absent)
      [ -d "$bin_dir" ] || { say "Creating $bin_dir"; act mkdir -p "$bin_dir" || die "could not create $bin_dir"; }
      say "Linking $link -> $target"
      act ln -s "$target" "$link" || die "could not create $link"
      ;;
    copy | repo)
      if [ "$(canon "$link")" = "$(canon "$target")" ]; then
        say "Link already in place: $link -> $target"
      else
        say "Replacing the link $link (it pointed to $(readlink "$link"), which is this app) -> $target"
        act ln -sfn "$target" "$link" || die "could not replace $link"
      fi
      ;;
    foreign-link | file)
      say "Replacing $link (--force)."
      act ln -sfn "$target" "$link" || die "could not replace $link"
      ;;
  esac
}

preflight_link() { # refuse early (before copying anything) when the command path is taken by something else
  local st what
  st=$(link_state)
  case $st in
    foreign-link | file)
      if [ "$st" = file ]; then what="a regular file"; else what="a link to $(readlink "$link")"; fi
      [ "$force" -eq 1 ] || die "$link already exists as $what; not touching it (use --force to replace it)"
      ;;
  esac
}

do_install_link() {
  [ -x "$repo_wrapper" ] || die "the wrapper is missing or not executable: $repo_wrapper"
  check_deps
  preflight_link
  say "Development mode: no copy; the command will run the app straight from $dir"
  place_link "$repo_wrapper"
  in_path || warn "$bin_dir is not in your PATH; add it or call $link directly"
  [ -f "$marker" ] && say "Note: an earlier copy install is still in $share_dir (uninstall removes it)."
  say "Done."
}

do_install_copy() {
  local mf f changed=0 removed=0 fresh=1 stale
  mf=$(mktemp "${TMPDIR:-/tmp}/kl-manifest.XXXXXX") || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f -- '$mf'" EXIT
  new_manifest > "$mf" || die "cannot install: the source is incomplete"
  check_deps
  preflight_link
  if [ -f "$marker" ]; then
    fresh=0
  elif share_non_empty && [ "$force" -ne 1 ]; then
    die "$share_dir exists, is not empty and has no $marker_name marker, so it was not created by this script; not touching it (use --force to install into it anyway)"
  elif [ -e "$share_dir" ] && [ ! -d "$share_dir" ]; then
    die "$share_dir exists and is not a directory"
  fi

  if [ "$fresh" -eq 0 ] && copy_identical "$mf"; then
    say "Already up to date: $share_dir ($(wc -l < "$mf" | tr -d ' ') files)"
  else
    [ -d "$share_dir" ] || { say "Creating $share_dir"; act mkdir -p "$share_dir" || die "could not create $share_dir"; }
    while IFS= read -r f; do
      if ! file_same "$dir/$f" "$share_dir/$f"; then
        changed=$((changed + 1))
        if [ -x "$dir/$f" ]; then act install -m 755 -- "$dir/$f" "$share_dir/$f"; else act install -m 644 -- "$dir/$f" "$share_dir/$f"; fi \
          || die "could not copy $f"
      fi
    done < "$mf"
    # files installed earlier that are no longer part of the runtime set (only names recorded in our marker)
    stale=$(comm -23 <(old_manifest) "$mf")
    for f in $stale; do
      if [ -f "$share_dir/$f" ] || [ -L "$share_dir/$f" ]; then
        say "Removing stale file: $f"
        act rm -f -- "$share_dir/$f"
        removed=$((removed + 1))
      fi
    done
    if [ "$dry" -eq 1 ]; then say "would write $marker"; else write_marker "$mf"; fi
    if [ "$dry" -eq 1 ]; then
      say "(dry run) $changed file(s) would be copied, $removed stale file(s) removed"
    elif [ "$fresh" -eq 1 ]; then
      say "Installed $(wc -l < "$mf" | tr -d ' ') files to $share_dir"
    else
      say "Updated $share_dir: $changed file(s) copied, $removed stale file(s) removed"
    fi
  fi
  place_link "$share_wrapper"
  in_path || warn "$bin_dir is not in your PATH; add it (for example in your shell profile) or call $link directly"
  say "Done. Run \`$name\` to start or toggle the launcher (see README.md: Hyprland integration for a hotkey)."
}

# ---- uninstall --------------------------------------------------------------------------------------------------------------
purge_dir() { # remove a flat directory (files and links only, no recursive delete), then the directory
  local d=$1 f left=0
  [ -d "$d" ] || { say "  not present: $d"; return 0; }
  if [ -L "$d" ]; then warn "$d is a symlink; leaving it alone"; return 0; fi
  for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      warn "$f is a directory (not created by this app); leaving it"
      left=1
    else
      act rm -f -- "$f"
    fi
  done
  if [ "$left" -eq 0 ]; then
    if [ "$dry" -eq 1 ]; then say "  would remove: $d"; else rmdir -- "$d" && say "  removed: $d"; fi
  fi
}

stop_running() {
  local p seen=""
  for p in "$share_dir" "$dir"; do
    case " $seen " in *" $p "*) continue ;; esac
    seen="$seen $p"
    if running_at "$p"; then
      say "A resident instance is running from $p."
      if confirm "Stop it with 'quickshell kill -p $p'?"; then
        act quickshell kill -p "$p" || warn "could not stop it"
      else
        say "Leaving it running."
      fi
    fi
  done
}

remove_share() {
  local f unknown=() known=""
  if [ ! -d "$share_dir" ]; then say "No share directory: $share_dir"; return 0; fi
  if [ ! -f "$marker" ]; then
    warn "$share_dir has no $marker_name marker, so it was not created by this script; not touching it"
    return 1
  fi
  known=$(old_manifest)
  for f in $known; do
    if [ -f "$share_dir/$f" ] || [ -L "$share_dir/$f" ]; then act rm -f -- "$share_dir/$f"; fi
  done
  act rm -f -- "$marker"
  for f in "$share_dir"/* "$share_dir"/.[!.]* "$share_dir"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ "$dry" -eq 1 ]; then
      case $'\n'"$known"$'\n' in *$'\n'"${f##*/}"$'\n'*) continue ;; esac
      [ "${f##*/}" = "$marker_name" ] && continue
    fi
    unknown+=("$f")
  done
  if [ "${#unknown[@]}" -gt 0 ]; then
    warn "left ${#unknown[@]} file(s) in $share_dir that this script did not install: ${unknown[*]}"
  elif [ "$dry" -eq 1 ]; then
    say "would remove: $share_dir"
  else
    rmdir -- "$share_dir" && say "Removed $share_dir"
  fi
  return 0
}

do_uninstall() {
  local st rc=0
  st=$(link_state)
  stop_running
  case $st in
    copy | repo)
      say "Removing $link"
      act rm -- "$link" || die "could not remove $link"
      ;;
    absent) say "Not installed: $link does not exist." ;;
    foreign-link) warn "$link is a link to $(readlink "$link"), not to this app; not touching it"; rc=1 ;;
    file) warn "$link is a regular file, not a link to this app; not touching it"; rc=1 ;;
  esac
  remove_share || rc=1
  if [ "$purge" -eq 1 ]; then
    say "Purge: this removes the config ($cfg_dir) and state ($state_dir) of kaos-launcher."
    if confirm "Really remove them?"; then
      purge_dir "$cfg_dir"
      purge_dir "$state_dir"
    else
      warn "purge not confirmed (use --yes to skip the question); config and state were kept"
      rc=1
    fi
  else
    say "Config ($cfg_dir) and state ($state_dir) were kept; use --purge to remove them."
  fi
  return "$rc"
}

# ---- status -----------------------------------------------------------------------------------------------------------------
do_status() {
  local st p seen=""
  st=$(link_state)
  case $st in
    copy) say "installed (mode: copy): $link -> $(readlink "$link")" ;;
    repo) say "installed (mode: link, development): $link -> $(readlink "$link")" ;;
    absent) say "not installed: $link does not exist" ;;
    foreign-link) say "not installed: $link is a link to $(readlink "$link") (another copy?)" ;;
    file) say "not installed: $link is a regular file" ;;
  esac
  if [ -f "$marker" ]; then
    say "share directory: $share_dir (installed copy: version $(marker_value version), $(marker_value date), from $(marker_value source))"
  elif [ -e "$share_dir" ]; then
    say "share directory: $share_dir exists but has no install marker"
  else
    say "share directory: $share_dir (not present)"
  fi
  if [ "${KAOS_INSTALL_NO_IPC:-0}" = 1 ]; then
    say "running: not checked (KAOS_INSTALL_NO_IPC=1)"
  else
    for p in "$share_dir" "$dir"; do
      case " $seen " in *" $p "*) continue ;; esac
      seen="$seen $p"
      if running_at "$p"; then say "running: yes, from $p"; else say "running: no, from $p"; fi
    done
  fi
  if in_path; then say "PATH: $bin_dir is in PATH"; else say "PATH: $bin_dir is NOT in PATH"; fi
  [ "$st" = copy ] || [ "$st" = repo ]
}

case $cmd in
  install) if [ "$mode" = link ]; then do_install_link; else do_install_copy; fi ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
