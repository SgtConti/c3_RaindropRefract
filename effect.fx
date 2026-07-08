// Raindrop Refraction (WebGL)
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

varying vec2 vTex;
uniform sampler2D samplerFront;
uniform sampler2D samplerBack;
uniform vec2 srcOriginStart;
uniform vec2 srcOriginEnd;
uniform vec2 layoutStart;
uniform vec2 layoutEnd;
uniform vec2 pixelSize;
uniform float seconds;
uniform float uDensity;
uniform float uSize;
uniform float uSpeed;
uniform float uRandomMag;
uniform float uWindX;
uniform float uStrength;
uniform float uBlurLod;
uniform float uSeed;

float hash12(vec2 p){
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p){
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
vec4 sampleBase(vec2 uv){
    vec4 front = texture2D(samplerFront, uv);
    vec4 back = texture2D(samplerBack, uv);
    return front + back * (1.0 - front.a);
}

void addDrop(vec2 p, vec2 id, vec2 f, float cell, inout float mask, inout vec2 normal){
    float active = step(hash12(id + uSeed * 17.0), clamp(uDensity, 0.0, 1.0) * 0.33);
    vec2 h = hash22(id + uSeed * 3.1);
    vec2 center = h - 0.5;
    center.x += sin(seconds * 1.7 + h.y * 6.28318) * 0.10 * uRandomMag;
    vec2 d = f - center;
    float sx = 0.20 + 0.18 * h.x;
    float sy = 0.65 + 0.50 * h.y;
    float body = 1.0 - smoothstep(0.2, 1.0, length(vec2(d.x / sx, d.y / sy)));
    float trailX = 1.0 - smoothstep(0.0, 0.18, abs(d.x));
    float trailY = 1.0 - smoothstep(-0.4, 1.5, d.y);
    float trail = trailX * trailY * smoothstep(-0.25, 0.25, d.y);
    float a = active * max(body, trail * 0.42);
    mask = max(mask, a);
    normal += a * normalize(vec2(d.x / max(sx, 0.01), d.y / max(sy, 0.01)) + vec2(0.0001));
}

void main(void){
    vec2 n = (vTex - srcOriginStart) / max(srcOriginEnd - srcOriginStart, vec2(1e-6));
    vec2 layoutPos = mix(layoutStart, layoutEnd, n);
    float cell = max(14.0, uSize);
    vec2 p = layoutPos + vec2(uSeed * 137.0, uSeed * 73.0);
    p.x -= seconds * uWindX;
    p.y -= seconds * (130.0 + uSize * 0.8) * uSpeed;
    vec2 g = floor(p / cell);
    vec2 f = fract(p / cell) - 0.5;
    float mask = 0.0;
    vec2 normal = vec2(0.0);
    for (int oy = -1; oy <= 1; oy++){
        for (int ox = -1; ox <= 1; ox++){
            addDrop(p, g + vec2(float(ox), float(oy)), f - vec2(float(ox), float(oy)), cell, mask, normal);
        }
    }
    float lodBoost = 1.0 + 0.02 * clamp(uBlurLod, 0.0, 4.0);
    normal *= pixelSize * (8.0 + uSize * 0.18) * clamp(uStrength, 0.0, 1.0) * lodBoost;
    vec4 base = sampleBase(vTex);
    vec4 refr = sampleBase(vTex + normal);
    vec3 rgb = mix(base.rgb, refr.rgb, clamp(mask, 0.0, 1.0));
    rgb += vec3(mask * 0.035);
    gl_FragColor = vec4(rgb, max(base.a, mask * 0.2));
}
