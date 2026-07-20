#version 460 core
#extension GL_ARB_gpu_shader_int64 : require

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
layout(location = 2) out vec3 fragpos;
layout(location = 3) flat out vec3 sun_dir_norm;
layout(location = 4) flat out uint side;
layout(location = 5) flat out uint block_array_layer;

struct MeshData {
    vec4 absolute_position;
    vec4 relative_position;
    float scale;
};

layout(std430, set = 1, binding = 0) readonly buffer MeshDataBuffer {
    MeshData meshes[];
};

const uint CHUNK_SIZE = 32u;
const uint COORD_MASK = CHUNK_SIZE - 1u;

uint decodeBlockType(uint64_t val) {
    return uint(val & 0xFFFFu);
}

uvec3 decodeLengths(uint64_t val) {
    return uvec3(
        uint(val >> 26u) & COORD_MASK,
        uint(val >> 21u) & COORD_MASK,
        uint(val >> 16u) & COORD_MASK
    );
}

uvec3 decodePosition(uint64_t val) {
    return uvec3(
        uint(val >> 41u) & COORD_MASK,
        uint(val >> 36u) & COORD_MASK,
        uint(val >> 31u) & COORD_MASK
    );
}

uint decodeSide(uint64_t val) {
    return uint(val >> 46u) & 0x7u;
}

const vec3 CUBE_FACES[6][4] = {
    { vec3( 0.5, -0.5,  0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5, -0.5, -0.5) },
    { vec3(-0.5, -0.5, -0.5), vec3(-0.5,  0.5, -0.5), vec3(-0.5,  0.5,  0.5), vec3(-0.5, -0.5,  0.5) },
    { vec3(-0.5,  0.5,  0.5), vec3(-0.5,  0.5, -0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5,  0.5,  0.5) },
    { vec3(-0.5, -0.5, -0.5), vec3(-0.5, -0.5,  0.5), vec3( 0.5, -0.5,  0.5), vec3( 0.5, -0.5, -0.5) },
    { vec3(-0.5, -0.5,  0.5), vec3(-0.5,  0.5,  0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5, -0.5,  0.5) },
    { vec3(-0.5,  0.5, -0.5), vec3(-0.5, -0.5, -0.5), vec3( 0.5, -0.5, -0.5), vec3( 0.5,  0.5, -0.5) }
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
    const uint quad_indices[6] = uint[6](0u, 1u, 2u, 0u, 2u, 3u);
    uint local_vertex = quad_indices[gl_VertexIndex];
    vec3 absolute_position = mesh.absolute_position.xyz;

    uvec3 local_pos = decodePosition(val);
    uvec3 lengths   = decodeLengths(val);
    uint block_type_local = decodeBlockType(val);
    side          = decodeSide(val);
    block_array_layer = block_type_local;

    vec3 coords = CUBE_FACES[side][local_vertex];
    coords += ceil(coords) * lengths;
    coords *= scale;
    vec3 local_fragcoords = vec3(local_pos) * scale + coords;
    fragpos = local_fragcoords + relative_position;
    vec3 absolute_fragpos = local_fragcoords + absolute_position;
    sun_dir_norm  = normalize(push_consts.pc.sun_dir);

    // TODO: Replace hardcoded surface animation with a data-driven block material system
    if ((local_pos + absolute_position).y == 0.0 && block_type_local == 3u) {
        float speed = 0.1;
        float t     = 1.0 + push_consts.pc.time;
        float safe_y = max(abs(absolute_fragpos.y), 1e-10);
        float safe_z = max(abs(absolute_fragpos.z), 1e-10);
        float p     = 1.0 + bouncingMod(
            absolute_fragpos.x * absolute_fragpos.y * absolute_fragpos.z * (absolute_fragpos.x / (safe_y * safe_z)) *
            (sin(absolute_fragpos.x) * sin(absolute_fragpos.y) * sin(absolute_fragpos.z)),
            400.0) / 400.0;
        coords.y -= bouncingMod(p * t * speed, 0.4);
        coords.y = max(coords.y, -0.5);
    }

    out_coords = coords;
    vec3 view_pos = coords + vec3(local_pos) * scale + relative_position;
    gl_Position = push_consts.pc.projview * vec4(view_pos, 1.0);
}
