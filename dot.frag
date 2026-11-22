// soft round dot: bright core, smooth falloff; the colour is the instance brightness times the material tint
VARYING vec2 vUv;
VARYING vec4 vCol;
VARYING float vFade;
void MAIN()
{
    float d = length(vUv - vec2(0.5)) * 2.0;
    float a = clamp(1.0 - d, 0.0, 1.0);
    float body = a * a * (3.0 - 2.0 * a);
    float core = smoothstep(0.55, 0.0, d);
    vec3 col = tint.rgb * vCol.rgb * (0.7 + 0.9 * core) * gain;
    FRAGCOLOR = vec4(col, body * vFade);
}
