#version 460 core
#extension GL_ARB_gpu_shader_int64 : require

#include "face_decode.glsl"

struct PushConstants {
    mat4 projview;
    vec3 sun_dir;
    float time;
    uint mesh_base;
};

layout(push_constant) uniform PushConsts {
    PushConstants pc;
} push_consts;

layout(location = 0) in uvec2 in_face_data;

layout(location = 1) out vec3 out_coords;
layout(location = 2) out vec3 frag_pos;
layout(location = 3) flat out vec3 sun_dir_norm;
layout(location = 4) flat out uint side;
layout(location = 5) flat out uint block_array_layer;
layout(location = 6) flat out float sun_day;

struct MeshData {
    vec4 absolute_position;
    vec4 relative_position;
    float scale;
};

layout(std430, set = 1, binding = 0) readonly buffer MeshDataBuffer {
    MeshData meshes[];
};

float bouncingMod(float x, float n) {
    x = abs(x);
    float cycle     = floor(x / n);
    float remainder = mod(x, n);
    return (mod(cycle, 2.0) == 0.0) ? remainder : n - remainder;
}

void main() {
    uint64_t val = packUint2x32(in_face_data);
    MeshData mesh = meshes[gl_DrawID + push_consts.pc.mesh_base];

    vec3 relative_position = mesh.relative_position.xyz;
    float scale = mesh.scale;
    vec3 absolute_position = mesh.absolute_position.xyz;

    uvec3 local_pos = decodePosition(val);
    uvec3 lengths   = decodeLengths(val);
    uint block_type_local = decodeBlockType(val);
    side = decodeSide(val);
    block_array_layer = block_type_local;

    // 4-vertex triangle strip per quad: 0=(-0.5,-0.5), 1=(+W,-0.5), 2=(-0.5,+H), 3=(+W,+H)
    // No overdraw, no clip distance, no index buffer.
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

    vec3 local_frag_coords = vec3(local_pos) * scale + coords;
    frag_pos = local_frag_coords + relative_position;
    vec3 absolute_frag_pos = local_frag_coords + absolute_position;
    sun_dir_norm = normalize(push_consts.pc.sun_dir);
    sun_day = smoothstep(-0.1, 0.25, sun_dir_norm.y);

    // Dense EnumIndexer index of water. EnumIndexer sorts by tag VALUE (fine_grass2045=0, null=1, air=2, water4095=3), not decl order. Keep in sync with src/world/Block.zig.
    const uint water_block_type = 3u;
    if ((local_pos + absolute_position).y == 0.0 && block_type_local == water_block_type) {
        float speed = 0.1;
        float t = 1.0 + push_consts.pc.time;
        float safe_y = max(abs(absolute_frag_pos.y), 1e-10);
        float safe_z = max(abs(absolute_frag_pos.z), 1e-10);
        float p = 1.0 + bouncingMod(
            absolute_frag_pos.x * absolute_frag_pos.y * absolute_frag_pos.z * (absolute_frag_pos.x / (safe_y * safe_z)) *
            (sin(absolute_frag_pos.x) * sin(absolute_frag_pos.y) * sin(absolute_frag_pos.z)),
            400.0) / 400.0;
        coords.y -= bouncingMod(p * t * speed, 0.4);
        coords.y = max(coords.y, -0.5);
    }

    out_coords = coords;
    vec3 view_pos = coords + vec3(local_pos) * scale + relative_position;
    gl_Position = push_consts.pc.projview * vec4(view_pos, 1.0);
}
