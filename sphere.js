// kaos-launcher sphere style: pure layout and particle functions, no QML types, so `node --test` can load them.
// In QML: import "sphere.js" as Sphere. In node: require("./sphere.js").
//
// Ring model: every app has an integer "slot" on a circular track of N slots; categories are consecutive runs of
// slots (arcs) separated by a gap. The ring is centred on a real-valued focus slot s0. warp() turns the slot offset
// u = slot - s0 into a displayed angle with a fisheye: dense and large near the front (phi = 0), compressed towards the
// back, so a 49-app arc stays readable and the whole ring still fits 360 degrees.

// counts: apps per category -> {N, K, start[], center[], offset[], items[{pi, ai, slot}]}
function buildRing(counts, gap) {
    if (gap === undefined) gap = 1.6;
    const start = [], center = [], offset = [], items = [];
    let slot = 0;
    counts.forEach((n, pi) => {
        start.push(slot);
        offset.push(items.length);
        for (let ai = 0; ai < n; ai++) items.push({ pi, ai, slot: slot + ai });
        center.push(n > 0 ? slot + (n - 1) / 2 : slot - gap / 2);   // an empty arc (all its apps are hexes) takes no slot
        if (n > 0) slot += n + gap;
    });
    return { N: Math.max(1, slot), K: counts.length, start, center, offset, items };
}

// wrap u into (-N/2, N/2]
function wrap(u, N) {
    let w = u - N * Math.floor(u / N);   // [0, N)
    if (w > N / 2) w -= N;
    return w;
}

// displayed angle in degrees (0 = front, +-180 = back) for slot offset u; p > 1 magnifies the front
function warp(u, N, p) {
    const h = N / 2, w = wrap(u, N), t = Math.min(1, Math.abs(w) / h);
    return Math.sign(w) * 180 * (1 - Math.pow(1 - t, p));
}

// degrees per slot at slot offset u (derivative of warp)
function spacing(u, N, p) {
    const h = N / 2, t = Math.min(1, Math.abs(wrap(u, N)) / h);
    return (180 * p / h) * Math.pow(1 - t, p - 1);
}

// point on the tilted ring: a, b = ellipse semi-axes (px), roll = in-plane tilt (degrees). The rings are seen from below, like
// the reference: the front is the UPPER arc (negative y, depth +1) and the back the lower arc (depth -1), so the selected item,
// which sits at the front, is at the top. Also returns the screen tangent angle (degrees) of the ring.
function project(phiDeg, a, b, rollDeg) {
    const f = phiDeg * Math.PI / 180, r = rollDeg * Math.PI / 180, cr = Math.cos(r), sr = Math.sin(r);
    const X = a * Math.sin(f), Y = -b * Math.cos(f), dX = a * Math.cos(f), dY = b * Math.sin(f);
    return {
        x: X * cr - Y * sr, y: X * sr + Y * cr, depth: Math.cos(f),
        tangent: Math.atan2(dX * sr + dY * cr, dX * cr - dY * sr) * 180 / Math.PI,
    };
}

// slot to centre on: app (pi, ai), or the arc centre when ai < 0
function targetSlot(ring, pi, ai) {
    if (pi < 0 || pi >= ring.K) return 0;
    return ai >= 0 ? ring.start[pi] + ai : ring.center[pi];
}

// shortest unwrapped target so an animation from s0 never takes the long way round
function nearestUnwrapped(s0, target, N) {
    return s0 + wrap(target - s0, N);
}

// the app whose slot is nearest to s (slot gaps resolve to the closer neighbour), or null for an empty ring
function nearestApp(ring, s) {
    if (ring.items.length === 0) return null;
    let best = null, bd = Infinity;
    for (const it of ring.items) {
        const d = Math.abs(wrap(it.slot - s, ring.N));
        if (d < bd) { bd = d; best = it; }
    }
    return { pi: best.pi, ai: best.ai };
}

// deterministic pseudo-random generator (LCG), so the sphere looks the same on every start
function rng(seed) {
    let s = seed >>> 0;
    return () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296;
}

// n points evenly spread on the unit sphere (Fibonacci spiral)
function fibonacciSphere(n) {
    const out = [], ga = Math.PI * (3 - Math.sqrt(5));
    for (let i = 0; i < n; i++) {
        const y = 1 - 2 * (i + 0.5) / n, r = Math.sqrt(1 - y * y), t = ga * i;
        out.push([Math.cos(t) * r, y, Math.sin(t) * r]);
    }
    return out;
}

// split the sphere points into groups: "cyan" patches (caps around a few directions), "tint" (scattered subset that
// takes the focused category colour) and "amber" (the rest). Each particle: {x, y, z, size (0.6..1.6), bright (0.5..1)}.
function particles(n, seed) {
    const rnd = rng(seed === undefined ? 7 : seed);
    const caps = [[0.8, 0.25, 0.55], [-0.5, -0.3, 0.8], [0.2, 0.7, -0.7]].map(v => {
        const l = Math.hypot(v[0], v[1], v[2]);
        return v.map(c => c / l);
    });
    const groups = { amber: [], cyan: [], tint: [] };
    for (const [x, y, z] of fibonacciSphere(n)) {
        const p = { x, y, z, size: 0.6 + rnd(), bright: 0.5 + 0.5 * rnd() };
        const inCap = caps.some(c => x * c[0] + y * c[1] + z * c[2] > 0.82);
        if (inCap && rnd() < 0.75) groups.cyan.push(p);
        else if (rnd() < 0.2) groups.tint.push(p);
        else groups.amber.push(p);
    }
    return groups;
}

// QML source text of an InstanceList for a particle list, to be built once with Qt.createQmlObject.
// radius = sphere radius in scene units, unit = scale of the particle model (100-unit cube), rgb = base colour [r, g, b] 0..1
function instanceSource(list, radius, unit, rgb) {
    const f = v => v.toFixed(3);
    let s = "import QtQuick\nimport QtQuick3D\nInstanceList {\n";
    for (const p of list) {
        const k = unit * p.size, c = rgb.map(v => Math.round(Math.min(1, v * p.bright) * 255).toString(16).padStart(2, "0")).join("");
        s += "InstanceListEntry{position.x:" + f(p.x * radius) + ";position.y:" + f(p.y * radius) + ";position.z:" + f(p.z * radius)
            + ";scale.x:" + f(k) + ";scale.y:" + f(k) + ";scale.z:" + f(k) + ";color:\"#" + c + "\"}\n";
    }
    return s + "}\n";
}

// ---- recent-app hexes (outside the ring) ----

// items: [{pi, ai}] newest first (rank = array position) -> clusters by category, ordered by their newest member:
// [{pi, items: [{pi, ai, rank}]}]. Within a cluster the apps stay newest first.
function clusterRecents(items) {
    const clusters = [], byPi = {};
    items.forEach((it, rank) => {
        let c = byPi[it.pi];
        if (!c) { c = { pi: it.pi, items: [] }; byPi[it.pi] = c; clusters.push(c); }
        c.items.push({ pi: it.pi, ai: it.ai, rank });
    });
    return clusters;
}

// walk order of the hex zone: cluster by cluster, newest first inside each. Adds cluster and pos (index in cluster).
function hexOrder(clusters) {
    const out = [];
    clusters.forEach((c, ci) => c.items.forEach((it, pos) => out.push({ pi: it.pi, ai: it.ai, rank: it.rank, cluster: ci, pos })));
    return out;
}

// brightness 1 (newest) .. 0.45 (the 20th)
function hexBrightness(rank) {
    return 1 - 0.55 * Math.min(Math.max(rank, 0), 19) / 19;
}

// corners of a pointy-top regular hexagon with circumradius R, around (0, 0)
function hexPoints(R) {
    const out = [];
    for (let i = 0; i < 6; i++) {
        const a = (60 * i - 30) * Math.PI / 180;
        out.push({ x: R * Math.cos(a), y: R * Math.sin(a) });
    }
    return out;
}

// ---- the outer orbit of recent-app hexes: a second, larger ellipse tilted on another diagonal than the ring ----

const ORBIT_ROLL = 12, ORBIT_RATIO = 0.38;   // in-plane tilt (degrees; the ring uses -9, the other way) and minor/major axis ratio

// screen radius (px) of the sphere silhouette for a panel of height H (perspective camera, centred; R = sphere radius in scene units)
function sphereRadiusPx(H, camDist, fov, R) {
    if (camDist === undefined) camDist = 630;
    if (fov === undefined) fov = 30;
    if (R === undefined) R = 100;
    return Math.tan(Math.asin(R / camDist)) / Math.tan(fov * Math.PI / 360) * H / 2;
}

// semi-axes of the inner ring in the Recents view (zoom 1): {A, B, sr}; the scene uses the same formula at any zoom
function ringAxes(W, H, zoom) {
    const sr = sphereRadiusPx(H, 630 / (zoom || 1)), A = Math.min(2.0 * sr, W * 0.44);
    return { A, B: A * 0.28, sr };
}

const ORBIT_RING_FACTOR = 1.22;   // the orbit is about this much bigger than the inner ring (major axis)

// Orbit semi-axes for a W x H panel and n hexes of circumradius R: the biggest ellipse whose hex centres stay inside the
// panel with room for the hexes, their labels and the controller's status line, but not bigger than ORBIT_RING_FACTOR times
// the inner ring (ringA, optional). The hex radius is reduced when n hexes would otherwise touch along the narrow part of the
// orbit. -> {A, B, roll, R}
function orbitGeom(W, H, R, roll, ratio, ringA, n) {
    if (roll === undefined) roll = ORBIT_ROLL;
    if (ratio === undefined) ratio = ORBIT_RATIO;
    const m = R * 1.4 + 26, r = roll * Math.PI / 180, c = Math.cos(r), s = Math.sin(r);
    const kx = Math.sqrt(c * c + ratio * ratio * s * s), ky = Math.sqrt(s * s + ratio * ratio * c * c);   // half extents per unit A
    let A = Math.max(1, Math.min((W / 2 - m) / kx, (H / 2 - m) / ky));
    if (ringA) A = Math.min(A, ringA * ORBIT_RING_FACTOR);
    const B = A * ratio;
    // neighbours are at least B * (2 pi / n) apart (narrowest part of the ellipse); a hex is sqrt(3) R wide, keep a 10% gap
    const Rfit = n > 0 ? B * 2 * Math.PI / n / (Math.sqrt(3) * 1.1) : R;
    return { A, B, roll, R: Math.max(8, Math.min(R, Rfit)) };
}

// hex i of n, with hex h0 (real, animated) at the front: {x, y (relative to the orbit centre), depth, phi}. Even spacing.
function orbitPos(i, n, h0, A, B, roll) {
    const phi = wrap(i - h0, n) * 360 / n, p = project(phi, A, B, roll);
    return { x: p.x, y: p.y, depth: p.depth, phi };
}

// how a hex looks at a given depth (+1 front .. -1 back): size factor, opacity, and whether it can be clicked
function depthLook(depth) {
    const k = Math.min(1, Math.max(0, (depth + 0.1) / 1.1)), o = Math.min(1, Math.max(0, (depth + 0.25) / 1.25));
    return { scale: 0.55 + 0.45 * k, op: 0.3 + 0.7 * o, clickable: depth > 0.15 };
}

// hex index nearest to the front for a real h0
function nearestHex(h0, n) {
    return n <= 0 ? -1 : ((Math.round(h0) % n) + n) % n;
}

// contiguous runs of the walk order by category: [{cluster, start, end}] (indices into hexOrder, inclusive)
function hexGroups(order) {
    const out = [];
    order.forEach((h, i) => {
        const last = out[out.length - 1];
        if (last && last.cluster === h.cluster) last.end = i;
        else out.push({ cluster: h.cluster, start: i, end: i });
    });
    return out;
}

// Label positions for the hex groups at the current rotation h0. geo: W, H, cx, cy, A, B, roll, R, labelH, charW, m.
// texts[cluster] = label text. Each visible (front) group gets one label just outside the orbit at the group's middle,
// else above or below it; a label that would touch a hex, another label, the panel edge or the search/status lines is
// moved outward, or hidden. geo.avoid (optional) = {A, B, roll, half}: keep label centres at least `half` px from that
// ellipse (the subdued inner ring's front band). -> [{visible, x, y, w, h}] per group (x, y = top-left in panel pixels)
function orbitLabels(groups, texts, n, h0, geo) {
    const R = geo.R, cr = Math.cos(geo.roll * Math.PI / 180), sr = Math.sin(geo.roll * Math.PI / 180);
    const hexes = [];
    for (let i = 0; i < n; i++) {
        const p = orbitPos(i, n, h0, geo.A, geo.B, geo.roll);
        hexes.push({ x: geo.cx + p.x, y: geo.cy + p.y, depth: p.depth, r: R * depthLook(p.depth).scale + 2 });
    }
    const blockers = hexes.filter(h => h.depth > -0.3);
    const placed = [], out = groups.map(() => ({ visible: false, x: 0, y: 0, w: 0, h: 0 }));
    const hitsCircle = (x, y, w, h, c) => {
        const nx = Math.max(x, Math.min(c.x, x + w)), ny = Math.max(y, Math.min(c.y, y + h));
        return Math.hypot(nx - c.x, ny - c.y) < c.r;
    };
    const valid = (x, y, w, h) => x >= geo.m && y >= geo.m && x + w <= geo.W - geo.m && y + h <= geo.H - geo.m
        && !(y < 58 && x < geo.cx + geo.W * 0.26 && x + w > geo.cx - geo.W * 0.26)        // search line
        && !(y + h > geo.H - 36 && x < geo.W * 0.6)                                          // status line
        && !(geo.avoid && [x, x + w / 2, x + w].some(px => ellipseDist(px, y + h / 2, geo.cx, geo.cy, geo.avoid.A, geo.avoid.B, geo.avoid.roll) < geo.avoid.half))
        && !blockers.some(c => hitsCircle(x, y, w, h, c))
        && !placed.some(l => l.x < x + w && x < l.x + l.w && l.y < y + h && y < l.y + l.h);
    groups.map((g, gi) => ({ g, gi })).sort((a, b) => (b.g.end - b.g.start) - (a.g.end - a.g.start) || a.gi - b.gi).forEach(({ g, gi }) => {
        const mid = (g.start + g.end) / 2, phi = wrap(mid - h0, n) * 360 / n, f = phi * Math.PI / 180;
        if (Math.cos(f) < 0.1) return;
        const w = (texts[g.cluster] || "").length * geo.charW + 4, h = geo.labelH;
        const q = project(phi, geo.A, geo.B, geo.roll);
        const X = geo.A * Math.sin(f) / (geo.A * geo.A), Y = -geo.B * Math.cos(f) / (geo.B * geo.B);   // outward normal (unrotated)
        const l = Math.hypot(X, Y) || 1, nx = (X * cr - Y * sr) / l, ny = (X * sr + Y * cr) / l;
        const cands = [];
        for (let k = 0; k < 4; k++) {
            const off = R * 0.95 + 8 + k * (h + 6);
            cands.push([geo.cx + q.x + nx * off + nx * w / 2 - w / 2, geo.cy + q.y + ny * off + ny * h / 2 - h / 2]);
        }
        const rr = R * depthLook(Math.cos(f)).scale + 4;
        cands.push([geo.cx + q.x - w / 2, geo.cy + q.y - rr - h], [geo.cx + q.x - w / 2, geo.cy + q.y + rr]);
        const c = cands.find(([x, y]) => valid(x, y, w, h));
        if (c) {
            out[gi] = { visible: true, x: c[0], y: c[1], w, h };
            placed.push(out[gi]);
        }
    });
    return out;
}

// ---- the two views: Recents (outer orbit of hexes; zone "hex") and All apps (zoomed inner ring; zone "ring") ----

const ZOOM_ALL = 1.45;   // camera zoom of the All apps view (sphere and ring grow by about 1.47x on screen)

// view when the panel opens: Recents when there is at least one hex, else All apps
function openView(nHex) { return nHex > 0 ? "hex" : "ring"; }
// view a search match asks for: a hex app -> Recents, a ring app -> All apps (the current one if there are no hexes)
function matchView(isHex, nHex) { return nHex > 0 && isHex ? "hex" : "ring"; }
// Tab / Shift+Tab: the other view, but only when there are hexes to show
function toggleView(view, nHex) { return nHex > 0 ? (view === "hex" ? "ring" : "hex") : "ring"; }

// state of the transition t (0 = Recents .. 1 = All apps): camera zoom and opacity of the orbit (gone by t = 0.65)
function viewFades(t) {
    const k = Math.min(1, Math.max(0, t));
    return { zoom: 1 + (ZOOM_ALL - 1) * k, orbitOp: Math.min(1, Math.max(0, (0.65 - k) / 0.65)) };
}

// look of the inner ring during the transition t: alpha (subdued in Recents, 1 in All apps), detail (arc labels and
// stripes: none in Recents, fading in during the second half), mix (0 = Recents look .. 1 = All apps look: icon size) and
// backing (opacity of the opaque background-coloured plate under each BACK-half ring icon: 1 in Recents, so what is behind an icon
// is really hidden and the icon's dimming is done by colour, not by letting the outer hexes show through; 0 from t = 0.5 on, when
// the ring's back half moves over the sphere)
function ringLook(t, subdued) {
    const k = Math.min(1, Math.max(0, t));
    return { alpha: subdued + (1 - subdued) * k, detail: Math.min(1, Math.max(0, (k - 0.5) / 0.5)), mix: k, backing: Math.min(1, Math.max(0, 1 - 2 * k)) };
}

// approximate distance in px from (x, y) to the ellipse (centre cx, cy, semi-axes A, B, tilt roll)
function ellipseDist(x, y, cx, cy, A, B, roll) {
    const dx = x - cx, dy = y - cy, r = Math.hypot(dx, dy), t = -roll * Math.PI / 180;
    const u = dx * Math.cos(t) - dy * Math.sin(t), v = dx * Math.sin(t) + dy * Math.cos(t);
    const e = Math.hypot(u / A, v / B);
    return e === 0 ? Math.min(A, B) : r * Math.abs(1 - 1 / e);
}

// is a hex entirely hidden behind the sphere? Only back hexes (depth < 0) whose whole badge (radius r) lies inside the sphere
// disc (radius sr, centred on the sphere; x, y relative to that centre). Front hexes are never hidden. A back hex that only
// partly overlaps the disc is covered by the opaque disc item that the scene draws behind the particles.
function hexOccluded(depth, x, y, r, sr) {
    return depth < 0 && Math.hypot(x, y) + r <= sr;
}

// ---- HUD: connector lines, corner brackets, starfield ----

// does the segment (x1, y1)-(x2, y2) touch the rect {x, y, w, h}? (Liang-Barsky)
function segmentHitsRect(x1, y1, x2, y2, r) {
    let t0 = 0, t1 = 1;
    const dx = x2 - x1, dy = y2 - y1;
    for (const [p, q] of [[-dx, x1 - r.x], [dx, r.x + r.w - x1], [-dy, y1 - r.y], [dy, r.y + r.h - y1]]) {
        if (p === 0) { if (q < 0) return false; continue; }
        const t = q / p;
        if (p < 0) { if (t > t1) return false; if (t > t0) t0 = t; }
        else { if (t < t0) return false; if (t < t1) t1 = t; }
    }
    return true;
}

// Thin lines from each visible group label to the front hexes of its group. groups: [{start, end}], labels: [{visible, x, y, w, h}]
// (orbitLabels), hexes: [{x, y, depth, r}] in panel pixels. A line starts on the label's edge (nearest point to the hex) and ends on
// the hex's edge; hexes at the back (depth <= 0.15) get none. -> [{x1, y1, x2, y2, g}]
function connectorLines(groups, labels, hexes) {
    const out = [];
    groups.forEach((g, gi) => {
        const l = labels[gi];
        if (!l || !l.visible) return;
        for (let i = g.start; i <= g.end; i++) {
            const h = hexes[i];
            if (!h || h.depth <= 0.15) continue;
            const sx = Math.max(l.x, Math.min(h.x, l.x + l.w)), sy = Math.max(l.y, Math.min(h.y, l.y + l.h));
            const dx = h.x - sx, dy = h.y - sy, d = Math.hypot(dx, dy);
            if (d <= h.r + 6) continue;
            out.push({ x1: sx, y1: sy, x2: h.x - dx / d * h.r, y2: h.y - dy / d * h.r, g: gi });
        }
    });
    return out;
}

// Corner brackets framing the sphere and ring area: eight thin rects {x, y, w, h} (two arms per corner). The frame is as wide as the
// ring and as tall as the sphere plus a margin, never closer than 14 px to the panel edge and kept clear of the status line (bottom)
// and the search line (top).
function bracketRects(W, H, sr, ringA, thick) {
    const t = thick || 1.5, arm = Math.max(10, H * 0.03);
    const hw = Math.min(W / 2 - 14, ringA + 16), hh = Math.min(H / 2 - 40, sr + 34);
    const cx = W / 2, cy = H / 2, out = [];
    for (const sx of [-1, 1]) for (const sy of [-1, 1]) {
        const x = cx + sx * hw, y = cy + sy * hh;
        out.push({ x: sx < 0 ? x : x - arm, y: sy < 0 ? y : y - t, w: arm, h: t });   // horizontal arm
        out.push({ x: sx < 0 ? x : x - t, y: sy < 0 ? y : y - arm, w: t, h: arm });   // vertical arm
    }
    return out;
}

// n stars in the unit square, seeded: [{x, y, size (1 or 2 px), a (0.08..0.4), tint (0..2)}]
function starField(n, seed) {
    const rnd = rng(seed === undefined ? 99 : seed), out = [];
    for (let i = 0; i < n; i++) {
        const b = rnd();
        out.push({ x: rnd(), y: rnd(), size: rnd() < 0.08 ? 2 : 1, a: 0.08 + 0.32 * b * b, tint: Math.floor(rnd() * 3) });
    }
    return out;
}

// ---- layer order (z), back to front. The outer orbit's back half is farther away than the inner ring's back half. ----
//   bg < hexBack (orbit back hexes) < ringBack (ring back icons, Recents) < disc (opaque sphere disc) < view (particles)
//   < ringBackOver (ring back icons in All apps, over the sphere) < ringFront < hexFront (orbit front hexes) < raised
//   < coreText (the selected app's name: over everything in the scene, including the ring's back chain and line) < label
// Each layer may add depth * 5 (-5..5), so the gaps between layers are wider than that.
const Z = { bg: -300, hexBack: -200, ringBack: -180, disc: -150, view: -100, ringBackOver: 4, ringFront: 8, hexFront: 20, raised: 24, coreText: 28, label: 30 };

if (typeof module !== "undefined") module.exports = {
    buildRing, wrap, warp, spacing, project, targetSlot, nearestUnwrapped, nearestApp, rng, fibonacciSphere, particles, instanceSource,
    clusterRecents, hexOrder, hexBrightness, hexPoints,
    ORBIT_ROLL, ORBIT_RATIO, orbitGeom, orbitPos, depthLook, nearestHex, hexGroups, orbitLabels,
    segmentHitsRect, connectorLines, bracketRects, starField, Z, sphereRadiusPx, ringAxes, ORBIT_RING_FACTOR, ZOOM_ALL, openView, matchView, toggleView, viewFades, ringLook, ellipseDist, hexOccluded,
};
