#version 460 core
#extension GL_EXT_nonuniform_qualifier : require

layout(early_fragment_tests) in;

layout(location = 0) out vec4 frag_color;

layout(location = 1) in vec3 in_coords;
layout(location = 3) flat in vec3 sun_dir_norm;
layout(location = 4) flat in uint side;
layout(location = 5) flat in uint block_array_layer;
layout(location = 6) flat in float sun_day;
layout(set = 0, binding = 0) uniform sampler2D textures[];

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

void main()
{
    vec3 normal = face_normals[side];
    vec2 tex_coords = vec2(in_coords[tex_coord_axes[side][0]], in_coords[tex_coord_axes[side][1]]) * 2.0;

    frag_color = texture(textures[nonuniformEXT(block_array_layer)], (tex_coords + 1.0) / 2.0);
    float light = mix(0.3, 0.5, sun_day) + max(dot(normal, -sun_dir_norm), 0.0) * sun_day;
    frag_color = vec4(light * frag_color.rgb, frag_color.a);
}
