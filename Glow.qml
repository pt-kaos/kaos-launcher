import QtQuick
import QtQuick3D

// Camera-facing soft glow: a quad with a radial-falloff texture, tinted and blended (no hard edge, unlike stacked spheres).
Model {
    id: g
    property Texture tex                // white radial falloff (Launcher.qml: glowTex)
    property quaternion camRot          // camera rotation, so the quad faces the camera
    property color glowColor: "white"
    property real glowAlpha: 0.5
    property real size: 100             // diameter in scene units
    source: "#Rectangle"
    pickable: false
    rotation: camRot
    scale: Qt.vector3d(size / 100, size / 100, 1)
    materials: PrincipledMaterial {
        lighting: PrincipledMaterial.NoLighting
        baseColor: Qt.rgba(g.glowColor.r, g.glowColor.g, g.glowColor.b, g.glowAlpha)
        baseColorMap: g.tex
        alphaMode: PrincipledMaterial.Blend
        cullMode: PrincipledMaterial.NoCulling
    }
}
