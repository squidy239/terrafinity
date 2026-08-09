#ifndef SHADOW_GLSL
#define SHADOW_GLSL

const int MAX_CASCADES = 32;

// Set 2 is the shared push-descriptor set, present in both the opaque and transparent
// pipelines. Binding 0 is the opaque depth sampler (transparent only; NULL for opaque),
// binding 1 is the shadow depth array with a comparison sampler, binding 2 the params.
layout(set = 2, binding = 1) uniform sampler2DArrayShadow shadow_map;
layout(set = 2, binding = 2, std430) readonly buffer ShadowParamsBuffer {
    mat4 light_viewproj[MAX_CASCADES];
    float split_radius[MAX_CASCADES];
    float texel_world_size[MAX_CASCADES];
    float box_radius[MAX_CASCADES];
    float normal_bias_scale;
    float blur_radius;
    float blend_fraction;
    float fade_start;
    float fade_end;
    uint cascade_count;
    float shadow_strength;
    uint debug_colors;
} shadow_params;

int shadowCascadeIndex(vec3 pos_rel) {
    float d = length(pos_rel);
    int cascade = 0;
    for (int i = 0; i < int(shadow_params.cascade_count) - 1; i++) {
        if (d < shadow_params.split_radius[i]) break;
        cascade = i + 1;
    }
    return cascade;
}

vec3 cascadeDebugColor(int cascade) {
    vec3 colors[MAX_CASCADES] = vec3[MAX_CASCADES](
        vec3(1.0, 0.3, 0.3),
        vec3(0.3, 1.0, 0.3),
        vec3(0.3, 0.3, 1.0),
        vec3(1.0, 1.0, 0.3),
        vec3(1.0, 0.7, 0.3),
        vec3(0.3, 1.0, 1.0),
        vec3(1.0, 0.3, 1.0),
        vec3(0.8, 0.8, 0.8),
        vec3(0.8, 0.2, 0.2),
        vec3(0.2, 0.8, 0.2),
        vec3(0.2, 0.2, 0.8),
        vec3(0.8, 0.8, 0.2),
        vec3(0.8, 0.5, 0.2),
        vec3(0.2, 0.8, 0.8),
        vec3(0.8, 0.2, 0.8),
        vec3(0.6, 0.6, 0.6),
        vec3(0.6, 0.1, 0.1),
        vec3(0.1, 0.6, 0.1),
        vec3(0.1, 0.1, 0.6),
        vec3(0.6, 0.6, 0.1),
        vec3(0.6, 0.4, 0.1),
        vec3(0.1, 0.6, 0.6),
        vec3(0.6, 0.1, 0.6),
        vec3(0.5, 0.5, 0.5),
        vec3(0.5, 0.0, 0.0),
        vec3(0.0, 0.5, 0.0),
        vec3(0.0, 0.0, 0.5),
        vec3(0.5, 0.5, 0.0),
        vec3(0.5, 0.3, 0.0),
        vec3(0.0, 0.5, 0.5),
        vec3(0.5, 0.0, 0.5),
        vec3(0.4, 0.4, 0.4)
    );
    return colors[cascade];
}

// Cheap per-fragment hash; decorrelates neighbouring pixels' tap patterns so the PCF
// kernel averages into a smooth gradient instead of banding into parallel lines.
float shadowHash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Projects p and averages the comparison result over a 16-sample golden-spiral PCF
// kernel. The non-uniform spiral spacing blurs edges without the banded intensity
// contours of a regular grid, and linear compare filtering turns each tap into a 2x2
// box. The kernel is rotated per fragment (by a hash of the screen position and
// cascade) so neighbouring pixels sample different offsets. Returns 1.0 (fully lit)
// when p projects outside the cascade's volume: a receiver outside the cascade has no
// shadow information, and forcing it into a comparison against the map's edge would
// manufacture false shadowed regions.
float sampleShadowCascade(int cascade, vec3 p) {
    // Blur radius is in world blocks; the cascade's box spans 2*box_radius across the
    // [0,1] UV range, so the same world radius gives the same penumbra in every cascade.
    float pcf_uv = shadow_params.blur_radius / (2.0 * shadow_params.box_radius[cascade]);

    vec4 proj = shadow_params.light_viewproj[cascade] * vec4(p, 1.0);
    vec3 ndc = proj.xyz / proj.w;

    if (ndc.x < -1.0 || ndc.x > 1.0 ||
        ndc.y < -1.0 || ndc.y > 1.0 ||
        ndc.z < 0.0 || ndc.z > 1.0) {
        return 1.0;
    }

    vec3 uv = vec3(ndc.xy * 0.5 + 0.5, ndc.z);

    const float golden_angle = 2.399963229728653;
    const int tap_count = 16;
    float rot = shadowHash(gl_FragCoord.xy + float(cascade) * 31.0) * 6.283185307179586;

    float shadow = 0.0;
    for (int i = 0; i < tap_count; i++) {
        float angle = rot + golden_angle * float(i);
        float radius = sqrt((float(i) + 0.5) / float(tap_count));
        vec2 offset = vec2(cos(angle), sin(angle)) * radius * pcf_uv;
        shadow += texture(shadow_map, vec4(uv.xy + offset, float(cascade), uv.z));
    }
    return shadow / float(tap_count);
}

// Returns the shadow factor in [0,1]: 1.0 fully lit, 0.0 fully shadowed.
// `normal` and `ndotl` feed the normal-offset bias; ndotl is dot(normal, sun_dir).
float sampleShadow(vec3 pos_rel, vec3 normal, float ndotl) {
    uint count = shadow_params.cascade_count;
    if (count == 0u) return 1.0;

    int cascade = shadowCascadeIndex(pos_rel);
    float d = length(pos_rel);

    // Normal-offset bias pushes the sample away from the surface along its OUTWARD
    // normal so the shadow texel the surface itself occupies does not self-shadow.
    // The shader's face_normals are inward (geometric), so the outward direction is
    // -normal: a top face (inward -Y) is pushed up toward the light. ndotl = dot(N,-L)
    // is the outward-normal term; the /max(ndotl, 0.2) divisor gives grazing surfaces
    // more bias. The cap scales with the texel so far cascades (coarse texels) get
    // enough bias to suppress acne while near cascades stay sub-voxel.
    float bias = shadow_params.normal_bias_scale * shadow_params.texel_world_size[cascade] / max(ndotl, 0.2);
    bias = min(bias, shadow_params.texel_world_size[cascade] * 3.0);
    vec3 p = pos_rel - normal * bias;

    float factor = sampleShadowCascade(cascade, p);

    // Blend band: cross-fade with the next cascade around each split so the texel size
    // change does not show a hard seam. The cross-fade completes exactly at the split
    // (t = 1), matching the point where shadowCascadeIndex flips over to the next
    // cascade, so the factor is continuous across the boundary.
    if (cascade < int(count) - 1) {
        float split = shadow_params.split_radius[cascade];
        float band = split * shadow_params.blend_fraction;
        float t = smoothstep(split - band, split, d);
        float next_factor = sampleShadowCascade(cascade + 1, p);
        factor = mix(factor, next_factor, t);
    }

    // Far fade: beyond the last split the map only covers the sphere, so fade to lit.
    if (d > shadow_params.fade_start) {
        float fade = 1.0 - smoothstep(shadow_params.fade_start, shadow_params.fade_end, d);
        factor = mix(1.0, factor, fade);
    }

    return mix(1.0, factor, shadow_params.shadow_strength);
}

#endif
