const test = require("node:test");
const assert = require("node:assert");
const S = require("./search.js");

const app = (label, comment = "", keywords = []) => ({ label, comment, keywords });
const planets = [
    { apps: [app("Firefox Web Browser", "Browse the web", ["internet", "www"]), app("Fish Shell Helper")] },
    { apps: [app("Files", "Manage files"), app("Visual Studio Code", "Editor", ["ide"]), app("Calculator", "Do sums with a firefox", [])] },
    { apps: [app("Zathura"), app("Café Tool")] },
];
const top = q => { const r = S.rank(planets, q); return r.length ? planets[r[0].pi].apps[r[0].ai].label : null; };
const names = q => S.rank(planets, q).map(m => planets[m.pi].apps[m.ai].label);

test("tiers: exact > prefix > word start > anchored subsequence > substring > subsequence", () => {
    const e = S.nameScore("Firefox", "firefox"), p = S.nameScore("Firefox Web", "fire"),
        w = S.nameScore("Mozilla Firefox", "fire"), a = S.nameScore("Firefox", "ffx"),
        s = S.nameScore("Superfire", "fire"), q = S.nameScore("Superfire", "pfr");
    assert.ok(e > p && p > w && w > a && a > s && s > q && q > 0, [e, p, w, a, s, q].join());
});

test("ff finds Firefox first", () => {
    assert.strictEqual(top("ff"), "Firefox Web Browser");
    assert.ok(names("ff").includes("Fish Shell Helper") === false);
    const ps = [{ apps: [app("LibreOffice"), app("Firefox")] }];
    assert.strictEqual(ps[0].apps[S.rank(ps, "ff")[0].ai].label, "Firefox");
});

test("acronym subsequence", () => {
    assert.strictEqual(top("vsc"), "Visual Studio Code");
});

test("name outranks keyword outranks comment", () => {
    assert.deepStrictEqual(names("fire"), ["Firefox Web Browser", "Calculator"]);
    assert.deepStrictEqual(names("internet"), ["Firefox Web Browser"]);
    assert.strictEqual(top("ide"), "Visual Studio Code");
    assert.deepStrictEqual(names("sums"), ["Calculator"]);
});

test("keyword beats comment", () => {
    const ps = [{ apps: [app("Alpha", "has beta inside"), app("Gamma", "", ["beta"])] }];
    assert.deepStrictEqual(S.rank(ps, "beta").map(m => m.ai), [1, 0]);
});

test("no subsequence in comments or keywords", () => {
    assert.strictEqual(S.appScore(app("Zed", "Browse the web", ["internet"]), "bw"), -1);
});

test("empty, blank and whitespace queries match nothing", () => {
    assert.deepStrictEqual(S.rank(planets, ""), []);
    assert.deepStrictEqual(S.rank(planets, "   "), []);
});

test("case and accents are ignored", () => {
    assert.strictEqual(top("CAFE"), "Café Tool");
    assert.strictEqual(top("café"), "Café Tool");
});

test("unmatched query, long query, unicode junk", () => {
    assert.deepStrictEqual(S.rank(planets, "qqqq"), []);
    assert.deepStrictEqual(S.rank(planets, "x".repeat(5000)), []);
    assert.deepStrictEqual(S.rank(planets, "日本語"), []);
});

test("ties break by shorter name, then alphabetical", () => {
    const ps = [{ apps: [app("Tool B"), app("Tool A"), app("Tool")] }];
    assert.deepStrictEqual(S.rank(ps, "tool").map(m => m.ai), [2, 1, 0]);
});

test("missing fields do not throw", () => {
    const ps = [{ apps: [{ label: "Bare" }] }];
    assert.strictEqual(S.rank(ps, "bare").length, 1);
});
