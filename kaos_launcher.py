#!/usr/bin/env python3
"""kaos-launcher backend: .desktop graph, config, state, launching.

kaos_launcher.py graph                          print graph JSON on stdout
kaos_launcher.py init [--save-planet NAME]      print {config, state, graph} JSON; creates the default config on
                                                first run; with --save-planet, stores the focused planet first
kaos_launcher.py save --planet NAME             store the focused planet in the state
kaos_launcher.py launch <path> [--id ID] [--planet NAME]
                                                launch the desktop entry detached; with --id, record it in the state
"""

import argparse
import configparser
import json
import math
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

# Main group -> freedesktop categories. The first group (in this order)
# with any matching category wins, so specific groups beat generic ones.
GROUPS = [
    ("Settings", {"Settings", "DesktopSettings", "HardwareSettings", "PackageManager"}),
    ("Games", {"Game"}),
    ("Development", {"Development", "IDE", "Debugger", "TextEditor"}),
    (
        "Graphics",
        {
            "Graphics",
            "2DGraphics",
            "3DGraphics",
            "Photography",
            "RasterGraphics",
            "VectorGraphics",
        },
    ),
    ("Multimedia", {"AudioVideo", "Audio", "Video", "Player", "Recorder", "Music"}),
    (
        "Internet",
        {"Network", "WebBrowser", "Email", "InstantMessaging", "FileTransfer"},
    ),
    (
        "Office",
        {
            "Office",
            "Spreadsheet",
            "WordProcessor",
            "Presentation",
            "Calendar",
            "Viewer",
        },
    ),
    ("System", {"System", "Monitor", "Security", "TerminalEmulator", "Emulator"}),
    ("Utility", {"Utility", "Archiving", "Calculator", "FileManager", "Accessibility"}),
]
FALLBACK = "Other"
TERMINALS = ["kitty", "alacritty", "foot", "wezterm", "konsole", "xterm"]
CODES = {"%f", "%F", "%u", "%U", "%i", "%c", "%k", "%d", "%D", "%n", "%N", "%v", "%m"}

# ---- config ----------------------------------------------------------------
# key -> (default, kind, lo, hi). kind: bool | int | float | str. Numbers are clamped to [lo, hi].
SETTINGS = {
    "run_in_background": (True, "bool", None, None),
    "recent_count": (5, "int", 0, 20),
    "panel_size_percent": (50.0, "float", 20.0, 100.0),
    "close_after_launch": (True, "bool", None, None),
    "orbit_speed": (1.0, "float", 0.0, 5.0),
    "starfield": (True, "bool", None, None),
    "icons": (True, "bool", None, None),
    "icon_theme": ("auto", "str", None, None),
    "terminal": ("auto", "str", None, None),
    "drag_speed": (0.25, "float", 0.02, 2.0),
    "tooltip_font_size": (11, "int", 6, 40),
}

DEFAULT_TOML = """\
# kaos-launcher configuration. Delete this file to get these defaults back.
# Missing or invalid values fall back to the default shown; numbers outside the range are clamped.

# Keep one resident instance; Escape or a launch hides the panel and the toggle command brings it back.
# false: Escape or a launch exits the process.
run_in_background = true

# How many recently launched apps (launched from kaos-launcher only) get a brighter glow. 0 turns it off. Range 0-20.
recent_count = 5

# Panel size as a percentage of the screen width and height. Range 20-100.
panel_size_percent = 50

# Hide (or exit) after launching an app.
close_after_launch = true

# Moon orbit speed. 1.0 normal, 0 stops the orbits. Range 0-5.
orbit_speed = 1.0

# Faint starfield in the background (drifts slightly when the ring turns).
starfield = true

# Show app icons on the moons (camera-facing billboards). false: plain spheres only.
icons = true

# Icon theme: "auto" (GTK settings of the session, then gsettings, then hicolor) or a theme name such as "Papirus-Dark".
# The theme's Inherits chain and hicolor are searched; apps without an icon stay plain spheres.
icon_theme = "auto"

# Terminal for Terminal=true apps: "auto" (uses $TERMINAL, then kitty, alacritty, foot, wezterm, konsole, xterm)
# or the name/path of a terminal that accepts "-e <command>".
terminal = "auto"

# Mouse drag sensitivity in degrees of ring rotation per pixel. Range 0.02-2.
drag_speed = 0.25

# Tooltip text size in pixels. Range 6-40.
tooltip_font_size = 11
"""


def _xdg(var, fallback):
    v = os.environ.get(var, "")
    return Path(v) if v and os.path.isabs(v) else Path.home() / fallback


def config_path():
    return _xdg("XDG_CONFIG_HOME", ".config") / "kaos-launcher" / "config.toml"


def state_path():
    return _xdg("XDG_STATE_HOME", ".local/state") / "kaos-launcher" / "state.json"


def defaults():
    return {k: v[0] for k, v in SETTINGS.items()}


def _atomic_write(path, text, replace=True):
    """Write text to path through a temp file in the same directory. replace=False never overwrites."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if replace:
            os.replace(tmp, path)
        else:
            os.link(tmp, path)  # fails if path exists: no clobber
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def ensure_config(path):
    """Create the commented default config when missing. Returns True if created. Never raises."""
    path = Path(path)
    if path.exists():
        return False
    try:
        _atomic_write(path, DEFAULT_TOML, replace=False)
        return True
    except FileExistsError:
        return False
    except OSError as ex:
        print(f"kaos-launcher: cannot create {path}: {ex}", file=sys.stderr)
        return False


def _coerce(value, kind, lo, hi, default):
    if kind == "bool":
        return value if isinstance(value, bool) else default
    if kind == "str":
        return value.strip() or default if isinstance(value, str) else default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    if not math.isfinite(value):
        return default
    value = min(max(value, lo), hi)
    return round(value) if kind == "int" else float(value)


def parse_config(text):
    """TOML text -> full settings dict. Invalid TOML or values fall back to defaults per key."""
    out = defaults()
    try:
        raw = tomllib.loads(text)
    except tomllib.TOMLDecodeError as ex:
        print(f"kaos-launcher: invalid config, using defaults: {ex}", file=sys.stderr)
        return out
    for key, (default, kind, lo, hi) in SETTINGS.items():
        if key in raw:
            out[key] = _coerce(raw[key], kind, lo, hi, default)
    return out


def load_config(path=None):
    """Create the default file on first run, then read it. Never raises."""
    path = Path(path) if path else config_path()
    ensure_config(path)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as ex:
        print(
            f"kaos-launcher: cannot read {path}, using defaults: {ex}", file=sys.stderr
        )
        return defaults()
    return parse_config(text)


# ---- state -----------------------------------------------------------------
def parse_state(text, recent_count=5):
    """JSON text -> {"planet": str|None, "recent": [desktop ids, newest first]}. Corrupt -> empty state."""
    out = {"planet": None, "recent": []}
    try:
        raw = json.loads(text)
    except ValueError:
        return out
    if not isinstance(raw, dict):
        return out
    if isinstance(raw.get("planet"), str) and raw["planet"]:
        out["planet"] = raw["planet"]
    recent = raw.get("recent")
    if isinstance(recent, list):
        seen = []
        for r in recent:
            if isinstance(r, str) and r and r not in seen:
                seen.append(r)
        out["recent"] = seen[: max(0, recent_count)]
    return out


def load_state(path=None, recent_count=5):
    path = Path(path) if path else state_path()
    try:
        return parse_state(path.read_text(encoding="utf-8"), recent_count)
    except (OSError, UnicodeDecodeError):
        return parse_state("", recent_count)


def save_state(state, path=None):
    path = Path(path) if path else state_path()
    try:
        _atomic_write(path, json.dumps(state, ensure_ascii=False, indent=1) + "\n")
        return True
    except OSError as ex:
        print(f"kaos-launcher: cannot write {path}: {ex}", file=sys.stderr)
        return False


def with_launch(state, app_id, recent_count):
    recent = [app_id] + [r for r in state["recent"] if r != app_id]
    return {**state, "recent": recent[: max(0, recent_count)]}


def data_dirs():
    home = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    dirs = [home] + [
        Path(d)
        for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(
            ":"
        )
        if d
    ]
    if Path("/usr/share") not in dirs:
        dirs.append(Path("/usr/share"))
    seen, out = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d / "applications")
    return out


def read_entry(path):
    cp = configparser.RawConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    try:
        cp.read(path, encoding="utf-8")
        e = cp["Desktop Entry"]
    except (configparser.Error, KeyError, UnicodeDecodeError, OSError):
        return None
    return e


def pick_group(cats):
    cs = set(cats)
    for name, members in GROUPS:
        if cs & members:
            return name
    return FALLBACK


def parse_keywords(e):
    """Keywords= plus GenericName= as a list of strings (empty when neither is set)."""
    out = [k.strip() for k in e.get("Keywords", "").split(";") if k.strip()]
    generic = e.get("GenericName", "").strip()
    if generic:
        out.append(generic)
    return out


# ---- icons -----------------------------------------------------------------
ICON_SIZE = (
    64  # wanted size in px; the billboards are small, 64 stays sharp up to ~2x zoom
)
ICON_EXTS = (".png", ".svg")  # xpm is not loadable by Qt Quick 3D textures


def icon_base_dirs():
    """Icon theme search path (freedesktop): ~/.icons, $XDG_DATA_HOME/icons, each data dir's icons."""
    home = Path.home()
    xdg_home = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
    dirs = [home / ".icons", xdg_home / "icons"] + [
        d.parent / "icons" for d in data_dirs()[1:]
    ]
    seen, out = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            out.append(d)
    return out


def _dir_distance(kind, size, lo, hi, thr, want):
    """Freedesktop icon-theme spec: how far a directory's sizes are from the wanted size."""
    if kind == "Fixed":
        return abs(size - want)
    if kind == "Scalable":
        return lo - want if want < lo else want - hi if want > hi else 0
    return max(0, abs(want - size) - thr)  # Threshold


class IconTheme:
    """One icon theme: its Inherits list and its directories sorted best-first for the wanted size."""

    def __init__(self, name, base_dirs, want=ICON_SIZE):
        self.name, self.inherits, self.dirs = (
            name,
            [],
            [],
        )  # dirs: [Path relative to the theme dir]
        self.roots = []  # existing theme directories (one per base dir)
        for b in base_dirs:
            idx = b / name / "index.theme"
            if not idx.is_file():
                continue
            self.roots.append(b / name)
            cp = configparser.RawConfigParser(strict=False, interpolation=None)
            cp.optionxform = str
            try:
                cp.read(idx, encoding="utf-8")
                head = cp["Icon Theme"]
            except (configparser.Error, KeyError, UnicodeDecodeError, OSError):
                continue
            if not self.inherits:
                self.inherits = [
                    x.strip() for x in head.get("Inherits", "").split(",") if x.strip()
                ]
            for d in (
                x.strip() for x in head.get("Directories", "").split(",") if x.strip()
            ):
                sec = cp[d] if cp.has_section(d) else None
                if sec is None:
                    continue
                try:
                    size = int(sec.get("Size", "0"))
                    if int(sec.get("Scale", "1")) != 1 or size <= 0:
                        continue
                    kind = sec.get("Type", "Threshold")
                    lo, hi = (
                        int(sec.get("MinSize", size)),
                        int(sec.get("MaxSize", size)),
                    )
                    thr = int(sec.get("Threshold", "2"))
                except ValueError:
                    continue
                key = (
                    _dir_distance(kind, size, lo, hi, thr, want),
                    0 if sec.get("Context", "") == "Applications" else 1,
                    0 if kind == "Scalable" else 1,
                    -size,
                )
                self.dirs.append((key, d))
        self.dirs.sort()

    def find(self, name):
        for _key, d in self.dirs:
            for root in self.roots:
                for ext in ICON_EXTS:
                    p = root / d / (name + ext)
                    if p.is_file():
                        return str(p)
        return ""


class IconResolver:
    """name -> file path following the theme and its Inherits chain, then hicolor, then loose files. Cached."""

    def __init__(self, theme="auto", base_dirs=None, pixmap_dirs=None, want=ICON_SIZE):
        self.base = list(base_dirs) if base_dirs is not None else icon_base_dirs()
        self.pix = (
            list(pixmap_dirs)
            if pixmap_dirs is not None
            else [d.parent / "pixmaps" for d in data_dirs()[1:]]
        )
        self.want = want
        self.chain = self._chain(
            active_icon_theme() if theme in ("", "auto") else theme
        )
        self.cache = {}

    def _chain(self, theme):
        out, todo = [], [theme]
        while todo:
            n = todo.pop(0)
            if n in [t.name for t in out]:
                continue
            t = IconTheme(n, self.base, self.want)
            if t.roots:
                out.append(t)
                todo = t.inherits + todo
        if "hicolor" not in [t.name for t in out]:
            h = IconTheme("hicolor", self.base, self.want)
            if h.roots:
                out.append(h)
        return out

    def resolve(self, name):
        name = (name or "").strip()
        if not name:
            return ""
        if name.startswith("/"):
            return (
                name
                if os.path.isfile(name) and name.lower().endswith(ICON_EXTS)
                else ""
            )
        if name in self.cache:
            return self.cache[name]
        found = ""
        for t in self.chain:
            found = t.find(name)
            if found:
                break
        if not found:
            for d in (
                self.pix + self.base
            ):  # /usr/share/pixmaps and loose files in the icons dirs
                for ext in ICON_EXTS:
                    if (d / (name + ext)).is_file():
                        found = str(d / (name + ext))
                        break
                if found:
                    break
        self.cache[name] = found
        return found


def active_icon_theme():
    """Icon theme of the session: GTK 3 settings.ini, then gsettings, else hicolor. Never raises."""
    ini = _xdg("XDG_CONFIG_HOME", ".config") / "gtk-3.0" / "settings.ini"
    try:
        for line in ini.read_text(encoding="utf-8").splitlines():
            k, _, v = line.partition("=")
            if k.strip() == "gtk-icon-theme-name" and v.strip():
                return v.strip()
    except (OSError, UnicodeDecodeError):
        pass
    try:
        r = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        v = r.stdout.strip().strip("'\"")
        if r.returncode == 0 and v:
            return v
    except (OSError, subprocess.SubprocessError):
        pass
    return "hicolor"


def resolve_icon(name, resolver=None):
    """Icon= value -> file path or "". Absolute paths must exist; names follow the active theme."""
    return (resolver or IconResolver()).resolve(name)


def build_graph(icons=True, icon_theme="auto"):
    resolver = IconResolver(icon_theme) if icons else None
    apps = {}
    for d in data_dirs():  # earlier dirs override later ones by desktop id
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.desktop")):
            did = str(p.relative_to(d)).replace("/", "-")
            if did in apps:
                continue
            apps[did] = p
    nodes, edges, groups = [], [], {}
    for did, p in apps.items():
        e = read_entry(p)
        if e is None or e.get("Type", "Application") != "Application":
            continue
        if (
            e.get("NoDisplay", "").lower() == "true"
            or e.get("Hidden", "").lower() == "true"
        ):
            continue
        if not e.get("Name") or not e.get("Exec"):
            continue
        cats = [c for c in e.get("Categories", "").split(";") if c]
        g = pick_group(cats)
        groups.setdefault(g, 0)
        groups[g] += 1
        nodes.append(
            {
                "id": did,
                "type": "app",
                "label": e["Name"],
                "comment": e.get("Comment", ""),
                "keywords": parse_keywords(e),
                "icon": resolver.resolve(e.get("Icon", "")) if resolver else "",
                "path": str(p),
                "group": g,
            }
        )
        edges.append({"source": "cat:" + g, "target": did})
    cat_nodes = [
        {"id": "cat:" + g, "type": "category", "label": g, "count": n}
        for g, n in sorted(groups.items())
    ]
    return {"nodes": cat_nodes + nodes, "edges": edges}


def clean_exec(exec_line):
    argv = shlex.split(exec_line)
    out = []
    for a in argv:
        if a in CODES:
            continue
        a = a.replace("%%", "\0")
        for c in CODES:
            a = a.replace(c, "")
        out.append(a.replace("\0", "%"))
    return out


def find_terminal(setting="auto"):
    """Terminal to use. setting: "auto" (detect) or a command name/path; an unusable one falls back to auto."""
    if setting and setting != "auto":
        if shutil.which(setting):
            return setting
        print(
            f"kaos-launcher: terminal '{setting}' not found, detecting", file=sys.stderr
        )
    t = os.environ.get("TERMINAL", "")
    cands = ([t] if t else []) + TERMINALS
    for c in cands:
        if shutil.which(c):
            return c
    return None


def launch(path, terminal="auto", app_id=None, planet=None, recent_count=5):
    e = read_entry(path)
    if e is None:
        sys.exit("cannot read " + path)
    argv = clean_exec(e.get("Exec", ""))
    if not argv:
        sys.exit("empty Exec in " + path)
    if e.get("Terminal", "").lower() == "true":
        term = find_terminal(terminal)
        if not term:
            sys.exit("Terminal=true but no terminal emulator found")
        argv = [term, "-e"] + argv
    cwd = e.get("Path") or None
    if cwd and not os.path.isdir(cwd):
        cwd = None
    try:
        subprocess.Popen(
            argv,
            cwd=cwd,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as ex:
        sys.exit(f"launch failed: {ex}")
    if app_id:  # only launches made from kaos-launcher are recorded
        st = with_launch(load_state(recent_count=recent_count), app_id, recent_count)
        if planet:
            st["planet"] = planet
        save_state(st)


def init(save_planet=None):
    cfg = load_config()
    state = load_state(recent_count=cfg["recent_count"])
    if save_planet and save_planet != state["planet"]:
        state["planet"] = save_planet
        save_state(state)
    return {
        "config": cfg,
        "state": state,
        "graph": build_graph(cfg["icons"], cfg["icon_theme"]),
    }


def init_state_only(planet):
    state = load_state(recent_count=load_config()["recent_count"])
    state["planet"] = planet
    save_state(state)


def main(argv):
    ap = argparse.ArgumentParser(prog="kaos_launcher.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("graph")
    p = sub.add_parser("init")
    p.add_argument("--save-planet")
    p = sub.add_parser("save")
    p.add_argument("--planet", required=True)
    p = sub.add_parser("launch")
    p.add_argument("path")
    p.add_argument("--id")
    p.add_argument("--planet")
    args = ap.parse_args(argv[1:])
    if args.cmd == "graph":
        json.dump(build_graph(), sys.stdout, ensure_ascii=False)
    elif args.cmd == "save":
        init_state_only(args.planet)
    elif args.cmd == "init":
        json.dump(init(args.save_planet), sys.stdout, ensure_ascii=False)
    else:
        cfg = load_config()
        launch(args.path, cfg["terminal"], args.id, args.planet, cfg["recent_count"])


if __name__ == "__main__":
    main(sys.argv)
