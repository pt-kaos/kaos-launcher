import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import kaos_launcher as a


class T(unittest.TestCase):
    def test_exec_codes(self):
        self.assertEqual(a.clean_exec("foo --x %U"), ["foo", "--x"])
        self.assertEqual(
            a.clean_exec('"/opt/my app/run" %f %i 100%%'), ["/opt/my app/run", "100%"]
        )

    def test_group_priority(self):
        self.assertEqual(
            a.pick_group(["Utility", "TerminalEmulator", "System"]), "System"
        )
        self.assertEqual(a.pick_group(["Settings", "System"]), "Settings")
        self.assertEqual(a.pick_group(["X-Foo"]), "Other")
        self.assertEqual(a.pick_group([]), "Other")

    def test_graph_shape(self):
        g = a.build_graph()
        ids = {n["id"] for n in g["nodes"]}
        for e in g["edges"]:
            self.assertIn(e["source"], ids)
            self.assertIn(e["target"], ids)

    def test_category_counts_match_apps(self):
        g = a.build_graph()
        for c in (n for n in g["nodes"] if n["type"] == "category"):
            apps = [
                n for n in g["nodes"] if n["type"] == "app" and n["group"] == c["label"]
            ]
            self.assertEqual(c["count"], len(apps))

    def test_read_entry_malformed(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bad.desktop"
            p.write_text("not a desktop file\n", encoding="utf-8")
            self.assertIsNone(a.read_entry(str(p)))

    def test_keywords(self):
        e = {"Keywords": "web;browser;;  www ;", "GenericName": "Web Browser"}
        self.assertEqual(a.parse_keywords(e), ["web", "browser", "www", "Web Browser"])
        self.assertEqual(a.parse_keywords({}), [])

    def test_graph_has_keywords_list(self):
        for n in a.build_graph()["nodes"]:
            if n["type"] == "app":
                self.assertIsInstance(n["keywords"], list)

    def test_launch_detached(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.desktop"
            p.write_text(
                "[Desktop Entry]\nType=Application\nName=T\nExec=true %U\n",
                encoding="utf-8",
            )
            a.launch(str(p))


class ConfigTests(unittest.TestCase):
    def test_defaults_when_empty_or_invalid(self):
        d = a.defaults()
        self.assertEqual(a.parse_config(""), d)
        self.assertEqual(a.parse_config("this is = = not toml"), d)

    def test_parse_default_toml_equals_defaults(self):
        self.assertEqual(a.parse_config(a.DEFAULT_TOML), a.defaults())

    def test_example_file_is_the_generated_default(self):
        ex = Path(__file__).with_name("config.example.toml")
        self.assertEqual(ex.read_text(encoding="utf-8"), a.DEFAULT_TOML)

    def test_per_key_fallback_and_types(self):
        c = a.parse_config(
            'recent_count = "many"\nrun_in_background = 1\norbit_speed = 2\nterminal = ""\nstarfield = false\n'
        )
        self.assertEqual(c["recent_count"], 5)  # wrong type -> default
        self.assertIs(c["run_in_background"], True)  # int is not a bool -> default
        self.assertEqual(c["orbit_speed"], 2.0)
        self.assertEqual(c["terminal"], "auto")
        self.assertIs(c["starfield"], False)  # valid keys survive bad neighbours

    def test_clamping(self):
        c = a.parse_config(
            "recent_count = 999\npanel_size_percent = 1\norbit_speed = -3\ndrag_speed = 50\ntooltip_font_size = 2\n"
        )
        self.assertEqual(c["recent_count"], 20)
        self.assertEqual(c["panel_size_percent"], 20.0)
        self.assertEqual(c["orbit_speed"], 0.0)
        self.assertEqual(c["drag_speed"], 2.0)
        self.assertEqual(c["tooltip_font_size"], 6)

    def test_nan_inf_and_zero_orbit(self):
        c = a.parse_config("orbit_speed = nan\ndrag_speed = inf\nrecent_count = 0\n")
        self.assertEqual(c["orbit_speed"], 1.0)
        self.assertEqual(c["drag_speed"], 0.25)
        self.assertEqual(c["recent_count"], 0)
        self.assertEqual(a.parse_config("orbit_speed = 0")["orbit_speed"], 0.0)

    def test_first_run_creates_file_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sub" / "config.toml"
            c = a.load_config(p)
            self.assertEqual(c, a.defaults())
            self.assertEqual(p.read_text(encoding="utf-8"), a.DEFAULT_TOML)
            p.write_text("recent_count = 3\n", encoding="utf-8")
            self.assertEqual(a.load_config(p)["recent_count"], 3)
            self.assertEqual(p.read_text(encoding="utf-8"), "recent_count = 3\n")
            self.assertEqual(
                os.listdir(p.parent), ["config.toml"]
            )  # no temp files left

    def test_unreadable_location_falls_back(self):
        with tempfile.TemporaryDirectory() as d:
            blocker = Path(d) / "file"
            blocker.write_text("x", encoding="utf-8")
            self.assertEqual(a.load_config(blocker / "config.toml"), a.defaults())

    def test_xdg_paths(self):
        with mock.patch.dict(
            os.environ, {"XDG_CONFIG_HOME": "/x/c", "XDG_STATE_HOME": "/x/s"}
        ):
            self.assertEqual(str(a.config_path()), "/x/c/kaos-launcher/config.toml")
            self.assertEqual(str(a.state_path()), "/x/s/kaos-launcher/state.json")
        with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "relative"}):
            self.assertEqual(
                a.config_path(), Path.home() / ".config/kaos-launcher/config.toml"
            )


class StateTests(unittest.TestCase):
    def test_missing_and_corrupt(self):
        empty = {"planet": None, "recent": []}
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "state.json"
            self.assertEqual(a.load_state(p), empty)
            for bad in (
                "",
                "{",
                "[1,2]",
                '"x"',
                "null",
                '{"planet": 5, "recent": "no"}',
            ):
                p.write_text(bad, encoding="utf-8")
                self.assertEqual(a.load_state(p), empty, bad)
            p.write_bytes(b"\xff\xfe\x00")
            self.assertEqual(a.load_state(p), empty)

    def test_roundtrip_atomic(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "deep" / "state.json"
            st = {"planet": "Internet", "recent": ["a.desktop", "b.desktop"]}
            self.assertTrue(a.save_state(st, p))
            self.assertEqual(a.load_state(p), st)
            self.assertEqual(os.listdir(p.parent), ["state.json"])
            self.assertEqual(json.loads(p.read_text(encoding="utf-8")), st)

    def test_recent_trim_dedupe_and_junk(self):
        raw = json.dumps({"planet": "X", "recent": ["a", "b", "a", 3, "", "c", "d"]})
        self.assertEqual(a.parse_state(raw, 3)["recent"], ["a", "b", "c"])
        self.assertEqual(a.parse_state(raw, 0)["recent"], [])

    def test_with_launch(self):
        st = {"planet": "X", "recent": ["a", "b", "c"]}
        self.assertEqual(a.with_launch(st, "c", 3)["recent"], ["c", "a", "b"])
        self.assertEqual(a.with_launch(st, "n", 3)["recent"], ["n", "a", "b"])
        self.assertEqual(a.with_launch(st, "n", 0)["recent"], [])
        self.assertEqual(st["recent"], ["a", "b", "c"])  # input untouched

    def test_history_keeps_20_independent_of_recent_count(self):
        ids = [f"app{i}.desktop" for i in range(25)]
        self.assertEqual(a.HISTORY_LIMIT, 20)
        self.assertEqual(a.parse_state(json.dumps({"recent": ids}))["recent"], ids[:20])
        st = {"planet": None, "recent": ids[:20]}
        out = a.with_launch(st, "new.desktop")
        self.assertEqual(out["recent"], ["new.desktop"] + ids[:19])
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "config.toml").write_text("recent_count = 2\n", encoding="utf-8")
            sdir = Path(d) / "kaos-launcher"
            sdir.mkdir()
            (sdir / "state.json").write_text(
                json.dumps({"planet": "X", "recent": ids}), encoding="utf-8"
            )
            env = {"XDG_STATE_HOME": d, "XDG_CONFIG_HOME": d}
            with mock.patch.dict(os.environ, env):
                self.assertEqual(
                    a.load_config(Path(d) / "config.toml")["recent_count"], 2
                )
                self.assertEqual(a.init()["state"]["recent"], ids[:20])

    def test_old_five_entry_state_still_loads(self):
        raw = json.dumps({"planet": "X", "recent": ["a", "b", "c", "d", "e"]})
        self.assertEqual(a.parse_state(raw)["recent"], ["a", "b", "c", "d", "e"])

    def test_saved_style_roundtrip_old_and_invalid(self):
        self.assertNotIn("style", a.parse_state('{"planet": "X", "recent": []}'))
        for bad in ('"cube"', "3", "null", '""'):
            self.assertNotIn("style", a.parse_state('{"style": ' + bad + "}"), bad)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "state.json"
            st = {"planet": "X", "recent": ["a"], "style": "sphere"}
            self.assertTrue(a.save_state(st, p))
            self.assertEqual(a.load_state(p), st)

    def test_launch_and_planet_save_preserve_style_and_history(self):
        ids = [f"app{i}.desktop" for i in range(20)]
        with tempfile.TemporaryDirectory() as d:
            env = {"XDG_STATE_HOME": d, "XDG_CONFIG_HOME": d}
            desk = Path(d) / "t.desktop"
            desk.write_text(
                "[Desktop Entry]\nType=Application\nName=T\nExec=true\n",
                encoding="utf-8",
            )
            with mock.patch.dict(os.environ, env):
                a.save_state({"planet": "X", "recent": ids, "style": "sphere"})
                a.launch(str(desk), app_id="t.desktop", planet="Y")
                st = a.load_state()
                self.assertEqual(st["style"], "sphere")
                self.assertEqual(st["recent"], ["t.desktop"] + ids[:19])
                a.init_state_only("Z")
                self.assertEqual(a.load_state()["style"], "sphere")
                self.assertEqual(a.load_state()["planet"], "Z")
                a.init_state_only(style="solar")  # F2 save keeps planet and history
                st = a.load_state()
                self.assertEqual((st["style"], st["planet"]), ("solar", "Z"))
                self.assertEqual(len(st["recent"]), 20)
                a.init_state_only(style="cube")  # invalid: ignored
                self.assertEqual(a.load_state()["style"], "solar")
                self.assertEqual(a.init()["state"]["style"], "solar")

    def test_style_precedence(self):
        cfg = {"style": "sphere"}
        self.assertEqual(a.effective_style("solar", {"style": "sphere"}, cfg), "solar")
        self.assertEqual(a.effective_style("", {"style": "solar"}, cfg), "solar")
        self.assertEqual(a.effective_style("", {}, cfg), "sphere")
        self.assertEqual(
            a.effective_style("bad", {"style": "bad"}, {"style": "x"}), "solar"
        )

    def test_style_parsing_and_fallback(self):
        self.assertEqual(a.defaults()["style"], "solar")
        self.assertEqual(a.parse_config('style = "sphere"\n')["style"], "sphere")
        self.assertEqual(a.parse_config('style = "solar"\n')["style"], "solar")
        for bad in ('style = "cube"', "style = 3", "style = true", 'style = ""'):
            self.assertEqual(a.parse_config(bad + "\n")["style"], "solar", bad)

    def test_hex_count_parsing_clamp_and_fallback(self):
        self.assertEqual(a.defaults()["hex_count"], 20)
        self.assertEqual(a.parse_config("hex_count = 7\n")["hex_count"], 7)
        self.assertEqual(a.parse_config("hex_count = 0\n")["hex_count"], 0)
        self.assertEqual(a.parse_config("hex_count = 99\n")["hex_count"], 20)
        self.assertEqual(a.parse_config("hex_count = -4\n")["hex_count"], 0)
        for bad in ('"many"', "true", "nan", "inf"):
            self.assertEqual(
                a.parse_config("hex_count = " + bad + "\n")["hex_count"], 20, bad
            )

    def test_color_keys_parse_normalise_and_fall_back(self):
        d = a.defaults()
        self.assertEqual(
            (d["color_main"], d["color_accent"], d["color_base"]),
            ("#ff9a3c", "#3cd6ff", "#0a0d12"),
        )
        c = a.parse_config(
            'color_main = "#F80"\ncolor_accent = "  #AbCdEf "\ncolor_base = "#000000"\n'
        )
        self.assertEqual(c["color_main"], "#ff8800")  # #rgb expands, lower case
        self.assertEqual(c["color_accent"], "#abcdef")
        self.assertEqual(c["color_base"], "#000000")
        for bad in (
            '"red"',
            '"#12"',
            '"#12345"',
            '"#1234567"',
            '"ff9a3c"',
            "5",
            "true",
            '""',
            '"#gg0000"',
        ):
            for key in ("color_main", "color_accent", "color_base"):
                self.assertEqual(
                    a.parse_config(f"{key} = {bad}\n")[key],
                    a.defaults()[key],
                    (key, bad),
                )
        # one bad key does not disturb the others
        c = a.parse_config('color_main = "nope"\ncolor_accent = "#fff"\n')
        self.assertEqual((c["color_main"], c["color_accent"]), ("#ff9a3c", "#ffffff"))

    def test_name_plate_key(self):
        self.assertIs(a.defaults()["name_plate"], False)
        self.assertIs(a.parse_config("name_plate = true\n")["name_plate"], True)
        for bad in ('"yes"', "1", "[]"):
            self.assertIs(
                a.parse_config(f"name_plate = {bad}\n")["name_plate"], False, bad
            )

    def test_open_animation_key(self):
        self.assertIs(a.defaults()["open_animation"], True)
        self.assertIs(
            a.parse_config("open_animation = false\n")["open_animation"], False
        )
        self.assertIs(a.parse_config('open_animation = "no"\n')["open_animation"], True)

    def test_generated_config_contains_style(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c" / "config.toml"
            a.load_config(p)
            text = p.read_text(encoding="utf-8")
            self.assertIn('style = "solar"', text)
            self.assertIn("hex_count = 20", text)
            self.assertIn("open_animation = true", text)
            self.assertIn("name_plate = false", text)
            for key, val in (
                ("color_main", "#ff9a3c"),
                ("color_accent", "#3cd6ff"),
                ("color_base", "#0a0d12"),
            ):
                self.assertIn(f'{key} = "{val}"', text)
            self.assertEqual(a.parse_config(text), a.defaults())

    def test_launch_records_only_with_id(self):
        with tempfile.TemporaryDirectory() as d:
            env = {"XDG_STATE_HOME": d, "XDG_CONFIG_HOME": d}
            desk = Path(d) / "t.desktop"
            desk.write_text(
                "[Desktop Entry]\nType=Application\nName=T\nExec=true\n",
                encoding="utf-8",
            )
            with mock.patch.dict(os.environ, env):
                a.launch(str(desk))
                self.assertFalse(a.state_path().exists())
                a.launch(str(desk), app_id="t.desktop", planet="Utility")
                self.assertEqual(
                    a.load_state(), {"planet": "Utility", "recent": ["t.desktop"]}
                )

    def test_init_first_run_and_save_planet(self):
        with (
            tempfile.TemporaryDirectory() as d,
            mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_CONFIG_HOME": d}),
        ):
            r = a.init("Games")
            self.assertEqual(r["config"], a.defaults())
            self.assertEqual(r["state"]["planet"], "Games")
            self.assertTrue(a.config_path().is_file())
            self.assertEqual(a.load_state()["planet"], "Games")
            self.assertIn("nodes", r["graph"])


class TerminalTests(unittest.TestCase):
    def test_configured_terminal_used_when_present(self):
        with mock.patch("shutil.which", side_effect=lambda c: "/bin/" + c):
            self.assertEqual(a.find_terminal("myterm"), "myterm")

    def test_missing_configured_terminal_falls_back_to_auto(self):
        def which(c):
            return "/bin/foot" if c == "foot" else None

        with (
            mock.patch("shutil.which", side_effect=which),
            mock.patch.dict(os.environ, {"TERMINAL": ""}),
        ):
            self.assertEqual(a.find_terminal("nope"), "foot")
            self.assertEqual(a.find_terminal("auto"), "foot")

    def test_none_found(self):
        with mock.patch("shutil.which", return_value=None):
            self.assertIsNone(a.find_terminal("auto"))

    def test_terminal_true_uses_configured_terminal(self):
        with tempfile.TemporaryDirectory() as d:
            desk = Path(d) / "t.desktop"
            desk.write_text(
                "[Desktop Entry]\nType=Application\nName=T\nExec=htop\nTerminal=true\n",
                encoding="utf-8",
            )
            with (
                mock.patch("shutil.which", return_value="/bin/x"),
                mock.patch("subprocess.Popen") as popen,
            ):
                a.launch(str(desk), terminal="myterm")
            self.assertEqual(popen.call_args.args[0], ["myterm", "-e", "htop"])


class IconTests(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.base = Path(self._td.name) / "icons"
        self.pix = Path(self._td.name) / "pixmaps"
        self.pix.mkdir()

    def theme(self, name, dirs, inherits=""):
        root = self.base / name
        root.mkdir(parents=True)
        lines = [
            "[Icon Theme]",
            f"Name={name}",
            f"Inherits={inherits}",
            "Directories=" + ",".join(d[0] for d in dirs),
        ]
        for d, size, kind, extra in dirs:
            lines += [
                "",
                f"[{d}]",
                f"Size={size}",
                f"Type={kind}",
                "Context=Applications",
            ] + extra
            (root / d).mkdir(parents=True)
        (root / "index.theme").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def touch(self, rel):
        p = self.base / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("x")
        return str(p)

    def resolver(self, theme):
        return a.IconResolver(theme, base_dirs=[self.base], pixmap_dirs=[self.pix])

    def test_picks_size_closest_to_64(self):
        self.theme(
            "T",
            [
                ("16/apps", 16, "Fixed", []),
                ("48/apps", 48, "Fixed", []),
                ("128/apps", 128, "Fixed", []),
            ],
        )
        self.touch("T/16/apps/x.png")
        want = self.touch("T/48/apps/x.png")
        self.touch("T/128/apps/x.png")
        self.assertEqual(self.resolver("T").resolve("x"), want)

    def test_scalable_covering_the_size_wins_over_png(self):
        self.theme(
            "T",
            [
                ("48/apps", 48, "Fixed", []),
                ("scalable/apps", 64, "Scalable", ["MinSize=8", "MaxSize=512"]),
            ],
        )
        self.touch("T/48/apps/x.png")
        want = self.touch("T/scalable/apps/x.svg")
        self.assertEqual(self.resolver("T").resolve("x"), want)

    def test_inherits_chain_and_hicolor_fallback(self):
        self.theme("Child", [("48/apps", 48, "Fixed", [])], inherits="Parent")
        self.theme("Parent", [("64/apps", 64, "Fixed", [])], inherits="Grand")
        self.theme("Grand", [("64/apps", 64, "Fixed", [])])
        self.theme("hicolor", [("48/apps", 48, "Fixed", [])])
        own = self.touch("Child/48/apps/own.png")
        par = self.touch("Parent/64/apps/par.png")
        gra = self.touch("Grand/64/apps/gra.png")
        hic = self.touch("hicolor/48/apps/hic.png")
        r = self.resolver("Child")
        self.assertEqual(
            [r.resolve(n) for n in ("own", "par", "gra", "hic")], [own, par, gra, hic]
        )
        self.assertEqual(r.resolve("nope"), "")
        # the child's own icon beats the parent's even when the parent's size fits better
        self.touch("Parent/64/apps/own.png")
        self.assertEqual(self.resolver("Child").resolve("own"), own)

    def test_inherits_cycle_terminates(self):
        self.theme("A", [("64/apps", 64, "Fixed", [])], inherits="B")
        self.theme("B", [("64/apps", 64, "Fixed", [])], inherits="A")
        want = self.touch("B/64/apps/x.png")
        self.assertEqual(self.resolver("A").resolve("x"), want)

    def test_absolute_path_pixmaps_and_missing(self):
        self.theme("T", [("64/apps", 64, "Fixed", [])])
        f = self.pix / "abs.svg"
        f.write_text("x")
        (self.pix / "loose.png").write_text("x")
        r = self.resolver("T")
        self.assertEqual(r.resolve(str(f)), str(f))
        self.assertEqual(r.resolve(str(self.pix / "gone.svg")), "")
        self.assertEqual(
            r.resolve(str(self.pix / "loose.png")), str(self.pix / "loose.png")
        )
        self.assertEqual(r.resolve("loose"), str(self.pix / "loose.png"))
        self.assertEqual(r.resolve(""), "")
        self.assertEqual(r.resolve("nope"), "")

    def test_unknown_theme_and_scale_dirs_are_ignored(self):
        self.theme(
            "hicolor",
            [("64/apps", 64, "Fixed", []), ("64@2/apps", 64, "Fixed", ["Scale=2"])],
        )
        self.touch("hicolor/64@2/apps/x.png")
        r = self.resolver("NoSuchTheme")
        self.assertEqual(r.resolve("x"), "")
        want = self.touch("hicolor/64/apps/x.png")
        self.assertEqual(self.resolver("NoSuchTheme").resolve("x"), want)

    def test_active_theme_from_gtk_settings(self):
        with (
            tempfile.TemporaryDirectory() as d,
            mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": d}),
        ):
            (Path(d) / "gtk-3.0").mkdir()
            (Path(d) / "gtk-3.0" / "settings.ini").write_text(
                "[Settings]\ngtk-icon-theme-name=Foo\n"
            )
            self.assertEqual(a.active_icon_theme(), "Foo")

    def test_icons_false_and_config_keys(self):
        cfg = a.parse_config("icons = false\nicon_theme = 'Papirus'\n")
        self.assertIs(cfg["icons"], False)
        self.assertEqual(cfg["icon_theme"], "Papirus")
        self.assertIs(a.parse_config("icons = 3")["icons"], True)
        self.assertEqual(a.parse_config("icon_theme = 4")["icon_theme"], "auto")
        g = a.build_graph(icons=False)
        self.assertTrue(all(n["icon"] == "" for n in g["nodes"] if n["type"] == "app"))


if __name__ == "__main__":
    unittest.main()
