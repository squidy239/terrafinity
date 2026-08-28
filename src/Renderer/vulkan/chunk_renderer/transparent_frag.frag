#version 460 core
#extension GL_EXT_nonuniform_qualifier : require

#include "shadow.glsl"

layout(location = 0) out vec4 out_accum;
layout(location = 1) out vec4 out_reveal;
layout(location = 2) out float out_volume;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 frag_pos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(location = 6) flat in float sun_day;
layout(set = 0, binding = 0) uniform sampler2D textures[];
layout(set = 2, binding = 0) uniform sampler2D opaque_depth_texture;

struct MaterialGpu {
    float density;
    float fresnel_power;
    float min_opacity;
    vec3 volume_color;
};

layout(set = 3, binding = 0, std430) readonly buffer Materials {
    MaterialGpu materials[];
};

const vec3 face_normals[6] = vec3[](
    vec3(-1.0,  0.0,  0.0),
    vec3( 1.0,  0.0,  0.0),
    vec3( 0.0, -1.0,  0.0),
    vec3( 0.0,  1.0,  0.0),
    vec3( 0.0,  0.0, -1.0),
    vec3( 0.0,  0.0,  1.0)
);

const uvec2 tex_coord_axes[6] = uvec2[](
    uvec2(1, 2),
    uvec2(1, 2),
    uvec2(0, 2),
    uvec2(0, 2),
    uvec2(0, 1),
    uvec2(0, 1)
);

const float max_weight = 3000.0;
const float min_weight = 1e-2;
const float max_optical_depth = 64000.0;
const float near_plane = 0.01;
const float absorption_floor = 0.01;
const float ambient_min = 0.3;
const float ambient_max = 0.5;
// Reference distance for sky pixels, which hold the cleared depth 0.0 and
// linearize to infinity. A finite shared reference lets an entry/exit pair
// cancel to their true thickness instead of both saturating to zero. Real
// backgrounds are never clamped: volumes can sit far beyond this (planet
// scale) and must integrate against their true distance. Sky-referenced
// distances beyond sky_dist_max clamp symmetrically so distant pairs cancel
// cleanly to zero instead of leaving f16 quantization noise.
const float sky_dist = 256.0;
const float sky_dist_max = 2048.0;

float calculateWeight(float screen_z, float alpha) {
    float depth_weight = max_weight * (screen_z * screen_z * screen_z);
    return alpha * max(min_weight, depth_weight);
}

layout(constant_id = 0) const bool draw_surface = true;

void main() {
    vec3 normal = face_normals[side];
    vec2 tex_coords = vec2(in_coords[tex_coord_axes[side][0]], in_coords[tex_coord_axes[side][1]]) * 2.0;

    vec4 unlit_color = texture(textures[nonuniformEXT(block_array_layer)], (tex_coords + 1.0) / 2.0);
    // face_normals are inward (see fragshader.frag), so Lambert uses -sun_dir.
    float ndl = max(dot(normal, -sun_dir_norm), 0.0);
    float light = mix(ambient_min, ambient_max, sun_day) + ndl * sun_day;
    if (shadow_params.cascade_count != 0u) {
        // The shadowed light applies to the surface term only; the volume's
        // absorption must stay position-independent (see below).
        if (shadow_params.debug_colors != 0u) {
            unlit_color.rgb *= cascadeDebugColor(shadowCascadeIndex(frag_pos));
        } else {
            float shadow = sampleShadow(frag_pos, normal, ndl);
            light = mix(ambient_min, ambient_max, sun_day) + ndl * sun_day * shadow;
        }
    }
    vec4 color = vec4(light * unlit_color.rgb, unlit_color.a);

    float fragment_depth = 1.0 / gl_FragCoord.w;
    float bg_depth_raw = texelFetch(opaque_depth_texture, ivec2(gl_FragCoord.xy), 0).r;
    float bg_depth_linear_raw = near_plane / bg_depth_raw;
    bool bg_is_sky = bg_depth_raw == 0.0;
    // Only the sky is infinite; every real background keeps its true distance
    // no matter how far, or volumes beyond the reference lose their depth.
    float bg_depth_linear = bg_is_sky ? sky_dist : bg_depth_linear_raw;

    // The depths above are eye-Z projections; scaling by the ray slant turns
    // them into true path length so off-axis pixels stop undercounting.
    float slant = length(frag_pos) / fragment_depth;
    float dist_to_bg = (bg_depth_linear - fragment_depth) * slant;
    if (bg_is_sky) dist_to_bg = clamp(dist_to_bg, -sky_dist_max, sky_dist_max);
    float sign = gl_FrontFacing ? 1.0 : -1.0;

    MaterialGpu mat = materials[nonuniformEXT(block_array_layer)];
    // Absorption is a material property, not a lighting term: entry and exit
    // faces sample light at different points, and only a position-independent
    // absorption cancels exactly. Day/night is applied to the scatter color in
    // the composite pass instead.
    vec3 absorption = max(vec3(1.0) - mat.volume_color, vec3(absorption_floor));
    float td = clamp(dist_to_bg * mat.density * sign, -max_optical_depth, max_optical_depth);
    vec3 optical_depth = td * absorption;

    float surface_revealage = 0.0;
    vec4 surface_accum = vec4(0.0);

    // The unclamped reference keeps the surface term for water farther than
    // sky_dist; the clamp exists only for the volume integral's f16 range.
    if (bg_depth_linear_raw >= fragment_depth && gl_FrontFacing && draw_surface) {
        vec3 view_dir = normalize(-frag_pos);
        float n_dot_v = abs(dot(normal, view_dir));
        float fresnel = pow(1.0 - n_dot_v, mat.fresnel_power);
        float view_alpha = mix(color.a * mat.min_opacity, color.a, fresnel);

        float weight = calculateWeight(gl_FragCoord.z, view_alpha);
        surface_accum = vec4(color.rgb * view_alpha, view_alpha) * weight;
        surface_revealage = view_alpha;
    }

    out_accum = vec4(optical_depth, surface_revealage);
    out_reveal = surface_accum;
    out_volume = td;
}
