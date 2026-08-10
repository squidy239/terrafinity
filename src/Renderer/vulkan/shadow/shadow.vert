#version 460 core
#extension GL_ARB_gpu_shader_int64 : require

#include "face_decode.glsl"

layout(push_constant) uniform PushConsts {
    mat4 light_viewproj;
    uint mesh_base;
} pc;

layout(location = 0) in uvec2 in_face_data;

struct MeshData {
    vec4 absolute_position;
    vec4 relative_position;
    float scale;
};

layout(std430, set = 0, binding = 0) readonly buffer MeshDataBuffer {
    MeshData meshes[];
};

void main() {
    uint64_t val = packUint2x32(in_face_data);
    MeshData mesh = meshes[gl_DrawID + pc.mesh_base];
    vec3 relative_position = mesh.relative_position.xyz;
    float scale = mesh.scale;
    const uint quad_indices[6] = uint[6](0u, 1u, 2u, 0u, 2u, 3u);
    uint local_vertex = quad_indices[gl_VertexIndex];

    uvec3 local_pos = decodePosition(val);
    uvec3 lengths = decodeLengths(val);
    uint side = decodeSide(val);

    vec3 coords = cube_faces[side][local_vertex];
    coords += ceil(coords) * lengths;
    coords *= scale;
    vec3 view_pos = coords + vec3(local_pos) * scale + relative_position;
    gl_Position = pc.light_viewproj * vec4(view_pos, 1.0);
}
