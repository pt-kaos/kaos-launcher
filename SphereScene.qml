import QtQuick
import QtQuick3D
import QtQuick.Shapes
import "sphere.js" as Sphere

// kaos-launcher "sphere" style: a particle sphere with a reactive core, a tilted ring of app icons grouped in category arcs,
// and the most recent apps as hexagons on a larger outer orbit, tilted on another diagonal. Scene interface: see the top of
// Launcher.qml.
//
// The ring and the orbit are 2D overlays positioned by the pure functions in sphere.js: the ring is a fisheye, the orbit has
// even spacing; on both the front is large and clickable and the back dimmed and shrunk. An app is in the ring OR on the orbit,
// never both. The sphere is a View3D with instanced particles; it is not clickable.
// Two views, never shown together (ctl.zone): "hex" = Recents (sphere + outer orbit; the inner ring is hidden) and "ring" =
// All apps (the camera zooms in, the inner ring is bigger, the orbit is hidden). Tab toggles; a search picks the view of its best
// match; every open starts in Recents when there are recents, else in All apps. Back hexes are really behind the sphere: an
// opaque disc item (the background colour) sits above them and below the particle view.
// TODO (Stage 4): connector lines, zone brackets, open animation, starfield, palette from config.
Item {
    id: scene

    property var ctl                // the Launcher controller
    readonly property bool settled: !dragging   // up/down selection is allowed except while dragging the ring
    readonly property bool hasZones: true
    readonly property int pulseMs: 380          // launch pulse; the controller delays closing by this long

    // ---- look constants (palette becomes configurable in Stage 4) ----
    // palette: config.toml color_main / color_accent / color_base (validated by the backend; the defaults are the fallback)
    readonly property color amber: ctl.cfg.color_main || "#ff9a3c"      // particles, labels, search highlights
    readonly property color cyan: ctl.cfg.color_accent || "#3cd6ff"     // highlights, hex borders, brackets, connector lines, ring line
    readonly property color baseColor: ctl.cfg.color_base || "#0a0d12"  // background, the opaque disc and the plates
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property int particleCount: 3600
    readonly property real sphereRadius: 100        // scene units
    readonly property real camDist: 630             // camera distance of the Recents view
    readonly property real camFov: 30
    readonly property real warpP: 2.4                 // ring fisheye strength (sphere.js warp)
    readonly property real ringGap: 1.6             // empty slots between category arcs
    readonly property real ringRoll: -9             // in-plane tilt of the ring, degrees
    readonly property real clickSlopPx: 6
    // Layer order (z), back to front: background < outer-orbit back hexes < inner-ring back icons (Recents) < opaque sphere disc <
    // particle view < inner-ring back icons over the sphere (All apps) < inner-ring front icons < outer-orbit front hexes < raised
    // (selected / hovered) hex < core text < labels. The outer orbit's back half is farther away than the ring's back half, so it is
    // always below it. Values and their tests: Z in sphere.js; each layer adds depth * 5 at most.
    readonly property var zl: Sphere.Z

    // tuning: the visible orbit line is off (the reference has none); the inner ring in the Recents view is quiet
    readonly property bool showOrbitLine: false     // true brings back the cyan track line of the outer hex orbit
    readonly property real ringRecentsAlpha: 0.5    // inner ring opacity in the Recents view (1 in All apps)
    readonly property real ringRecentsIconFrac: 0.034   // uniform inner-ring icon size in Recents, as a fraction of the panel height

    // ---- geometry derived from the panel size ----
    readonly property real cx: width / 2
    readonly property real cy: height / 2
    // screen radius of the sphere silhouette (perspective camera, centred)
    readonly property real dist: camDist / zoom   // camera distance now (the All apps view moves the camera closer)
    readonly property real sr: Math.tan(Math.asin(sphereRadius / dist)) / Math.tan(camFov * Math.PI / 360) * height / 2
    readonly property real ringA: Math.min(2.0 * sr, width * 0.44)
    readonly property real ringB: ringA * 0.28
    readonly property real maxIcon: Math.max(18, height * 0.062) * (1 + 0.45 * viewT)   // bigger icons in the All apps view
    readonly property real hexBaseR: Math.max(15, height * 0.046)         // wanted hexagon circumradius
    readonly property real hexR: orbit.R                                  // actual: a little smaller when many hexes would touch
    readonly property real labelPx: Math.max(10, height * 0.023)         // category label font size (ring and hexes)

    // ---- views: viewT 0 = Recents (outer orbit), 1 = All apps (zoomed ring); animated 350 ms, never by a timer ----
    property real viewT: 0
    readonly property string curView: hexOrder.length > 0 ? ctl.zone : "ring"
    readonly property var fades: Sphere.viewFades(viewT)
    readonly property real zoom: fades.zoom
    readonly property var rl: Sphere.ringLook(viewT, ringRecentsAlpha)   // inner ring: alpha, detail (labels, stripes), mix (icon size)
    readonly property bool ringBehind: viewT < 0.5   // Recents look: the back half of the ring passes behind the sphere
    readonly property real orbitOp: fades.orbitOp
    onCurViewChanged: flyView()
    function flyView() {
        ctl.dbg("view -> " + curView);
        viewAnim.stop();
        const to = curView === "ring" ? 1 : 0;
        if (Math.abs(to - viewT) < 1e-3) { viewT = to; return; }
        viewAnim.from = viewT; viewAnim.to = to; viewAnim.restart();
    }
    NumberAnimation { id: viewAnim; target: scene; property: "viewT"; duration: 350; easing.type: Easing.InOutCubic }
    readonly property string hint: hexOrder.length > 0
        ? (curView === "hex" ? "Recents   Tab: all apps   arrows: select   type: search   Enter: launch   Esc: clear/close"
                          : "All apps   Tab: recents   arrows: select   type: search   Enter: launch   Esc: clear/close")
        : "arrows: select   type: search   Enter: launch   Esc: clear/close"

    // ---- hexes: the recent apps (newest first), clustered by category ----
    readonly property int hexMax: ctl.cfg.hex_count === undefined ? 20 : ctl.cfg.hex_count
    readonly property var appIndex: {   // desktop id -> [planet index, app index]
        const m = {};
        ctl.planets.forEach((p, pi) => p.apps.forEach((a, ai) => { m[a.id] = [pi, ai]; }));
        return m;
    }
    readonly property var hexItems: {
        const out = [], seen = {};
        for (const id of ctl.recentIds.slice(0, hexMax)) {
            const e = appIndex[id];
            if (e && !seen[id]) { seen[id] = true; out.push({ pi: e[0], ai: e[1] }); }
        }
        return out;
    }
    readonly property var hexClusters: Sphere.clusterRecents(hexItems).map(c => Object.assign({}, c, { label: ctl.planets[c.pi].label.toUpperCase() }))
    readonly property var hexOrder: Sphere.hexOrder(hexClusters)      // walk order of the hex zone
    readonly property var hexIndex: {                                // "pi:ai" -> index in hexOrder
        const m = {};
        hexOrder.forEach((h, i) => { m[h.pi + ":" + h.ai] = i; });
        return m;
    }
    readonly property var hexPoly: Sphere.hexPoints(hexR).map(p => Qt.point(p.x + hexR, p.y + hexR))
    // outer orbit: larger than the ring, tilted the other way; scaled to the panel (sphere.js orbitGeom)
    readonly property var orbit: Sphere.orbitGeom(width, height, hexBaseR, undefined, undefined, Sphere.ringAxes(width, height).A, hexOrder.length)   // ~1.22x the inner ring (Recents size, not the zoomed one)
    readonly property var hexGroups: Sphere.hexGroups(hexOrder)
    property real h0: 0             // hex at the front of the orbit (real, animated)
    function hexPos(i) {            // geometry of hex i: x, y relative to the panel centre, depth, scale and opacity
        const p = Sphere.orbitPos(i, hexOrder.length, h0, orbit.A, orbit.B, orbit.roll), l = Sphere.depthLook(p.depth);
        return { x: p.x, y: p.y, depth: p.depth, scale: l.scale, op: l.op * openT, clickable: l.clickable };
    }
    // one label per group at its middle (recomputed while the orbit turns; cheap: <= 20 hexes)
    readonly property var hexLabels: Sphere.orbitLabels(hexGroups, hexClusters.map(c => c.label), hexOrder.length, h0, {
        W: width, H: height, cx: cx, cy: cy, A: orbit.A, B: orbit.B, roll: orbit.roll, R: hexR, m: 10,
        labelH: labelPx * 1.3, charW: labelPx * 0.62 + 2,
        avoid: { A: ringA, B: ringB, roll: ringRoll, half: height * ringRecentsIconFrac + labelPx }   // the quiet ring's band
    })
    function flyHex(t) {
        const n = hexOrder.length;
        animH.stop();
        if (n === 0) return;
        const to = h0 + Sphere.wrap(t - h0, n);
        if (Math.abs(to - h0) < 1e-3) { h0 = to; return; }
        animH.from = h0; animH.to = to; animH.restart();
    }
    NumberAnimation { id: animH; target: scene; property: "h0"; duration: 300; easing.type: Easing.OutCubic }
    property int hexSel: -1         // selected hex (index in hexOrder) while the hex zone is active
    property int hoverHex: -1
    onHexSelChanged: if (!dragging && hexSel >= 0) flyHex(hexSel)
    readonly property var hexMatch: {
        const out = {};
        if (ctl.searching) for (const m of ctl.matches) { const h = hexIndex[m.pi + ":" + m.ai]; if (h !== undefined) out[h] = true; }
        return out;
    }

    // ---- ring state: every app that is not a hex ----
    readonly property var ringApps: ctl.planets.map((p, pi) => {   // per category: original app indices that are in the ring
        const out = [];
        p.apps.forEach((a, ai) => { if (hexIndex[pi + ":" + ai] === undefined) out.push(ai); });
        return out;
    })
    readonly property var ring: Sphere.buildRing(ringApps.map(a => a.length), ringGap)   // ring item .ai is an index into ringApps[pi]
    property real s0: 0             // focus slot (real): the ring is centred here
    property bool dragging: false
    property int hoverIdx: -1       // flat ring index under the mouse, -1 = none
    // ring selection (original app index) from the search match or the keyboard, or null
    readonly property var ringCur: {
        if (ctl.searching) {
            const m = ctl.matches[ctl.matchPos];
            return m && hexIndex[m.pi + ":" + m.ai] === undefined ? { pi: m.pi, ai: m.ai } : null;
        }
        const pi = ctl.focusIdx, ai = ctl.selIdx;
        return ai >= 0 && pi < ringApps.length && ringApps[pi].indexOf(ai) >= 0 ? { pi: pi, ai: ai } : null;
    }
    // what is selected now: ring app, hex app (hex: true) or null
    readonly property var cur: {
        if (ctl.searching) {
            const m = ctl.matches[ctl.matchPos];
            return m ? { pi: m.pi, ai: m.ai, hex: hexIndex[m.pi + ":" + m.ai] !== undefined } : null;
        }
        if (ctl.zone === "hex") {
            const h = hexOrder[hexSel];
            return h ? { pi: h.pi, ai: h.ai, hex: true } : null;
        }
        return ringCur ? { pi: ringCur.pi, ai: ringCur.ai, hex: false } : null;
    }
    readonly property string activeZone: ctl.searching ? (cur && cur.hex ? "hex" : "ring") : ctl.zone
    readonly property int selFlat: ringCur && activeZone === "ring" ? ring.offset[ringCur.pi] + ringApps[ringCur.pi].indexOf(ringCur.ai) : -1
    readonly property int selHexIdx: cur && cur.hex ? hexIndex[cur.pi + ":" + cur.ai] : -1
    readonly property var matchFlat: {   // flat ring index -> true, for the current search
        const out = {};
        if (ctl.searching) for (const m of ctl.matches) {
            const k = ringApps[m.pi].indexOf(m.ai);
            if (k >= 0) out[ring.offset[m.pi] + k] = true;
        }
        return out;
    }
    // slot the ring should be centred on: the selected ring app, else the middle of the focused arc
    readonly property real tgt: Sphere.targetSlot(ring, ctl.focusIdx, ringCur && ringCur.pi === ctl.focusIdx ? ringApps[ringCur.pi].indexOf(ringCur.ai) : -1)
    onTgtChanged: if (!dragging) flyTo(tgt)
    property color catColor: {   // focused category, or the category of the selected hex app
        const pi = cur && cur.hex ? cur.pi : ctl.focusIdx;
        return pi < ctl.planets.length ? ctl.planets[pi].color : amber;
    }
    Behavior on catColor { ColorAnimation { duration: 450 } }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
    function mod(a, n) { return ((a % n) + n) % n; }

    function flyTo(t) {
        anim.stop();
        const to = Sphere.nearestUnwrapped(s0, t, ring.N);
        if (Math.abs(to - s0) < 1e-3) { s0 = to; return; }
        anim.from = s0; anim.to = to; anim.restart();
    }
    NumberAnimation { id: anim; target: scene; property: "s0"; duration: 300; easing.type: Easing.OutCubic }

    // screen geometry of ring item i: position relative to the panel centre, size, depth (+1 front .. -1 back), opacity
    function geom(i) {
        const it = ring.items[i];
        if (!it) return { x: 0, y: 0, depth: -1, size: 0, op: 0, tan: 0, spPx: 0, phi: 180 };
        const u = Sphere.wrap(it.slot - s0, ring.N);
        const phi = Sphere.warp(u, ring.N, warpP);
        const pr = Sphere.project(phi, ringA, ringB, ringRoll);
        const f = phi * Math.PI / 180;
        const spPx = Math.hypot(ringA * Math.cos(f), ringB * Math.sin(f)) * Sphere.spacing(u, ring.N, warpP) * Math.PI / 180;
        const dk = clamp((pr.depth + 0.1) / 1.1, 0, 1);
        const full = Math.max(Math.min(spPx * 0.92, maxIcon), maxIcon * 0.4) * (0.45 + 0.55 * dk);   // floor keeps the back of the ring visible as a chain
        const small = height * ringRecentsIconFrac * (0.6 + 0.4 * dk);                              // Recents: small, uniform icons
        const base = small + (full - small) * rl.mix;
        let op = (0.32 + 0.68 * clamp((pr.depth + 0.25) / 1.25, 0, 1)) * rl.alpha * openT;
        if (ctl.searching && !matchFlat[i]) op *= 0.22;
        return { x: pr.x, y: pr.y, depth: pr.depth, size: Math.max(0, base), op: op, tan: pr.tangent, spPx: spPx, phi: phi };
    }

    // ---- scene interface ----
    function reset() {
        anim.stop();
        animH.stop(); s0 = tgt; h0 = 0; dragging = false; hoverIdx = -1; hoverHex = -1;
        ctl.zone = Sphere.openView(hexOrder.length);   // every open: Recents when there are recents (newest selected), else All apps
        hexSel = hexOrder.length > 0 ? 0 : -1;
        viewAnim.stop(); viewT = curView === "ring" ? 1 : 0;   // no fly-in of the view on open
        if (ctl.awake) startOpen(); else { openAnimator.stop(); openT = 1; }
    }
    function clearHover() { hoverIdx = -1; hoverHex = -1; }
    function setZone(z) {   // Tab / Shift+Tab: the other view (the controller passes the one it wants)
        ctl.zone = Sphere.toggleView(curView, hexOrder.length) === z ? z : curView;
        if (ctl.zone === "hex" && hexSel < 0) hexSel = 0;
    }
    function stepBy(d) {   // Left/Right: next/previous hex in the hex zone, else the next/previous category arc
        if (curView === "hex") {   // Recents: walk the hexes (while searching the match decides, so nothing)
            if (!ctl.searching) hexSel = hexSel < 0 ? (d > 0 ? 0 : hexOrder.length - 1) : mod(hexSel + d, hexOrder.length);
            return;
        }
        const n = ctl.planets.length;
        if (n === 0) return;
        let f = ctl.focusIdx;
        for (let t = 0; t < n; t++) { f = mod(f + d, n); if (ringApps[f].length > 0) break; }   // arcs whose apps are all hexes are skipped
        if (!ctl.searching) ctl.selIdx = -1;
        ctl.focusIdx = f;
        flyTo(tgt);
    }
    function cycleSel(d) {   // Up/Down without a search: step inside the active zone (wraps)
        if (curView === "hex") {
            const n = hexOrder.length;
            if (n > 0) hexSel = hexSel < 0 ? (d > 0 ? 0 : n - 1) : mod(hexSel + d, n);
            return;
        }
        const L = ringApps[ctl.focusIdx] || [];
        if (L.length === 0) return;
        const k = ctl.selIdx >= 0 ? L.indexOf(ctl.selIdx) : -1;
        ctl.selIdx = L[k < 0 ? (d > 0 ? 0 : L.length - 1) : mod(k + d, L.length)];
    }
    function goTo(pi, ai) {   // search: a hex match switches to the hex zone (no ring rotation), a ring match rotates the ring
        const h = hexIndex[pi + ":" + ai];
        if (h !== undefined) { ctl.zone = Sphere.matchView(true, hexOrder.length); hexSel = h; flyHex(h); return; }
        ctl.zone = Sphere.matchView(false, hexOrder.length);
        ctl.focusIdx = pi;
        flyTo(tgt);
    }
    function currentApp() { return cur ? ctl.planets[cur.pi].apps[cur.ai] : null; }
    function pickAt(x, y, v) {   // target under (x, y) in the visible view (or view v): front ring icon or front hex, as {kind, idx, pi, ai, app}, or null
        const vw = v === undefined ? curView : v;
        let best = null;
        if (vw === "ring") {
            let bz = -2;
            for (let i = 0; i < ring.items.length; i++) {
                const g = geom(i);
                if (g.depth < 0.15) continue;
                const r = Math.max(g.size, 16) / 2 + 2;
                if (Math.hypot(x - cx - g.x, y - cy - g.y) <= r && g.depth + (i === selFlat ? 1 : 0) > bz) {
                    bz = g.depth + (i === selFlat ? 1 : 0);
                    best = { kind: "app", idx: i, pi: ring.items[i].pi, ai: ringApps[ring.items[i].pi][ring.items[i].ai], app: appAt(i) };
                }
            }
        } else {
            let hexRatio = Infinity;
            for (let i = 0; i < hexOrder.length; i++) {
                const g = hexPos(i);
                if (!g.clickable) continue;   // front hexes only; they are never behind the sphere
                const ratio = Math.hypot(x - cx - g.x, y - cy - g.y) / (hexR * g.scale * 0.95);
                if (ratio <= 1 && ratio < hexRatio) { hexRatio = ratio; best = { kind: "hex", idx: i, pi: hexOrder[i].pi, ai: hexOrder[i].ai, app: hexApp(i) }; }
            }
        }
        if (ctl.debug && !ma.hoverCall) ctl.dbg("pick(" + Math.round(x) + "," + Math.round(y) + ") -> " + (best ? best.kind + " #" + best.idx : "nothing"));
        return best;
    }
    function hexOccluded(i) { const g = hexPos(i); return Sphere.hexOccluded(g.depth, g.x, g.y, hexR * g.scale, sr); }
    function hiddenBackHexes() { let n = 0; for (let i = 0; i < hexOrder.length; i++) if (hexOccluded(i)) n++; return n; }
    function hexApp(i) { const h = hexOrder[i]; return h ? ctl.planets[h.pi].apps[h.ai] : null; }
    function hexClusterHit(ci) { return hexOrder.some((h, i) => h.cluster === ci && hexMatch[i] === true); }
    function appAt(i) { const it = ring.items[i]; return it ? ctl.planets[it.pi].apps[ringApps[it.pi][it.ai]] : null; }
    Component.onCompleted: {
        buildParticles();
        reset();
    }

    // ---- launch pulse: the sphere swells and its core flares for ~380 ms (the controller delays the close by pulseMs) ----
    property real pulse: 0
    // ---- open animation: the particles assemble from scattered positions in 280 ms (ease-out), rings and hexes fade in ----
    property real openT: 1
    function startOpen() {   // on every show (and when the scene is created), only while the panel is visible
        openAnimator.stop();
        if (ctl.cfg.open_animation === false) { openT = 1; return; }
        openT = 0;
        openAnimator.restart();
    }
    NumberAnimation { id: openAnimator; target: scene; property: "openT"; from: 0; to: 1; duration: 280; easing.type: Easing.OutCubic }
    Connections {
        target: scene.ctl
        function onAwakeChanged() { if (scene.ctl.awake) scene.startOpen(); else { openAnimator.stop(); scene.openT = 1; } }
    }
    SequentialAnimation {
        id: pulseAnim
        NumberAnimation { target: scene; property: "pulse"; to: 1; duration: 130; easing.type: Easing.OutQuad }
        NumberAnimation { target: scene; property: "pulse"; to: 0; duration: 250; easing.type: Easing.InQuad }
    }
    Connections { target: scene.ctl; function onLaunched() { pulseAnim.restart(); } }

    // KAOS_DEBUG=1: pick at the projected centre of the front-most and the back-most icon (expect: itself, nothing)
    Timer {
        interval: 3000; running: ctl.debug; repeat: false
        onTriggered: {
            let f = 0, b = 0;
            for (let i = 0; i < ring.items.length; i++) {
                if (geom(i).depth > geom(f).depth) f = i;
                if (geom(i).depth < geom(b).depth) b = i;
            }
            const gf = geom(f), gb = geom(b);
            const hf = pickAt(cx + gf.x, cy + gf.y, "ring"), hb = pickAt(cx + gb.x, cy + gb.y, "ring");
            ctl.dbg("selftest front icon #" + f + " (" + Math.round(cx + gf.x) + "," + Math.round(cy + gf.y) + " size " + Math.round(gf.size) + ") -> "
                + (hf ? "#" + hf.idx : "nothing") + "; back icon #" + b + " -> " + (hb ? "#" + hb.idx : "nothing"));
            const hp = hexOrder.length > 0 ? hexPos(0) : null, hh = hp ? pickAt(cx + hp.x, cy + hp.y, "hex") : null;
            ctl.dbg("selftest hexes: " + hexOrder.length + " in " + hexClusters.length + " clusters, ring apps " + ring.items.length
                + (hp ? "; front hex 0 at " + Math.round(cx + hp.x) + "," + Math.round(cy + hp.y) + " -> " + (hh ? hh.kind + " #" + hh.idx : "nothing")
                + "; view " + curView + ", zoom " + zoom.toFixed(2) + ", sr " + Math.round(sr) + ", back hexes hidden " + hiddenBackHexes()
                + "; orbit A=" + Math.round(orbit.A) + " B=" + Math.round(orbit.B) + " labels " + hexLabels.filter(l => l.visible).length + "/" + hexGroups.length : ""));
        }
    }

    // ---- particle sphere: three instanced models (amber, cyan patches, a subset that takes the category colour) ----
    function buildParticles() {
        const t0 = Date.now();
        const g = Sphere.particles(particleCount, 7);
        const mk = (list, rgb) => Qt.createQmlObject(Sphere.instanceSource(list, sphereRadius, 0.018, rgb), scene, "sphere-instances");
        mAmber.instancing = mk(g.amber, [1, 1, 1]);   // instance colour = brightness only; the material tint is the palette colour
        mCyan.instancing = mk(g.cyan, [1, 1, 1]);
        mTint.instancing = mk(g.tint, [1, 1, 1]);
        ctl.dbg("sphere: " + particleCount + " particles built in " + (Date.now() - t0) + " ms");
    }

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

    Rectangle { anchors.fill: parent; z: scene.zl.bg; color: scene.baseColor }   // background (the View3D is transparent)
    Rectangle {   // opaque disc the size of the sphere silhouette: hides back hexes behind the sphere, under the particles
        x: scene.cx - scene.sr; y: scene.cy - scene.sr; width: scene.sr * 2; height: scene.sr * 2; radius: scene.sr
        z: scene.zl.disc; color: scene.baseColor
    }

    View3D {
        id: view
        anchors.fill: parent
        z: scene.zl.view   // above the back layers, below the ring's front and the front hexes
        camera: cam
        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Transparent   // the background rectangle and the occluding disc show through
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.Medium
            fog: Fog {   // far particles fade into the background: depth cue without lighting
                enabled: true
                color: scene.baseColor
                depthEnabled: true
                depthNear: scene.dist - scene.sphereRadius
                depthFar: scene.dist + scene.sphereRadius * 1.1
                depthCurve: 1.0
            }
        }
        PerspectiveCamera { id: cam; fieldOfView: scene.camFov; position: Qt.vector3d(0, 0, scene.dist) }

        Texture { id: glowTex; sourceItem: glowSrc }

        // glows: category colour halo, amber body, bright core
        Node {
            Glow { tex: glowTex; camRot: cam.rotation; glowColor: scene.catColor; glowAlpha: 0.22 + 0.3 * scene.pulse; size: 400 + 160 * scene.pulse }
            Glow { tex: glowTex; camRot: cam.rotation; glowColor: scene.amber; glowAlpha: 0.5 + 0.3 * scene.pulse; size: 190 + 80 * scene.pulse }
            Glow { tex: glowTex; camRot: cam.rotation; glowColor: "#fff1d0"; glowAlpha: 0.95; size: 150 + 90 * scene.pulse }
        }

        Node {
            eulerRotation.x: 16
            eulerRotation.z: -8
            scale: Qt.vector3d(1 + 0.14 * scene.pulse, 1 + 0.14 * scene.pulse, 1 + 0.14 * scene.pulse)
            Node {
                id: spin
                NumberAnimation on eulerRotation.y {
                    from: 0; to: 360; loops: Animation.Infinite; duration: 110000
                    paused: !scene.ctl.awake
                }
                Model {
                    id: mAmber
                    source: "#Rectangle"; pickable: false
                    materials: DotMaterial { tint: scene.amber; assemble: scene.openT; sizeMul: 3.2 / scene.zoom }
                }
                Model {
                    id: mCyan
                    source: "#Rectangle"; pickable: false
                    materials: DotMaterial { tint: scene.cyan; assemble: scene.openT; sizeMul: 3.2 / scene.zoom }
                }
                Model {
                    id: mTint
                    source: "#Rectangle"; pickable: false
                    materials: DotMaterial { tint: scene.catColor; assemble: scene.openT; sizeMul: 3.2 / scene.zoom }
                }
            }
        }
    }

    // ---- core text: the selected app's name, about halfway between the sphere centre and its border (no category name: the hex / icon labels carry
    // it; no search text: the controller's top box shows it) ----
    Item {
        x: cx - sr * 0.7; y: cy - sr * 0.35 + sr * 0.5; width: sr * 1.4; height: sr * 0.7
        z: scene.zl.coreText   // in front of everything else in the scene (the ring's back chain and line pass over the lower sphere in All apps)
        Rectangle {   // soft dark plate behind the name: keeps it readable over the brightest particles (translucent, so the sphere still shows)
            anchors.centerIn: coreName
            width: coreName.contentWidth + 28; height: coreName.contentHeight + 12
            radius: height / 2
            color: scene.alpha(scene.baseColor, 0.5)
            visible: scene.ctl.cfg.name_plate === true && coreName.text !== ""
        }
        Text {
            id: coreName
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: "#ffffff"
            style: Text.Outline; styleColor: scene.baseColor
            font.bold: true
            font.pixelSize: Math.max(13, scene.sr * 0.115)
            text: {
                const a = scene.currentApp();
                return a ? a.label : "";
            }
        }
    }

    // ---- inner ring: quiet in the Recents view (small icons, low opacity, no labels or stripes, back half behind the sphere),
    // full in the All apps view. Back items sit under the opaque disc in Recents, over the sphere in All apps. ----
    Shape {   // ring line, back half: in Recents an opaque pre-mixed dim colour (not translucent), so it also hides what is behind it
        opacity: (scene.ringBehind ? 1 : scene.rl.alpha) * scene.openT
        x: scene.cx; y: scene.cy; z: scene.ringBehind ? scene.zl.ringBack : scene.zl.ringBackOver
        rotation: scene.ringRoll
        ShapePath {
            strokeColor: scene.ringBehind ? Qt.tint(scene.baseColor, scene.alpha(scene.cyan, 0.33 * scene.rl.alpha)) : scene.alpha(scene.cyan, 0.33); strokeWidth: 1; fillColor: "transparent"
            PathAngleArc { centerX: 0; centerY: 0; radiusX: scene.ringA; radiusY: scene.ringB; startAngle: 0; sweepAngle: 180 }
        }
    }
    Shape {   // ring line, front half
        opacity: scene.rl.alpha * scene.openT
        x: scene.cx; y: scene.cy; z: scene.zl.ringFront - 3
        rotation: scene.ringRoll
        ShapePath {
            strokeColor: scene.alpha(scene.cyan, 0.47); strokeWidth: 1.2; fillColor: "transparent"
            PathAngleArc { centerX: 0; centerY: 0; radiusX: scene.ringA; radiusY: scene.ringB; startAngle: 180; sweepAngle: 180 }
        }
    }
    Repeater {   // thin stripe in the category colour along each arc (one short segment per app, contiguous)
        model: scene.ring.items.length
        delegate: Rectangle {
            required property int index
            readonly property var it: scene.ring.items[index]
            readonly property var g: scene.geom(index)
            readonly property var pr: Sphere.project(g.phi, scene.ringA * 0.86, scene.ringB * 0.86, scene.ringRoll)
            width: Math.max(2, g.spPx * 0.86 + 1); height: 2
            x: scene.cx + pr.x - width / 2; y: scene.cy + pr.y - 1
            rotation: pr.tangent
            z: g.depth >= 0 ? scene.zl.ringFront - 2 + g.depth : (scene.ringBehind ? scene.zl.ringBack - 1 + g.depth * 5 : scene.zl.ringBackOver - 2 + g.depth)
            color: it ? scene.ctl.planets[it.pi].color : "transparent"
            opacity: g.op * 0.8 * scene.rl.detail
            visible: g.op > 0.05 && scene.rl.detail > 0.02
        }
    }
    Repeater {
        model: scene.ring.items.length
        delegate: Item {
            id: ic
            required property int index
            readonly property var it: scene.ring.items[index]
            readonly property var app: scene.appAt(index)
            readonly property var g: scene.geom(index)
            readonly property bool sel: scene.selFlat === index
            readonly property bool hov: scene.hoverIdx === index && g.depth > 0.15
            readonly property bool hit: scene.ctl.searching && scene.matchFlat[index] === true
            readonly property real sz: g.size * (sel ? 1.5 : hov ? 1.3 : hit ? 1.15 : 1)
            readonly property string icon: scene.ctl.cfg.icons && app && app.icon ? app.icon : ""
            readonly property color pc: it ? scene.ctl.planets[it.pi].color : "white"
            width: sz; height: sz
            x: scene.cx + g.x - sz / 2; y: scene.cy + g.y - sz / 2
            z: g.depth >= 0 ? scene.zl.ringFront + g.depth * 2 + (sel ? 3 : hov ? 2 : 0) : (scene.ringBehind ? scene.zl.ringBack + g.depth * 5 : scene.zl.ringBackOver + g.depth)
            readonly property real iconOp: sel || hov ? Math.max(g.op, 0.9) : g.op   // dimming of the icon itself (over its backing plate)
            readonly property real backing: g.depth < 0 ? scene.rl.backing : 0         // back-half icons in Recents get an opaque plate
            visible: g.op > 0.03 && sz > 1.5

            Rectangle {   // opaque plate in the background colour: hides what is behind the icon (outer-orbit back hexes), not translucent
                visible: ic.backing > 0.01
                anchors.centerIn: parent
                width: ic.sz + 1; height: width; radius: width * 0.22
                color: scene.baseColor
                opacity: ic.backing
            }

            Rectangle {   // highlight: selected = white, hover = cyan, search hit = amber
                visible: (ic.sel || ic.hov || ic.hit) && scene.rl.mix > 0.5
                opacity: ic.iconOp
                anchors.centerIn: parent
                width: ic.sz + 8; height: width; radius: width / 2
                color: ic.sel ? "#30ffffff" : "transparent"
                border.width: 2
                border.color: ic.sel ? "#ffffff" : ic.hov ? scene.cyan : scene.amber
            }
            Rectangle {   // no icon: small dot in the category colour
                visible: ic.icon === ""
                opacity: ic.iconOp
                anchors.centerIn: parent
                width: ic.sz * 0.6; height: width; radius: width / 2
                color: ic.pc
            }
            Image {
                visible: ic.icon !== ""
                opacity: ic.iconOp
                anchors.fill: parent
                source: ic.icon !== "" ? Qt.url("file://" + ic.icon) : ""
                sourceSize: Qt.size(64, 64)
                asynchronous: true
                smooth: true
                mipmap: true
                fillMode: Image.PreserveAspectFit
            }
        }
    }
    Repeater {   // category labels, outside the front of the ring
        model: scene.ring.K
        delegate: Text {
            id: lb
            required property int index
            readonly property real u: Sphere.wrap(scene.ring.center[index] - scene.s0, scene.ring.N)
            readonly property real phi: Sphere.warp(u, scene.ring.N, scene.warpP)
            readonly property var pr: Sphere.project(phi, scene.ringA * 1.12, scene.ringB * 1.0, scene.ringRoll)
            readonly property var pd: scene.ctl.planets[index]
            text: pd ? pd.label.toUpperCase() : ""
            color: pd ? pd.color : "white"
            font.pixelSize: scene.labelPx
            font.letterSpacing: 2
            font.bold: true
            style: Text.Outline; styleColor: "#000000"
            x: scene.clamp(scene.cx + pr.x - width / 2, 6, scene.width - 6 - width); y: scene.cy + pr.y - scene.maxIcon * 0.75 * pr.depth - height / 2   // above the front icons; kept inside the panel
            z: scene.zl.label
            visible: pr.depth > 0.05 && scene.ringApps[index].length > 0 && scene.rl.detail > 0.02
            opacity: (index === scene.ctl.focusIdx ? 1 : 0.7) * scene.clamp(pr.depth * 1.4, 0, 1) * scene.rl.detail * scene.openT
        }
    }

    // ---- hex orbit: recent apps on a larger ellipse (2D overlay; brightness = recency) ----
    Shape {   // orbit line, back half: behind the opaque disc, so the sphere hides it
        visible: scene.showOrbitLine && scene.hexOrder.length > 0 && scene.orbitOp > 0.01
        opacity: scene.orbitOp
        x: scene.cx; y: scene.cy; z: scene.zl.hexBack - 10
        rotation: scene.orbit.roll
        ShapePath {
            strokeColor: scene.alpha(scene.cyan, 0.27); strokeWidth: 1; fillColor: "transparent"
            PathAngleArc { centerX: 0; centerY: 0; radiusX: scene.orbit.A; radiusY: scene.orbit.B; startAngle: 0; sweepAngle: 180 }
        }
    }
    Shape {   // orbit line, front half: over the sphere
        visible: scene.showOrbitLine && scene.hexOrder.length > 0 && scene.orbitOp > 0.01
        opacity: scene.orbitOp
        x: scene.cx; y: scene.cy; z: scene.zl.hexFront - 5
        rotation: scene.orbit.roll
        ShapePath {
            strokeColor: scene.alpha(scene.cyan, 0.5); strokeWidth: 1.5; fillColor: "transparent"
            PathAngleArc { centerX: 0; centerY: 0; radiusX: scene.orbit.A; radiusY: scene.orbit.B; startAngle: 180; sweepAngle: 180 }
        }
    }
    Repeater {   // one label per category group, at the group's middle just outside the orbit
        model: scene.hexGroups.length
        delegate: Text {
            required property int index
            readonly property var lab: scene.hexLabels[index]
            readonly property var cl: scene.hexClusters[scene.hexGroups[index].cluster]
            x: lab ? lab.x : 0; y: lab ? lab.y : 0; width: lab ? lab.w : 0; height: lab ? lab.h : 0
            text: cl.label
            color: scene.ctl.planets[cl.pi].color
            font.pixelSize: scene.labelPx
            font.letterSpacing: 2
            font.bold: true
            style: Text.Outline; styleColor: "#000000"
            verticalAlignment: Text.AlignVCenter
            z: scene.zl.label
            visible: lab !== undefined && lab.visible && scene.orbitOp > 0.01
            opacity: (scene.ctl.searching && !scene.hexClusterHit(scene.hexGroups[index].cluster) ? 0.3 : 0.95) * scene.orbitOp * scene.openT
        }
    }
    Repeater {
        model: scene.hexOrder.length
        delegate: Item {
            id: hx
            required property int index
            readonly property var h: scene.hexOrder[index]
            readonly property var g: scene.hexPos(index)
            readonly property var app: scene.ctl.planets[h.pi].apps[h.ai]
            readonly property color pc: scene.ctl.planets[h.pi].color
            readonly property bool sel: scene.selHexIdx === index && (scene.activeZone === "hex" || scene.ctl.searching)
            readonly property bool hov: scene.hoverHex === index && g.clickable
            readonly property bool hit: scene.hexMatch[index] === true
            readonly property real bright: Sphere.hexBrightness(h.rank) * (scene.ctl.searching && !hit ? 0.25 : 1)
            readonly property color edge: sel ? "#ffffff" : hov ? scene.cyan : hit ? scene.amber : scene.cyan   // border colour (accent)
            readonly property real glowK: bright * (sel ? 2.4 : hov ? 1.7 : 1)                                 // glow strength
            readonly property string icon: scene.ctl.cfg.icons && app && app.icon ? app.icon : ""
            x: scene.cx + g.x - scene.hexR; y: scene.cy + g.y - scene.hexR
            width: scene.hexR * 2; height: scene.hexR * 2
            scale: g.scale * (sel || hov ? 1.12 : 1)
            visible: scene.orbitOp > 0.01 && !scene.hexOccluded(index)   // a back hex fully behind the sphere is not drawn at all
            opacity: (sel || hov ? Math.max(g.op, 0.9) : g.op) * scene.orbitOp
            z: g.depth >= 0 ? scene.zl.hexFront + g.depth * 5 + (sel || hov ? scene.zl.raised - scene.zl.hexFront : 0) : scene.zl.hexBack + g.depth * 5   // front: over the sphere and the ring; back: under the ring's back icons
            Shape {   // dark translucent badge with a thin glowing border: two wide faint strokes under the main one (no blur, no effects)
                anchors.fill: parent
                ShapePath {
                    strokeWidth: 7; strokeColor: scene.alpha(hx.edge, 0.07 * hx.glowK); fillColor: "transparent"
                    joinStyle: ShapePath.RoundJoin
                    PathPolyline { path: scene.hexPoly.concat([scene.hexPoly[0]]) }
                }
                ShapePath {
                    strokeWidth: 3.6; strokeColor: scene.alpha(hx.edge, 0.17 * hx.glowK); fillColor: "transparent"
                    joinStyle: ShapePath.RoundJoin
                    PathPolyline { path: scene.hexPoly.concat([scene.hexPoly[0]]) }
                }
                ShapePath {
                    strokeWidth: hx.sel ? 2.4 : hx.hov ? 2 : 1.3
                    strokeColor: scene.alpha(hx.edge, hx.sel ? 1 : 0.4 + 0.55 * hx.bright)
                    fillColor: scene.alpha(scene.baseColor, 0.78)
                    joinStyle: ShapePath.RoundJoin
                    PathPolyline { path: scene.hexPoly.concat([scene.hexPoly[0]]) }
                }
            }
            Image {
                visible: hx.icon !== ""
                anchors.centerIn: parent
                width: scene.hexR * 1.15; height: width
                source: hx.icon !== "" ? Qt.url("file://" + hx.icon) : ""
                sourceSize: Qt.size(64, 64)
                asynchronous: true
                smooth: true
                mipmap: true
                fillMode: Image.PreserveAspectFit
                opacity: 0.35 + 0.65 * hx.bright
            }
            Text {   // no icon: first letter in the category colour
                visible: hx.icon === ""
                anchors.centerIn: parent
                color: hx.pc
                opacity: 0.35 + 0.65 * hx.bright
                font.bold: true
                font.pixelSize: scene.hexR * 0.9
                text: hx.app && hx.app.label ? hx.app.label.charAt(0).toUpperCase() : "?"
            }
        }
    }

    // ---- connector lines: thin lines from each front group's label to its hexes (label edge to hex edge), under the hexes ----
    readonly property var hexConnectors: {
        const n = hexOrder.length, hs = [];
        if (n === 0) return [];
        for (let i = 0; i < n; i++) { const p = hexPos(i); hs.push({ x: cx + p.x, y: cy + p.y, depth: p.depth, r: hexR * p.scale }); }
        return Sphere.connectorLines(hexGroups, hexLabels, hs);
    }
    Repeater {
        model: scene.hexConnectors
        delegate: Rectangle {
            required property var modelData
            readonly property real len: Math.hypot(modelData.x2 - modelData.x1, modelData.y2 - modelData.y1)
            x: modelData.x1; y: modelData.y1 - 0.5
            width: len; height: 1
            transformOrigin: Item.Left
            rotation: Math.atan2(modelData.y2 - modelData.y1, modelData.x2 - modelData.x1) * 180 / Math.PI
            color: scene.ctl.planets[scene.hexClusters[scene.hexGroups[modelData.g].cluster].pi].color
            opacity: 0.35 * scene.orbitOp * scene.openT
            visible: scene.orbitOp > 0.01
            z: scene.zl.hexFront - 4
        }
    }

    // ---- corner brackets: tiny accent L-shapes framing the sphere and ring area; a bit brighter in the Recents view ----
    Repeater {
        model: Sphere.bracketRects(scene.width, scene.height, scene.sr, scene.ringA)
        delegate: Rectangle {
            required property var modelData
            x: modelData.x; y: modelData.y; width: modelData.w; height: modelData.h
            color: scene.cyan
            opacity: (0.28 + 0.27 * scene.orbitOp) * scene.openT
            z: scene.zl.bg + 5
        }
    }

    // ---- starfield (the existing `starfield` option): sparse, dim, static dots behind everything; painted once per size ----
    Canvas {
        id: stars
        anchors.fill: parent
        z: scene.zl.bg + 1
        visible: scene.ctl.cfg.starfield !== false
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const c = getContext("2d");
            c.clearRect(0, 0, width, height);
            const tints = ["255,255,255", "200,215,255", "255,236,210"];
            for (const s of Sphere.starField(Math.round(width * height / 3000), 99)) {
                c.fillStyle = "rgba(" + tints[s.tint] + "," + (s.a * 0.8) + ")";
                c.fillRect(Math.floor(s.x * width), Math.floor(s.y * height), s.size, s.size);
            }
        }
    }

    // ---- mouse: hover highlight, click to launch (front icons), drag to rotate ----
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: scene.hoverIdx >= 0 || scene.hoverHex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
        property real px: 0
        property real startX: 0
        property real startY: 0
        property bool moved: false
        property bool wasAnimating: false
        property bool hoverCall: false
        property bool dragHex: false   // the drag turns the orbit (Recents view) instead of the ring (All apps view)
        onPressed: m => {
            px = m.x; startX = m.x; startY = m.y; moved = false;
            wasAnimating = anim.running || animH.running; anim.stop(); animH.stop();
            dragHex = scene.curView === "hex";
            scene.ctl.dbg("press " + Math.round(m.x) + "," + Math.round(m.y));
        }
        onPositionChanged: m => {
            if (pressed) {
                if (!moved && Math.hypot(m.x - startX, m.y - startY) > scene.clickSlopPx) {
                    moved = true; scene.dragging = true; scene.hoverIdx = -1; scene.hoverHex = -1;
                }
                if (moved && dragHex) {   // finger-follow at the front of the orbit (px per slot = A * step in rad * cos tilt)
                    const n = scene.hexOrder.length;
                    scene.h0 -= (m.x - px) * (scene.ctl.cfg.drag_speed / 0.25) / (scene.orbit.A * (2 * Math.PI / n) * Math.cos(scene.orbit.roll * Math.PI / 180));
                } else if (moved) scene.s0 -= (m.x - px) * scene.ctl.cfg.drag_speed / Sphere.spacing(0, scene.ring.N, scene.warpP);
                px = m.x;
            } else {
                hoverCall = true;
                const h = scene.pickAt(m.x, m.y);
                hoverCall = false;
                scene.hoverIdx = h && h.kind === "app" ? h.idx : -1;
                scene.hoverHex = h && h.kind === "hex" ? h.idx : -1;
            }
        }
        onExited: { scene.hoverIdx = -1; scene.hoverHex = -1; }
        onReleased: m => {
            scene.ctl.dbg("release moved=" + moved + " wasAnimating=" + wasAnimating);
            if (moved && dragHex) {   // snap to the nearest hex and select it (a search keeps its own selection)
                scene.dragging = false;
                if (!scene.ctl.searching) { scene.ctl.zone = "hex"; scene.hexSel = Sphere.nearestHex(scene.h0, scene.hexOrder.length); }
                scene.flyHex(scene.ctl.searching && scene.selHexIdx >= 0 ? scene.selHexIdx : scene.hexSel >= 0 ? scene.hexSel : Sphere.nearestHex(scene.h0, scene.hexOrder.length));
                return;
            }
            if (moved) {
                scene.dragging = false;
                const n = Sphere.nearestApp(scene.ring, scene.s0);
                if (n && !scene.ctl.searching) { scene.ctl.focusIdx = n.pi; scene.ctl.selIdx = n.ai; }
                scene.flyTo(scene.tgt);
                return;
            }
            if (wasAnimating) { scene.flyTo(scene.tgt); if (scene.hexSel >= 0) scene.flyHex(scene.hexSel); return; }
            const h = scene.pickAt(m.x, m.y);
            if (h) {
                scene.ctl.dbg("launch " + h.app.label);
                scene.ctl.launchApp(h.app);
            }
        }
    }
}
