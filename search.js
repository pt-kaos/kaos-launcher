// kaos-launcher search: fuzzy matching and ranking. Pure functions, no QML types, so `node --test` can load it.
// In QML: import "search.js" as Search. In node: require("./search.js").
//
// Ranking, best first: name (exact > prefix > word start > subsequence anchored on the first letter > substring > other subsequence), then keywords, then comment.
// Any name match outranks any keyword match, which outranks any comment match. Keywords and comment never use
// subsequence matching (a two-letter query is a subsequence of almost every sentence).

function norm(s) {
    s = String(s === undefined || s === null ? "" : s).toLowerCase();
    if (s.normalize) s = s.normalize("NFD").replace(/[̀-ͯ]/g, "");
    return s;
}

function isWordChar(c) {
    return /[a-z0-9]/.test(c);
}

// index of q in t where the match starts a word, or -1
function wordStart(t, q) {
    let from = 0;
    for (;;) {
        const i = t.indexOf(q, from);
        if (i < 0) return -1;
        if (i === 0 || !isWordChar(t[i - 1])) return i;
        from = i + 1;
    }
}

// greedy leftmost subsequence; returns 300..590 (700..740 when the first query char is the name's first char), or -1
function subsequence(t, q) {
    let ti = 0, score = 300, prev = -2, first = -1;
    for (let qi = 0; qi < q.length; qi++) {
        const i = t.indexOf(q[qi], ti);
        if (i < 0) return -1;
        if (i === 0 || !isWordChar(t[i - 1])) score += 25;   // initial of a word (acronym style)
        if (i === prev + 1) score += 15;                      // consecutive
        score -= Math.min(i - ti, 10);                        // gap penalty
        if (qi === 0) first = i;
        prev = i;
        ti = i + 1;
    }
    return first === 0 ? Math.min(score + 400, 740) : Math.min(score, 590);
}

// name score: exact 1000 > prefix > word start (750..800) > anchored subsequence (700..740) > substring (550..600) > subsequence (300..590); -1 none
function nameScore(name, query) {
    const t = norm(name), q = norm(query).trim();
    if (q === "") return -1;
    if (t === q) return 1000;
    if (t.startsWith(q)) return 900 - Math.min(t.length - q.length, 50);
    const w = wordStart(t, q);
    if (w >= 0) return 800 - Math.min(w, 50);
    const i = t.indexOf(q);
    if (i >= 0) return 600 - Math.min(i, 50);
    return subsequence(t, q);
}

// text score for keywords/comment: base + word-start bonus, no subsequence; -1 none
function textScore(text, query, base) {
    const t = norm(text), q = norm(query).trim();
    if (q === "" || t === "") return -1;
    const w = wordStart(t, q);
    if (w >= 0) return base + 40 - Math.min(w, 30);
    if (t.indexOf(q) >= 0) return base;
    return -1;
}

// app: {label, comment, keywords:[...]}; returns score or -1
function appScore(app, query) {
    const n = nameScore(app.label, query);
    if (n >= 0) return n;
    const kws = app.keywords || [];
    let best = -1;
    for (let k = 0; k < kws.length; k++) best = Math.max(best, textScore(kws[k], query, 200));
    if (best >= 0) return best;
    return textScore(app.comment, query, 100);
}

// planets: [{apps:[...]}]; returns [{pi, ai, score}] best first (score, shorter name, name, original order)
function rank(planets, query) {
    const out = [];
    if (norm(query).trim() === "") return out;
    for (let pi = 0; pi < planets.length; pi++) {
        const apps = planets[pi].apps;
        for (let ai = 0; ai < apps.length; ai++) {
            const s = appScore(apps[ai], query);
            if (s >= 0) out.push({ pi: pi, ai: ai, score: s, label: apps[ai].label });
        }
    }
    out.sort((a, b) =>
        b.score - a.score ||
        a.label.length - b.label.length ||
        (norm(a.label) < norm(b.label) ? -1 : norm(a.label) > norm(b.label) ? 1 : 0) ||
        a.pi - b.pi || a.ai - b.ai);
    return out.map(m => ({ pi: m.pi, ai: m.ai, score: m.score }));
}

if (typeof module !== "undefined") module.exports = { norm, nameScore, textScore, appScore, rank };
