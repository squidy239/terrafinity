#version 460 core
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) out vec4 outAccum;
layout(location = 1) out vec4 outReveal;
layout(location = 2) out float outVolume;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 fragpos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
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

const uvec2 texcoord_axes[6] = uvec2[](
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

float calculate_weight(float screen_z, float alpha) {
    float depth_weight = max_weight * (screen_z * screen_z * screen_z);
    return alpha * max(min_weight, depth_weight);
}

layout(constant_id = 0) const bool draw_surface = true;

void main() {
    vec3 normal = face_normals[side];
    vec2 texcoords = vec2(in_coords[texcoord_axes[side][0]], in_coords[texcoord_axes[side][1]]) * 2.0;

    vec4 unlit_color = texture(textures[nonuniformEXT(block_array_layer)], (texcoords + 1.0) / 2.0);
    vec4 color = vec4((0.5 + max(dot(normal, sun_dir_norm), 0.0)) * unlit_color.rgb, unlit_color.a);

    float fragment_depth = 1.0 / gl_FragCoord.w;
    float bg_depth_raw = texelFetch(opaque_depth_texture, ivec2(gl_FragCoord.xy), 0).r;
    float bg_depth_linear = near_plane / bg_depth_raw;

    float dist_to_bg = min(bg_depth_linear - fragment_depth, max_optical_depth);
    float sign = gl_FrontFacing ? 1.0 : -1.0;

    MaterialGpu mat = materials[nonuniformEXT(block_array_layer)];
    vec3 absorption = max(vec3(1.0) - mat.volume_color, vec3(0.01));
    float td = clamp(dist_to_bg * mat.density * sign, -max_optical_depth, max_optical_depth);
    vec3 optical_depth = td * absorption;

    float surface_revealage = 0.0;
    vec4 surface_accum = vec4(0.0);

    if (bg_depth_linear >= fragment_depth && gl_FrontFacing && draw_surface) {
        vec3 view_dir = normalize(-fragpos);
        float NdotV = abs(dot(normal, view_dir));
        float fresnel = pow(1.0 - NdotV, mat.fresnel_power);
        float view_alpha = mix(color.a * mat.min_opacity, color.a, fresnel);

        float weight = calculate_weight(gl_FragCoord.z, view_alpha);
        surface_accum = vec4(color.rgb * view_alpha, view_alpha) * weight;
        surface_revealage = view_alpha;
    }

    outAccum = vec4(optical_depth, surface_revealage);
    outReveal = surface_accum;
    outVolume = td;
}
