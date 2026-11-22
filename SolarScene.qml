import QtQuick
import QtQuick3D
import QtQml

// kaos-launcher "solar" style: sun at the centre, categories (planets) on a ring, apps (moons) orbit the focused planet.
// Scene interface (see the comment at the top of Launcher.qml): ctl, settled, stepBy, goTo, pickAt, reset, clearHover.
Item {
    id: scene

    property var ctl                // the Launcher controller: planets, focusIdx, selIdx, search state, cfg, launchApp, dbg
    readonly property bool settled: moonsOn   // true while the ring is at rest: moon selection allowed
    readonly property var recentShown: ctl.recentIds.slice(0, ctl.cfg.recent_count)   // v1 meaning of recent_count: brighter glow only

    readonly property real ringRadius: 260
    readonly property real ringXScale: 0.8        // the ring is an ellipse, narrower sideways, so side planets stay inside a near-square panel
    readonly property real clickSlopPx: 6         // press-to-release movement below this is a click, not a drag
    property bool hoverQuiet: false   // debug: hover picks are not logged (only clicks and the self-test)
    property real ringAngle: 0      // degrees; planet i faces the camera when ringAngle == i * stepDeg
    property int pendingIdx: 0
    property bool moonsOn: true     // moons shown only while the ring is at rest
    property int hoverApp: -1
    readonly property real stepDeg: ctl.planets.length > 0 ? 360 / ctl.planets.length : 360

    function tint(c, k) { return Qt.vector3d(c.r * k, c.g * k, c.b * k); }
    function mod(a, n) { return ((a % n) + n) % n; }

    function planetPos(i, ang) {
        const a = (i * stepDeg - ang) * Math.PI / 180;
        return Qt.vector3d(ringRadius * ringXScale * Math.sin(a), 0, ringRadius * Math.cos(a));
    }

    // ---- scene interface ----
    function reset() {   // snap to the controller's focusIdx, no animation (after load, and when this scene is created)
        anim.stop();
        pendingIdx = ctl.focusIdx; ringAngle = ctl.focusIdx * stepDeg; moonsOn = true; hoverApp = -1;
    }
    function clearHover() { hoverApp = -1; }
    function goTo(pi, ai) { goPlanet(pi); }   // fly to planet pi; the moon (ai) is selected by the controller state
    function stepBy(d) { goCell(Math.round(ringAngle / stepDeg) + d); }
    function pickAt(x, y) {   // topmost pickable object under (x, y), or null
        const r = view.pick(x, y);
        const h = r.objectHit ? r.objectHit : null;
        if (!hoverQuiet) ctl.dbg("pick(" + Math.round(x) + "," + Math.round(y) + ") -> " + (h ? (h.kind + " #" + h.idx) : "nothing"));
        return h;
    }
    Component.onCompleted: reset()

    // ---- ring animation ----
    function goCell(cell) {   // cell: unwrapped integer position of the ring
        if (ctl.planets.length === 0) return;
        moonsOn = false;
        hoverApp = -1;
        anim.stop();
        pendingIdx = mod(cell, ctl.planets.length);
        if (!ctl.searching) ctl.selIdx = -1;   // selection resets when the focused planet changes
        anim.from = ringAngle;
        anim.to = cell * stepDeg;
        anim.restart();
    }
    function curCell() { return Math.round((anim.running ? anim.to : ringAngle) / stepDeg); }
    function goPlanet(pi) {   // shortest way round to planet pi (no-op if it is already the target)
        const n = ctl.planets.length;
        if (n === 0) return;
        const cell = curCell();
        let d = mod(pi - mod(cell, n), n);
        if (d > n / 2) d -= n;
        if (d !== 0) goCell(cell + d);
    }
    function snap() { goCell(Math.round(ringAngle / stepDeg)); }

    NumberAnimation {
        id: anim
        target: scene
        property: "ringAngle"
        duration: 380
        easing.type: Easing.OutCubic
        onFinished: { ctl.focusIdx = scene.pendingIdx; scene.ringAngle = ctl.focusIdx * scene.stepDeg; scene.moonsOn = true; }
    }

    // KAOS_DEBUG=1: after start, pick at the projected centre of the front planet, a side planet and moon 0 and log hits.
    Timer {
        interval: 2500; running: ctl.debug; repeat: false
        onTriggered: {
            const pts = [["front planet", scene.planetPos(ctl.focusIdx, scene.ringAngle)]];
            for (let i = 0; i < ctl.planets.length; i++) {   // every other planet whose centre is inside the view and in front
                const p = scene.planetPos(i, scene.ringAngle), sp = view.mapFrom3DScene(p);
                if (i !== ctl.focusIdx && p.z > 0 && sp.x >= 0 && sp.x <= view.width) pts.push(["planet " + i, p]);
            }
            const m = moonRep.objectAt(0);
            if (m) pts.push(["moon 0", m.probe]);
            for (const [name, p] of pts) {
                const sp = view.mapFrom3DScene(p);
                ctl.dbg("selftest " + name + " (view " + Math.round(view.width) + "x" + Math.round(view.height) + ") at " + Math.round(sp.x) + "," + Math.round(sp.y));
                scene.pickAt(sp.x, sp.y);
            }
        }
    }

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
            clearColor: ctl.space
            backgroundMode: SceneEnvironment.Color
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.High
        }

        PerspectiveCamera {
            id: cam
            fieldOfView: 40
            position: Qt.vector3d(0, 150, scene.ringRadius + 330)
            eulerRotation.x: -19
        }
        DirectionalLight { eulerRotation.x: -25; eulerRotation.y: -20; brightness: 1.0 }
        PointLight { position: Qt.vector3d(0, 0, 0); brightness: 1.5; constantFade: 1; linearFade: 0; quadraticFade: 0 }

        Texture { id: surfTex; sourceItem: surfSrc }
        Texture { id: glowTex; sourceItem: glowSrc }
        Texture { id: sunTex; sourceItem: sunSrc }

        // starfield: one far quad facing the camera; the texture slides a little when the ring turns (static otherwise: no idle cost)
        Model {
            visible: ctl.cfg.starfield
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
                    positionU: scene.ringAngle * 0.0007
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
            model: ctl.planets.length
            delegate: Node {
                id: pn
                required property int index
                readonly property var pd: ctl.planets[index]
                readonly property color pc: pd.color
                readonly property bool front: index === ctl.focusIdx && scene.moonsOn
                position: scene.planetPos(index, scene.ringAngle)

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
                            paused: !ctl.awake
                        }
                        materials: PrincipledMaterial {
                            baseColor: pn.pc
                            baseColorMap: surfTex
                            roughness: 0.8
                            emissiveFactor: scene.tint(pn.pc, 0.2)
                        }
                    }
                }
            }
        }

        // moons of the focused planet (always at the front of the ring)
        Node {
            position: Qt.vector3d(0, 0, scene.ringRadius)
            scale: scene.moonsOn ? Qt.vector3d(1, 1, 1) : Qt.vector3d(0.001, 0.001, 0.001)
            Behavior on scale { Vector3dAnimation { duration: 220 } }

            Repeater3D {
                id: moonRep
                model: ctl.focusApps.length
                delegate: Node {
                    id: mn
                    required property int index
                    readonly property var app: ctl.focusApps[index]
                    readonly property string icon: ctl.cfg.icons && app && app.icon ? app.icon : ""
                    readonly property bool hov: scene.hoverApp === index
                    readonly property bool sel: ctl.selApp === index
                    readonly property bool hit: ctl.focusMatch[index] === true
                    readonly property bool rec: scene.recentShown.indexOf(app ? app.id : "") >= 0
                    readonly property color mc: ctl.planets[ctl.focusIdx].color
                    readonly property vector3d probe: mn.scenePosition

                    // orbit layout: several rings (more apps -> more rings), moons evenly spaced on a ring,
                    // each ring with its own tilt, yaw, radius and speed (alternating direction) so moons keep apart
                    readonly property int n: ctl.focusApps.length
                    readonly property int rings: Math.min(5, Math.max(1, Math.ceil(n / 9)))
                    readonly property int ring: index % rings
                    readonly property int perRing: Math.ceil((n - ring) / rings)
                    readonly property real phase: Math.floor(index / rings) * 360 / perRing + ring * 23
                    readonly property real orbitR: ctl.focusR + 22 + ring * 13
                    readonly property real tilt: [10, -18, 24, -10, 30][ring] * Math.PI / 180
                    readonly property real yaw: ring * 57 * Math.PI / 180
                    property real spin: 0   // 0..360, animated
                    NumberAnimation on spin {
                        from: 0; to: 360; loops: Animation.Infinite
                        duration: (42000 + mn.ring * 9000) / Math.max(0.05, ctl.cfg.orbit_speed)
                        paused: mn.hov || mn.sel || !ctl.awake || ctl.cfg.orbit_speed <= 0
                    }
                    position: {
                        const a = (phase + (ring % 2 === 0 ? spin : -spin)) * Math.PI / 180;
                        const x = orbitR * Math.cos(a), z = -orbitR * Math.sin(a);
                        const y1 = -z * Math.sin(tilt), z1 = z * Math.cos(tilt);
                        return Qt.vector3d(x * Math.cos(yaw) + z1 * Math.sin(yaw), y1, -x * Math.sin(yaw) + z1 * Math.cos(yaw));
                    }

                    // visual size as a fraction of the 100-unit sphere: selected > hovered > search hit > normal > dimmed
                    readonly property real s: sel ? 0.24 : hov ? 0.2 : hit ? (ctl.searching ? 0.17 : 0.13) : 0.08

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
                            emissiveFactor: scene.tint(mn.mc, mn.sel || mn.hov ? 0.8 : !mn.hit ? 0.03 : ctl.searching ? 0.9 : mn.rec ? 0.7 : 0.2)
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
        model: ctl.planets.length
        delegate: Text {
            id: lbl
            required property int index
            readonly property var pd: ctl.planets[index]
            readonly property point sp: {
                const p = scene.planetPos(index, scene.ringAngle);
                const resize = view.width + view.height;   // dependency: re-map on resize
                return view.mapFrom3DScene(Qt.vector3d(p.x, -pd.r - 8 + resize * 0, p.z));
            }
            x: sp.x - width / 2
            y: sp.y
            visible: scene.planetPos(index, scene.ringAngle).z > -scene.ringRadius * 0.4
            text: ctl.searching ? pd.label + "  " + ctl.planetMatches[index] : pd.label
            color: index === ctl.focusIdx && scene.moonsOn ? "#ffffff" : ctl.searching && ctl.planetMatches[index] > 0 ? "#ffe9a8" : "#9aa0b0"
            font.pixelSize: Math.max(11, view.height * 0.026)
            font.bold: index === ctl.focusIdx && scene.moonsOn
        }
    }

    MouseArea {
        id: ma
        anchors.fill: view
        hoverEnabled: true
        cursorShape: scene.hoverApp >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
        property real px: 0
        property real startX: 0
        property real startY: 0
        property bool moved: false
        property string lastHover: ""
        property bool wasAnimating: false

        onPressed: m => {
            px = m.x; startX = m.x; startY = m.y; moved = false;
            wasAnimating = anim.running; anim.stop();
            ctl.dbg("press " + Math.round(m.x) + "," + Math.round(m.y));
        }
        onPositionChanged: m => {
            if (pressed) {
                if (!moved && Math.hypot(m.x - startX, m.y - startY) > scene.clickSlopPx) {
                    moved = true; scene.moonsOn = false; scene.hoverApp = -1;
                }
                if (moved) scene.ringAngle -= (m.x - px) * ctl.cfg.drag_speed;
                px = m.x;
            } else if (scene.moonsOn) {
                scene.hoverQuiet = true;
                const h = scene.pickAt(m.x, m.y);
                scene.hoverQuiet = false;
                if (ctl.debug && (h ? h.kind + h.idx : "") !== lastHover) { lastHover = h ? h.kind + h.idx : ""; ctl.dbg("hover -> " + (lastHover || "nothing")); }
                scene.hoverApp = h && h.kind === "moon" ? h.idx : -1;
            }
        }
        onExited: scene.hoverApp = -1
        onReleased: m => {
            ctl.dbg("release moved=" + moved + " wasAnimating=" + wasAnimating);
            if (moved) { scene.snap(); return; }
            if (wasAnimating) { scene.snap(); return; }
            const h = scene.pickAt(m.x, m.y);
            if (!h) return;
            if (h.kind === "moon" && scene.moonsOn) {
                ctl.dbg("launch " + ctl.focusApps[h.idx].label);
                ctl.launchApp(ctl.focusApps[h.idx]);
            } else if (h.kind === "planet" && h.idx !== ctl.focusIdx) {
                ctl.dbg("focus planet " + h.idx);
                scene.goPlanet(h.idx);
            }
        }
    }

    // tooltip: hovered moon (at the mouse) or, failing that, the keyboard-selected moon (next to it)
    Rectangle {
        readonly property var app: scene.hoverApp >= 0 && scene.hoverApp < ctl.focusApps.length ? ctl.focusApps[scene.hoverApp]
            : scene.moonsOn && ctl.selApp >= 0 && ctl.selApp < ctl.focusApps.length ? ctl.focusApps[ctl.selApp] : null
        readonly property bool byMouse: scene.hoverApp >= 0
        readonly property point selPt: {
            const resize = view.width + view.height;   // dependency: re-map on resize
            const m = scene.moonsOn && ctl.selApp >= 0 ? moonRep.objectAt(ctl.selApp) : null;
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
                font.pixelSize: ctl.cfg.tooltip_font_size
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
                font.pixelSize: ctl.cfg.tooltip_font_size
                text: parent.parent.app ? parent.parent.app.comment : ""
            }
        }
    }
}
