# Changelog

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
