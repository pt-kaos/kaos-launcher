# Changelog

## Unreleased

- `install.sh`: installs the `kaos-launcher` command as a symlink (default `~/.local/bin`, `--bin-dir`, `$KAOS_BIN_DIR`), idempotent, refuses to replace
  other files or links without `--force`, checks dependencies and `PATH` without installing anything; `uninstall` removes only its own link
  (`--purge` also removes config and state after confirmation), offers to stop a running instance of this app only; `status`, `--dry-run`.
  Tested by `install.test.sh` in temporary directories.

## 0.2.0 - 2026-11-22

Adds a second visual style, "sphere", next to the solar style. Solar behaves as in 0.1.0.

- **Styles.** New config key `style` (`"solar"` default, `"sphere"`). F2 swaps the style live and saves the choice in `state.json`
  (never in `config.toml`); `kaos-launcher --style solar|sphere` / `KAOS_STYLE` overrides it for one run (a resident instance
  receives it over IPC). Precedence: one-run override, saved style, config.
- **Controller and scenes.** `Launcher.qml` is now a style-independent controller (data, search, launching, keys, status); the 3D
  scenes are `SolarScene.qml` (the 0.1.0 scene, moved unchanged) and `SphereScene.qml`, behind a small documented scene interface.
- **Sphere style.** A glowing particle sphere (soft round dots drawn as camera-facing instanced quads with a small custom shader,
  amber with cyan patches, tinted towards the focused category, a bright core that shows the selected app's name) with
  two rings seen from below, so the selected item is at the top:
  - the **inner ring** holds every app that is not a hexagon, in category arcs (uppercase label, thin category stripe), with a
    fisheye layout so a 40+ app category stays readable;
  - the **outer orbit** holds the most recent apps as glowing hexagons: evenly spaced, grouped by category with one uppercase
    label per group and thin connector lines, brightness by recency, tilted the other way from the inner ring, the back half dimmed
    and really behind the sphere (an opaque disc and plates hide what is behind it, with a fixed layer order).
- **Two views.** Recents (sphere + orbit, the inner ring as a quiet band) and All apps (camera zoom 1.45, bigger icons, orbit hidden).
  Tab / Shift+Tab toggle them; every show opens in Recents when there are recents, else in All apps; a search goes to the view of
  its best match; the mouse and keys work in the visible view only.
- **Launch pulse**: the sphere swells and its core flares for about 0.4 s before the panel hides.
- **HUD**: corner brackets, a dim static starfield (`starfield`), no tooltip (the selected app's name is in the core, the group name on the labels),
  an optional open animation (`open_animation`, default on; the particles assemble in under 0.3 s).
- **New config keys**: `style`, `hex_count` (0-20, default 20), `open_animation`, `name_plate` (default off), and the sphere palette `color_main`,
  `color_accent`, `color_base` (hex strings, validated, invalid values fall back per key).
- **State.** `state.json` now always keeps the last 20 launches (independent of `recent_count`, which keeps its meaning for the
  solar glow) and an optional `style` field. Older files load unchanged.
- **Tools.** `KAOS_DEBUG=1` also logs a frame-rate estimate every 2 s and the first-frame time; `sphere.js` holds the pure layout
  logic with 100+ node tests (ring, orbit, labels, connectors, views, occlusion, brackets, starfield, layer order).

## 0.1.0 - 2026-11-08

Initial release.

- 3D "solar system" launcher (Qt Quick 3D inside a standalone Quickshell window): categories are planets on a ring
  around a sun, the apps of the focused planet orbit it as moons.
- Mouse (drag, click to launch, hover tooltip) and keyboard (arrows, Enter, Escape) control.
- Type-to-search with fuzzy ranking on name, keywords and comment; the camera flies to the best match.
- Icons from the freedesktop icon theme (active theme, Inherits chain, hicolor), plain spheres as fallback.
- Resident background mode with IPC toggle, single instance, `kaos-launcher` wrapper script.
- `config.toml` (created with commented defaults on first run) and `state.json` (last planet, recent launches).
- Terminal=true apps are wrapped in a detected or configured terminal.
- Starfield, glows, recent-app highlight.
