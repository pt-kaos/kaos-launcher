import QtQuick
import QtQuick3D
import QtQml
import Quickshell
import Quickshell.Io
import "search.js" as Search

// kaos-launcher scene: sun at the centre, categories (planets) on a ring, apps (moons) orbit the focused planet.
// Window-agnostic Item: shell.qml hosts it in a FloatingWindow (a layer-shell host can replace that file).
Item {
    id: win
    focus: true

    // ---- settings: user options come from config.toml (kaos_launcher.py init); these are the fixed look constants ----
    property var cfg: ({
        run_in_background: true, recent_count: 5, panel_size_percent: 50, close_after_launch: true,
        orbit_speed: 1.0, starfield: true, icons: true, terminal: "auto", drag_speed: 0.25, tooltip_font_size: 11
    })
    property bool awake: true       // false while the panel is hidden: animations pause
    property bool loaded: false     // first init result applied
    property var recentIds: []      // desktop ids launched from kaos-launcher, newest first
    signal closeRequested()         // Escape / launch: the host hides the window or quits
    readonly property real ringRadius: 260
    readonly property real ringXScale: 0.8        // the ring is an ellipse, narrower sideways, so side planets stay inside a near-square panel
    readonly property real clickSlopPx: 6         // press-to-release movement below this is a click, not a drag
    readonly property bool debug: Quickshell.env("KAOS_DEBUG") === "1"
    readonly property color space: "#05060b"
    readonly property var palette: ["#e5836b", "#e0b25a", "#8cc46a", "#5bbfa6", "#5aa9e0", "#8a8ae6", "#c780e0", "#e07aa6", "#a0a8b8", "#d0d0a0"]

    property bool hoverQuiet: false   // debug: hover picks are not logged (only clicks and the self-test)
    function dbg(msg) { if (debug) console.log("[kaos] " + msg); }

    readonly property string dir: Quickshell.shellDir
    property var planets: []        // {id,label,count,color,r,apps:[{label,comment,path,...}]}
    property real ringAngle: 0      // degrees; planet i faces the camera when ringAngle == i * stepDeg
    property int focusIdx: 0        // settled focus
    property int pendingIdx: 0
    property bool moonsOn: true     // moons shown only while the ring is at rest
    property int hoverApp: -1
    property int selIdx: -1         // keyboard-selected moon of the focused planet (no search active); -1 = none
    property string query: ""       // search text
    property var matches: []        // [{pi, ai, score}] best first, from search.js
    property int matchPos: 0        // selected match while searching (Up/Down cycle matches)
    readonly property bool searching: query.trim() !== ""
    // moon of the focused planet that is selected: by match while searching, else by selIdx
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
    readonly property real stepDeg: planets.length > 0 ? 360 / planets.length : 360
    readonly property var focusApps: planets.length > 0 ? planets[focusIdx].apps : []
    readonly property real focusR: planets.length > 0 ? planets[focusIdx].r : 30

    function tint(c, k) { return Qt.vector3d(c.r * k, c.g * k, c.b * k); }
    function mod(a, n) { return ((a % n) + n) % n; }

    function planetPos(i, ang) {
        const a = (i * stepDeg - ang) * Math.PI / 180;
        return Qt.vector3d(ringRadius * ringXScale * Math.sin(a), 0, ringRadius * Math.cos(a));
    }

    function load(text) {
        let g, init;
        try { init = JSON.parse(text); g = init.graph; } catch (e) { status = "Bad JSON from generator: " + e; return; }
        cfg = Object.assign({}, cfg, init.config);
        recentIds = init.state.recent || [];
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
        anim.stop();
        focusIdx = start; pendingIdx = start; ringAngle = start * stepDeg; moonsOn = true;
        selIdx = -1; hoverApp = -1; query = ""; matches = []; matchPos = 0;
        status = apps.length + " apps";
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
        selIdx = -1; query = ""; matches = []; matchPos = 0; hoverApp = -1;
        requestReload(planets.length > 0 ? planets[focusIdx].label : "");
    }
    function quit() {     // host is exiting (run_in_background = false): save the planet, then quit
        quitting = true;
        if (launcher.running) return;
        if (planets.length === 0) { Qt.quit(); return; }
        saveProc.command = ["python3", "-I", dir + "/kaos_launcher.py", "save", "--planet", planets[focusIdx].label];
        saveProc.running = true;
    }

    function goCell(cell) {   // cell: unwrapped integer position of the ring
        if (planets.length === 0) return;
        moonsOn = false;
        hoverApp = -1;
        anim.stop();
        pendingIdx = mod(cell, planets.length);
        if (!searching) selIdx = -1;   // selection resets when the focused planet changes
        anim.from = ringAngle;
        anim.to = cell * stepDeg;
        anim.restart();
    }
    function curCell() { return Math.round((anim.running ? anim.to : ringAngle) / stepDeg); }
    function goPlanet(pi) {   // shortest way round to planet pi (no-op if it is already the target)
        if (planets.length === 0) return;
        const cell = curCell();
        let d = mod(pi - mod(cell, planets.length), planets.length);
        if (d > planets.length / 2) d -= planets.length;
        if (d !== 0) goCell(cell + d);
    }
    function stepBy(d) { goCell(Math.round(ringAngle / stepDeg) + d); }
    function snap() { goCell(Math.round(ringAngle / stepDeg)); }

    function selectedApp() {
        if (searching) {
            const m = matches[matchPos];
            return m ? planets[m.pi].apps[m.ai] : null;
        }
        return selIdx >= 0 && selIdx < focusApps.length ? focusApps[selIdx] : null;
    }

    function setQuery(q) {
        query = q;
        matches = Search.rank(planets, q);
        matchPos = 0;
        hoverApp = -1;
        if (matches.length > 0) goPlanet(matches[0].pi);
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

    function cycle(d) {   // Up/Down: matches while searching, else the moons of the focused planet
        hoverApp = -1;
        if (searching) {
            if (matches.length === 0) return;
            matchPos = mod(matchPos + d, matches.length);
            goPlanet(matches[matchPos].pi);
            dbg("select match " + matchPos + "/" + matches.length + " " + selectedApp().label);
        } else if (focusApps.length > 0 && moonsOn) {
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
        recentIds = [a.id].concat(recentIds.filter(x => x !== a.id)).slice(0, cfg.recent_count);
        status = "Launched " + a.label;
        toastTimer.restart();
        if (cfg.close_after_launch) closeRequested();
    }

    function pickAt(x, y) {
        const r = view.pick(x, y);
        const h = r.objectHit ? r.objectHit : null;
        if (!hoverQuiet) dbg("pick(" + Math.round(x) + "," + Math.round(y) + ") -> " + (h ? (h.kind + " #" + h.idx) : "nothing"));
        return h;
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

    // KAOS_DEBUG=1: after start, pick at the projected centre of the front planet, a side planet and moon 0 and log hits.
    Timer {
        interval: 2500; running: win.debug; repeat: false
        onTriggered: {
            const pts = [["front planet", win.planetPos(win.focusIdx, win.ringAngle)]];
            for (let i = 0; i < win.planets.length; i++) {   // every other planet whose centre is inside the view and in front
                const p = win.planetPos(i, win.ringAngle), sp = view.mapFrom3DScene(p);
                if (i !== win.focusIdx && p.z > 0 && sp.x >= 0 && sp.x <= view.width) pts.push(["planet " + i, p]);
            }
            const m = moonRep.objectAt(0);
            if (m) pts.push(["moon 0", m.probe]);
            for (const [name, p] of pts) {
                const sp = view.mapFrom3DScene(p);
                win.dbg("selftest " + name + " (view " + Math.round(view.width) + "x" + Math.round(view.height) + ") at " + Math.round(sp.x) + "," + Math.round(sp.y));
                win.pickAt(sp.x, sp.y);
            }
        }
    }
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
    Timer { id: toastTimer; interval: 2500; onTriggered: win.status = win.planets.length > 0 ? win.planets[win.focusIdx].label : "" }

    NumberAnimation {
        id: anim
        target: win
        property: "ringAngle"
        duration: 380
        easing.type: Easing.OutCubic
        onFinished: { win.focusIdx = win.pendingIdx; win.ringAngle = win.focusIdx * win.stepDeg; win.moonsOn = true; }
    }

    // Keys are WindowShortcuts, not Keys handlers: they fire whatever item (or none) has active focus,
    // so clicks, drags, hover and the tooltip cannot lose them.
    Shortcut { sequence: "Escape"; context: Qt.WindowShortcut; onActivated: win.escapeKey() }
    Shortcut { sequence: "Left"; context: Qt.WindowShortcut; onActivated: { win.dbg("key Left"); win.stepBy(-1); } }
    Shortcut { sequence: "Right"; context: Qt.WindowShortcut; onActivated: { win.dbg("key Right"); win.stepBy(1); } }
    Shortcut { sequence: "Up"; context: Qt.WindowShortcut; onActivated: win.cycle(-1) }
    Shortcut { sequence: "Down"; context: Qt.WindowShortcut; onActivated: win.cycle(1) }
    Shortcut { sequence: "Return"; context: Qt.WindowShortcut; onActivated: win.launchSelected() }
    Shortcut { sequence: "Enter"; context: Qt.WindowShortcut; onActivated: win.launchSelected() }
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

    Item {
        anchors.fill: parent

        // ---- procedural textures: painted once, shared (no image files) ----
        // planet surface: soft dark/light blotches and bands that wrap in longitude, so the spin is visible; tinted per planet
        Canvas {
            id: surfSrc
            visible: false
            width: 512; height: 256
            onPaint: {
                const c = getContext("2d"), W = width, H = height;
                let seed = 4242;
                const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
                c.fillStyle = "#c4c4c4"; c.fillRect(0, 0, W, H);
                for (let k = 0; k < 10; k++) {
                    c.fillStyle = rnd() < 0.5 ? "rgba(255,255,255,0.30)" : "rgba(30,30,30,0.32)";
                    c.fillRect(0, rnd() * H, W, 5 + rnd() * 24);
                }
                for (let k = 0; k < 90; k++) {
                    const x = rnd() * W, y = rnd() * H, rx = 10 + rnd() * 46, ry = 4 + rnd() * 14, dark = rnd() < 0.62;
                    for (const dx of [-W, 0, W]) {
                        c.save(); c.translate(x + dx, y); c.scale(1, ry / rx);
                        const g = c.createRadialGradient(0, 0, 0, 0, 0, rx);
                        g.addColorStop(0, dark ? "rgba(15,15,15,0.8)" : "rgba(255,255,255,0.75)");
                        g.addColorStop(1, dark ? "rgba(15,15,15,0)" : "rgba(255,255,255,0)");
                        c.fillStyle = g; c.beginPath(); c.arc(0, 0, rx, 0, 2 * Math.PI); c.fill(); c.restore();
                    }
                }
            }
        }
        // soft round falloff used by every glow sprite
        Canvas {
            id: glowSrc
            visible: false
            width: 128; height: 128
            onPaint: {
                const c = getContext("2d"), g = c.createRadialGradient(64, 64, 0, 64, 64, 64);
                const stops = [[0, 1], [0.15, 0.7], [0.3, 0.38], [0.5, 0.15], [0.7, 0.05], [0.85, 0.012], [1, 0]];
                for (const [p, a] of stops) g.addColorStop(p, "rgba(255,255,255," + a + ")");
                c.fillStyle = g; c.fillRect(0, 0, 128, 128);
            }
        }
        // sun core: hot centre, solid out to about 60% of the radius, then a soft fade
        Canvas {
            id: sunSrc
            visible: false
            width: 256; height: 256
            onPaint: {
                const c = getContext("2d"), g = c.createRadialGradient(128, 128, 0, 128, 128, 128);
                g.addColorStop(0, "rgba(255,250,225,1)");
                g.addColorStop(0.5, "rgba(255,226,150,1)");
                g.addColorStop(0.68, "rgba(255,205,110,0.75)");
                g.addColorStop(0.85, "rgba(255,190,90,0.25)");
                g.addColorStop(1, "rgba(255,180,80,0)");
                c.fillStyle = g; c.fillRect(0, 0, 256, 256);
            }
        }
        // stars: 1 texel = 1 screen pixel, tiled; a few brighter ones
        Canvas {
            id: starSrc
            visible: false
            width: 1024; height: 1024
            onPaint: {
                const c = getContext("2d"), W = width;
                let seed = 99;
                const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
                c.fillStyle = "#05060b"; c.fillRect(0, 0, W, W);
                const tints = ["255,255,255", "200,215,255", "255,236,210"];
                for (let k = 0; k < 420; k++) {
                    const b = 0.18 + Math.pow(rnd(), 2.5) * 0.62, sz = rnd() < 0.07 ? 2 : 1;
                    c.fillStyle = "rgba(" + tints[Math.floor(rnd() * 3)] + "," + b + ")";
                    c.fillRect(Math.floor(rnd() * W), Math.floor(rnd() * W), sz, sz);
                }
            }
        }

        View3D {
            id: view
            anchors.fill: parent
            camera: cam
            environment: SceneEnvironment {
                clearColor: win.space
                backgroundMode: SceneEnvironment.Color
                antialiasingMode: SceneEnvironment.MSAA
                antialiasingQuality: SceneEnvironment.High
            }

            PerspectiveCamera {
                id: cam
                fieldOfView: 40
                position: Qt.vector3d(0, 150, win.ringRadius + 330)
                eulerRotation.x: -19
            }
            DirectionalLight { eulerRotation.x: -25; eulerRotation.y: -20; brightness: 1.0 }
            PointLight { position: Qt.vector3d(0, 0, 0); brightness: 1.5; constantFade: 1; linearFade: 0; quadraticFade: 0 }

            Texture { id: surfTex; sourceItem: surfSrc }
            Texture { id: glowTex; sourceItem: glowSrc }
            Texture { id: sunTex; sourceItem: sunSrc }

            // starfield: one far quad facing the camera; the texture slides a little when the ring turns (static otherwise: no idle cost)
            Model {
                visible: win.cfg.starfield
                source: "#Rectangle"; pickable: false
                position: cam.position.plus(cam.forward.times(2400))
                rotation: cam.rotation
                readonly property real hgt: 2 * 2400 * Math.tan(cam.fieldOfView * Math.PI / 360) * 1.05
                scale: Qt.vector3d(hgt * view.width / Math.max(1, view.height) / 100, hgt / 100, 1)
                materials: PrincipledMaterial {
                    lighting: PrincipledMaterial.NoLighting
                    baseColor: "#ffffff"
                    baseColorMap: Texture {
                        sourceItem: starSrc
                        tilingModeHorizontal: Texture.Repeat
                        tilingModeVertical: Texture.Repeat
                        scaleU: view.width / 1024
                        scaleV: view.height / 1024
                        positionU: win.ringAngle * 0.0007
                    }
                }
            }

            // sun: bright core fading out smoothly, inside two soft glow sprites (no hard edge anywhere)
            Node {
                Glow { tex: glowTex; camRot: cam.rotation; glowColor: "#ff9a3c"; glowAlpha: 0.5; size: 340 }
                Glow { tex: glowTex; camRot: cam.rotation; glowColor: "#ffc766"; glowAlpha: 0.8; size: 180 }
                Glow { tex: sunTex; camRot: cam.rotation; glowColor: "#ffffff"; glowAlpha: 1.0; size: 112 }
            }

            // planets on the ring
            Repeater3D {
                model: win.planets.length
                delegate: Node {
                    id: pn
                    required property int index
                    readonly property var pd: win.planets[index]
                    readonly property color pc: pd.color
                    readonly property bool front: index === win.focusIdx && win.moonsOn
                    position: win.planetPos(index, win.ringAngle)

                    Glow {
                        tex: glowTex; camRot: cam.rotation
                        glowColor: pn.pc; glowAlpha: pn.front ? 0.6 : 0.4
                        size: pn.pd.r * 4.4
                    }
                    Node {
                        eulerRotation.z: ((pn.index * 11) % 31) - 15   // axis tilt, differs per planet
                        Model {
                            property string kind: "planet"
                            pickable: true
                            property int idx: pn.index
                            source: "#Sphere"
                            scale: Qt.vector3d(pn.pd.r / 50, pn.pd.r / 50, pn.pd.r / 50)
                            NumberAnimation on eulerRotation.y {
                                from: 0; to: 360; loops: Animation.Infinite
                                duration: 34000 + pn.index * 3000
                                paused: !win.awake
                            }
                            materials: PrincipledMaterial {
                                baseColor: pn.pc
                                baseColorMap: surfTex
                                roughness: 0.8
                                emissiveFactor: win.tint(pn.pc, 0.2)
                            }
                        }
                    }
                }
            }

            // moons of the focused planet (always at the front of the ring)
            Node {
                position: Qt.vector3d(0, 0, win.ringRadius)
                scale: win.moonsOn ? Qt.vector3d(1, 1, 1) : Qt.vector3d(0.001, 0.001, 0.001)
                Behavior on scale { Vector3dAnimation { duration: 220 } }

                Repeater3D {
                    id: moonRep
                    model: win.focusApps.length
                    delegate: Node {
                        id: mn
                        required property int index
                        readonly property var app: win.focusApps[index]
                        readonly property string icon: win.cfg.icons && app && app.icon ? app.icon : ""
                        readonly property bool hov: win.hoverApp === index
                        readonly property bool sel: win.selApp === index
                        readonly property bool hit: win.focusMatch[index] === true
                        readonly property bool rec: win.recentIds.indexOf(app ? app.id : "") >= 0
                        readonly property color mc: win.planets[win.focusIdx].color
                        readonly property vector3d probe: mn.scenePosition

                        // orbit layout: several rings (more apps -> more rings), moons evenly spaced on a ring,
                        // each ring with its own tilt, yaw, radius and speed (alternating direction) so moons keep apart
                        readonly property int n: win.focusApps.length
                        readonly property int rings: Math.min(5, Math.max(1, Math.ceil(n / 9)))
                        readonly property int ring: index % rings
                        readonly property int perRing: Math.ceil((n - ring) / rings)
                        readonly property real phase: Math.floor(index / rings) * 360 / perRing + ring * 23
                        readonly property real orbitR: win.focusR + 22 + ring * 13
                        readonly property real tilt: [10, -18, 24, -10, 30][ring] * Math.PI / 180
                        readonly property real yaw: ring * 57 * Math.PI / 180
                        property real spin: 0   // 0..360, animated
                        NumberAnimation on spin {
                            from: 0; to: 360; loops: Animation.Infinite
                            duration: (42000 + mn.ring * 9000) / Math.max(0.05, win.cfg.orbit_speed)
                            paused: mn.hov || mn.sel || !win.awake || win.cfg.orbit_speed <= 0
                        }
                        position: {
                            const a = (phase + (ring % 2 === 0 ? spin : -spin)) * Math.PI / 180;
                            const x = orbitR * Math.cos(a), z = -orbitR * Math.sin(a);
                            const y1 = -z * Math.sin(tilt), z1 = z * Math.cos(tilt);
                            return Qt.vector3d(x * Math.cos(yaw) + z1 * Math.sin(yaw), y1, -x * Math.sin(yaw) + z1 * Math.cos(yaw));
                        }

                        // visual size as a fraction of the 100-unit sphere: selected > hovered > search hit > normal > dimmed
                        readonly property real s: sel ? 0.24 : hov ? 0.2 : hit ? (win.searching ? 0.17 : 0.13) : 0.08

                        // pick area: invisible sphere, larger than the visible moon so small moons are easy to hit
                        Model {
                            id: mdl
                            property string kind: "moon"
                            property int idx: mn.index
                            pickable: true
                            source: "#Sphere"
                            scale: Qt.vector3d(0.2, 0.2, 0.2)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: Qt.rgba(0, 0, 0, 0.004)
                                alphaMode: PrincipledMaterial.Blend
                            }
                        }
                        // recent app: soft halo in the planet colour; selection: white halo
                        Glow {
                            visible: mn.rec && mn.hit && !mn.sel
                            tex: glowTex; camRot: cam.rotation
                            glowColor: mn.mc; glowAlpha: 0.95; size: mn.s * 100 * 3.8
                            position: cam.forward.times(10)
                        }
                        Glow {
                            visible: mn.sel
                            tex: glowTex; camRot: cam.rotation
                            glowColor: "#ffffff"; glowAlpha: 0.7; size: mn.s * 100 * 3.0
                            position: cam.forward.times(10)
                        }
                        // plain sphere in the planet colour: the moon of apps without an icon (or icons = false)
                        Model {
                            visible: mn.icon === ""
                            source: "#Sphere"; pickable: false
                            scale: Qt.vector3d(mn.s * 0.85, mn.s * 0.85, mn.s * 0.85)
                            materials: PrincipledMaterial {
                                baseColor: mn.hit ? mn.mc : Qt.darker(mn.mc, 3)
                                roughness: 0.5
                                emissiveFactor: win.tint(mn.mc, mn.sel || mn.hov ? 0.8 : !mn.hit ? 0.03 : win.searching ? 0.9 : mn.rec ? 0.7 : 0.2)
                            }
                        }
                        // icon: camera-facing quad (texture loaded only for the focused planet's moons)
                        Texture {
                            id: itex
                            source: mn.icon !== "" ? Qt.url("file://" + mn.icon) : ""
                            generateMipmaps: true
                            mipFilter: Texture.Linear
                        }
                        Model {
                            visible: mn.icon !== ""
                            source: "#Rectangle"; pickable: false
                            rotation: cam.rotation
                            position: cam.forward.times(-14)
                            opacity: mn.hit ? 1.0 : 0.28
                            readonly property real sz: mn.s * 100
                            scale: Qt.vector3d(sz / 100, sz / 100, 1)
                            materials: PrincipledMaterial {
                                lighting: PrincipledMaterial.NoLighting
                                baseColor: mn.hit ? "#ffffff" : "#8a8a8a"
                                baseColorMap: itex
                                alphaMode: PrincipledMaterial.Blend
                                cullMode: PrincipledMaterial.NoCulling
                            }
                        }
                    }
                }
            }
        }

        // planet labels (2D overlay following the 3D positions)
        Repeater {
            model: win.planets.length
            delegate: Text {
                id: lbl
                required property int index
                readonly property var pd: win.planets[index]
                readonly property point sp: {
                    const p = win.planetPos(index, win.ringAngle);
                    const resize = view.width + view.height;   // dependency: re-map on resize
                    return view.mapFrom3DScene(Qt.vector3d(p.x, -pd.r - 8 + resize * 0, p.z));
                }
                x: sp.x - width / 2
                y: sp.y
                visible: win.planetPos(index, win.ringAngle).z > -win.ringRadius * 0.4
                text: win.searching ? pd.label + "  " + win.planetMatches[index] : pd.label
                color: index === win.focusIdx && win.moonsOn ? "#ffffff" : win.searching && win.planetMatches[index] > 0 ? "#ffe9a8" : "#9aa0b0"
                font.pixelSize: Math.max(11, view.height * 0.026)
                font.bold: index === win.focusIdx && win.moonsOn
            }
        }

        MouseArea {
            id: ma
            anchors.fill: view
            hoverEnabled: true
            cursorShape: win.hoverApp >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
            property real px: 0
            property real startX: 0
            property real startY: 0
            property bool moved: false
            property string lastHover: ""
            property bool wasAnimating: false

            onPressed: m => {
                px = m.x; startX = m.x; startY = m.y; moved = false;
                wasAnimating = anim.running; anim.stop();
                win.dbg("press " + Math.round(m.x) + "," + Math.round(m.y));
            }
            onPositionChanged: m => {
                if (pressed) {
                    if (!moved && Math.hypot(m.x - startX, m.y - startY) > win.clickSlopPx) {
                        moved = true; win.moonsOn = false; win.hoverApp = -1;
                    }
                    if (moved) win.ringAngle -= (m.x - px) * win.cfg.drag_speed;
                    px = m.x;
                } else if (win.moonsOn) {
                    win.hoverQuiet = true;
                    const h = win.pickAt(m.x, m.y);
                    win.hoverQuiet = false;
                    if (win.debug && (h ? h.kind + h.idx : "") !== lastHover) { lastHover = h ? h.kind + h.idx : ""; win.dbg("hover -> " + (lastHover || "nothing")); }
                    win.hoverApp = h && h.kind === "moon" ? h.idx : -1;
                }
            }
            onExited: win.hoverApp = -1
            onReleased: m => {
                win.dbg("release moved=" + moved + " wasAnimating=" + wasAnimating);
                if (moved) { win.snap(); return; }
                if (wasAnimating) { win.snap(); return; }
                const h = win.pickAt(m.x, m.y);
                if (!h) return;
                if (h.kind === "moon" && win.moonsOn) {
                    win.dbg("launch " + win.focusApps[h.idx].label);
                    win.launchApp(win.focusApps[h.idx]);
                } else if (h.kind === "planet" && h.idx !== win.focusIdx) {
                    win.dbg("focus planet " + h.idx);
                    win.goPlanet(h.idx);
                }
            }
        }

        // tooltip: hovered moon (at the mouse) or, failing that, the keyboard-selected moon (next to it)
        Rectangle {
            readonly property var app: win.hoverApp >= 0 && win.hoverApp < win.focusApps.length ? win.focusApps[win.hoverApp]
                : win.moonsOn && win.selApp >= 0 && win.selApp < win.focusApps.length ? win.focusApps[win.selApp] : null
            readonly property bool byMouse: win.hoverApp >= 0
            readonly property point selPt: {
                const resize = view.width + view.height;   // dependency: re-map on resize
                const m = win.moonsOn && win.selApp >= 0 ? moonRep.objectAt(win.selApp) : null;
                return m ? view.mapFrom3DScene(m.probe) : Qt.point(resize * 0, 0);
            }
            readonly property real ax: byMouse ? ma.mouseX : selPt.x
            readonly property real ay: byMouse ? ma.mouseY : selPt.y
            visible: app !== null
            x: Math.max(6, Math.min(ax + 16, view.width - width - 6))
            y: Math.max(6, Math.min(ay + 18, view.height - height - 6))
            color: "#d0101420"; radius: 6
            border.color: byMouse ? "#3a4050" : "#c8d0e8"
            width: Math.min(view.width * 0.5, Math.max(tipName.implicitWidth, tipComment.implicitWidth) + 20)
            height: tipCol.implicitHeight + 14
            Column {
                id: tipCol
                anchors.centerIn: parent
                width: parent.width - 20
                spacing: 2
                // long names wrap to at most 2 lines, comments to 3; anything longer is cut with an ellipsis
                Text {
                    id: tipName
                    width: parent.width
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: "#ffffff"
                    font.bold: true
                    font.pixelSize: win.cfg.tooltip_font_size
                    text: parent.parent.app ? parent.parent.app.label : ""
                }
                Text {
                    id: tipComment
                    width: parent.width
                    visible: text !== ""
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: "#c8ccd8"
                    font.pixelSize: win.cfg.tooltip_font_size
                    text: parent.parent.app ? parent.parent.app.comment : ""
                }
            }
        }

        // search line
        Rectangle {
            visible: win.query !== ""
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 12 }
            width: Math.min(view.width * 0.8, sline.implicitWidth + 28)
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
                font.pixelSize: Math.max(14, view.height * 0.032)
                text: win.query + "\u258f   " + (win.matches.length > 0
                    ? (win.matchPos + 1) + "/" + win.matches.length : "no match")
            }
        }

        Text {
            anchors { left: parent.left; bottom: parent.bottom; margins: 10 }
            color: "#6a7080"
            font.pixelSize: 12
            text: win.status + "   |   arrows: rotate / select   type: search   Enter: launch   Esc: clear/close"
        }
    }
}
