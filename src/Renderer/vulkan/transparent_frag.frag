#version 460 core
#extension GL_EXT_nonuniform_qualifier : require

layout(early_fragment_tests) in;

layout(location = 0) out vec4 outAccum;
layout(location = 1) out vec4 outReveal;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 fragpos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(location = 7) in float view_space_depth;
layout(set = 0, binding = 0) uniform sampler2D textures[];
layout(set = 1, binding = 0) uniform sampler2D opaque_depth_texture;

struct PushConstants {
    mat4 projview;
    vec3 sun_dir;
    float time;
};

layout(push_constant) uniform PushConsts {
    PushConstants pc;
} push_consts_frag;

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

float calculate_weight(float linear_depth, float alpha) {
    float z = linear_depth;
    float tmp = 0.03 / (0.00001 + pow(z / 200.0, 4.0));
    return alpha * clamp(tmp, 0.01, 3000.0);
}

layout(constant_id = 0) const bool draw_surface = true;

void main()
{
    vec3 normal = face_normals[side];
    vec2 texcoords = vec2(in_coords[texcoord_axes[side][0]], in_coords[texcoord_axes[side][1]]) * 2.0;

    vec4 unlit_color = texture(textures[nonuniformEXT(block_array_layer)], (texcoords + 1.0) / 2.0);

    vec4 color = vec4((0.5 + max(dot(normal, sun_dir_norm), 0.0)) * unlit_color.rgb, unlit_color.a);

    float bg_depth_raw = texelFetch(opaque_depth_texture, ivec2(gl_FragCoord.xy), 0).r;
    float bg_depth_linear = (bg_depth_raw >= 0.9999999 || bg_depth_raw <= 0.0000001)
        ? 1000.0
        : (0.01 / max(bg_depth_raw, 1e-6));

    float volume_thickness = gl_FrontFacing ? max(bg_depth_linear - view_space_depth, 0.0) : (view_space_depth - bg_depth_linear);

    vec4 volume_color = texelFetch(textures[nonuniformEXT(block_array_layer)], ivec2(0, 0), 0);
    vec3 absorption = max(1.0 - volume_color.rgb, vec3(0.01));
    float density = 0.1;
    vec3 opticalDepth = volume_thickness * absorption * density;

    float wboit_reveal = 0.0;
    vec4 wboit_color = vec4(0.0);

    if (gl_FrontFacing && draw_surface) {
        float weight = calculate_weight(view_space_depth, color.a);
        wboit_color = vec4(color.rgb * color.a, color.a) * weight;
        wboit_reveal = color.a;
    }

    outAccum = vec4(opticalDepth, wboit_reveal);
    outReveal = wboit_color;
}
