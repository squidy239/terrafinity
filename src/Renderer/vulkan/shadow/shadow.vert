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

    uvec3 local_pos = decodePosition(val);
    uvec3 lengths = decodeLengths(val);
    uint side = decodeSide(val);

    uint a0 = face_axes[side][0];
    uint a1 = face_axes[side][1];
    uint a2 = 3u - a0 - a1;
    bool swapped = face_swap[side];
    uint u_axis = swapped ? a1 : a0;
    uint v_axis = swapped ? a0 : a1;

    float u_len = float(lengths[u_axis]);
    float v_len = float(lengths[v_axis]);

    vec3 anchor = vec3(0.0);
    anchor[a0] = -0.5;
    anchor[a1] = -0.5;
    anchor[a2] = face_sign[side];

    vec3 coords = anchor;
    if (gl_VertexIndex == 1u) coords[u_axis] += 1.0 + u_len;
    else if (gl_VertexIndex == 2u) coords[v_axis] += 1.0 + v_len;
    else if (gl_VertexIndex == 3u) {
        coords[u_axis] += 1.0 + u_len;
        coords[v_axis] += 1.0 + v_len;
    }
    coords *= scale;

    vec3 view_pos = coords + vec3(local_pos) * scale + relative_position;
    gl_Position = pc.light_viewproj * vec4(view_pos, 1.0);
}
