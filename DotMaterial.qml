import QtQuick
import QtQuick3D

// Additive, unlit, soft round dot (see dot.vert / dot.frag). tint = base colour, gain = brightness, sizeMul = quad size factor, assemble = open animation.
CustomMaterial {
    property color tint: "white"
    property real gain: 1.3
    property real sizeMul: 3.2
    property real assemble: 1.0   // open animation: 0 = scattered, 1 = on the sphere
    shadingMode: CustomMaterial.Unshaded
    sourceBlend: CustomMaterial.SrcAlpha
    destinationBlend: CustomMaterial.One
    depthDrawMode: Material.NeverDepthDraw
    cullMode: Material.NoCulling
    vertexShader: "dot.vert"
    fragmentShader: "dot.frag"
}
