import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// kaos-launcher host. Run: quickshell -p <this dir>   (single instance: add -n; toggle: see README)
// Plain FloatingWindow (a Hyprland float/size window rule is needed, see README). For a layer-shell variant
// (Quickshell PanelWindow + WlrLayershell, e.g. for another machine), replace only this file: the scene is Launcher.qml.
ShellRoot {
    id: root
    // KAOS_START_HIDDEN=1 starts the resident instance hidden (autostart); default is to show at start.
    property bool shown: Quickshell.env("KAOS_START_HIDDEN") !== "1"
    property var targetScreen: null

    // Monitor with the focused window (Hyprland focus follows the mouse by default); first screen otherwise.
    function pickScreen() {
        const fm = Hyprland.focusedMonitor;
        let s = null;
        if (fm) for (const sc of Quickshell.screens) if (sc.name === fm.name) s = sc;
        targetScreen = s ? s : (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
        scene.dbg("screen: " + (targetScreen ? targetScreen.name + " " + targetScreen.width + "x" + targetScreen.height : "none")
            + " (hyprland focused: " + (fm ? fm.name : "n/a") + ")");
    }
    function show() { scene.dbg("show"); pickScreen(); shown = true; }
    // run_in_background = false: "hide" ends the process instead (after saving the focused planet).
    function hide() {
        if (!shown) return;
        scene.dbg("hide");
        if (!scene.cfg.run_in_background) { scene.quit(); return; }
        shown = false;
        scene.hidden();
    }
    function toggle() { if (shown) hide(); else show(); }

    IpcHandler {
        target: "launcher"
        function toggle(): void { root.toggle(); }
        function show(): void { root.show(); }
        function hide(): void { root.hide(); }
        // one-run style override from `kaos-launcher --style` on a resident instance ("solar" | "sphere")
        function setStyle(name: string): void { scene.styleOverride = name; }
    }

    FloatingWindow {
        title: "kaos-launcher"
        color: scene.space
        visible: root.shown && scene.loaded
        implicitWidth: Math.round(screenW * scene.cfg.panel_size_percent / 100)
        implicitHeight: Math.round(screenH * scene.cfg.panel_size_percent / 100)
        readonly property real screenW: root.targetScreen ? root.targetScreen.width : 1920
        readonly property real screenH: root.targetScreen ? root.targetScreen.height : 1080

        Launcher {
            id: scene
            anchors.fill: parent
            awake: root.shown
            styleOverride: Quickshell.env("KAOS_STYLE") || ""
            onCloseRequested: root.hide()
        }
    }

    // Hyprland's monitor list arrives shortly after start: re-pick while hidden or not yet shown.
    Connections {
        target: Hyprland
        function onFocusedMonitorChanged() { if (!root.shown || !scene.loaded) root.pickScreen(); }
    }
    Component.onCompleted: pickScreen()
}
