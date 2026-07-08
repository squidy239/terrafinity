#version 460 core

// Early fragment tests enable the GPU to discard occluded fragments before
// running the fragment shader. Without this, the unconditional gl_FragDepth
// write disables early-Z, wasting shader throughput on hidden fragments.
// When draw_over != 0, the depth value is modified, which means late-Z handles
// the updated depth — but the common case (draw_over == 0) benefits from early-Z.
layout(early_fragment_tests) in;

layout(location = 0) out vec4 frag_color;

layout(location = 1) in vec3 in_coords;
layout(location = 2) in vec3 fragpos;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(binding = 1) uniform sampler2DArray texture_array;
layout(location = 6) flat in float scale;

struct PushConstants {
    mat4 projview;
    vec3 sun_dir;
    float time;
    int draw_over;
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

void main()
{
    vec3 normal = face_normals[side];
    vec2 texcoords = vec2(in_coords[texcoord_axes[side][0]], in_coords[texcoord_axes[side][1]]) * 2.0;

    frag_color = texture(texture_array, vec3((texcoords + 1.0) / 2.0, float(block_array_layer)));
    frag_color = vec4((0.5 + max(dot(normal, sun_dir_norm), 0.0)) * frag_color.rgb, frag_color.a);
    if (frag_color.a < 0.01) discard;

    gl_FragDepth = gl_FragCoord.z / (push_consts_frag.pc.draw_over != 0 ? pow(max(1.0, scale), 8.0) : 1.0);
}
