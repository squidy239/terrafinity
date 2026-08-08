#ifndef SHADOW_GLSL
#define SHADOW_GLSL

const int MAX_CASCADES = 4;

// Set 2 is the shared push-descriptor set, present in both the opaque and transparent
// pipelines. Binding 0 is the opaque depth sampler (transparent only; NULL for opaque),
// binding 1 is the shadow depth array with a comparison sampler, binding 2 the params.
layout(set = 2, binding = 1) uniform sampler2DArrayShadow shadow_map;
layout(set = 2, binding = 2, std430) readonly buffer ShadowParamsBuffer {
    mat4 light_viewproj[MAX_CASCADES];
    vec4 split_radius;
    vec4 texel_world_size;
    vec4 box_radius;
    vec4 depth_bias_constant;
    vec4 normal_bias_scale;
    vec4 pcf_radius_texels;
    float blend_fraction;
    float fade_start;
    float fade_end;
    uint cascade_count;
    float shadow_strength;
    uint debug_colors;
    float _pad[2];
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
    vec3 colors[4] = vec3[4](
        vec3(1.0, 0.3, 0.3),
        vec3(0.3, 1.0, 0.3),
        vec3(0.3, 0.3, 1.0),
        vec3(1.0, 1.0, 0.3)
    );
    return colors[cascade];
}

// Projects p and averages the comparison result over a 3x3 PCF kernel. Linear compare
// filtering turns each tap into a 2x2 box, so the effective kernel is a 4x4 blur.
// Returns 1.0 (fully lit) when p projects outside the cascade's volume: a receiver
// outside the cascade has no shadow information, and forcing it into a comparison
// against the map's edge would manufacture false shadowed regions.
float sampleShadowCascade(int cascade, vec3 p) {
    float texel_uv = shadow_params.texel_world_size[cascade] / (2.0 * shadow_params.box_radius[cascade]);
    float pcf_uv = shadow_params.pcf_radius_texels[cascade] * texel_uv;

    vec4 proj = shadow_params.light_viewproj[cascade] * vec4(p, 1.0);
    vec3 ndc = proj.xyz / proj.w;

    if (ndc.x < -1.0 || ndc.x > 1.0 ||
        ndc.y < -1.0 || ndc.y > 1.0 ||
        ndc.z < 0.0 || ndc.z > 1.0) {
        return 1.0;
    }

    vec3 uv = vec3(ndc.xy * 0.5 + 0.5, ndc.z);

    float shadow = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 offset = vec2(float(dx) * pcf_uv, float(dy) * pcf_uv);
            shadow += texture(shadow_map, vec4(uv.xy + offset, float(cascade), uv.z));
        }
    }
    return shadow / 9.0;
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
    float bias = shadow_params.normal_bias_scale[cascade] * shadow_params.texel_world_size[cascade] / max(ndotl, 0.2);
    bias = min(bias, shadow_params.texel_world_size[cascade] * 3.0);
    vec3 p = pos_rel - normal * bias;

    float factor = sampleShadowCascade(cascade, p);

    // Blend band: cross-fade with the next cascade around each split so the texel size
    // change does not show a hard seam. The two cascades may contain the same region at
    // different streaming LODs if a refinement boundary lands in the band — a brief,
    // transient ghosted shadow that is the honest cost of this design.
    if (cascade < int(count) - 1) {
        float split = shadow_params.split_radius[cascade];
        float band = split * shadow_params.blend_fraction;
        float t = smoothstep(split - band, split + band, d);
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
