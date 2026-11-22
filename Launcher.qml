import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import "search.js" as Search

// kaos-launcher controller: scene-agnostic. It owns data load/reload, search, launching, all keyboard Shortcuts,
// the search line and the status/toast text. The visual scene is loaded through a Loader chosen by `style`.
// Window-agnostic Item: shell.qml hosts it in a FloatingWindow (a layer-shell host can replace that file).
//
// Scene interface (SolarScene.qml, SphereScene.qml). The scene is an Item with:
//   property var ctl            set by the controller (a reference to this Item); the scene reads planets, focusIdx, selIdx, selApp,
//                               query, matches, focusMatch, planetMatches, searching, recentIds, cfg, awake, space, focusApps, focusR,
//                               and calls launchApp(app) and dbg(msg). It writes focusIdx (when its focus settles) and selIdx.
//   readonly property bool settled   true while a moon/app selection is allowed (not mid-rotation)
//   function stepBy(d)          Left/Right: move focus d categories (animated)
//   function goTo(pi, ai)       fly focus to category pi (search / match cycling); ai is the app index inside it
//   function pickAt(x, y)       topmost pickable object under the scene point, or null (debug self-test)
//   function reset()            snap to ctl.focusIdx without animation (after (re)load, and right after the scene is created)
//   function clearHover()       drop any mouse-hover state (keyboard took over, search typed, panel hidden)
// Optional, sphere style only (solar defines none of these, so Tab, zones and the launch pulse do nothing there):
//   readonly property bool hasZones   the scene has two views; ctl.zone is "hex" (Recents: the outer orbit of recent apps)
//                               or "ring" (All apps: the zoomed inner ring). Tab / Shift+Tab toggle; the scene sets the
//                               zone itself on open (reset()) and from search matches (goTo())
//   function setZone(z)         switch view (ignored when there are no recent apps)
//   readonly property string hint   optional text for the bottom hint line (solar has none and keeps the default)
//   function cycleSel(d)        Up/Down without a search: step the selection inside the active zone (the controller's own
//                               focusApps/selIdx stepping is bypassed, since hex apps are not in the ring)
//   function currentApp()       the app Enter launches without a search (the active zone's selection), or null
//   readonly property int pulseMs   > 0: launchApp emits launched() and delays closing by this long so the scene can pulse
Item {
    id: win
    focus: true

    // ---- settings: user options come from config.toml (kaos_launcher.py init); these are the fixed look constants ----
    property var cfg: ({
        run_in_background: true, recent_count: 5, panel_size_percent: 50, close_after_launch: true,
        orbit_speed: 1.0, starfield: true, icons: true, terminal: "auto", drag_speed: 0.25, tooltip_font_size: 11, style: "solar", hex_count: 20, open_animation: true, name_plate: false,
        color_main: "#ff9a3c", color_accent: "#3cd6ff", color_base: "#0a0d12"
    })
    property bool awake: true       // false while the panel is hidden: animations pause
    property bool loaded: false     // first init result applied
    property var recentIds: []      // desktop ids launched from kaos-launcher, newest first (full history, up to 20)
    readonly property int historyLimit: 20
    signal closeRequested()         // Escape / launch: the host hides the window or quits
    signal launched()               // an app was launched from this panel (before the optional delayed close)
    property string zone: "ring"    // sphere style: active keyboard zone, "ring" or "hex"
    readonly property bool debug: Quickshell.env("KAOS_DEBUG") === "1"
    readonly property color space: "#05060b"
    readonly property var palette: ["#e5836b", "#e0b25a", "#8cc46a", "#5bbfa6", "#5aa9e0", "#8a8ae6", "#c780e0", "#e07aa6", "#a0a8b8", "#d0d0a0"]

    // ---- style: precedence (same as kaos_launcher.effective_style): KAOS_STYLE / IPC override (one run, not saved),
    // then the style saved in state.json by F2, then `style` in config.toml ----
    readonly property var styles: ["solar", "sphere"]
    property string styleOverride: ""   // set by shell.qml from KAOS_STYLE, or over IPC by `kaos-launcher --style`
    property string savedStyle: ""      // state.json "style" ("" = none)
    property string style: "solar"
    readonly property var sc: sceneLoader.item   // the active scene (null while loading)
    function baseStyle() {   // evaluated on demand: a readonly binding can still be stale inside onStyleOverrideChanged
        for (const v of [styleOverride, savedStyle, cfg.style]) if (styles.indexOf(v) >= 0) return v;
        return "solar";
    }
    function applyBaseStyle() { style = baseStyle(); dbg("style = " + style); }
    function toggleStyle() {   // F2: swap and save to state.json (an explicit choice also ends a one-run override)
        const next = style === "solar" ? "sphere" : "solar";
        savedStyle = next; styleOverride = ""; style = next;
        dbg("style -> " + next + " (saved)");
        pendingStyle = next; pumpStyle();
    }
    property string pendingStyle: ""
    function pumpStyle() {
        if (pendingStyle === "" || styleProc.running) return;
        styleProc.command = ["python3", "-I", dir + "/kaos_launcher.py", "save", "--style", pendingStyle];
        pendingStyle = "";
        styleProc.running = true;
    }
    onStyleOverrideChanged: applyBaseStyle()

    function dbg(msg) { if (debug) console.log("[kaos] " + msg); }

    readonly property string dir: Quickshell.shellDir
    property var planets: []        // {id,label,count,color,r,apps:[{label,comment,path,...}]}
    property int focusIdx: 0        // settled focus
    property int selIdx: -1         // keyboard-selected app of the focused category (no search active); -1 = none
    property string query: ""       // search text
    property var matches: []        // [{pi, ai, score}] best first, from search.js
    property int matchPos: 0        // selected match while searching (Up/Down cycle matches)
    readonly property bool searching: query.trim() !== ""
    // app of the focused category that is selected: by match while searching, else by selIdx
    readonly property int selApp: {
        if (searching) {
            const m = matches[matchPos];
            return m && m.pi === focusIdx ? m.ai : -1;
        }
        return selIdx < focusApps.length ? selIdx : -1;
    }
    // per moon of the focused planet: does it match the search (all true when not searching)
    readonly property var focusMatch: {
        const out = focusApps.map(() => !searching);
        if (searching) for (const m of matches) if (m.pi === focusIdx) out[m.ai] = true;
        return out;
    }
    // planet index -> number of matches, for the labels
    readonly property var planetMatches: {
        const out = planets.map(() => 0);
        for (const m of matches) out[m.pi]++;
        return out;
    }
    property string status: "Loading..."
    readonly property var focusApps: planets.length > 0 ? planets[focusIdx].apps : []
    readonly property real focusR: planets.length > 0 ? planets[focusIdx].r : 30

    function mod(a, n) { return ((a % n) + n) % n; }

    function load(text) {
        let g, init;
        try { init = JSON.parse(text); g = init.graph; } catch (e) { status = "Bad JSON from generator: " + e; return; }
        cfg = Object.assign({}, cfg, init.config);
        recentIds = init.state.recent || [];
        if (pendingStyle === "" && !styleProc.running) savedStyle = init.state.style || "";   // else keep the local F2 choice
        applyBaseStyle();
        const apps = g.nodes.filter(n => n.type === "app");
        const cats = g.nodes.filter(n => n.type === "category");
        planets = cats.map((c, k) => ({
            id: c.id, label: c.label, count: c.count,
            color: palette[k % palette.length],
            r: Math.min(30, 14 + Math.sqrt(c.count) * 2.4),
            apps: apps.filter(a => a.group === c.label)
        }));
        // open on the last focused planet, no fly-in
        let start = planets.findIndex(p => p.label === init.state.planet);
        if (start < 0) start = 0;
        focusIdx = start;
        selIdx = -1; query = ""; matches = []; matchPos = 0; zone = "ring";
        if (sc) sc.reset();
        status = apps.length + " apps";
        if (debug && loadT === 0) loadT = Date.now();
        loaded = true;
    }

    // ---- reload / hide / quit plumbing ----
    property bool reloadPending: false
    property string saveLabel: ""
    property bool quitting: false
    function requestReload(label) {   // re-run init (rescans apps, re-reads config and state), saving the focused planet first
        saveLabel = label; reloadPending = true; pump();
    }
    function pump() {
        if (!reloadPending || launcher.running || initProc.running) return;
        reloadPending = false;
        initProc.command = ["python3", "-I", dir + "/kaos_launcher.py", "init"].concat(saveLabel !== "" ? ["--save-planet", saveLabel] : []);
        initProc.running = true;
    }
    function hidden() {   // host hid the window: reset the view and refresh data so the next show is instant
        selIdx = -1; query = ""; matches = []; matchPos = 0; zone = "ring";
        if (sc) sc.clearHover();
        requestReload(planets.length > 0 ? planets[focusIdx].label : "");
    }
    function quit() {     // host is exiting (run_in_background = false): save the planet, then quit
        quitting = true;
        if (launcher.running) return;
        if (planets.length === 0) { Qt.quit(); return; }
        saveProc.command = ["python3", "-I", dir + "/kaos_launcher.py", "save", "--planet", planets[focusIdx].label];
        saveProc.running = true;
    }

    // ---- navigation: forwarded to the scene ----
    function stepBy(d) { if (sc) sc.stepBy(d); }
    function goTo(pi, ai) { if (sc) sc.goTo(pi, ai); }
    function pickAt(x, y) { return sc ? sc.pickAt(x, y) : null; }

    function selectedApp() {
        if (searching) {
            const m = matches[matchPos];
            return m ? planets[m.pi].apps[m.ai] : null;
        }
        if (sc && sc.hasZones) return sc.currentApp();
        return selIdx >= 0 && selIdx < focusApps.length ? focusApps[selIdx] : null;
    }

    function setQuery(q) {
        query = q;
        matches = Search.rank(planets, q);
        matchPos = 0;
        if (sc) sc.clearHover();
        if (matches.length > 0) goTo(matches[0].pi, matches[0].ai);
        dbg("search '" + q + "' -> " + matches.length + " matches" + (matches.length > 0
            ? ", best " + planets[matches[0].pi].apps[matches[0].ai].label + " (planet " + planets[matches[0].pi].label + ")" : ""));
    }
    function typeChar(t) { setQuery(query + t); }
    function backspace() { if (query !== "") setQuery(query.slice(0, -1)); }
    function clearSearch() {
        if (searching) selIdx = selApp;   // keep the selected moon selected after the search ends
        query = ""; matches = []; matchPos = 0;
    }
    function escapeKey() {
        if (query !== "") { dbg("Escape: clear search"); clearSearch(); }
        else { dbg("Escape: close"); closeRequested(); }
    }

    function cycle(d) {   // Up/Down: matches while searching, else the apps of the focused category
        if (sc) sc.clearHover();
        if (searching) {
            if (matches.length === 0) return;
            matchPos = mod(matchPos + d, matches.length);
            goTo(matches[matchPos].pi, matches[matchPos].ai);
            dbg("select match " + matchPos + "/" + matches.length + " " + selectedApp().label);
        } else if (sc && sc.hasZones) {
            if (sc.settled) sc.cycleSel(d);
        } else if (focusApps.length > 0 && sc && sc.settled) {
            selIdx = selIdx < 0 ? (d > 0 ? 0 : focusApps.length - 1) : mod(selIdx + d, focusApps.length);
            dbg("select moon " + selIdx + " " + focusApps[selIdx].label);
        }
    }
    function launchSelected() {
        const a = selectedApp();
        if (!a) return;
        dbg("Enter: launch " + a.label);
        launchApp(a);
    }

    function launchApp(a) {
        if (launcher.running) return;
        launcher.command = ["python3", "-I", dir + "/kaos_launcher.py", "launch", a.path, "--id", a.id, "--planet", a.group];
        launcher.running = true;
        recentIds = [a.id].concat(recentIds.filter(x => x !== a.id)).slice(0, historyLimit);
        status = "Launched " + a.label;
        toastTimer.restart();
        launched();
        if (!cfg.close_after_launch) return;
        if (sc && sc.pulseMs > 0) closeTimer.restart();   // let the scene pulse first
        else closeRequested();
    }
    function toggleZone() {   // Tab / Shift+Tab (sphere style only; not while searching, where the match decides the zone)
        if (searching || !sc || !sc.hasZones) return;
        sc.setZone(zone === "ring" ? "hex" : "ring");
        dbg("zone -> " + zone);
    }

    Process {
        id: initProc
        stdout: StdioCollector { onStreamFinished: win.load(text) }
        stderr: StdioCollector { onStreamFinished: if (text !== "") { win.status = "Generator: " + text; win.dbg("generator stderr: " + text); } }
        onExited: win.pump()
    }
    Process {
        id: launcher
        onExited: { if (win.quitting) win.quit(); else win.pump(); }
    }
    Process { id: saveProc; onExited: Qt.quit() }
    Process { id: styleProc; onExited: win.pumpStyle() }

    // KAOS_DEBUG=1: scripted keyboard/search self-test through the real handlers (not input injection).
    // Query from KAOS_DEBUG_QUERY (default "ff"). Steps run every 700 ms starting 4 s after launch.
    Timer {
        id: searchTest
        property int step: 0
        interval: 700; running: false; repeat: true
        onTriggered: {
            const log = tag => win.dbg("selftest2 " + tag + ": focus=" + (win.planets[win.focusIdx] ? win.planets[win.focusIdx].label : "-")
                + " selApp=" + win.selApp + " query='" + win.query + "' matches=" + win.matches.length + " matchPos=" + win.matchPos);
            switch (step++) {
            case 0: win.cycle(1); log("down (no search)"); break;
            case 1: win.cycle(-1); log("up (no search)"); break;
            case 2: for (const ch of (Quickshell.env("KAOS_DEBUG_QUERY") || "ff")) win.typeChar(ch); log("typed"); break;
            case 3: log("after fly"); break;
            case 4: win.cycle(1); log("down (next match)"); break;
            case 5: win.backspace(); log("backspace"); break;
            case 6: win.escapeKey(); log("escape 1 (clears)"); break;
            case 7: win.stepBy(1); log("right"); break;
            default: stop(); win.dbg("selftest2 done (second Escape would close)");
            }
        }
    }
    Timer { interval: 4000; running: win.debug; repeat: false; onTriggered: searchTest.running = true }
    Timer { id: closeTimer; interval: sc && sc.pulseMs > 0 ? sc.pulseMs : 1; onTriggered: win.closeRequested() }
    // KAOS_DEBUG=1: frame rate estimate every 2 s (the FrameAnimation keeps the window rendering continuously, so this is the display
    // rate while the scene keeps up; compare styles and views by it and by CPU use; GPU load is not measured)
    property int frames: 0
    property double loadT: 0       // debug: time of the first load, to log how long the first frame after it takes (includes shader compiles)
    Connections {
        target: win.Window.window
        enabled: win.debug && win.loadT > 0
        function onFrameSwapped() { win.dbg("first frame " + (Date.now() - win.loadT) + " ms after the first load (style " + win.style + ")"); win.loadT = -1; }
    }
    FrameAnimation { running: win.debug && win.awake; onTriggered: win.frames++ }
    Timer {
        interval: 2000; running: win.debug && win.awake; repeat: true
        onTriggered: { win.dbg("fps " + (win.frames / 2).toFixed(1) + " (style " + win.style + ", zone " + win.zone + ")"); win.frames = 0; }
    }
    Timer { id: toastTimer; interval: 2500; onTriggered: win.status = win.planets.length > 0 ? win.planets[win.focusIdx].label : "" }
    // Keys are WindowShortcuts, not Keys handlers: they fire whatever item (or none) has active focus,
    // so clicks, drags, hover and the tooltip cannot lose them.
    Shortcut { sequence: "Escape"; context: Qt.WindowShortcut; onActivated: win.escapeKey() }
    Shortcut { sequence: "Left"; context: Qt.WindowShortcut; onActivated: { win.dbg("key Left"); win.stepBy(-1); } }
    Shortcut { sequence: "Right"; context: Qt.WindowShortcut; onActivated: { win.dbg("key Right"); win.stepBy(1); } }
    Shortcut { sequence: "Up"; context: Qt.WindowShortcut; onActivated: win.cycle(-1) }
    Shortcut { sequence: "Down"; context: Qt.WindowShortcut; onActivated: win.cycle(1) }
    Shortcut { sequence: "Return"; context: Qt.WindowShortcut; onActivated: win.launchSelected() }
    Shortcut { sequence: "Enter"; context: Qt.WindowShortcut; onActivated: win.launchSelected() }
    Shortcut { sequence: "Tab"; context: Qt.WindowShortcut; onActivated: win.toggleZone() }
    Shortcut { sequence: "Shift+Tab"; context: Qt.WindowShortcut; onActivated: win.toggleZone() }
    Shortcut { sequence: "F2"; context: Qt.WindowShortcut; onActivated: win.toggleStyle() }
    Shortcut { sequence: "Backspace"; context: Qt.WindowShortcut; onActivated: win.backspace() }
    // Search input: one window Shortcut per plain key (a TextInput would swallow Left/Right/Backspace).
    // Shift/other characters fall through to Keys.onPressed below.
    Instantiator {
        model: "abcdefghijklmnopqrstuvwxyz0123456789-.,/'".split("")
        property int added: 0
        onObjectAdded: { added++; if (added === model.length) win.dbg("search key shortcuts registered: " + added); }
        delegate: Shortcut {
            required property string modelData
            sequence: modelData
            context: Qt.WindowShortcut
            onActivated: win.typeChar(modelData)
        }
    }
    Shortcut { sequence: "Space"; context: Qt.WindowShortcut; onActivated: if (win.query !== "") win.typeChar(" ") }
    // debug only: log every key that reaches the item tree, and focus changes
    Keys.onPressed: e => {
        win.dbg("Keys.onPressed key=" + e.key + " text='" + e.text + "' (item activeFocus=" + win.activeFocus + ")");
        const plain = !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
        if (plain && e.text.length === 1 && e.text >= " " && e.text !== "\u007f") {   // Shift+letter, accents, symbols
            win.typeChar(e.text);
            e.accepted = true;
        }
    }
    onActiveFocusChanged: dbg("scene activeFocus=" + activeFocus)
    Component.onCompleted: { forceActiveFocus(); requestReload(""); dbg("completed, activeFocus=" + activeFocus); }
    Connections {
        target: win.Window.window
        function onActiveChanged() { win.dbg("window active=" + win.Window.window.active); if (win.Window.window.active) win.forceActiveFocus(); }
    }

    Loader {
        id: sceneLoader
        anchors.fill: parent
        sourceComponent: win.style === "sphere" ? sphereScene : solarScene
        onLoaded: {   // a live style swap while searching: fly the new scene to the current match
            const m = win.matches[win.matchPos];
            if (win.searching && m) item.goTo(m.pi, m.ai);
        }
    }
    Component { id: solarScene; SolarScene { ctl: win } }
    Component { id: sphereScene; SphereScene { ctl: win } }

    // search line
    Rectangle {
        visible: win.query !== ""
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
        width: Math.min(win.width * 0.8, sline.implicitWidth + 28)
        height: sline.implicitHeight + 14
        radius: 8
        color: "#e00c1020"
        border.color: win.matches.length > 0 ? "#c8d0e8" : "#e07070"
        Text {
            id: sline
            anchors.centerIn: parent
            width: parent.width - 28
            elide: Text.ElideLeft
            color: win.matches.length > 0 ? "#ffffff" : "#e08a8a"
            font.pixelSize: Math.max(14, win.height * 0.032)
            text: win.query + "\u258f   " + (win.matches.length > 0
                ? (win.matchPos + 1) + "/" + win.matches.length : "no match")
        }
    }

    Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 10 }
        color: "#6a7080"
        font.pixelSize: 12
        text: win.status + "   |   " + (sc && sc.hint ? sc.hint : "arrows: rotate / select   type: search   Enter: launch   Esc: clear/close")
    }
}
