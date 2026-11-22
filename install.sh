#!/usr/bin/env bash
# kaos-launcher installer: put the `kaos-launcher` command on your PATH as a symlink, or remove it again.
# It never uses sudo, never installs packages, and only touches the one link (and, with --purge, this app's config and state).
set -u

self=$(readlink -f "$0")
dir=$(cd "$(dirname "$self")" && pwd)
wrapper="$dir/kaos-launcher"
name=kaos-launcher

usage() {
  cat <<USAGE
Usage: install.sh [install|uninstall|status] [options]

  install      link <bin-dir>/$name to the wrapper in this directory (default)
  uninstall    remove that link (only if it points to this directory's wrapper)
  status       show whether it is installed, where the link points, and whether the app is running

Options:
  --bin-dir DIR   where the link lives (default: \$KAOS_BIN_DIR, else ~/.local/bin)
  --force         install: replace a link or file that is already there
  --purge         uninstall: also remove the config and state directories (asks first)
  --yes           do not ask for confirmation (with --purge and for stopping a running instance)
  --dry-run       print what would happen and change nothing
  -h, --help      this help

Environment: KAOS_BIN_DIR (default bin dir), KAOS_INSTALL_NO_IPC=1 (do not look for a running instance; for tests).
Exit status: 0 success, 1 refused or failed, 2 usage error.
USAGE
}

cmd=install
bin_dir=${KAOS_BIN_DIR:-$HOME/.local/bin}
force=0 purge=0 yes=0 dry=0
while [ $# -gt 0 ]; do
  case $1 in
    install | uninstall | status) cmd=$1 ;;
    --bin-dir)
      [ $# -ge 2 ] || { echo "install.sh: --bin-dir needs a directory" >&2; exit 2; }
      bin_dir=$2
      shift
      ;;
    --bin-dir=*) bin_dir=${1#--bin-dir=} ;;
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
  local d real
  real=$(readlink -f "$bin_dir" 2>/dev/null || echo "$bin_dir")
  case ":$PATH:" in *":$bin_dir:"* | *":$real:"*) return 0 ;; esac
  return 1
}

# is a resident instance of THIS directory's app running? (read-only IPC probe; never toggles anything)
running() {
  [ "${KAOS_INSTALL_NO_IPC:-0}" = 1 ] && return 1
  command -v quickshell >/dev/null 2>&1 || return 1
  quickshell ipc -p "$dir" show >/dev/null 2>&1
}

link_state() { # prints: absent | ours | foreign-link | file
  if [ -L "$link" ]; then
    if [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$wrapper")" ]; then echo ours; else echo foreign-link; fi
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

do_install() {
  [ -x "$wrapper" ] || die "the wrapper is missing or not executable: $wrapper"
  check_deps
  local st
  st=$(link_state)
  case $st in
    ours) say "Already installed: $link -> $(readlink "$link")"; ;;
    foreign-link | file)
      local what
      what="a link to $(readlink "$link")"
      [ "$st" = file ] && what="a regular file"
      if [ "$force" -ne 1 ]; then
        die "$link already exists as $what; not touching it (use --force to replace it)"
      fi
      say "Replacing $link (was $what)."
      act ln -sfn "$wrapper" "$link" || die "could not create $link"
      ;;
    absent)
      [ -d "$bin_dir" ] || { say "Creating $bin_dir"; act mkdir -p "$bin_dir" || die "could not create $bin_dir"; }
      say "Linking $link -> $wrapper"
      act ln -s "$wrapper" "$link" || die "could not create $link"
      ;;
  esac
  if ! in_path; then
    warn "$bin_dir is not in your PATH; add it (for example in your shell profile) or call $link directly"
  fi
  say "Done. Run \`$name\` to start or toggle the launcher (see README.md: Hyprland integration for a hotkey)."
}

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

do_uninstall() {
  local st
  st=$(link_state)
  if running; then
    say "A resident instance of this app is running (quickshell -p $dir)."
    if confirm "Stop it with 'quickshell kill -p $dir'?"; then
      act quickshell kill -p "$dir" || warn "could not stop it"
    else
      say "Leaving it running."
    fi
  fi
  case $st in
    ours)
      say "Removing $link"
      act rm -- "$link" || die "could not remove $link"
      ;;
    absent) say "Not installed: $link does not exist." ;;
    foreign-link) die "$link is a link to $(readlink "$link"), not to this app's wrapper; not touching it" ;;
    file) die "$link is a regular file, not a link to this app's wrapper; not touching it" ;;
  esac
  if [ "$purge" -eq 1 ]; then
    say "Purge: this removes the config ($cfg_dir) and state ($state_dir) of kaos-launcher."
    if confirm "Really remove them?"; then
      purge_dir "$cfg_dir"
      purge_dir "$state_dir"
    else
      die "purge not confirmed (use --yes to skip the question); config and state were kept"
    fi
  else
    say "Config ($cfg_dir) and state ($state_dir) were kept; use --purge to remove them."
  fi
}

do_status() {
  local st
  st=$(link_state)
  case $st in
    ours) say "installed: $link -> $(readlink "$link")" ;;
    absent) say "not installed: $link does not exist" ;;
    foreign-link) say "not installed: $link is a link to $(readlink "$link") (another copy?)" ;;
    file) say "not installed: $link is a regular file" ;;
  esac
  if [ "${KAOS_INSTALL_NO_IPC:-0}" = 1 ]; then
    say "running: not checked (KAOS_INSTALL_NO_IPC=1)"
  elif running; then
    say "running: yes (resident instance of $dir)"
  else
    say "running: no"
  fi
  if in_path; then say "PATH: $bin_dir is in PATH"; else say "PATH: $bin_dir is NOT in PATH"; fi
  [ "$st" = ours ]
}

case $cmd in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
