// kaos-launcher sphere particles: camera-facing quad per instance (billboard), so the dots stay round while the sphere turns.
// `assemble` (0..1) is the open animation: at 0 every dot sits far out along its own direction, at 1 it is on the sphere.
VARYING vec2 vUv;
VARYING vec4 vCol;
VARYING float vFade;
void MAIN()
{
    vec3 p = (INSTANCE_MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;              // instance centre in model space
    float h = fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);     // stable per-dot random 0..1
    vec3 q = p * (1.0 + (1.0 - assemble) * (0.8 + 2.0 * h));
    vec4 c = VIEW_MATRIX * MODEL_MATRIX * vec4(q, 1.0);                           // view space
    float s = length(INSTANCE_MODEL_MATRIX[0].xyz);                               // instance scale
    c.xy += VERTEX.xy * s * sizeMul;
    POSITION = PROJECTION_MATRIX * c;
    vUv = UV0;
    vCol = INSTANCE_COLOR;
    vFade = mix(0.2, 1.0, assemble);
}
