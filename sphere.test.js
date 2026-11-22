const test = require("node:test");
const assert = require("node:assert");
const S = require("./sphere.js");

const near = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, a + " vs " + b);

test("buildRing: slots are consecutive per arc with a gap between arcs", () => {
    const r = S.buildRing([3, 1, 2], 1.5);
    assert.deepStrictEqual(r.items.map(i => i.slot), [0, 1, 2, 4.5, 7, 8]);
    assert.deepStrictEqual(r.start, [0, 4.5, 7]);
    assert.deepStrictEqual(r.offset, [0, 3, 4]);
    assert.deepStrictEqual(r.center, [1, 4.5, 7.5]);
    near(r.N, 3 + 1 + 2 + 3 * 1.5);
    assert.strictEqual(r.K, 3);
});

test("buildRing: empty and single-category input", () => {
    const e = S.buildRing([]);
    assert.strictEqual(e.items.length, 0);
    assert.ok(e.N >= 1);
    assert.strictEqual(S.nearestApp(e, 3), null);
    assert.strictEqual(S.buildRing([0, 2]).items.length, 2);
});

test("wrap: into (-N/2, N/2]", () => {
    near(S.wrap(0, 10), 0);
    near(S.wrap(6, 10), -4);
    near(S.wrap(-6, 10), 4);
    near(S.wrap(25, 10), 5);
    near(S.wrap(-5, 10), 5);
    near(S.wrap(10, 10), 0);
});

test("warp: front is 0, back is 180, monotonic and odd", () => {
    const N = 160;
    near(S.warp(0, N, 3), 0);
    near(Math.abs(S.warp(N / 2, N, 3)), 180);
    near(S.warp(-12, N, 3), -S.warp(12, N, 3));
    let prev = -1;
    for (let u = 0; u <= N / 2; u += 1) {
        const w = S.warp(u, N, 3);
        assert.ok(w >= prev, "monotonic at " + u);
        prev = w;
    }
});

test("warp: the front is magnified (more degrees per slot than a linear ring), the back compressed", () => {
    const N = 160;
    assert.ok(S.spacing(0, N, 3) > 360 / N * 2.5);
    assert.ok(S.spacing(70, N, 3) < 360 / N / 4);
    near(S.spacing(0, N, 3), 180 * 3 / 80);
    // derivative agrees with finite differences
    near(S.spacing(10, N, 3), S.warp(10.001, N, 3) * 1000 - S.warp(10, N, 3) * 1000, 0.05);
});

test("a 49-app arc: front half holds enough slots at readable spacing", () => {
    const N = 160, p = 3;
    let front = 0;
    for (let u = -80; u <= 80; u++) if (Math.abs(S.warp(u, N, p)) < 90) front++;
    assert.ok(front >= 30, "front slots " + front);
    // neighbouring slots at the front are well separated on a 280 px wide ring (> 24 px at depth ~1)
    const px = S.spacing(0, N, p) * Math.PI / 180 * 280;
    assert.ok(px > 24, "px " + px);
});

test("project: the front is the upper arc (negative y), the back the lower arc", () => {
    const f = S.project(0, 200, 60, 0), b = S.project(180, 200, 60, 0), s = S.project(90, 200, 60, 0);
    near(f.x, 0); near(f.y, -60); near(f.depth, 1);
    near(b.y, 60); near(b.depth, -1);
    near(s.x, 200); near(s.y, 0, 1e-9); near(s.depth, 0, 1e-9);
    near(s.tangent, 90, 1e-6);   // at the side the ring runs downwards on screen (towards the back)
    near(S.project(0, 200, 60, 0).tangent, 0, 1e-9);   // at the front the ring runs to the right
});

test("project: roll rotates the ring in its plane", () => {
    const p = S.project(90, 100, 30, 90);
    near(p.x, 0, 1e-9); near(p.y, 100);
    const q = S.project(0, 100, 30, 0);
    near(Math.abs(q.tangent), 0);
});

test("targetSlot and nearestUnwrapped never take the long way", () => {
    const r = S.buildRing([5, 5, 5], 1);
    near(S.targetSlot(r, 1, 2), r.start[1] + 2);
    near(S.targetSlot(r, 2, -1), r.center[2]);
    assert.strictEqual(S.targetSlot(r, 9, 0), 0);
    near(S.nearestUnwrapped(1, r.N - 1, r.N), 1 + (-2));   // wraps backwards
    near(S.nearestUnwrapped(r.N - 1, 1, r.N), r.N - 1 + 2);
    near(S.nearestUnwrapped(3, 5, r.N), 5);
});

test("nearestApp: gap resolves to a neighbour, wraps around", () => {
    const r = S.buildRing([2, 2], 2);   // slots 0,1 | 4,5 ; N = 8
    assert.deepStrictEqual(S.nearestApp(r, 0.2), { pi: 0, ai: 0 });
    assert.deepStrictEqual(S.nearestApp(r, 1.9), { pi: 0, ai: 1 });
    assert.deepStrictEqual(S.nearestApp(r, 3.4), { pi: 1, ai: 0 });
    assert.deepStrictEqual(S.nearestApp(r, 7.8), { pi: 0, ai: 0 });   // 7.8 is 0.2 before slot 8 = 0
    assert.deepStrictEqual(S.nearestApp(r, -0.4), { pi: 0, ai: 0 });
});

test("fibonacciSphere: n unit vectors, roughly balanced", () => {
    const pts = S.fibonacciSphere(1000);
    assert.strictEqual(pts.length, 1000);
    let sx = 0, sy = 0, sz = 0;
    for (const [x, y, z] of pts) {
        near(Math.hypot(x, y, z), 1, 1e-9);
        sx += x; sy += y; sz += z;
    }
    assert.ok(Math.hypot(sx, sy, sz) < 15);
});

test("particles: deterministic, complete, three groups, ranges", () => {
    const a = S.particles(2400, 7), b = S.particles(2400, 7);
    assert.deepStrictEqual(a, b);
    assert.strictEqual(a.amber.length + a.cyan.length + a.tint.length, 2400);
    assert.ok(a.cyan.length > 100 && a.cyan.length < 700);
    assert.ok(a.tint.length > 200 && a.tint.length < 700);
    for (const p of [...a.amber, ...a.cyan, ...a.tint]) {
        assert.ok(p.size >= 0.6 && p.size <= 1.6 && p.bright >= 0.5 && p.bright <= 1);
    }
    assert.notDeepStrictEqual(S.particles(50, 1), S.particles(50, 2));
});

test("instanceSource: one entry per particle, valid colours", () => {
    const g = S.particles(300, 3);
    const src = S.instanceSource(g.amber, 100, 0.03, [1, 0.6, 0.24]);
    assert.strictEqual((src.match(/InstanceListEntry\{/g) || []).length, g.amber.length);
    assert.ok(src.startsWith("import QtQuick\nimport QtQuick3D\nInstanceList {"));
    for (const m of src.matchAll(/color:"#([0-9a-f]+)"/g)) assert.strictEqual(m[1].length, 6);
    assert.strictEqual(S.instanceSource([], 100, 1, [1, 1, 1]).includes("InstanceListEntry"), false);
});

// ---- hexes ----
test("clusterRecents: grouped by category, ordered by newest member, newest first inside", () => {
    const items = [{ pi: 3, ai: 0 }, { pi: 1, ai: 4 }, { pi: 3, ai: 2 }, { pi: 7, ai: 1 }, { pi: 1, ai: 0 }];
    const c = S.clusterRecents(items);
    assert.deepStrictEqual(c.map(x => x.pi), [3, 1, 7]);
    assert.deepStrictEqual(c[0].items.map(i => i.rank), [0, 2]);
    assert.deepStrictEqual(c[1].items.map(i => i.rank), [1, 4]);
    assert.deepStrictEqual(S.clusterRecents([]), []);
    const o = S.hexOrder(c);
    assert.deepStrictEqual(o.map(i => i.rank), [0, 2, 1, 4, 3]);
    assert.deepStrictEqual(o.map(i => i.cluster), [0, 0, 1, 1, 2]);
    assert.deepStrictEqual(o.map(i => i.pos), [0, 1, 0, 1, 0]);
});

test("hexBrightness: newest brightest, monotonic, bounded", () => {
    near(S.hexBrightness(0), 1);
    near(S.hexBrightness(19), 0.45);
    near(S.hexBrightness(40), 0.45);
    near(S.hexBrightness(-3), 1);
    for (let r = 1; r < 20; r++) assert.ok(S.hexBrightness(r) < S.hexBrightness(r - 1));
});

test("hexPoints: six corners at distance R", () => {
    const p = S.hexPoints(10);
    assert.strictEqual(p.length, 6);
    p.forEach(q => near(Math.hypot(q.x, q.y), 10, 1e-9));
    near(Math.max(...p.map(q => q.y)), 10);   // pointy-top
});

test("buildRing: an arc without ring apps takes no slot", () => {
    const r = S.buildRing([2, 0, 2], 1);
    assert.deepStrictEqual(r.items.map(i => i.slot), [0, 1, 3, 4]);
    near(r.N, 2 + 2 + 2 * 1);
    assert.strictEqual(r.start[2], 3);
});

// ---- hex orbit ----
const PANELS = [[960, 540], [1280, 720], [1920, 1080], [700, 700]];
const panel = (W, H, n) => {
    const base = Math.max(15, H * 0.046), ring = S.ringAxes(W, H), o = S.orbitGeom(W, H, base, undefined, undefined, ring.A, n), lp = Math.max(10, H * 0.023);
    // the subdued inner ring in the Recents view: its icons are about 3.4% of the height, so its band is thin
    return { W, H, cx: W / 2, cy: H / 2, A: o.A, B: o.B, roll: o.roll, R: o.R, m: 10, labelH: lp * 1.3, charW: lp * 0.62 + 2,
        avoid: { A: ring.A, B: ring.B, roll: -9, half: H * 0.034 + lp } };
};
// n hexes in g groups (sizes as even as possible), as a walk order
const order = (n, g) => S.hexOrder(S.clusterRecents(Array.from({ length: n }, (_, i) => ({ pi: Math.floor(i * g / n), ai: i }))));

test("orbitGeom: fits the panel (hex centres, hexes and room for labels) at every panel size", () => {
    for (const [W, H] of PANELS) {
        const R = Math.max(15, H * 0.046), o = S.orbitGeom(W, H, R), r = o.roll * Math.PI / 180;
        const halfW = Math.hypot(o.A * Math.cos(r), o.B * Math.sin(r)), halfH = Math.hypot(o.A * Math.sin(r), o.B * Math.cos(r));
        assert.ok(halfW + R <= W / 2 - 10, W + "x" + H + " width");
        assert.ok(halfH + R <= H / 2 - 10 - 16, W + "x" + H + " height (incl. status line)");
        near(o.B / o.A, S.ORBIT_RATIO);
        // extreme hexes really are inside, by sampling the whole orbit
        for (let i = 0; i < 40; i++) {
            const p = S.orbitPos(i, 40, 0, o.A, o.B, o.roll);
            assert.ok(Math.abs(p.x) <= halfW + 1e-6 && Math.abs(p.y) <= halfH + 1e-6);
        }
    }
});

test("orbit leans the opposite way from the ring (-9 degrees), at a gentle angle, and is larger on 16:9 panels", () => {
    assert.ok(S.ORBIT_ROLL > 0, "opposite lean");
    assert.ok(S.ORBIT_ROLL >= 8 && S.ORBIT_ROLL <= 16, "gentle tilt like the reference");
    assert.ok(S.ORBIT_ROLL - (-9) >= 15, "the orbits cross at an angle of at least 15 degrees");
    assert.ok(S.ORBIT_RATIO >= 0.35 && S.ORBIT_RATIO <= 0.55);
    const o = S.orbitGeom(960, 540, 25);
    const sr = Math.tan(Math.asin(100 / 630)) / Math.tan(15 * Math.PI / 180) * 540 / 2;
    assert.ok(o.A > Math.min(2.0 * sr, 960 * 0.44), "larger than the ring");
    assert.ok(o.B > sr * 0.9, "the orbit wraps the sphere");
});

test("orbitPos: points lie on the rotated ellipse, evenly spaced in angle, front hex at depth 1", () => {
    const A = 300, B = 150, roll = 32, n = 12, r = -roll * Math.PI / 180;
    for (let i = 0; i < n; i++) {
        const p = S.orbitPos(i, n, 0, A, B, roll);
        const u = p.x * Math.cos(r) - p.y * Math.sin(r), v = p.x * Math.sin(r) + p.y * Math.cos(r);
        near(Math.hypot(u / A, v / B), 1, 1e-9);
    }
    const f = S.orbitPos(0, n, 0, A, B, roll);
    near(f.depth, 1); near(f.phi, 0);
    near(S.orbitPos(6, n, 0, A, B, roll).depth, -1, 1e-9);
    near(S.orbitPos(1, n, 0, A, B, roll).phi, 30);
    near(S.orbitPos(11, n, 0, A, B, roll).phi, -30);
    // rotating by h0 brings that hex to the front
    near(S.orbitPos(5, n, 5, A, B, roll).depth, 1);
    near(S.orbitPos(5, n, 4.5, A, B, roll).phi, 15);
});

test("orbitPos: a single hex sits at the front, two are opposite", () => {
    near(S.orbitPos(0, 1, 0, 300, 150, 32).depth, 1);
    near(S.orbitPos(1, 2, 0, 300, 150, 32).depth, -1, 1e-9);
});

test("depthLook: back is smaller and dimmer, only the front is clickable", () => {
    const f = S.depthLook(1), b = S.depthLook(-1), m = S.depthLook(0.2);
    near(f.scale, 1); near(f.op, 1);
    assert.ok(b.scale < 0.6 && b.op < 0.4);
    assert.strictEqual(f.clickable, true);
    assert.strictEqual(m.clickable, true);
    assert.strictEqual(S.depthLook(0.15).clickable, false);
    assert.strictEqual(S.depthLook(-0.5).clickable, false);
    for (let d = -1; d < 1; d += 0.1) assert.ok(S.depthLook(d + 0.1).scale >= S.depthLook(d).scale);
});

test("nearestHex: rounds and wraps; -1 for an empty orbit", () => {
    assert.strictEqual(S.nearestHex(2.4, 5), 2);
    assert.strictEqual(S.nearestHex(2.6, 5), 3);
    assert.strictEqual(S.nearestHex(-0.6, 5), 4);
    assert.strictEqual(S.nearestHex(4.6, 5), 0);
    assert.strictEqual(S.nearestHex(7.2, 5), 2);
    assert.strictEqual(S.nearestHex(1, 0), -1);
});

test("hexGroups: contiguous runs by category in walk order", () => {
    const o = order(7, 3);
    const g = S.hexGroups(o);
    assert.strictEqual(g.length, 3);
    assert.strictEqual(g[0].start, 0);
    assert.strictEqual(g[g.length - 1].end, 6);
    g.forEach((x, i) => { if (i > 0) assert.strictEqual(x.start, g[i - 1].end + 1); });
    assert.deepStrictEqual(S.hexGroups([]), []);
    // newest member decides the group order, newest first inside
    const items = [{ pi: 5, ai: 0 }, { pi: 2, ai: 1 }, { pi: 5, ai: 3 }];
    const oo = S.hexOrder(S.clusterRecents(items));
    assert.deepStrictEqual(oo.map(h => h.pi), [5, 5, 2]);
    assert.deepStrictEqual(oo.map(h => h.rank), [0, 2, 1]);
});

const overlap = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
for (const [W, H] of PANELS) {
    for (const [n, g] of [[1, 1], [3, 3], [9, 9], [20, 5], [20, 10], [7, 2]]) {
        test(`orbitLabels ${W}x${H} ${n} hexes in ${g} groups: labels never touch hexes, each other or the panel edge (all rotations)`, () => {
            const geo = panel(W, H, n), o = order(n, g), groups = S.hexGroups(o);
            const texts = {};
            S.clusterRecents(Array.from({ length: n }, (_, i) => ({ pi: Math.floor(i * g / n), ai: i }))).forEach((c, ci) => { texts[ci] = "CATEGORY" + ci; });
            let sawFront = 0;
            for (let h0 = 0; h0 < n; h0 += 0.5) {
                const L = S.orbitLabels(groups, texts, n, h0, geo);
                assert.strictEqual(L.length, groups.length);
                const vis = L.filter(l => l.visible);
                vis.forEach((l, i) => {
                    assert.ok(l.x >= 0 && l.y >= 0 && l.x + l.w <= W && l.y + l.h <= H, "inside");
                    vis.slice(i + 1).forEach(m => assert.ok(!overlap(l, m), "labels overlap"));
                    [l.x, l.x + l.w / 2, l.x + l.w].forEach(px => assert.ok(S.ellipseDist(px, l.y + l.h / 2, geo.cx, geo.cy, geo.avoid.A, geo.avoid.B, geo.avoid.roll) >= geo.avoid.half, "label on the ring band"));
                    for (let k = 0; k < n; k++) {
                        const p = S.orbitPos(k, n, h0, geo.A, geo.B, geo.roll);
                        if (p.depth <= -0.3) continue;
                        const r = geo.R * S.depthLook(p.depth).scale, cx = Math.max(l.x, Math.min(geo.cx + p.x, l.x + l.w)), cy = Math.max(l.y, Math.min(geo.cy + p.y, l.y + l.h));
                        assert.ok(Math.hypot(cx - geo.cx - p.x, cy - geo.cy - p.y) >= r, "label over hex " + k);
                    }
                });
                if (Number.isInteger(h0) && vis.length > 0) sawFront++;
            }
            assert.ok(sawFront >= 1, "at least one label is shown when a hex is at the front");
        });
    }
}

test("orbitLabels: no hexes -> no labels; groups at the back are hidden", () => {
    const geo = panel(960, 540, 2);
    assert.deepStrictEqual(S.orbitLabels([], {}, 0, 0, geo), []);
    const groups = S.hexGroups(order(2, 2));
    const L = S.orbitLabels(groups, { 0: "A", 1: "B" }, 2, 0, geo);
    assert.strictEqual(L[0].visible, true);
    assert.strictEqual(L[1].visible, false);   // opposite side of the orbit
});

// ---- views, fades, occlusion ----
test("openView / matchView / toggleView: Recents only when there are hexes", () => {
    assert.strictEqual(S.openView(20), "hex");
    assert.strictEqual(S.openView(1), "hex");
    assert.strictEqual(S.openView(0), "ring");
    assert.strictEqual(S.matchView(true, 5), "hex");
    assert.strictEqual(S.matchView(false, 5), "ring");
    assert.strictEqual(S.matchView(true, 0), "ring");
    assert.strictEqual(S.toggleView("hex", 5), "ring");
    assert.strictEqual(S.toggleView("ring", 5), "hex");
    assert.strictEqual(S.toggleView("ring", 0), "ring");   // Tab does nothing without hexes
    assert.strictEqual(S.toggleView("hex", 0), "ring");
});

test("viewFades: zoom grows and the orbit fades out with t", () => {
    const a = S.viewFades(0), b = S.viewFades(1);
    near(a.zoom, 1); near(a.orbitOp, 1);
    near(b.zoom, S.ZOOM_ALL); near(b.orbitOp, 0);
    assert.ok(S.ZOOM_ALL >= 1.3 && S.ZOOM_ALL <= 1.6);
    let prevZ = 0, prevO = 2;
    for (let t = 0; t <= 1.0001; t += 0.05) {
        const f = S.viewFades(t);
        assert.ok(f.zoom >= prevZ && f.orbitOp <= prevO);
        prevZ = f.zoom; prevO = f.orbitOp;
    }
    near(S.viewFades(-1).zoom, 1); near(S.viewFades(5).zoom, S.ZOOM_ALL);
});

test("ringLook: subdued and without labels or stripes in Recents, full in All apps, monotonic in between", () => {
    const a = S.ringLook(0, 0.42), b = S.ringLook(1, 0.42);
    near(a.alpha, 0.42); near(a.detail, 0); near(a.mix, 0);
    near(a.backing, 1); near(b.backing, 0); near(S.ringLook(0.5, 0.42).backing, 0); near(S.ringLook(0.25, 0.42).backing, 0.5);
    near(b.alpha, 1); near(b.detail, 1); near(b.mix, 1);
    near(S.ringLook(0.5, 0.42).detail, 0);   // labels start fading in only in the second half
    let p = { alpha: 0, detail: -1, mix: -1 };
    for (let t = 0; t <= 1.0001; t += 0.05) {
        const f = S.ringLook(t, 0.42);
        assert.ok(f.alpha >= p.alpha && f.detail >= p.detail && f.mix >= p.mix);
        p = f;
    }
    near(S.ringLook(-3, 0.5).alpha, 0.5); near(S.ringLook(9, 0.5).alpha, 1);
});

test("ellipseDist: zero on the ellipse, grows away from it", () => {
    const p = S.orbitPos(3, 12, 0, 300, 150, 12);
    near(S.ellipseDist(500 + p.x, 300 + p.y, 500, 300, 300, 150, 12), 0, 1e-6);
    assert.ok(S.ellipseDist(500 + p.x * 1.3, 300 + p.y * 1.3, 500, 300, 300, 150, 12) > 20);
});

test("hexOccluded: only back hexes fully inside the sphere disc are hidden; front hexes never", () => {
    assert.strictEqual(S.hexOccluded(-1, 10, 10, 20, 160), true);
    assert.strictEqual(S.hexOccluded(-0.01, 0, 0, 20, 160), true);
    assert.strictEqual(S.hexOccluded(-1, 150, 0, 20, 160), false);    // sticks out of the disc
    assert.strictEqual(S.hexOccluded(-1, 300, 0, 10, 160), false);    // outside the disc
    for (const d of [0, 0.2, 1]) assert.strictEqual(S.hexOccluded(d, 0, 0, 5, 1000), false);
    // on a small orbit that passes over the sphere: no front hex is ever hidden, and some back hexes are
    const R = 25, o = { A: 300, B: 110, roll: S.ORBIT_ROLL }, sr = Math.tan(Math.asin(100 / 630)) / Math.tan(15 * Math.PI / 180) * 270;
    let hiddenBack = 0;
    for (let h0 = 0; h0 < 20; h0 += 0.5) for (let i = 0; i < 20; i++) {
        const p = S.orbitPos(i, 20, h0, o.A, o.B, o.roll), hid = S.hexOccluded(p.depth, p.x, p.y, R * S.depthLook(p.depth).scale, sr);
        if (p.depth >= 0) assert.strictEqual(hid, false);
        else if (hid) hiddenBack++;
    }
    assert.ok(hiddenBack > 0, "the orbit does pass behind the sphere");
    // the real orbit at 960x540 wraps the sphere: front hexes are still never hidden
    const g = S.orbitGeom(960, 540, R);
    for (let i = 0; i < 20; i++) { const p = S.orbitPos(i, 20, 0, g.A, g.B, g.roll); if (p.depth >= 0) assert.strictEqual(S.hexOccluded(p.depth, p.x, p.y, R, sr), false); }
});

test("orbit is clearly bigger than the inner ring, but only about ORBIT_RING_FACTOR times (major axis), at 16:9 panels", () => {
    for (const [W, H] of [[960, 540], [1280, 720], [1920, 1080]]) {
        const ring = S.ringAxes(W, H), o = S.orbitGeom(W, H, Math.max(15, H * 0.046), undefined, undefined, ring.A, 20);
        const f = o.A / ring.A;
        assert.ok(f >= 1.2 && f <= 1.35, W + "x" + H + " factor " + f);
        assert.ok(o.B > ring.B, "taller than the ring");
    }
    const r = S.ringAxes(960, 540);
    assert.ok(Math.abs(r.A - 324) < 1 && Math.abs(r.B - 90.7) < 0.5);
});

for (const [W, H] of PANELS) {
    for (const n of [1, 2, 3, 9, 20]) {
        test(`hexes never overlap at ${n} hexes, ${W}x${H}; front hexes clear the status line and the core text`, () => {
            const ring = S.ringAxes(W, H), base = Math.max(15, H * 0.046), o = S.orbitGeom(W, H, base, undefined, undefined, ring.A, n);
            assert.ok(o.R <= base && o.R >= base * (W / H > 1.5 ? 0.8 : 0.5), "hex radius " + o.R + " vs " + base);   // square panels shrink the hexes more
            const w = Math.sqrt(3) * o.R;
            for (let h0 = 0; h0 < n; h0 += 0.5) {
                const ps = [];
                for (let i = 0; i < n; i++) ps.push(S.orbitPos(i, n, h0, o.A, o.B, o.roll));
                for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
                    assert.ok(Math.hypot(ps[i].x - ps[j].x, ps[i].y - ps[j].y) >= w * 1.0, `hexes ${i},${j} touch at h0=${h0}`);
                }
                ps.filter(p => p.depth > 0.5).forEach(p => {
                    const sc = S.depthLook(p.depth).scale;
                    assert.ok(H / 2 + p.y + o.R * sc <= H - 36 + 1, "front hex over the status line");
                    assert.ok(!(Math.abs(p.x) < ring.sr * 0.7 && Math.abs(p.y) < ring.sr * 0.2 + o.R * sc), "front hex over the core text (name up to two lines + category: about +-0.2 sr)");
                });
            }
        });
    }
}

test("Z: layers run back to front as documented", () => {
    const order = ["bg", "hexBack", "ringBack", "disc", "view", "ringBackOver", "ringFront", "hexFront", "raised", "coreText", "label"];
    for (let i = 1; i < order.length; i++) assert.ok(S.Z[order[i]] > S.Z[order[i - 1]], order[i] + " above " + order[i - 1]);
    // each depth-dependent layer may add -5..5: the outer orbit's back hexes stay below the ring's back icons, which stay below the disc
    assert.ok(S.Z.hexBack + 5 < S.Z.ringBack - 5);
    assert.ok(S.Z.ringBack + 5 < S.Z.disc && S.Z.disc < S.Z.view);
    // the ring's back icons move over the sphere at the transition midpoint (ringBackOver): back hexes still stay below them
    assert.ok(S.Z.hexBack + 5 < S.Z.ringBackOver - 5 || S.Z.hexBack + 5 < S.Z.view);
    assert.ok(S.Z.ringBackOver > S.Z.view && S.Z.ringFront > S.Z.view);
    // front hexes win over the ring's front icons (which add up to 2 + bonuses); selected/hovered hexes are raised above everything but labels
    assert.ok(S.Z.hexFront > S.Z.ringFront + 2 + 3 + 5);
    assert.ok(S.Z.hexFront + 5 + S.Z.raised - S.Z.hexFront < S.Z.label + 20);
});

// ---- focus at the top ----
test("the focus (front-most hex of the orbit, the selected app of the ring) is at the TOP of its ellipse, and the rolls are unchanged", () => {
    for (const [W, H] of PANELS) {
        const ring = S.ringAxes(W, H), o = S.orbitGeom(W, H, Math.max(15, H * 0.046), undefined, undefined, ring.A, 20);
        const f = S.orbitPos(0, 20, 0, o.A, o.B, o.roll), b = S.orbitPos(10, 20, 0, o.A, o.B, o.roll);
        assert.ok(f.y < -o.B * 0.9 && f.depth === 1, W + "x" + H + " front hex is at the top");
        assert.ok(b.y > o.B * 0.9, "back hex is at the bottom");
        const rf = S.project(0, ring.A, ring.B, -9);
        assert.ok(rf.y < -ring.B * 0.9, "the ring's front is at the top as well");
        // the ellipse itself still leans the same way: a point at the right end is higher for the ring (-9) and lower for the orbit (+12)
        assert.ok(S.project(90, ring.A, ring.B, -9).y < 0 && S.project(90, o.A, o.B, o.roll).y > 0);
        // front hexes clear the controller's search line at the top (it ends at about y = 50) and sit well above the status line
        for (let h0 = 0; h0 < 20; h0 += 0.5) for (let i = 0; i < 20; i++) {
            const p = S.orbitPos(i, 20, h0, o.A, o.B, o.roll);
            if (p.depth > 0.5) assert.ok(H / 2 + p.y - o.R * S.depthLook(p.depth).scale >= 52 - 1, "front hex under the search line");
        }
    }
});

test("hexOccluded: with the front at the top the hidden hexes are on the lower half of the sphere", () => {
    const R = 25, sr = S.sphereRadiusPx(540), o = { A: 300, B: 110, roll: S.ORBIT_ROLL };
    let lower = 0, upper = 0;
    for (let h0 = 0; h0 < 20; h0 += 0.5) for (let i = 0; i < 20; i++) {
        const p = S.orbitPos(i, 20, h0, o.A, o.B, o.roll);
        if (S.hexOccluded(p.depth, p.x, p.y, R * S.depthLook(p.depth).scale, sr)) { if (p.y > 0) lower++; else upper++; }
    }
    assert.ok(lower > 0 && lower >= upper * 3, "hidden: lower " + lower + ", upper " + upper);
});


// ---- HUD: connectors, brackets, starfield ----
test("segmentHitsRect", () => {
    const r = { x: 10, y: 10, w: 20, h: 20 };
    assert.strictEqual(S.segmentHitsRect(0, 20, 40, 20, r), true);
    assert.strictEqual(S.segmentHitsRect(0, 0, 5, 5, r), false);
    assert.strictEqual(S.segmentHitsRect(15, 15, 16, 16, r), true);   // inside
    assert.strictEqual(S.segmentHitsRect(0, 50, 40, 50, r), false);
    assert.strictEqual(S.segmentHitsRect(20, 0, 20, 9, r), false);
    assert.strictEqual(S.segmentHitsRect(20, 0, 20, 12, r), true);
});

for (const [W, H] of PANELS) {
    for (const [n, g] of [[1, 1], [3, 3], [9, 9], [20, 5], [20, 10]]) {
        test(`connectors ${W}x${H} ${n} hexes in ${g} groups: label edge to hex edge, front hexes only, never through the core text`, () => {
            const geo = panel(W, H, n), o = order(n, g), groups = S.hexGroups(o), sr = S.ringAxes(W, H).sr;
            const texts = {};
            groups.forEach(gr => { texts[gr.cluster] = "CATEGORY" + gr.cluster; });
            const core = { x: W / 2 - sr * 0.6, y: H / 2 - sr * 0.32, w: sr * 1.2, h: sr * 0.64 };
            let total = 0;
            for (let h0 = 0; h0 < n; h0 += 0.5) {
                const labels = S.orbitLabels(groups, texts, n, h0, geo);
                const hexes = [];
                for (let i = 0; i < n; i++) { const p = S.orbitPos(i, n, h0, geo.A, geo.B, geo.roll); hexes.push({ x: W / 2 + p.x, y: H / 2 + p.y, depth: p.depth, r: geo.R * S.depthLook(p.depth).scale }); }
                const lines = S.connectorLines(groups, labels, hexes);
                total += lines.length;
                lines.forEach(l => {
                    assert.ok(labels[l.g].visible, "only for visible labels");
                    const lab = labels[l.g];
                    assert.ok(l.x1 >= lab.x - 1e-6 && l.x1 <= lab.x + lab.w + 1e-6 && l.y1 >= lab.y - 1e-6 && l.y1 <= lab.y + lab.h + 1e-6, "starts on the label");
                    const hx = hexes.find((h, i) => i >= groups[l.g].start && i <= groups[l.g].end && Math.abs(Math.hypot(l.x2 - h.x, l.y2 - h.y) - h.r) < 1e-6);
                    assert.ok(hx && hx.depth > 0.15, "ends on the edge of a front hex of its group");
                    assert.ok(!S.segmentHitsRect(l.x1, l.y1, l.x2, l.y2, core), "line through the core text");
                });
            }
            if (n >= 3) assert.ok(total > 0, "some connector lines exist");   // a lone hex sits right next to its label: no line needed
        });
    }
}

test("connectorLines: none without labels or for back hexes", () => {
    const groups = [{ start: 0, end: 1 }], hexes = [{ x: 100, y: 100, depth: 0.9, r: 20 }, { x: 200, y: 100, depth: -0.5, r: 10 }];
    assert.deepStrictEqual(S.connectorLines(groups, [{ visible: false }], hexes), []);
    const L = S.connectorLines(groups, [{ visible: true, x: 80, y: 20, w: 60, h: 14 }], hexes);
    assert.strictEqual(L.length, 1);
    assert.deepStrictEqual(S.connectorLines([], [], []), []);
});

for (const [W, H] of PANELS) {
    test(`bracketRects ${W}x${H}: tiny, inside the panel, clear of the search and status lines, both views`, () => {
        for (const zoom of [1, S.ZOOM_ALL]) {
            const ring = S.ringAxes(W, H, zoom), rects = S.bracketRects(W, H, ring.sr, ring.A);
            assert.strictEqual(rects.length, 8);
            rects.forEach(r => {
                assert.ok(r.x >= 10 && r.y >= 10 && r.x + r.w <= W - 10 && r.y + r.h <= H - 10, "inside with margin");
                assert.ok(r.w <= H * 0.04 + 12 && r.h <= H * 0.04 + 12, "tiny");
                assert.ok(!(r.y < 58 && r.x < W / 2 + W * 0.26 && r.x + r.w > W / 2 - W * 0.26), "search line");
                assert.ok(!(r.y + r.h > H - 36 && r.x < W * 0.6), "status line");
            });
        }
    });
}

test("starField: seeded, stable, in range, dim", () => {
    const a = S.starField(150, 99), b = S.starField(150, 99);
    assert.deepStrictEqual(a, b);
    assert.strictEqual(a.length, 150);
    a.forEach(s => assert.ok(s.x >= 0 && s.x < 1 && s.y >= 0 && s.y < 1 && s.a >= 0.08 && s.a <= 0.4 && (s.size === 1 || s.size === 2) && s.tint >= 0 && s.tint <= 2));
    assert.notDeepStrictEqual(S.starField(10, 1), S.starField(10, 2));
    assert.deepStrictEqual(S.starField(0), []);
});
